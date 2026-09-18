import Foundation
import Vapor
import StitchPilotCore

// The editing operations that need the engine's geometry (ShapeMerger,
// StitchTypeClassifier): each takes the whole document and returns the
// edited document, mirroring the corresponding AppState method on the
// Mac. Pure per-object field edits (colour, stitch type, parameters)
// never come here -- the browser does those itself and re-digitizes.

struct EditResponse: Content {
    var document: StitchDocument
    var selectedIDs: [UUID]
    var status: String
}

func editRoutes(_ engine: RoutesBuilder) {
    let edit = engine.grouped("edit")

    /// AppState.mergeSelectedShapesIntoOneObject
    edit.post("merge-shapes") { req -> EditResponse in
        struct In: Content { var document: StitchDocument; var objectIDs: [UUID] }
        let body = try req.content.decode(In.self)
        return try await Engine.run {
            var current = body.document
            let ids = Set(body.objectIDs)
            let selected = current.objects.filter { ids.contains($0.id) }
            guard selected.count >= 2 else { throw Abort(.badRequest, reason: "Select at least two objects to merge.") }
            guard let mergedShape = ShapeMerger.merge(selected.map(\.shape)) else {
                throw Abort(.unprocessableEntity, reason: "Couldn't merge the selected shapes.")
            }
            let firstIndex = current.objects.firstIndex(where: { ids.contains($0.id) }) ?? current.objects.count
            let representative = selected[0]
            let parameters = StitchGenerationParameters()
            let stitchType = StitchTypeClassifier.classify(shape: mergedShape, parameters: parameters)
            let merged = EmbroideryObject(name: representative.name, shape: mergedShape, stitchType: stitchType,
                                          threadColor: representative.threadColor, parameters: parameters)
            current.objects.removeAll { ids.contains($0.id) }
            current.objects.insert(merged, at: min(firstIndex, current.objects.count))
            return EditResponse(document: current, selectedIDs: [merged.id], status: "Merged \(ids.count) objects into one.")
        }
    }

    /// AppState.addOutlines -- a bean-stitch outline round every filled object (C7).
    edit.post("outlines") { req -> EditResponse in
        struct In: Content { var document: StitchDocument }
        let body = try req.content.decode(In.self)
        return try await Engine.run {
            var current = body.document
            let outlines = DesignFinishing.outlineObjects(for: current)
            guard !outlines.isEmpty else { throw Abort(.unprocessableEntity, reason: "Every filled object already has an outline.") }
            current.objects += outlines
            return EditResponse(document: current, selectedIDs: outlines.map(\.id), status: "Added \(outlines.count) outline\(outlines.count == 1 ? "" : "s").")
        }
    }

    /// AppState.addBorder -- a satin border round the whole design (C7).
    edit.post("border") { req -> EditResponse in
        struct In: Content { var document: StitchDocument; var threadColor: ThreadColor; var widthMM: Double? }
        let body = try req.content.decode(In.self)
        return try await Engine.run {
            var current = body.document
            current.objects.removeAll { $0.name == "Border" }
            guard let border = DesignFinishing.borderObject(for: current, widthMM: body.widthMM ?? DesignFinishing.borderWidthMM, threadColor: body.threadColor) else {
                throw Abort(.unprocessableEntity, reason: "Couldn't build a border round this design.")
            }
            current.objects.append(border)
            return EditResponse(document: current, selectedIDs: [border.id], status: "Added a \(String(format: "%.1f", body.widthMM ?? DesignFinishing.borderWidthMM)) mm border.")
        }
    }

    /// AppState.eraseStroke
    edit.post("erase") { req -> EditResponse in
        struct In: Content { var document: StitchDocument; var points: [Point2D]; var radiusMM: Double; var selectedIDs: [UUID]? }
        let body = try req.content.decode(In.self)
        return try await Engine.run {
            var current = body.document
            guard body.radiusMM > 0, !body.points.isEmpty, !current.objects.isEmpty else {
                return EditResponse(document: current, selectedIDs: body.selectedIDs ?? [], status: "")
            }
            let strokeBox = strokeBounds(body.points, radiusMM: body.radiusMM)
            let touched = current.objects.indices.filter { current.objects[$0].shape.boundingBox.intersects(strokeBox) }
            guard !touched.isEmpty else { return EditResponse(document: current, selectedIDs: body.selectedIDs ?? [], status: "") }
            var removed: Set<UUID> = []
            var changed = false
            for i in touched {
                if let reduced = ShapeMerger.subtractStroke([current.objects[i].shape], strokePoints: body.points, radiusMM: body.radiusMM) {
                    guard reduced != current.objects[i].shape else { continue }
                    changed = true
                    current.objects[i].shape = reduced
                    if !current.objects[i].stitchTypeIsManualOverride {
                        current.objects[i].stitchType = StitchTypeClassifier.classify(shape: reduced, parameters: current.objects[i].parameters)
                    }
                } else {
                    changed = true
                    removed.insert(current.objects[i].id)
                }
            }
            guard changed else { return EditResponse(document: current, selectedIDs: body.selectedIDs ?? [], status: "") }
            current.objects.removeAll { removed.contains($0.id) }
            let selected = (body.selectedIDs ?? []).filter { !removed.contains($0) }
            let status = removed.isEmpty ? "Erased from \(touched.count) object(s)." : "Erased \(removed.count) object(s) entirely."
            return EditResponse(document: current, selectedIDs: selected, status: status)
        }
    }

    /// AppState.paintStroke / extendObject / addNewPaintedObject /
    /// confirmPaintMerge / keepPaintSeparate. `mode` "auto" behaves like
    /// the Mac's first pass: extends the selected object, or -- when the
    /// stroke touches exactly one unselected object -- answers with
    /// `pendingMerge` so the browser can ask "extend it, or keep separate?"
    /// and call again with mode "extend" or "separate".
    edit.post("paint") { req -> Response in
        struct In: Content {
            var document: StitchDocument; var points: [Point2D]; var radiusMM: Double
            var mode: String?; var targetID: UUID?; var selectedID: UUID?
            var paintColor: RGBColor; var matchToThreadLibrary: Bool?; var palette: [ThreadColor]?
        }
        struct Pending: Content { var pendingMerge: PendingMerge }
        struct PendingMerge: Content { var targetID: UUID; var targetName: String }
        let body = try req.content.decode(In.self)
        let result: Either<EditResponse, Pending> = try await Engine.run {
            var current = body.document
            guard body.radiusMM > 0, !body.points.isEmpty else { return .left(EditResponse(document: current, selectedIDs: [], status: "")) }
            let mode = body.mode ?? "auto"

            func extend(_ index: Int) -> EditResponse {
                guard let extended = ShapeMerger.mergeWithStroke([current.objects[index].shape], strokePoints: body.points, radiusMM: body.radiusMM) else {
                    return EditResponse(document: current, selectedIDs: [current.objects[index].id], status: "")
                }
                current.objects[index].shape = extended
                current.objects[index].stitchType = StitchTypeClassifier.classify(shape: extended, parameters: current.objects[index].parameters)
                return EditResponse(document: current, selectedIDs: [current.objects[index].id], status: "Extended \(current.objects[index].name).")
            }
            func addNew(threadColor: ThreadColor?) -> EditResponse {
                guard let strokeShape = ShapeMerger.mergeWithStroke([], strokePoints: body.points, radiusMM: body.radiusMM) else {
                    return EditResponse(document: current, selectedIDs: [], status: "")
                }
                let parameters = StitchGenerationParameters()
                let stitchType = StitchTypeClassifier.classify(shape: strokeShape, parameters: parameters)
                let palette = (body.palette?.isEmpty == false) ? body.palette! : ThreadLibrary.genericPalette
                let color = threadColor ?? ((body.matchToThreadLibrary ?? true)
                    ? (ThreadLibrary.nearestMatch(to: body.paintColor, in: palette) ?? .generic(body.paintColor, name: "Painted Color"))
                    : .generic(body.paintColor, name: "Painted Color"))
                let object = EmbroideryObject(name: "Painted Shape", shape: strokeShape, stitchType: stitchType, threadColor: color, parameters: parameters)
                current.objects.append(object)
                return EditResponse(document: current, selectedIDs: [object.id], status: "Added a new painted shape.")
            }

            switch mode {
            case "extend":
                guard let target = body.targetID, let index = current.objects.firstIndex(where: { $0.id == target }) else {
                    throw Abort(.badRequest, reason: "That object no longer exists.")
                }
                return .left(extend(index))
            case "separate":
                let color = body.targetID.flatMap { id in current.objects.first(where: { $0.id == id })?.threadColor }
                return .left(addNew(threadColor: color))
            default:
                if let id = body.selectedID, let index = current.objects.firstIndex(where: { $0.id == id }) {
                    return .left(extend(index))
                }
                let strokeBox = strokeBounds(body.points, radiusMM: body.radiusMM)
                var overlapping: [Int] = []
                for (i, object) in current.objects.enumerated() where object.shape.boundingBox.intersects(strokeBox) {
                    guard let merged = ShapeMerger.mergeWithStroke([object.shape], strokePoints: body.points, radiusMM: body.radiusMM),
                          merged.subPaths.count < object.shape.subPaths.count + 1 else { continue }
                    overlapping.append(i)
                }
                if overlapping.count == 1 {
                    let object = current.objects[overlapping[0]]
                    return .right(Pending(pendingMerge: PendingMerge(targetID: object.id, targetName: object.name)))
                }
                return .left(addNew(threadColor: nil))
            }
        }
        switch result {
        case .left(let edit): return try await edit.encodeResponse(for: req)
        case .right(let pending): return try await pending.encodeResponse(for: req)
        }
    }

    /// Re-run auto-classification for some objects after their geometry
    /// changed in the browser (a corner-handle resize: AppState.scaleSelection).
    edit.post("classify") { req -> EditResponse in
        struct In: Content { var document: StitchDocument; var objectIDs: [UUID] }
        let body = try req.content.decode(In.self)
        return try await Engine.run {
            var current = body.document
            let ids = Set(body.objectIDs)
            for i in current.objects.indices where ids.contains(current.objects[i].id) && !current.objects[i].stitchTypeIsManualOverride {
                current.objects[i].stitchType = StitchTypeClassifier.classify(shape: current.objects[i].shape, parameters: current.objects[i].parameters)
            }
            return EditResponse(document: current, selectedIDs: body.objectIDs, status: "")
        }
    }

    /// AppState.generateLetteringObjects + addLettering(spec:threadColor:replacing:):
    /// the browser produces the glyph outlines (from a font file, see
    /// web/src/lettering.ts) in mm with the run's cap height known; the
    /// server classifies the run and builds the objects, replacing
    /// `replaceIDs` (the raster-traced fragments) when given.
    edit.post("lettering") { req -> EditResponse in
        struct GlyphPlacement: Content { var character: String; var originXMM: Double }
        struct Condense: Content { var k: Double; var centerXMM: Double }
        struct In: Content {
            var document: StitchDocument; var shapes: [VectorShape]; var capHeightMM: Double
            var threadColor: ThreadColor; var targetCenter: Point2D; var replaceIDs: [UUID]?
            /// Turn the run about its centre, degrees clockwise on screen
            /// (Y down) -- a tagline re-set over a tilted original.
            var rotationDegrees: Double?
            /// The font and where each glyph sits on the straight
            /// baseline (one per shape): with these the run sews the
            /// font's pre-digitized columns (`GlyphColumnLibrary`) -- the
            /// same letter the same way at every size -- and the outlines
            /// serve for bounds and selection. The browser's own arc and
            /// condensing are re-applied to the columns here.
            var fontID: String?
            var glyphs: [GlyphPlacement]?
            var arcRadiusMM: Double?
            var totalWidthMM: Double?
            var condense: Condense?
        }
        let body = try req.content.decode(In.self)
        return try await Engine.run {
            var current = body.document
            guard !body.shapes.isEmpty else { throw Abort(.badRequest, reason: "This text produced no visible letterforms.") }
            var combined = BoundingBox.empty
            for shape in body.shapes { combined = combined.union(shape.boundingBox) }
            let offsetX = body.targetCenter.x - (combined.minX + combined.width / 2)
            let offsetY = body.targetCenter.y - (combined.minY + combined.height / 2)
            let theta = (body.rotationDegrees ?? 0) * .pi / 180
            let (cosT, sinT) = (cos(theta), sin(theta))
            let cx = combined.minX + combined.width / 2, cy = combined.minY + combined.height / 2
            func place(_ p: Point2D) -> Point2D {
                let dx = p.x - cx, dy = p.y - cy
                return Point2D(cx + dx * cosT - dy * sinT + offsetX, cy + dx * sinT + dy * cosT + offsetY)
            }
            let translated = body.shapes.map { shape in
                VectorShape(subPaths: shape.subPaths.map { sp in SubPath(points: sp.points.map(place), closed: sp.closed) })
            }
            // Library columns for each glyph, through the same frame the
            // browser put the outlines through: arc, condensing, then the
            // rotation and centring above.
            var columnsByIndex: [Int: [SatinColumn]] = [:]
            if let fontID = body.fontID, let placements = body.glyphs, placements.count == body.shapes.count,
               let font = GlyphColumnLibrary.font(fontID) {
                let arcRadius = body.arcRadiusMM ?? 0
                let totalWidth = body.totalWidthMM ?? combined.width
                func browserFrame(_ p: Point2D) -> Point2D {
                    var q = p
                    if arcRadius != 0 {
                        // web/src/lettering.ts remapToArc
                        let centeredX = q.x - totalWidth / 2
                        let t = centeredX / arcRadius
                        let effectiveRadius = arcRadius - q.y
                        q = Point2D(effectiveRadius * sin(t), effectiveRadius * (1 - cos(t)) - (effectiveRadius - arcRadius))
                    }
                    if let c = body.condense { q = Point2D(c.centerXMM + (q.x - c.centerXMM) * c.k, q.y) }
                    return place(q)
                }
                for (i, placement) in placements.enumerated() {
                    if let columns = GlyphColumnLibrary.columns(font: font, character: placement.character, capHeightMM: body.capHeightMM,
                                                                origin: Point2D(placement.originXMM, 0), transform: browserFrame) {
                        columnsByIndex[i] = columns
                    }
                }
            }
            // The run takes the document's thread weight (the density panel
            // sets it on every object), so the satin-or-outline rule agrees
            // with the Text step's minimum for that weight.
            var parameters = StitchGenerationParameters()
            if let weight = current.objects.map(\.parameters.threadWeight).first { parameters.threadWeight = weight }
            // Letters are satin along their strokes, branching where the
            // glyph does -- the same path traced lettering takes.
            parameters.allowBranchingSatin = true
            parameters.minSatinWidthMM = min(parameters.minSatinWidthMM, StitchTypeClassifier.strokeMinimumSatinWidthMM)
            let runType = StitchTypeClassifier.classifyLetteringRun(shapes: translated, parameters: parameters, capHeightMM: body.capHeightMM)
            let objects = translated.enumerated().map { i, shape -> EmbroideryObject in
                if let columns = columnsByIndex[i] {
                    // A library glyph is satin whatever the run's size says:
                    // its columns hold a hairline at the thread's minimum.
                    return EmbroideryObject(name: "Letter \(i + 1)", shape: shape, stitchType: .satin, threadColor: body.threadColor,
                                            parameters: parameters, stitchTypeIsManualOverride: true, satinColumns: columns)
                }
                return EmbroideryObject(name: "Letter \(i + 1)", shape: shape, stitchType: StitchTypeClassifier.classifyGlyphInRun(shape: shape, runStitchType: runType, parameters: parameters),
                                        threadColor: body.threadColor, parameters: parameters, stitchTypeIsManualOverride: true)
            }
            let replace = Set(body.replaceIDs ?? [])
            let insertAt = current.objects.firstIndex(where: { replace.contains($0.id) }) ?? current.objects.count
            current.objects.removeAll { replace.contains($0.id) }
            current.objects.insert(contentsOf: objects, at: min(insertAt, current.objects.count))
            return EditResponse(document: current, selectedIDs: objects.map(\.id), status: "Added \(objects.count) letter(s).")
        }
    }
}

private func strokeBounds(_ points: [Point2D], radiusMM: Double) -> BoundingBox {
    var box = BoundingBox.empty
    for p in points { box = box.union(BoundingBox(minX: p.x - radiusMM, minY: p.y - radiusMM, maxX: p.x + radiusMM, maxY: p.y + radiusMM)) }
    return box
}

enum Either<L, R> { case left(L), right(R) }
extension Point2D: Content {}
extension VectorShape: Content {}
