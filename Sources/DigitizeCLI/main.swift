import Foundation
import StitchPilotCore

// A no-GUI harness around the exact digitizing pipeline the app uses --
// see Package.swift's comment on this target for why it exists. Renders a
// PNG approximation of the sewn-out result via StitchRenderer alongside a
// quality report, so digitizing quality can be inspected and regression-
// tested without driving the SwiftUI app itself.
//
// Usage: DigitizeCLI <input file> <output.png> [widthMM] [heightMM] [maxColors] [pixelsPerMM]

setbuf(stdout, nil)

let args = CommandLine.arguments

if args.count >= 3, args[1] == "--validate-formats" {
    // One-off cross-validation pass: read every real-world DST/PES file
    // under a directory (e.g. a clone of EmbroidePy/samples) with
    // StitchPilot's own readers and report which fail. Not the normal
    // digitize-artwork path this tool otherwise exercises -- see
    // ThirdPartySampleTests.swift for the permanent, vendored-fixture
    // version of this same idea.
    let dir = URL(fileURLWithPath: args[2])
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var passed = 0, failed = 0
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let ext = file.pathExtension.lowercased()
        guard ext == "dst" || ext == "pes" else { continue }
        do {
            let data = try Data(contentsOf: file)
            let commands = ext == "dst" ? try DSTFormat.read(data).commands : try PESFormat.read(data).commands
            let stitchCount = commands.filter { if case .stitch = $0 { return true }; return false }.count
            let box = BoundingBox(points: commands.compactMap { $0.point })
            let sane = stitchCount > 0 && box.width > 0 && box.width < 1000 && box.height > 0 && box.height < 1000
            if sane {
                passed += 1
            } else {
                failed += 1
                print("SUSPECT \(file.lastPathComponent): stitches=\(stitchCount) box=\(box.width)x\(box.height)")
            }
        } catch {
            failed += 1
            print("FAIL \(file.lastPathComponent): \(error)")
        }
    }
    print("--- \(passed) passed, \(failed) failed/suspect ---")
    exit(failed == 0 ? 0 : 1)
}

