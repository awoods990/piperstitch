import Foundation
import Vapor
import StitchPilotCore

func routes(_ app: Application) throws {
    let api = app.grouped("api", "v1")

    // The commit this build came from, so "is my engine change live?" is
    // a question with an answer from outside. Railway sets the variable on
    // every deploy; it is absent when running locally.
    api.get("health") { _ in
        var body = ["status": "ok"]
        if let sha = Environment.get("RAILWAY_GIT_COMMIT_SHA"), !sha.isEmpty {
            body["build"] = String(sha.prefix(7))
        }
        if let when = Environment.get("RAILWAY_DEPLOYMENT_ID"), !when.isEmpty {
            body["deployment"] = String(when.prefix(8))
        }
        return body
    }

    // Accounts, billing and saved projects (see Auth.swift). The engine
    // routes below require a signed-in, entitled account whenever License
    // Admin is configured.
    authRoutes(api)

    // Server-to-server: License Admin re-digitizes a saved project to show
    // support staff the stitch preview and parameters. Guarded by the same
    // shared key License Admin's own web API uses.
    api.post("internal", "digitize") { req -> DigitizeResponse in
        let key = req.application.auth.webAPIKey
        guard req.application.auth.enabled, !key.isEmpty, req.headers.first(name: "X-API-Key") == key else {
            throw Abort(.unauthorized, reason: "Invalid API key")
        }
        let body = try req.content.decode(DigitizeRequest.self)
        let started = Date()
        let (plan, colors, report) = try await Engine.run { () throws -> (StitchPlan, [ThreadColor], EmbroideryReadinessReport) in
            let (plan, colors) = try DigitizePipeline.flattenWithColors(body.document)
            let report = QualityAnalyzer.analyze(plan, hoopWidthMM: body.hoopWidthMM, hoopHeightMM: body.hoopHeightMM, document: body.document)
            return (plan, colors, report)
        }
        return DigitizeResponse(plan: WirePlan(plan), colors: colors, report: WireReport(report),
                                stats: WireStats(plan),
                                elapsedMS: Int(Date().timeIntervalSince(started) * 1000),
                                candidate: CandidateAssessment.assess(report: report))
    }

    // Server-to-server: PiperStitch Proofs exports the machine files for a
    // proof version from the exact document it rendered, so the released
    // file and the proof share their bytes. Same key guard as above; same
    // writer as the signed-in `export` route below.
    api.post("internal", "export", ":format") { req -> Response in
        let key = req.application.auth.webAPIKey
        guard req.application.auth.enabled, !key.isEmpty, req.headers.first(name: "X-API-Key") == key else {
            throw Abort(.unauthorized, reason: "Invalid API key")
        }
        guard let format = req.parameters.get("format").flatMap({ ExportFormat(rawValue: $0.lowercased()) }) else {
            throw Abort(.notFound, reason: "Unknown export format. Use one of: \(ExportFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let body = try req.content.decode(ExportRequest.self)
        let data = try await Engine.run { () throws -> Data in
            let (plan, colors) = try DigitizePipeline.flattenWithColors(body.document)
            return try format.write(plan, designName: body.document.name, threadColors: colors.map(\.rgb))
        }
        let response = Response(status: .ok, body: .init(data: data))
        response.headers.contentType = HTTPMediaType(type: "application", subType: "octet-stream")
        return response
    }
    // Server-to-server: PiperStitch Proofs turns a customer's artwork into
    // a first-pass digitized project in the shop's account the moment it
    // arrives (import + build in one call, the same two steps the web app
    // does interactively). Body: RGBA pixels (`kind=raster`, dimensions in
    // the query) or SVG text (`kind=svg`). Returns the StitchDocument;
    // Proofs saves it through License Admin's projects API.
    api.on(.POST, "internal", "build-from-artwork", body: .collect(maxSize: "48mb")) { req -> DocumentResponse in
        let key = req.application.auth.webAPIKey
        guard req.application.auth.enabled, !key.isEmpty, req.headers.first(name: "X-API-Key") == key else {
            throw Abort(.unauthorized, reason: "Invalid API key")
        }
        struct Query: Content {
            var kind: String; var name: String; var widthMM: Double; var heightMM: Double?
            var width: Int?; var height: Int?; var maxColors: Int?; var fabricType: FabricType?
        }
        let q = try req.query.decode(Query.self)
        guard q.widthMM > 0, var buffer = req.body.data, let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            throw Abort(.badRequest, reason: "A finished width and artwork bytes are required.")
        }
        let (shapes, fillColors): ([VectorShape], [RGBColor?]) = try await Engine.run {
            if q.kind == "svg" {
                let r = try SVGImporter.importShapes(from: Data(bytes))
                return (r.shapes, r.fillColors)
            }
            guard let w = q.width, let h = q.height, w > 1, h > 1, w * h <= 16_000_000, bytes.count == w * h * 4 else {
                throw Abort(.badRequest, reason: "Raster artwork needs width/height and exactly width*height*4 bytes of RGBA.")
            }
            let r = try ImageImporter.importShapes(rgba: bytes, width: w, height: h, maxColors: q.maxColors ?? ColorQuantizationPreset.normalEmbroidery.defaultMaxColors)
            return (r.shapes, r.fillColors)
        }
        var bounds = BoundingBox.empty
        for shape in shapes { bounds = bounds.union(shape.boundingBox) }
        guard !bounds.isEmpty, bounds.width > 0, bounds.height > 0 else { throw Abort(.unprocessableEntity, reason: "No usable shapes in the artwork.") }
        let source = ImportedSource(shapes: shapes, fillColors: fillColors, bounds: bounds, pixelWidth: q.kind == "svg" ? 0 : (q.width ?? 0), pixelHeight: q.kind == "svg" ? 0 : (q.height ?? 0))
        let heightMM = q.heightMM ?? (q.widthMM * bounds.height / bounds.width)
        let document = try await Engine.run {
            DocumentBuilder.build(source: source, name: q.name, widthMM: q.widthMM, heightMM: heightMM,
                                  matchToThreadLibrary: true, palette: nil, fabricType: q.fabricType ?? .standard)
        }
        return DocumentResponse(document: document)
    }
    let engine = api.grouped(EntitlementGate())
    editRoutes(engine)

    api.get("catalog") { _ -> CatalogResponse in
        CatalogResponse(
            hoops: HoopProfile.commonHoops.map { CatalogSize(name: $0.name, widthMM: $0.widthMM, heightMM: $0.heightMM) },
            garmentPresets: GarmentSizePreset.standardPresets.map { CatalogSize(name: $0.name, widthMM: $0.widthMM, heightMM: $0.heightMM) },
            fabrics: FabricType.allCases.map { CatalogFabric(id: $0.rawValue, displayName: $0.displayName, shortName: $0.shortName, isHeadwear: $0.isHeadwear, stabilizer: $0.stabilizerAdvice) },
            colorPresets: ColorQuantizationPreset.allCases.map { CatalogColorPreset(id: $0.rawValue, maxColors: $0.defaultMaxColors) },
            threadPalette: ThreadLibrary.genericPalette,
            stitchTypes: StitchType.allCases.map(\.rawValue),
            fillPatterns: FillPattern.allCases.map { CatalogNamed(id: $0.rawValue, displayName: $0.displayName) },
            underlayTypes: UnderlayType.allCases.map(\.rawValue),
            exportFormats: ExportFormat.allCases.map(\.rawValue),
            defaultParameters: StitchGenerationParameters(),
            minimumCapHeightMM: Dictionary(uniqueKeysWithValues: ThreadWeight.allCases.map {
                ($0.rawValue, TextLineFinder.minimumCapHeightMM(for: $0))
            })
        )
    }

    // Raster import. The body is straight-alpha RGBA, row-major, top row
    // first -- exactly what a browser <canvas> getImageData() hands back --
    // optionally gzip-encoded (Content-Encoding: gzip; Vapor inflates it
    // before we see it). Dimensions ride in the query. This is the one
    // place the web edition diverges from the Mac app's file-in path:
    // decoding happens in the browser, everything after that is the same
    // code (`ImageImporter.importShapes(rgba:...)`).
    engine.on(.POST, "import", "raster", body: .collect(maxSize: "48mb")) { req -> ImportResponse in
        struct Query: Content { var width: Int; var height: Int; var maxColors: Int?; var hoopWidthMM: Double?; var hoopHeightMM: Double? }
        let q = try req.query.decode(Query.self)
        guard q.width > 1, q.height > 1, q.width * q.height <= 16_000_000 else {
            throw Abort(.badRequest, reason: "Image dimensions out of range.")
        }
        guard var buffer = req.body.data, buffer.readableBytes == q.width * q.height * 4,
              let pixels = buffer.readBytes(length: buffer.readableBytes) else {
            throw Abort(.badRequest, reason: "Body must be exactly width*height*4 bytes of RGBA.")
        }
        let maxColors = q.maxColors ?? ColorQuantizationPreset.normalEmbroidery.defaultMaxColors
        let result = try await Engine.run {
            try ImageImporter.importShapes(rgba: pixels, width: q.width, height: q.height, maxColors: maxColors)
        }
        return importResponse(shapes: result.shapes, fillColors: result.fillColors,
                              pixelWidth: result.pixelWidth, pixelHeight: result.pixelHeight,
                              hoopWidthMM: q.hoopWidthMM, hoopHeightMM: q.hoopHeightMM,
                              backgroundColor: result.backgroundColor.flatMap { $0.isPreviewGround ? $0 : nil },
                              textLines: TextLineFinder.find(shapes: result.shapes, fillColors: result.fillColors, imageHeightPixels: result.pixelHeight),
                              candidate: CandidateAssessment.assess(importResult: result))
    }

    // SVG import: the file's text, as-is.
    engine.on(.POST, "import", "svg", body: .collect(maxSize: "16mb")) { req -> ImportResponse in
        struct Query: Content { var hoopWidthMM: Double?; var hoopHeightMM: Double? }
        let q = try req.query.decode(Query.self)
        guard var buffer = req.body.data, let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            throw Abort(.badRequest, reason: "Empty SVG.")
        }
        let data = Data(bytes)
        let result = try await Engine.run { try SVGImporter.importShapes(from: data) }
        return importResponse(shapes: result.shapes, fillColors: result.fillColors, pixelWidth: 0, pixelHeight: 0,
                              hoopWidthMM: q.hoopWidthMM, hoopHeightMM: q.hoopHeightMM,
                              textLines: TextLineFinder.find(shapes: result.shapes, fillColors: result.fillColors, imageHeightPixels: 0))
    }

    // Source shapes + the user's answers (size, fabric, palette) -> a
    // document of classified objects. Also how a size change on a fresh
    // import is applied: same call, new size.
    engine.post("build") { req -> DocumentResponse in
        let body = try req.content.decode(BuildRequest.self)
        guard body.widthMM > 0, body.heightMM > 0, !body.source.shapes.isEmpty else {
            throw Abort(.badRequest, reason: "A size and at least one shape are required.")
        }
        let document = try await Engine.run {
            DocumentBuilder.build(source: body.source, name: body.name, widthMM: body.widthMM, heightMM: body.heightMM,
                                  matchToThreadLibrary: body.matchToThreadLibrary ?? true, palette: body.palette,
                                  fabricType: body.fabricType ?? .standard, threadWeight: body.threadWeight ?? .wt40,
                                  dropShapeIndices: body.dropShapeIndices, omittedTextLines: body.omittedTextLines)
        }
        return DocumentResponse(document: document)
    }

    // Resize a document that no longer has source shapes behind it (a
    // saved project), re-fitting from its own bounds.
    engine.post("resize") { req -> DocumentResponse in
        let body = try req.content.decode(ResizeRequest.self)
        guard body.widthMM > 0, body.heightMM > 0 else { throw Abort(.badRequest, reason: "Size must be positive.") }
        let document = try await Engine.run { DocumentBuilder.resize(body.document, widthMM: body.widthMM, heightMM: body.heightMM) }
        return DocumentResponse(document: document)
    }

    // The digitize step itself: document -> stitch plan + color sequence +
    // readiness report, all in one pass (see flattenWithColors).
    engine.post("digitize") { req -> DigitizeResponse in
        let body = try req.content.decode(DigitizeRequest.self)
        let started = Date()
        let (plan, colors, report) = try await Engine.run { () throws -> (StitchPlan, [ThreadColor], EmbroideryReadinessReport) in
            let (plan, colors) = try DigitizePipeline.flattenWithColors(body.document)
            let report = QualityAnalyzer.analyze(plan, hoopWidthMM: body.hoopWidthMM, hoopHeightMM: body.hoopHeightMM, document: body.document)
            return (plan, colors, report)
        }
        return DigitizeResponse(
            plan: WirePlan(plan),
            colors: colors,
            report: WireReport(report),
            stats: WireStats(plan),
            elapsedMS: Int(Date().timeIntervalSince(started) * 1000),
            candidate: CandidateAssessment.assess(report: report)
        )
    }

    // Machine file: re-flatten (0.4 s, and guarantees the file matches the
    // document rather than a stale plan) and encode.
    engine.post("export", ":format") { req -> Response in
        guard let format = req.parameters.get("format").flatMap({ ExportFormat(rawValue: $0.lowercased()) }) else {
            throw Abort(.notFound, reason: "Unknown export format. Use one of: \(ExportFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let body = try req.content.decode(ExportRequest.self)
        let document = body.document
        let data = try await Engine.run { () throws -> Data in
            let (plan, colors) = try DigitizePipeline.flattenWithColors(document)
            return try format.write(plan, designName: document.name, threadColors: colors.map(\.rgb))
        }
        let response = Response(status: .ok, body: .init(data: data))
        response.headers.contentType = HTTPMediaType(type: "application", subType: "octet-stream")
        let safeName = document.name.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
        response.headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"\(safeName).\(format.rawValue)\"")
        return response
    }
}

private func importResponse(shapes: [VectorShape], fillColors: [RGBColor?], pixelWidth: Int, pixelHeight: Int,
                            hoopWidthMM: Double?, hoopHeightMM: Double?, backgroundColor: RGBColor? = nil, textLines: [TextLine] = [],
                            candidate: CandidateAssessment? = nil) -> ImportResponse {
    var bounds = BoundingBox.empty
    for shape in shapes { bounds = bounds.union(shape.boundingBox) }
    let source = ImportedSource(shapes: shapes, fillColors: fillColors, bounds: bounds, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    let size = DocumentBuilder.recommendedSize(for: source, hoopWidthMM: hoopWidthMM, hoopHeightMM: hoopHeightMM)
    let aspect = bounds.height > 0 ? bounds.width / bounds.height : 1
    return ImportResponse(source: source, recommendedWidthMM: size.widthMM, recommendedHeightMM: size.heightMM, aspectRatio: aspect, backgroundColor: backgroundColor, textLines: textLines, candidate: candidate)
}

/// The same five machine formats `AppState.exportChoosingFormat` offers.
enum ExportFormat: String, CaseIterable {
    case dst, pes, exp, jef, vp3

    func write(_ plan: StitchPlan, designName: String, threadColors: [RGBColor]) throws -> Data {
        switch self {
        case .dst: return try DSTFormat.write(plan, designName: designName)
        case .exp: return try EXPFormat.write(plan, designName: designName)
        case .pes: return try PESFormat.write(plan, designName: designName, threadColors: threadColors)
        case .jef: return try JEFFormat.write(plan, designName: designName, threadColors: threadColors)
        case .vp3: return try VP3Format.write(plan, designName: designName, threadColors: threadColors)
        }
    }
}