/// A structural profile of a stitch plan, printed the same way for a file
/// we generated and for a professionally digitized one, so the two can be
/// compared number for number (see the "professional samples" entry in
/// DIGITIZING_ENGINE.md). Per colour run: stitch count, mean stitch length,
/// and the share of stitches that reverse direction against the previous
/// one -- a satin column reverses on every stitch (zigzag), a fill only at
/// row ends, a running stitch almost never -- which is enough to tell how
/// much of a design a digitizer chose to sew as satin without any object
/// information.
func printProfile(_ plan: StitchPlan) {
    var runs: [(stitches: Int, lengthSum: Double, reversals: Int, pairs: Int, lengths: [Double])] = []
    var current: (stitches: Int, lengthSum: Double, reversals: Int, pairs: Int, lengths: [Double]) = (0, 0, 0, 0, [])
    var last: Point2D? = nil
    var lastDir: Point2D? = nil
    var allLengths: [Double] = []
    for command in plan.commands {
        switch command {
        case .stitch(let p):
            current.stitches += 1
            if let l = last {
                let d = Point2D(p.x - l.x, p.y - l.y)
                let len = l.distance(to: p)
                if len > 0.05 {
                    current.lengthSum += len; current.lengths.append(len); allLengths.append(len)
                    if let ld = lastDir {
                        let dot = (d.x * ld.x + d.y * ld.y) / (len * max(1e-9, ld.distance(to: .zero)))
                        current.pairs += 1
                        if dot < -0.5 { current.reversals += 1 }
                    }
                    lastDir = d
                }
            }
            last = p
        case .jump(let p):
            last = p; lastDir = nil
        case .colorChange:
            runs.append(current); current = (0, 0, 0, 0, []); last = nil; lastDir = nil
        case .trim, .stop:
            last = nil; lastDir = nil
        case .end:
            break
        }
    }
    if current.stitches > 0 { runs.append(current) }
    let box = BoundingBox(points: plan.commands.compactMap { $0.point })
    let sorted = allLengths.sorted()
    func pct(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
    print(String(format: "Profile: %d stitches, %d colour runs, %d trims, %.1f x %.1f mm, %.0f mm thread",
                 plan.stitchCount, runs.count, plan.trimCount, box.width, box.height, plan.totalStitchLength))
    print(String(format: "  stitch length p10/p50/p90/max: %.2f / %.2f / %.2f / %.2f mm", pct(0.1), pct(0.5), pct(0.9), sorted.last ?? 0))
    let area = max(1, box.width * box.height)
    print(String(format: "  stitches per mm² of bbox: %.2f", Double(plan.stitchCount) / area))
    var satinish = 0
    for (i, r) in runs.enumerated() {
        let rev = r.pairs > 0 ? Double(r.reversals) / Double(r.pairs) : 0
        let mean = r.lengths.isEmpty ? 0 : r.lengthSum / Double(r.lengths.count)
        let kind = rev > 0.8 ? "satin-like" : rev > 0.25 ? "mixed" : mean > 2.0 && rev < 0.25 ? "fill/run" : "fill"
        if rev > 0.8 { satinish += r.stitches }
        print(String(format: "  run %2d: %6d st  mean %.2f mm  reversal %.0f%%  %@", i + 1, r.stitches, mean, rev * 100, kind))
    }
    print(String(format: "  satin-like share of stitches: %.0f%%", plan.stitchCount > 0 ? Double(satinish) / Double(plan.stitchCount) * 100 : 0))
}

if args.count >= 4, args[1] == "--analyze" {
    // Diagnostic: read a finished DST/PES (e.g. a professionally digitized
    // sample), print its structural profile, and render it with our own
    // renderer so it can sit beside our result for the same artwork.
    let inputURL = URL(fileURLWithPath: args[2])
    let outputURL = URL(fileURLWithPath: args[3])
    let ppm = args.count > 4 ? (Double(args[4]) ?? 12) : 12
    let data = try Data(contentsOf: inputURL)
    let ext = inputURL.pathExtension.lowercased()
    let decodedCommands = ext == "dst" ? try DSTFormat.read(data).commands : try PESFormat.read(data).commands
    let box = BoundingBox(points: decodedCommands.compactMap { $0.point })
    let margin = 3.0
    // The readers hand back document space (Y-down), so only a shift to a
    // positive origin is needed. If a machine file ever renders upside-down
    // here, that reader's Y sign is wrong -- see DSTFormat's coordinate note.
    let shifted = decodedCommands.map { command -> StitchCommand in
        switch command {
        case .stitch(let p): return .stitch(Point2D(p.x - box.minX + margin, p.y - box.minY + margin))
        case .jump(let p): return .jump(Point2D(p.x - box.minX + margin, p.y - box.minY + margin))
        default: return command
        }
    }
    let plan = StitchPlan(commands: shifted)
    print("=== \(inputURL.lastPathComponent) ===")
    printProfile(plan)
    // The readers don't carry thread colours, so each run gets a distinct
    // colour from a fixed palette: structure is what's being compared.
    let palette: [UInt32] = [0x2f5d3a, 0x8a2c2c, 0x2c4f8a, 0xc08a2a, 0x6a3a8a, 0x2a8a8a, 0x8a5a2a, 0x555555, 0xb04a8a, 0x4a8a3a]
    let runCount = plan.colorChangeCount + 1
    let colors = (0..<runCount).map { ThreadColor.generic(RGBColor(hex: palette[$0 % palette.count])) }
    var options = StitchRenderer.Options()
    options.pixelsPerMM = ppm
    guard let png = StitchRenderer.renderPNGData(plan, widthMM: box.width + 2 * margin, heightMM: box.height + 2 * margin, colors: colors, options: options) else {
        print("Render failed"); exit(1)
    }
    try png.write(to: outputURL)
    print("Wrote \(outputURL.path)")
    exit(0)
}

if args.count >= 3, args[1] == "--recommend-size" {
    // Diagnostic: what SizeRecommender would set as the initial Finished
    // Size for this file, matching AppState.importFile's own logic --
    // useful for checking real artwork without driving the GUI.
    let inputURL = URL(fileURLWithPath: args[2])
    let data = try Data(contentsOf: inputURL)
    let isSVG = inputURL.pathExtension.lowercased() == "svg"
    let rawShapes: [VectorShape] = isSVG
        ? try SVGImporter.importShapes(from: data).shapes
        : try ImageImporter.importShapes(from: data, maxColors: 8).shapes
    let recommended = SizeRecommender.recommendedWidthMM(for: rawShapes, currentWidthMM: 100)
    print("Recommended width for \(inputURL.lastPathComponent): \(recommended)mm")
    exit(0)
}

if args.count >= 3, args[1] == "--detect-text" {
    // Diagnostic: what TextDetector finds in a real raster file, without
    // driving the GUI's Add Lettering / review flow.
    let inputURL = URL(fileURLWithPath: args[2])
    let data = try Data(contentsOf: inputURL)
    let regions = try TextDetector.detectTextRegions(from: data)
    print("\(regions.count) text region(s) found in \(inputURL.lastPathComponent):")
    for region in regions {
        print("  \"\(region.text)\" confidence=\(String(format: "%.2f", region.confidence)) rotation=\(String(format: "%.1f", region.rotationDegrees))deg weight=\(region.suggestedWeight) box=(\(Int(region.boundingBoxPixels.minX)),\(Int(region.boundingBoxPixels.minY)))-(\(Int(region.boundingBoxPixels.maxX)),\(Int(region.boundingBoxPixels.maxY)))")
    }
    exit(0)
}

// --- Glyph column library --------------------------------------------------
// `--build-glyph-library <font.outlines.json> <out.columns.json> [capMM=22]`
// runs every glyph's outline (from web/scripts/export-glyph-outlines.mjs,
// cap height 1000 units, y down) through the satin generator at `capMM`
// and stores the resulting columns in units. `--glyph-sheet <columns.json>
// <out.png> [capMM=8] [text]` sews the library at a size and renders it
// for review. `--emit-glyph-data <dir> <out.swift>` embeds every
// *.columns.json in the directory as Swift source for the Core.
struct GlyphOutlineFile: Decodable {
    struct Glyph: Decodable { var advance: Double; var contours: [[[Double]]] }
    var fontID: String
    var capHeightUnits: Double
    var glyphs: [String: Glyph]
}

func glyphShape(_ glyph: GlyphOutlineFile.Glyph, capMM: Double, offset: Point2D) -> VectorShape {
    let scale = capMM / 1000
    return VectorShape(subPaths: glyph.contours.map { contour in
        SubPath(points: contour.map { Point2D($0[0] * scale + offset.x, $0[1] * scale + offset.y) }, closed: true)
    })
}

/// A glyph's contours as separate pieces: each outer contour with the
/// holes inside it (an "i" is a stem and a dot; a "%" three pieces; a
/// "B" one piece with two holes). Fed in as one shape the dot read as a
/// hole and sewed as an outlined box.
func glyphPieces(_ shape: VectorShape) -> [VectorShape] {
    let contours = shape.subPaths
    guard contours.count > 1 else { return [shape] }
    func contains(_ outer: [Point2D], _ inner: [Point2D]) -> Bool {
        guard let p = inner.first else { return false }
        return PolygonGeometry.pointInPolygons(p, polygons: [outer])
    }
    // Depth = how many other contours enclose it: even is an outer, odd a hole.
    let depth = contours.indices.map { i in contours.indices.filter { $0 != i && contains(contours[$0].points, contours[i].points) }.count }
    var pieces: [VectorShape] = []
    for i in contours.indices where depth[i] % 2 == 0 {
        var subPaths = [contours[i]]
        for j in contours.indices where depth[j] == depth[i] + 1 && contains(contours[i].points, contours[j].points) {
            subPaths.append(contours[j])
        }
        pieces.append(VectorShape(subPaths: subPaths))
    }
    return pieces.isEmpty ? [shape] : pieces
}

func glyphParameters() -> StitchGenerationParameters {
    var parameters = StitchGenerationParameters()
    parameters.allowBranchingSatin = true
    parameters.minSatinWidthMM = min(parameters.minSatinWidthMM, StitchTypeClassifier.strokeMinimumSatinWidthMM)
    return parameters
}

if args.count >= 4, args[1] == "--build-glyph-library" {
    let outlines = try JSONDecoder().decode(GlyphOutlineFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let capMM = args.count > 4 ? (Double(args[4]) ?? 22) : 22
    let parameters = glyphParameters()
    // Work in positive millimetre space: the glyph frame has capitals at
    // negative y.
    let offset = Point2D(5, capMM * 1.6)
    var glyphs: [String: GlyphColumns] = [:]
    var missing: [String] = []
    var stitchTotal = 0
    for (character, glyph) in outlines.glyphs.sorted(by: { $0.key < $1.key }) {
        let shape = glyphShape(glyph, capMM: capMM, offset: offset)
        if ProcessInfo.processInfo.environment["DEBUG_COLUMNS"] != nil { print("  glyph \(character): \(shape.subPaths.count) sub-paths") }
        do {
            var columns: [SatinColumn] = []
            if ProcessInfo.processInfo.environment["DEBUG_PIECES"] != nil {
                let glyphArea = shape.subPaths.reduce(0.0) { $0 + abs(PolygonGeometry.signedArea($1.points)) }
                let pieceArea = glyphPieces(shape).reduce(0.0) { total, piece in
                    total + (piece.subPaths.first.map { abs(PolygonGeometry.signedArea($0.points)) } ?? 0)
                }
                print(String(format: "  pieces %@: %d pieces, %.1f%% of the glyph's area",
                             character, glyphPieces(shape).count, glyphArea > 0 ? pieceArea / glyphArea * 100 : 0))
            }
            for piece in glyphPieces(shape) {
                // A stray contour in the font (Merriweather's h carries a
                // 0.3 mm one) is not a piece of the letter; an i's dot at
                // this size is a few square millimetres.
                guard let outer = piece.subPaths.first, abs(PolygonGeometry.signedArea(outer.points)) >= 0.5 else { continue }
                // Digitize the piece both ways and keep the one that
                // actually covers it. The library is built here, offline,
                // so this costs build time rather than anybody's stitch-
                // out -- and it means no letter can come out worse than it
                // did before, because the old plan is one of the two.
                let reconstructed = (try? SatinColumnGenerator.columnPlanWithFallback(for: piece, parameters: parameters)) ?? []
                // GLYPH_COLUMNS=skeleton goes back to inferring them, for
                // comparing the two on a font.
                let readOff = ProcessInfo.processInfo.environment["GLYPH_COLUMNS"] == "skeleton"
                    ? [] : GlyphColumnExtractor.columns(for: piece)
                func score(_ plan: [SatinColumn]) -> Double {
                    guard !plan.isEmpty else { return -1 }
                    let measured = GlyphColumnExtractor.coverage(of: plan, in: piece)
                    return measured.covered - measured.spill * 1.5   // outside the letter is worse than short of it
                }
                let readScore = score(readOff), oldScore = score(reconstructed)
                if ProcessInfo.processInfo.environment["DEBUG_COLUMNS"] != nil {
                    print(String(format: "    piece %@: outline %.3f (%d cols) vs skeleton %.3f (%d cols)",
                                 character, readScore, readOff.count, oldScore, reconstructed.count))
                }
                columns += readScore > oldScore ? readOff : reconstructed
            }
            // A stub the skeleton left (an M's 0.8 mm edge, a demoted
            // junction) is a column with no width and no length: drop it.
            columns.removeAll { column in
                let widest = zip(column.railA, column.railB).map { $0.distance(to: $1) }.max() ?? 0
                return widest < 0.2 || PolygonGeometry.pathLength(column.midline) < 0.4
            }
            guard !columns.isEmpty else { missing.append(character); continue }
            if ProcessInfo.processInfo.environment["DEBUG_COLUMNS"] != nil { print("    -> \(columns.count) columns: " + columns.map { "\($0.railA.count)\($0.travelOut ? "t" : "")" }.joined(separator: " ")) }
            // Back to units, rails thinned to what a 0.05 mm tolerance keeps.
            let toUnits = 1000 / capMM
            let stored = columns.map { column in
                column.thinned(epsilon: ProcessInfo.processInfo.environment["THIN_MM"].flatMap(Double.init) ?? 0.05).mapped { Point2D(($0.x - offset.x) * toUnits, ($0.y - offset.y) * toUnits) }
            }
            let runs = SatinColumnGenerator.sewColumns(columns, parameters: parameters, polygons: shape.subPaths.map { $0.points })
            let count = runs.reduce(0) { $0 + $1.count }
            guard count > 0 else { missing.append(character); continue }
            stitchTotal += count
            glyphs[character] = GlyphColumns(advance: glyph.advance, columns: stored)
        }
    }
    let font = GlyphColumnFont(fontID: outlines.fontID, digitizedCapHeightMM: capMM, glyphs: glyphs, missing: missing)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(font)
    try data.write(to: URL(fileURLWithPath: args[3]))
    print("\(outlines.fontID): \(glyphs.count) glyphs, \(missing.count) missing\(missing.isEmpty ? "" : " (" + missing.joined() + ")"), \(stitchTotal) stitches at \(capMM) mm, \(data.count / 1024) KB")
    exit(0)
}

if args.count >= 4, args[1] == "--glyph-sheet" {
    let font = try GlyphColumnLibrary.load(from: URL(fileURLWithPath: args[2]))
    // The glyph outlines (GLYPH_OUTLINES=<font.outlines.json>) give each
    // object its real shape, as the lettering route does; without them a
    // bounding box stands in and hops across a counter read as covered.
    let outlines: GlyphOutlineFile? = ProcessInfo.processInfo.environment["GLYPH_OUTLINES"].flatMap { path in
        try? JSONDecoder().decode(GlyphOutlineFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    let capMM = args.count > 4 ? (Double(args[4]) ?? 8) : 8
    let text = args.count > 5 ? args[5] : "ABCDEFGHIJKLM\nNOPQRSTUVWXYZ\nabcdefghijklm\nnopqrstuvwxyz\n0123456789&@#\n.,;:!?'\"()-/%$"
    let parameters = glyphParameters()
    let scale = capMM / GlyphColumnLibrary.capHeightUnits
    let gap = capMM * 0.12
    var objects: [EmbroideryObject] = []
    var y = capMM * 1.4
    var widest = 0.0
    for line in text.split(separator: "\n") {
        var x = capMM * 0.5
        for character in line {
            let key = String(character)
            guard let glyph = font.glyphs[key] else { x += capMM * 0.5; continue }
            let origin = Point2D(x, y)
            let columns = GlyphColumnLibrary.columns(font: font, character: key, capHeightMM: capMM, origin: origin) ?? []
            let shape: VectorShape
            if let outline = outlines?.glyphs[key] {
                shape = glyphShape(outline, capMM: capMM, offset: origin)
            } else {
                var box = BoundingBox.empty
                for column in columns { for p in column.railA + column.railB { box = box.union(BoundingBox(minX: p.x, minY: p.y, maxX: p.x, maxY: p.y)) } }
                shape = VectorShape(subPaths: [SubPath(points: [Point2D(box.minX, box.minY), Point2D(box.maxX, box.minY), Point2D(box.maxX, box.maxY), Point2D(box.minX, box.maxY)], closed: true)])
            }
            // GENERIC=1 sews the outlines through the generic lettering path
            // instead, for comparison against the library.
            if ProcessInfo.processInfo.environment["GENERIC"] != nil {
                let runType = StitchTypeClassifier.classifyLetteringRun(shapes: [shape], parameters: parameters, capHeightMM: capMM)
                objects.append(EmbroideryObject(name: key, shape: shape, stitchType: StitchTypeClassifier.classifyGlyphInRun(shape: shape, runStitchType: runType, parameters: parameters),
                                                threadColor: .generic(RGBColor(hex: 0x1144AA)), parameters: parameters, stitchTypeIsManualOverride: true))
            } else {
                objects.append(EmbroideryObject(name: key, shape: shape, stitchType: .satin, threadColor: .generic(RGBColor(hex: 0x1144AA)),
                                                parameters: parameters, stitchTypeIsManualOverride: true, satinColumns: columns))
            }
            x += glyph.advance * scale + gap
        }
        widest = max(widest, x)
        y += capMM * 1.6
    }
    let widthMM = widest + capMM * 0.5, heightMM = y
    let doc = StitchDocument(name: "sheet", physicalWidthMM: widthMM, physicalHeightMM: heightMM, objects: objects)
    let plan = try DigitizePipeline.flatten(doc)
    var options = StitchRenderer.Options()
    options.pixelsPerMM = ProcessInfo.processInfo.environment["PIXELS_PER_MM"].flatMap(Double.init) ?? 20
    guard let png = StitchRenderer.renderPNGData(plan, widthMM: widthMM, heightMM: heightMM, colors: [.generic(RGBColor(hex: 0x1144AA))], options: options) else {
        print("Render failed"); exit(1)
    }
    try png.write(to: URL(fileURLWithPath: args[3]))
    print("\(font.fontID) at \(capMM) mm: \(objects.count) glyphs, \(plan.stitchCount) stitches, \(plan.trimCount) trims -> \(args[3])")
    exit(0)
}

if args.count >= 4, args[1] == "--emit-glyph-data" {
    let dir = URL(fileURLWithPath: args[2])
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix(".columns.json") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var swift = "// Generated by `DigitizeCLI --emit-glyph-data`; do not edit by hand.\n// One JSON document per web font id (see GlyphColumnLibrary).\nenum GlyphColumnData {\n    static func json(for fontID: String) -> String? { fonts[fontID] }\n    static let fonts: [String: String] = [\n"
    for file in files {
        let font = try GlyphColumnLibrary.load(from: file)
        let json = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        swift += "        \"\(font.fontID)\": #\"\"\"\n\(json)\n\"\"\"#,\n"
    }
    swift += "    ]\n}\n"
    try swift.write(to: URL(fileURLWithPath: args[3]), atomically: true, encoding: .utf8)
    print("\(files.count) fonts -> \(args[3])")
    exit(0)
}

if args.count >= 5, args[1] == "--lettering-preview" {
    // Diagnostic: render real lettering (generated the same way AppState's
    // Add Lettering path does, including the run-level stitch-type
    // classification) to a PNG, without driving the GUI.
    let text = args[2]
    let fontPostScriptName = args[3]
    let outputURL = URL(fileURLWithPath: args[4])
    let fontSizeMM = args.count > 5 ? (Double(args[5]) ?? 20) : 20

    var previewPixelsPerMM = 20.0
    let spec = LetteringSpec(text: text, fontPostScriptName: fontPostScriptName, fontSizeMM: fontSizeMM)
    let rawShapes = try LetteringGenerator.generateShapes(spec: spec)
    var rawCombined = BoundingBox.empty
    for shape in rawShapes { rawCombined = rawCombined.union(shape.boundingBox) }
    // Center within the canvas the same way AppState.generateLetteringObjects does.
    let offsetX = -rawCombined.minX + 5, offsetY = -rawCombined.minY + 5
    let shapes = rawShapes.map { shape in
        VectorShape(subPaths: shape.subPaths.map { sp in
            SubPath(points: sp.points.map { Point2D($0.x + offsetX, $0.y + offsetY) }, closed: sp.closed)
        })
    }
    var combined = BoundingBox.empty
    for shape in shapes { combined = combined.union(shape.boundingBox) }
    // The same parameters the web server's lettering route uses: satin
    // along the strokes, branching where the glyph does.
    var parameters = StitchGenerationParameters()
    parameters.allowBranchingSatin = true
    parameters.minSatinWidthMM = min(parameters.minSatinWidthMM, StitchTypeClassifier.strokeMinimumSatinWidthMM)
    if let ppm = ProcessInfo.processInfo.environment["PIXELS_PER_MM"].flatMap(Double.init) { previewPixelsPerMM = ppm }
    let runType = StitchTypeClassifier.classifyLetteringRun(shapes: shapes, parameters: parameters, capHeightMM: fontSizeMM)
    print("Run stitch type: \(runType)")
    let objects = shapes.enumerated().map { i, shape -> EmbroideryObject in
        let stitchType = StitchTypeClassifier.classifyGlyphInRun(shape: shape, runStitchType: runType, parameters: parameters)
        print("  glyph \(i): subPaths=\(shape.subPaths.count) -> \(stitchType)")
        return EmbroideryObject(name: "Letter \(i)", shape: shape, stitchType: stitchType,
                                 threadColor: .generic(RGBColor(hex: 0x1144AA)), parameters: parameters)
    }
    let widthMM = combined.width + 10, heightMM = combined.height + 10
    let doc = StitchDocument(name: text, physicalWidthMM: widthMM, physicalHeightMM: heightMM, objects: objects)
    let plan = try DigitizePipeline.flatten(doc)
    print("Stitch count: \(plan.stitchCount), trims: \(plan.trimCount)")
    var options = StitchRenderer.Options()
    options.pixelsPerMM = previewPixelsPerMM
    guard let pngData = StitchRenderer.renderPNGData(plan, widthMM: widthMM, heightMM: heightMM, colors: [.generic(RGBColor(hex: 0x1144AA))], options: options) else {
        print("Render failed"); exit(1)
    }
    try pngData.write(to: outputURL)
    print("Wrote \(outputURL.path)")
    exit(0)
}

guard args.count >= 3 else {
    print("Usage: DigitizeCLI <input> <output.png> [widthMM=100] [heightMM=100] [maxColors=8] [pixelsPerMM=12]")
    print("       DigitizeCLI --recommend-size <input>")
    print("       DigitizeCLI --detect-text <input>")
    print("       DigitizeCLI --lettering-preview <text> <fontPostScriptName> <output.png> [fontSizeMM=20]")
    print("       DigitizeCLI --build-glyph-library <font.outlines.json> <out.columns.json> [capMM=22]")
    print("       DigitizeCLI --glyph-sheet <font.columns.json> <out.png> [capMM=8] [text]")
    print("       DigitizeCLI --emit-glyph-data <dir> <out.swift>")
    exit(1)
}

let startTime = Date()
func checkpoint(_ label: String) {
    print(String(format: "[%.2fs] %@", Date().timeIntervalSince(startTime), label))
}

let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
let widthMM = args.count > 3 ? (Double(args[3]) ?? 100) : 100
let heightMM = args.count > 4 ? (Double(args[4]) ?? 100) : 100
let maxColors = args.count > 5 ? (Int(args[5]) ?? 8) : 8
let pixelsPerMM = args.count > 6 ? (Double(args[6]) ?? 12) : 12

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

do {
    let data = try Data(contentsOf: inputURL)
    let isSVG = inputURL.pathExtension.lowercased() == "svg"

    let rawShapes: [VectorShape]
    let fillColors: [RGBColor?]
    var artworkBackground: RGBColor? = nil
    var artworkPixelHeight = 0
    if isSVG {
        let result = try SVGImporter.importShapes(from: data)
        rawShapes = result.shapes
        fillColors = result.fillColors
    } else {
        let result = try ImageImporter.importShapes(from: data, maxColors: maxColors)
        rawShapes = result.shapes
        fillColors = result.fillColors
        artworkBackground = result.backgroundColor
        artworkPixelHeight = result.pixelHeight
        let candidate = CandidateAssessment.assess(importResult: result)
        if candidate.verdict != .good {
            print("  candidate: \(candidate.verdict.rawValue)")
            for reason in candidate.reasons { print("    - \(reason.message)") }
        }
        if ProcessInfo.processInfo.environment["DEBUG_IMPORT"] != nil || ProcessInfo.processInfo.environment["DEBUG_CANDIDATE"] != nil {
            let st = result.colorStatistics
            let box = result.shapes.reduce(BoundingBox.empty) { $0.union($1.boundingBox) }
            let tiny = result.shapes.filter { let b = $0.boundingBox; return max(b.width, b.height) < max(box.width, box.height) * 0.01 }.count
            print(String(format: "  candidate: %dx%d px, fg %d px, distinct %.3f, meanDE %.2f, ambiguous %.3f, shapes %d (tiny %d)",
                         result.pixelWidth, result.pixelHeight, st.foregroundPixels, st.distinctColorFraction, st.meanColorDistance, st.ambiguousFraction, result.shapes.count, tiny))
        }
    }
    guard !rawShapes.isEmpty else { fail("No usable shapes found in \(inputURL.lastPathComponent).") }
    checkpoint("Imported \(rawShapes.count) raw shapes")

    var combined = BoundingBox.empty
    for shape in rawShapes { combined = combined.union(shape.boundingBox) }

    // Text too small to sew at this size is left out whole (the web app's
    // Text step lets the customer re-type it; here the rule alone applies).
    // KEEP_SMALL_TEXT=1 sews it anyway, for comparison.
    var droppedShapeIndices = Set<Int>()
    var omittedTextLines = 0
    var rescue = SmallTextRescue.Plan()
    if combined.width > 0 {
        let scale = min(widthMM / combined.width, heightMM / max(1e-9, combined.height))
        let minimum = TextLineFinder.minimumCapHeightMM(for: .wt40)
        let lines = TextLineFinder.find(shapes: rawShapes, fillColors: fillColors, imageHeightPixels: artworkPixelHeight)
        if ProcessInfo.processInfo.environment["KEEP_SMALL_TEXT"] == nil {
            rescue = SmallTextRescue.plan(lines: lines, shapes: rawShapes, scaleToMM: scale, minimumCapHeightMM: minimum)
            droppedShapeIndices = rescue.dropped
            omittedTextLines = rescue.omittedLines
        }
        if let width = SmallTextRescue.widthThatSewsAllText(lines: lines, currentWidthMM: widthMM,
                                                            scaleToMM: scale, minimumCapHeightMM: minimum) {
            print(String(format: "  text: at %.0f mm wide some lines are too small to sew; %.1f mm wide would carry them all", widthMM, width))
        }
        for (k, line) in lines.enumerated() {
            let capMM = line.capHeightPixels * scale
            let grown = line.shapeIndices.first.flatMap { rescue.growth[$0] }
            let note: String
            if let grown = grown {
                note = String(format: " -- too small, grown %.0f%% to %.1f mm", (grown - 1) * 100, capMM * grown)
            } else if !line.shapeIndices.isEmpty, rescue.dropped.contains(line.shapeIndices[0]) {
                note = " -- too small, left out"
            } else {
                note = ""
            }
            print(String(format: "  text line %d: %d letters, cap %.1f mm, %.0f deg, %@%@%@", k + 1, line.shapeIndices.count, capMM, line.rotationDegrees,
                         line.suggestsBold ? "bold" : "regular", line.curved ? ", curved" : "", note))
        }
    }
    let shapesToFit = rawShapes.enumerated().map { index, shape -> VectorShape in
        guard let scale = rescue.growth[index], let centre = rescue.centre[index] else { return shape }
        return SmallTextRescue.grown(shape, by: scale, about: centre)
    }

    var objects: [EmbroideryObject] = []
    // `combined` stays the artwork's own bounds, so growing a tagline
    // does not shrink the rest of the logo to make room for it.
    var fittedPieces: [[VectorShape]] = shapesToFit.enumerated().map { i, shape in
        droppedShapeIndices.contains(i) ? [] : [shape.fitToPhysicalSize(widthMM: widthMM, heightMM: heightMM, within: combined)]
    }
    if isSVG {
        // Vector fills overlap back to front; sew each region once (C2).
        fittedPieces = DesignFinishing.removeOverlaps(fittedPieces.map { $0[0] }, opaque: fillColors.map { $0 != nil })
    }
    for (i, pieces) in fittedPieces.enumerated() {
      for (pieceIndex, fitted) in pieces.enumerated() {
        let detectedRGB = (i < fillColors.count ? fillColors[i] : nil) ?? RGBColor(hex: 0x000000)
        let threadColor = ThreadLibrary.nearestMatch(to: detectedRGB) ?? .generic(detectedRGB)
        var parameters = StitchGenerationParameters()
        // Diagnostic toggle, like ONLY_OBJECT/DEBUG_SATIN below: exercise the
        // branching-satin path (see DIGITIZING_ENGINE.md) against a real file
        // without changing the engine's own default.
        if ProcessInfo.processInfo.environment["ALLOW_BRANCHING_SATIN"] != nil {
            parameters.allowBranchingSatin = true
        }
        // UNDERLAY=none (any UnderlayType raw value): force every object's underlay.
        if ProcessInfo.processInfo.environment["BACKSTOP"] == "off" { CoverageBackstop.isEnabled = false }
        if let raw = ProcessInfo.processInfo.environment["UNDERLAY"], let underlay = UnderlayType(rawValue: raw) {
            parameters.underlayType = underlay
        }
        // FABRIC=terry (any FabricType raw value): sew as if on that fabric.
        if let raw = ProcessInfo.processInfo.environment["FABRIC"], let fabric = FabricType(rawValue: raw) {
            parameters.fabricType = fabric
        }
        let stitchType = StitchTypeClassifier.classify(shape: fitted, parameters: parameters)
        if ProcessInfo.processInfo.environment["DEBUG_CLASSIFY"] != nil {
            let box = fitted.boundingBox
            let reason = stitchType == .tatamiFill ? (SatinColumnGenerator.branchingSatinRejection(shape: fitted, parameters: parameters) ?? "eligible (rejected elsewhere)") : "-"
            print(String(format: "  classify Object %d: %@; subPaths=%d bbox %.1fx%.1f; branching satin: %@", i + 1, stitchType.rawValue, fitted.subPaths.count, box.width, box.height, reason))
        }
        objects.append(EmbroideryObject(name: pieceIndex == 0 ? "Object \(i + 1)" : "Object \(i + 1) (\(pieceIndex + 1))", shape: fitted, stitchType: stitchType,
                                         threadColor: threadColor, parameters: parameters))
      }
    }
    objects = StitchTypeClassifier.separateStrokesFromAreas(objects)
    objects = StitchTypeClassifier.harmonizeSameColorFillConsistency(objects)
    objects = StitchTypeClassifier.reconcileRunningStitchOutliers(objects)
    checkpoint("Built \(objects.count) objects")

    if let onlyStr = ProcessInfo.processInfo.environment["ONLY_OBJECT"], let only = Int(onlyStr), only >= 1, only <= objects.count {
        objects = [objects[only - 1]]
        print("Isolated Object \(only): \(objects[0].stitchType.rawValue), subPaths=\(objects[0].shape.subPaths.count)")
    }

    var document = StitchDocument(name: inputURL.deletingPathExtension().lastPathComponent,
                                  physicalWidthMM: widthMM, physicalHeightMM: heightMM, objects: objects, omittedTextLines: omittedTextLines)
    // LAYDOWN=1: a white laydown stitch first (`LaydownSettings`).
    if ProcessInfo.processInfo.environment["LAYDOWN"] != nil {
        document.laydown = LaydownSettings(threadColor: .generic(RGBColor(hex: 0xF2EFE8), name: "Ecru"))
    }
    let (plan, colors) = try DigitizePipeline.flattenWithColors(document)
    checkpoint("Flattened plan: \(plan.stitchCount) stitches, \(colors.count) colors")
    let report = QualityAnalyzer.analyze(plan, document: document)
    checkpoint("Quality analysis done")

    print("=== \(inputURL.lastPathComponent) ===")
    print("Objects: \(objects.count)  Stitches: \(plan.stitchCount)  Colors: \(colors.count)  Color changes: \(plan.colorChangeCount)  Trims: \(plan.trimCount)")
    print("Max stitch length: \(String(format: "%.2f", plan.maxStitchLength()))mm  Total thread: \(String(format: "%.0f", plan.totalStitchLength))mm  Est. run time: \(RunTimeEstimator.estimate(plan).formatted) at \(Int(RunTimeEstimator.defaultStitchesPerMinute)) spm")
    print("Readiness: \(report.score)/100 (\(report.isReadyToSew ? "Ready to Sew" : "Review Recommended"))")
    if ProcessInfo.processInfo.environment["DEBUG_SHAPELOSS"] != nil {
        for (index, pieces) in fittedPieces.enumerated() where !pieces.isEmpty {
            let before = pieces.reduce(0.0) { total, piece in
                total + piece.subPaths.reduce(0.0) { $0 + abs(PolygonGeometry.signedArea($1.points)) }
            }
            // Objects carry no back-reference, so match on overlap: the
            // object whose box sits inside this piece's.
            let box = pieces[0].boundingBox
            let after = objects.filter { object in
                let b = object.shape.boundingBox
                return b.minX >= box.minX - 0.5 && b.maxX <= box.maxX + 0.5 && b.minY >= box.minY - 0.5 && b.maxY <= box.maxY + 0.5
            }.reduce(0.0) { total, object in
                total + object.shape.subPaths.reduce(0.0) { $0 + abs(PolygonGeometry.signedArea($1.points)) }
            }
            if before > 1, after < before * 0.97 {
                print(String(format: "  shape %d: %.1f mm2 imported -> %.1f mm2 in objects (%.0f%% lost before any stitch)",
                             index, before, after, (before - after) / before * 100))
            }
        }
    }
    // A design-level coverage check: every stitch against the artwork as
    // imported, not against each object's own (possibly already reduced)
    // shape. Tells apart "the generator missed" from "the shape lost its
    // ends before any generator saw it".
    if ProcessInfo.processInfo.environment["DEBUG_COVERAGE"] != nil {
        var runs: [[Point2D]] = []
        var current: [Point2D] = []
        for command in plan.commands {
            switch command {
            case .stitch(let p): current.append(p)
            default:
                if current.count > 1 { runs.append(current) }
                current = []
            }
        }
        if current.count > 1 { runs.append(current) }
        for (index, pieces) in fittedPieces.enumerated() where !pieces.isEmpty {
            guard !droppedShapeIndices.contains(index) else { continue }
            for piece in pieces {
                let missing = CoverageBackstop.missingRegions(in: piece, covered: runs)
                let area = missing.reduce(0.0) { $0 + ($1.subPaths.first.map { abs(PolygonGeometry.signedArea($0.points)) } ?? 0) }
                let whole = piece.subPaths.reduce(0.0) { $0 + abs(PolygonGeometry.signedArea($1.points)) }
                if area > 0.5, whole > 0 {
                    let box = piece.boundingBox
                    print(String(format: "  uncovered: shape %d, %.1f of %.1f mm2 (%.0f%%) bare, at (%.0f,%.0f)-(%.0f,%.0f)",
                                 index, area, whole, area / whole * 100, box.minX, box.minY, box.maxX, box.maxY))
                }
            }
        }
    }
    if ProcessInfo.processInfo.environment["PROFILE"] != nil { printProfile(plan) }
    if ProcessInfo.processInfo.environment["DUMP_PLAN"] != nil {
        for (i, c) in plan.commands.enumerated() {
            switch c {
            case .stitch(let p): print(String(format: "  %d: stitch (%.2f,%.2f)", i, p.x, p.y))
            case .jump(let p): print(String(format: "  %d: jump (%.2f,%.2f)", i, p.x, p.y))
            default: print("  \(i): \(c)")
            }
        }
    }
    // DUMP_BREAKS=1: every non-stitch command with the gap it spans, plus
    // any stitch over 6 mm -- the things a sew-out shows as loose thread.
    if ProcessInfo.processInfo.environment["DUMP_BREAKS"] != nil {
        var last: Point2D? = nil
        for (i, c) in plan.commands.enumerated() {
            switch c {
            case .stitch(let p):
                if let l = last, l.distance(to: p) > 6 { print(String(format: "  %d: LONG STITCH %.1fmm (%.1f,%.1f)->(%.1f,%.1f)", i, l.distance(to: p), l.x, l.y, p.x, p.y)) }
                last = p
            case .jump(let p):
                if let l = last { print(String(format: "  %d: jump %.1fmm (%.1f,%.1f)->(%.1f,%.1f)", i, l.distance(to: p), l.x, l.y, p.x, p.y)) } else { print("  \(i): jump to (\(p.x), \(p.y))") }
                last = p
            default: print("  \(i): \(c)")
            }
        }
    }
    for issue in report.issues {
        print("  [\(issue.severity.rawValue)] \(issue.message)")
    }
    // The longest few needle-penetrating segments, so a suspiciously large
    // `maxStitchLength()` (an unintended jump-as-stitch, not a real design
    // feature) can be traced back to *where* in the design it happens.
    do {
        var segments: [(from: Point2D, to: Point2D, length: Double)] = []
        var last: Point2D?
        for command in plan.commands {
            switch command {
            case .stitch(let p):
                if let l = last { segments.append((l, p, l.distance(to: p))) }
                last = p
            case .jump(let p):
                last = p
            case .colorChange, .trim, .stop:
                last = nil
            case .end:
                break
            }
        }
        let debugThreshold = ProcessInfo.processInfo.environment["DEBUG_SATIN"] != nil ? 3.0 : 12.5
        let longest = segments.sorted { $0.length > $1.length }.prefix(15)
        if let worst = longest.first, worst.length > debugThreshold {
            print("--- longest stitch segments ---")
            for s in longest {
                print(String(format: "  %.2fmm: (%.3f, %.3f) -> (%.3f, %.3f)", s.length, s.from.x, s.from.y, s.to.x, s.to.y))
            }
        }
    }
    for object in objects {
        let box = object.shape.boundingBox
        print(String(format: "  - %@: %@, color %@, bbox=(%.1f,%.1f)-(%.1f,%.1f)",
                      object.name, object.stitchType.rawValue, object.threadColor.name, box.minX, box.minY, box.maxX, box.maxY))
    }

    // EXPORT=/path/file.pes (or .dst/.exp/.jef/.vp3): also write the
    // machine file, exactly as the app would.
    if let exportPath = ProcessInfo.processInfo.environment["EXPORT"] {
        let url = URL(fileURLWithPath: exportPath)
        let threadRGBs = colors.map { $0.rgb }
        let data: Data
        switch url.pathExtension.lowercased() {
        case "pes": data = try PESFormat.write(plan, designName: document.name, threadColors: threadRGBs)
        case "exp": data = try EXPFormat.write(plan, designName: document.name)
        case "jef": data = try JEFFormat.write(plan, designName: document.name, threadColors: threadRGBs)
        case "vp3": data = try VP3Format.write(plan, designName: document.name, threadColors: threadRGBs)
        default: data = try DSTFormat.write(plan, designName: document.name)
        }
        try data.write(to: url)
        print("Exported \(url.path)")
    }

    var renderOptions = StitchRenderer.Options()
    renderOptions.pixelsPerMM = pixelsPerMM
    // Preview on the artwork's own ground when it is a real colour (a
    // navy card, a grey field): the stitches meant for that garment are
    // otherwise white on the paper-coloured default.
    if let bg = artworkBackground, StitchRenderer.isPreviewGround(bg) {
        renderOptions.backgroundColor = (Double(bg.r) / 255, Double(bg.g) / 255, Double(bg.b) / 255)
    }
    guard let pngData = StitchRenderer.renderPNGData(plan, widthMM: widthMM, heightMM: heightMM, colors: colors, options: renderOptions) else {
        fail("Rendering failed.")
    }
    try pngData.write(to: outputURL)
    print("Wrote \(outputURL.path)")
} catch {
    fail("Error: \(error)")
}
