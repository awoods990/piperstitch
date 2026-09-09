import Foundation
import SwiftUI
import AppKit
import StitchPilotCore
import UniformTypeIdentifiers

/// Owns the currently-open design and drives the Phase 1 workflow: import ->
/// (optionally resize) -> Auto Digitize -> preview -> export DST. Thin by
/// design (spec: "the source image describes what the customer wants to
/// see... the embroidery design describes how the machine must sew" — all
/// of that translation logic lives in StitchPilotCore, not here).
@MainActor
final class AppState: ObservableObject {
    /// Bumped on *every* assignment to `document`, regardless of call site
    /// -- a `didSet` on the property itself rather than something each of
    /// the dozen-plus mutating functions below has to remember to do, so
    /// it can't silently drift out of sync with a future edit path. This
    /// is the ground truth for "how current is the on-screen preview,"
    /// replacing the previous, easier-to-get-wrong signal of comparing a
    /// hash of the stitch plan's own commands (`StitchCanvasView`'s old
    /// `planSignature`) -- an exact integer both here and in
    /// `stitchPlanGeneration` below is cheap to compare and can't produce
    /// a false "unchanged" the way a hash collision theoretically could.
    @Published private(set) var documentEditGeneration = 0
    @Published var document: StitchDocument? {
        didSet { documentEditGeneration += 1 }
    }
    /// Which `documentEditGeneration` the *current* `stitchPlan` was
    /// actually generated from -- nil until the first successful digitize.
    /// `isPreviewStale` below is the whole point of tracking this: while
    /// an edit's debounced regenerate is still pending or running, this
    /// lags `documentEditGeneration`, and the canvas uses that gap to show
    /// the in-flight stitch/realistic layer as visibly not-yet-caught-up
    /// instead of silently drawing it as if it were current -- found
    /// directly against a real report that editing one letter's stitch
    /// parameters made the canvas look like a *different* letter's edit
    /// had reverted: the live artwork outline (always current, drawn
    /// straight from `document`) updated instantly, while the solid
    /// stitch-path/realistic layer underneath it kept showing the
    /// pre-edit state for the ~150ms-plus-compute gap before the
    /// debounced regenerate actually finished -- two layers of the same
    /// canvas disagreeing with each other reads as "it changed, then
    /// changed back," even though nothing was ever actually lost.
    @Published private(set) var stitchPlanGeneration: Int?
    /// True whenever the on-screen stitch plan (and therefore the
    /// realistic bitmap rendered from it) doesn't yet reflect the latest
    /// edit -- see `stitchPlanGeneration`'s doc comment.
    var isPreviewStale: Bool { stitchPlanGeneration != documentEditGeneration }
    @Published var stitchPlan: StitchPlan?
    @Published var readinessReport: EmbroideryReadinessReport?
    /// The color sequence for the current `stitchPlan`, computed alongside
    /// it in `autoDigitize()` -- exported and the canvas preview both need
    /// this, and recomputing it independently (as they each used to) means
    /// redoing the whole per-object generation pass again just for colors.
    @Published private(set) var lastColorSequence: [ThreadColor] = []
    /// The normal starting width for a design with no fine detail to react
    /// to -- `SizeRecommender` only ever scales *up* from this, never down,
    /// so a plain bold logo keeps this familiar, comfortable default.
    private let defaultPhysicalWidthMM: Double = 100
    @Published var physicalWidthMM: Double = 100
    @Published var physicalHeightMM: Double = 100
    @Published var lockAspectRatio: Bool = true
    private var sourceAspectRatio: Double = 1
    /// Text `TextDetector` found in the most recent raster import, still
    /// unresolved -- each entry disappears once the user replaces it with
    /// generated Lettering (`replaceDetectedText`) or the sheet reviewing
    /// them is dismissed without acting on it. Empty for an SVG import
    /// (already vector, nothing to detect) or when detection finds
    /// nothing above its confidence floor.
    @Published var detectedTextRegions: [DetectedTextRegion] = []

    /// Only affects raster import (spec §8) — vector artwork already has
    /// discrete fill colors, nothing to quantize. Changing this re-imports
    /// the last-dropped raster file at the new color count.
    @Published var colorPreset: ColorQuantizationPreset = .normalEmbroidery {
        didSet {
            guard oldValue != colorPreset, let url = lastImportedURL, isRasterURL(url) else { return }
            importFile(url: url)
        }
    }
    private var lastImportedURL: URL?

    /// Spec §9: snap artwork colors to the nearest sewable thread color via
    /// Delta-E rather than exporting the literal detected pixel color.
    /// Toggling this re-fits from the stored geometry so the effect is
    /// visible immediately without re-importing.
    @Published var matchToThreadLibrary: Bool = true {
        didSet {
            guard oldValue != matchToThreadLibrary, !lastRawShapes.isEmpty else { return }
            regenerateFromStoredGeometry()
            scheduleLiveRegenerate()
        }
    }

    /// nil = no hoop constraint checked. Re-analyzes immediately on change
    /// so switching hoops updates the readiness score without re-running
    /// Auto Digitize (spec §36: "alert if design exceeds sewing area").
    @Published var selectedHoop: HoopProfile? = HoopProfile.commonHoops[2] {
        didSet {
            guard let plan = stitchPlan else { return }
            readinessReport = QualityAnalyzer.analyze(plan, hoopWidthMM: selectedHoop?.widthMM, hoopHeightMM: selectedHoop?.heightMM)
        }
    }

    /// The fabric this design is meant to be sewn on (spec's Phase 5 --
    /// see `FabricType`'s own doc comment). A whole-document setting, not
    /// per-object, since a design is normally digitized once for one
    /// target garment/fabric -- changing it here writes `fabricType` onto
    /// every current object's own parameters (spec §10: every object
    /// carries its own copy) and regenerates, the same "bulk-apply, then
    /// live-regenerate" pattern `mergeColors(from:into:)` uses for color.
    @Published var selectedFabricType: FabricType = .standard {
        didSet {
            guard oldValue != selectedFabricType, var current = document else { return }
            commitImmediateUndoSnapshot()
            for i in current.objects.indices { current.objects[i].parameters.fabricType = selectedFabricType }
            document = current
            scheduleLiveRegenerate()
        }
    }

    @Published var statusMessage: String = "Drag in an image or SVG file, then click Click to Create."
    @Published var errorMessage: String?
    @Published var isBusy = false
    /// True while a live edit's debounced regenerate (`scheduleLiveRegenerate`)
    /// is waiting to fire or actually recomputing the stitch plan -- distinct
    /// from `isBusy`, which is reserved for big one-shot blocking operations
    /// (import, open project). The canvas shows a small "refreshing" hint
    /// while this is true, since the background regenerate/render changes
    /// introduced their own gap between "you made an edit" and "the preview
    /// visibly caught up" that's otherwise easy to mistake for the app
    /// being stuck rather than still working.
    @Published var isRegeneratingPreview = false

    // MARK: - Custom thread library (spec §9: "a user's 'My Thread
    // Inventory' subset" -- the matching engine already accepts any
    // palette; this is the missing piece letting a user actually build one
    // instead of always matching against the built-in generic palette).

    private static let customThreadLibraryDefaultsKey = "com.oneclickstitch.customThreadLibrary"

    /// The user's own defined thread colors, persisted across launches.
    /// When non-empty, matching (`regenerateFromStoredGeometry`) and the
    /// per-object thread-color picker use *only* this list instead of the
    /// generic palette -- the whole point of defining your own inventory is
    /// matching against colors you actually own, not arbitrary ones you
    /// don't.
    @Published var customThreadLibrary: [ThreadColor] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(customThreadLibrary) {
                UserDefaults.standard.set(data, forKey: Self.customThreadLibraryDefaultsKey)
            }
        }
    }

    /// The palette actually used for matching and the color picker --
    /// the user's own library when they've defined one, the built-in
    /// generic palette otherwise.
    var effectivePalette: [ThreadColor] {
        customThreadLibrary.isEmpty ? ThreadLibrary.genericPalette : customThreadLibrary
    }

    func addCustomThreadColor(name: String, rgb: StitchPilotCore.RGBColor) {
        customThreadLibrary.append(ThreadColor(name: name, rgb: rgb))
    }

    func removeCustomThreadColor(id: ThreadColor.ID) {
        customThreadLibrary.removeAll { $0.id == id }
    }

    private func loadCustomThreadLibrary() {
        guard let data = UserDefaults.standard.data(forKey: Self.customThreadLibraryDefaultsKey),
              let decoded = try? JSONDecoder().decode([ThreadColor].self, from: data) else { return }
        customThreadLibrary = decoded
    }

    init() {
        loadCustomThreadLibrary()
    }

    /// The object list's current selection -- a set so the canvas's
    /// rubber-band select and shift-click can select several objects at
    /// once (needed for "Merge Shapes"), not just one. Self-healing rather
    /// than reset everywhere a new object set replaces the old one (import,
    /// resize, project load all mint fresh `EmbroideryObject` ids):
    /// `selectedObjects` below simply drops any id that no longer matches
    /// anything in the current document, which naturally clears the
    /// inspector/selection highlight.
    @Published var selectedObjectIDs: Set<EmbroideryObject.ID> = []

    /// The single selected object, for the Object Inspector's per-object
    /// editor -- nil both when nothing is selected and when several things
    /// are (multi-selection has its own, reduced UI; editing individual
    /// stitch parameters only makes sense for exactly one object at a time).
    var selectedObjectID: EmbroideryObject.ID? {
        selectedObjectIDs.count == 1 ? selectedObjectIDs.first : nil
    }

    var selectedObject: EmbroideryObject? {
        guard let id = selectedObjectID, let document else { return nil }
        return document.objects.first { $0.id == id }
    }

    /// Every currently-selected object, in document order -- for bulk
    /// actions (Merge Shapes, bulk delete) that operate on however many
    /// are selected, one or many.
    var selectedObjects: [EmbroideryObject] {
        guard let document else { return [] }
        return document.objects.filter { selectedObjectIDs.contains($0.id) }
    }

    var canMergeSelectedShapes: Bool { selectedObjectIDs.count >= 2 }

    /// Applies `transform` to the selected object's stored copy in the
    /// document (spec: manual per-object overrides before export). This
    /// only updates the master document -- it deliberately does not
    /// re-flatten the stitch plan on every edit, the same way resizing or
    /// changing the hoop doesn't either; Auto Digitize is the one explicit
    /// "regenerate now" action, so a user typing into a density field
    /// doesn't trigger a full re-digitize on every keystroke.
    func updateSelectedObject(_ transform: (inout EmbroideryObject) -> Void) {
        guard let id = selectedObjectID, var current = document,
              let index = current.objects.firstIndex(where: { $0.id == id }) else { return }
        beginUndoableChange()
        transform(&current.objects[index])
        document = current
        scheduleLiveRegenerate()
    }

    /// Removes every currently-selected object (spec: let the user edit
    /// the file, not just tweak per-object parameters) -- e.g. dropping a
    /// mis-detected speck or a background shape the auto-import picked up,
    /// one at a time or several at once via multi-select.
    func deleteSelectedObject() {
        guard var current = document, !selectedObjectIDs.isEmpty else { return }
        let ids = selectedObjectIDs
        guard current.objects.contains(where: { ids.contains($0.id) }) else { return }
        commitImmediateUndoSnapshot()
        current.objects.removeAll { ids.contains($0.id) }
        document = current
        selectedObjectIDs = []
        scheduleLiveRegenerate()
    }

    /// Reassigns every object currently using any of `sourceColors` to
    /// `target` in one action (spec: let the user edit the file -- bulk
    /// color cleanup across many auto-detected objects, not one at a
    /// time). Matches by RGB value, not `ThreadColor.id`, since objects
    /// created independently during import never share an id even when
    /// they're visually the same color.
    func mergeColors(from sourceColors: Set<StitchPilotCore.RGBColor>, into target: ThreadColor) {
        guard var current = document else { return }
        commitImmediateUndoSnapshot()
        for i in current.objects.indices where sourceColors.contains(current.objects[i].threadColor.rgb) {
            current.objects[i].threadColor = target
        }
        document = current
        scheduleLiveRegenerate()
    }

    /// Joins every currently-selected object's geometry into a single
    /// object -- the fix for the "last 10%" of a digitize where a letter
    /// or logo detail came in as several disconnected fragments (most
    /// often anti-aliasing noise breaking up what should be one solid
    /// shape). Select the pieces (rubber-band or shift-click on the
    /// canvas, or in the object list) and merge them back into one clean
    /// piece without needing to know *why* it fragmented. Uses
    /// `ShapeMerger`'s rasterize-and-retrace approach rather than true
    /// polygon union, which this engine doesn't otherwise implement --
    /// fine for joining a handful of nearby fragments, not a general
    /// vector-boolean tool.
    func mergeSelectedShapesIntoOneObject() {
        guard var current = document else { return }
        let ids = selectedObjectIDs
        let selected = current.objects.filter { ids.contains($0.id) }
        guard selected.count >= 2 else { return }
        guard let mergedShape = ShapeMerger.merge(selected.map { $0.shape }) else {
            errorMessage = "Couldn't merge the selected shapes."
            return
        }
        commitImmediateUndoSnapshot()

        let firstIndex = current.objects.firstIndex(where: { ids.contains($0.id) }) ?? current.objects.count
        let representative = selected[0]
        let parameters = StitchGenerationParameters()
        let stitchType = StitchTypeClassifier.classify(shape: mergedShape, parameters: parameters)
        let merged = EmbroideryObject(name: representative.name, shape: mergedShape, stitchType: stitchType,
                                       threadColor: representative.threadColor, parameters: parameters)
        current.objects.removeAll { ids.contains($0.id) }
        current.objects.insert(merged, at: min(firstIndex, current.objects.count))
        document = current
        selectedObjectIDs = [merged.id]
        scheduleLiveRegenerate()
        statusMessage = "Merged \(ids.count) objects into one."
    }

    // MARK: - Move / resize selection (canvas drag, corner handles)

    /// Translates every currently-selected object's shape by (dxMM, dyMM) --
    /// dragging a selection around the canvas, most usefully a lettering
    /// group (every glyph object is selected right after `addLettering`
    /// adds it) but works for any selection. Regenerates from the moved
    /// geometry like any other shape edit; stitch type is untouched since
    /// moving doesn't change a shape's own dimensions.
    func translateSelection(dxMM: Double, dyMM: Double) {
        guard var current = document, !selectedObjectIDs.isEmpty, dxMM != 0 || dyMM != 0 else { return }
        commitImmediateUndoSnapshot()
        let transform = AffineTransform2D.translation(dxMM, dyMM)
        for i in current.objects.indices where selectedObjectIDs.contains(current.objects[i].id) {
            current.objects[i].shape = current.objects[i].shape.transformed(by: transform)
        }
        document = current
        scheduleLiveRegenerate()
    }

    /// Scales every currently-selected object's shape by `scale`, anchored
    /// at `anchorMM` (the corner opposite whichever resize handle was
    /// dragged, so that corner stays fixed in place) -- dragging a
    /// selection's corner handle to resize it, e.g. a lettering group.
    /// Follows the same durability rule as `applyPhysicalSizeChange`: an
    /// object whose stitch type the user already picked manually keeps it,
    /// since resizing a shape shouldn't silently overwrite a deliberate
    /// choice back to whatever auto-classification would produce.
    func scaleSelection(scale: Double, anchorMM: Point2D) {
        guard var current = document, !selectedObjectIDs.isEmpty, scale > 0, abs(scale - 1) > 0.001 else { return }
        commitImmediateUndoSnapshot()
        let transform = AffineTransform2D.translation(-anchorMM.x, -anchorMM.y)
            .concatenating(.scale(scale, scale))
            .concatenating(.translation(anchorMM.x, anchorMM.y))
        for i in current.objects.indices where selectedObjectIDs.contains(current.objects[i].id) {
            current.objects[i].shape = current.objects[i].shape.transformed(by: transform)
            if !current.objects[i].stitchTypeIsManualOverride {
                current.objects[i].stitchType = StitchTypeClassifier.classify(shape: current.objects[i].shape, parameters: current.objects[i].parameters)
            }
        }
        document = current
        scheduleLiveRegenerate()
    }

    // MARK: - Paint (manual coverage fix, spec: "shade in the rest of an
    // area if the app only captures part of the shape")

    @Published var isPaintMode = false {
        didSet {
            guard isPaintMode else { return }
            // Paint and Erase are two mutually exclusive brush tools
            // sharing the same click-and-drag gesture on the canvas --
            // switching one on turns the other off, the same way neither
            // can coexist with an ordinary multi-selection (see below).
            isEraseMode = false
            // Painting and multi-selecting are two different tools sharing
            // the same click-and-drag gesture on the canvas; clearing the
            // selection when entering paint mode keeps the two from
            // fighting over what a drag means, and a fresh multi-selection
            // left over from before wouldn't be an intentional "extend
            // this object" target anyway.
            guard selectedObjectIDs.count > 1 else { return }
            selectedObjectIDs = []
        }
    }
    @Published var paintBrushRadiusMM: Double = 1.5
    @Published var paintColorRGB = StitchPilotCore.RGBColor(hex: 0x000000)

    // MARK: - Erase (the delete pen: manual coverage removal, the inverse
    // of Paint above -- fixing a spot the auto-digitize or an import
    // over-captured shouldn't require knowing which object to select and
    // deleting the whole thing, just drawing over the part that's wrong).

    @Published var isEraseMode = false {
        didSet {
            guard isEraseMode else { return }
            isPaintMode = false
            guard selectedObjectIDs.count > 1 else { return }
            selectedObjectIDs = []
        }
    }

    /// Erases a freehand brush stroke's own coverage from every object it
    /// overlaps -- unlike Paint (scoped to the single selected object, or
    /// else it creates something new), Erase acts on whatever the stroke
    /// actually touches regardless of selection, the more natural reading
    /// of "a delete pen that takes stuff away" wherever it's dragged. An
    /// object a stroke erases down to nothing is removed outright rather
    /// than left behind as an empty shape.
    func eraseStroke(points: [Point2D], radiusMM: Double) {
        guard radiusMM > 0, !points.isEmpty, var current = document, !current.objects.isEmpty else { return }

        // A cheap bounding-box pre-filter before the real (rasterize-and-
        // retrace) subtraction test -- most objects in a typical design
        // aren't anywhere near a given stroke, and skipping straight past
        // them keeps an erase drag responsive even on a design with many
        // objects.
        var strokeBox = BoundingBox.empty
        for p in points { strokeBox = strokeBox.union(BoundingBox(minX: p.x - radiusMM, minY: p.y - radiusMM, maxX: p.x + radiusMM, maxY: p.y + radiusMM)) }

        var touchedIndices: [Int] = []
        for i in current.objects.indices where current.objects[i].shape.boundingBox.intersects(strokeBox) {
            touchedIndices.append(i)
        }
        guard !touchedIndices.isEmpty else { return }

        var changedAnything = false
        var indicesToRemove: [Int] = []
        for i in touchedIndices {
            if let reduced = ShapeMerger.subtractStroke([current.objects[i].shape], strokePoints: points, radiusMM: radiusMM) {
                guard reduced != current.objects[i].shape else { continue }
                changedAnything = true
                current.objects[i].shape = reduced
                if !current.objects[i].stitchTypeIsManualOverride {
                    current.objects[i].stitchType = StitchTypeClassifier.classify(shape: reduced, parameters: current.objects[i].parameters)
                }
            } else {
                changedAnything = true
                indicesToRemove.append(i)
            }
        }
        guard changedAnything else { return }
        commitImmediateUndoSnapshot()
        let removedIDs = Set(indicesToRemove.map { current.objects[$0].id })
        if !removedIDs.isEmpty {
            current.objects.removeAll { removedIDs.contains($0.id) }
            selectedObjectIDs.subtract(removedIDs)
        }
        document = current
        scheduleLiveRegenerate()
        statusMessage = removedIDs.isEmpty
            ? "Erased from \(touchedIndices.count) object(s)."
            : "Erased \(removedIDs.count) object(s) entirely."
    }

    /// Extends the single selected object's shape with a freehand brush
    /// stroke, or -- if nothing is selected -- creates a brand-new object
    /// from the stroke alone. A paint tool rather than a vector-editing
    /// one specifically so fixing a gap doesn't require understanding why
    /// the gap happened, just seeing it and drawing over it.
    func paintStroke(points: [Point2D], radiusMM: Double) {
        guard radiusMM > 0, !points.isEmpty, var current = document else { return }

        if let id = selectedObjectID, let index = current.objects.firstIndex(where: { $0.id == id }) {
            guard let extended = ShapeMerger.mergeWithStroke([current.objects[index].shape], strokePoints: points, radiusMM: radiusMM) else { return }
            commitImmediateUndoSnapshot()
            current.objects[index].shape = extended
            current.objects[index].stitchType = StitchTypeClassifier.classify(shape: extended, parameters: current.objects[index].parameters)
            document = current
            scheduleLiveRegenerate()
            statusMessage = "Extended \(current.objects[index].name)."
        } else {
            guard let strokeShape = ShapeMerger.mergeWithStroke([], strokePoints: points, radiusMM: radiusMM) else { return }
            commitImmediateUndoSnapshot()
            let parameters = StitchGenerationParameters()
            let stitchType = StitchTypeClassifier.classify(shape: strokeShape, parameters: parameters)
            let threadColor = matchToThreadLibrary
                ? (ThreadLibrary.nearestMatch(to: paintColorRGB, in: effectivePalette) ?? .generic(paintColorRGB, name: "Painted Color"))
                : .generic(paintColorRGB, name: "Painted Color")
            let newObject = EmbroideryObject(name: "Painted Shape", shape: strokeShape, stitchType: stitchType,
                                              threadColor: threadColor, parameters: parameters)
            current.objects.append(newObject)
            document = current
            selectedObjectIDs = [newObject.id]
            scheduleLiveRegenerate()
            statusMessage = "Added a new painted shape."
        }
    }

    // MARK: - Lettering

    /// Every installed font family the Lettering tool's picker can offer,
    /// paired with the exact PostScript name `LetteringGenerator` needs
    /// (CoreText's own currency -- not always identical to the family
    /// name, e.g. some families' bold member has no space where the
    /// family name does). Resolves each family's bold member when it has
    /// one, since a bold, simple stroke satin-stitches most cleanly; the
    /// user still picks the family, this just chooses a sensible default
    /// weight within it rather than offering every weight as a separate
    /// scope-widening picker for a first version.
    static func availableLetteringFonts() -> [(displayName: String, postScriptName: String)] {
        let manager = NSFontManager.shared
        var results: [(displayName: String, postScriptName: String)] = []
        for family in manager.availableFontFamilies.sorted() {
            let bold = manager.font(withFamily: family, traits: .boldFontMask, weight: 9, size: 12)
            let font = bold ?? NSFont(name: family, size: 12) ?? manager.font(withFamily: family, traits: [], weight: 5, size: 12)
            guard let font else { continue }
            results.append((family, font.fontName))
        }
        return results
    }

    /// Generates one `EmbroideryObject` per glyph from `spec`
    /// (`LetteringGenerator`), translated so the combined result is
    /// centered on `targetCenter` -- the shared placement logic behind
    /// `addLettering`, `addLettering(spec:threadColor:replacing:)`, and
    /// `replaceDetectedText`, so all three ways of adding lettering
    /// position and classify it identically.
    private func generateLetteringObjects(spec: LetteringSpec, threadColor: ThreadColor, targetCenter: Point2D) throws -> [EmbroideryObject] {
        let shapes = try LetteringGenerator.generateShapes(spec: spec)
        var combined = BoundingBox.empty
        for shape in shapes { combined = combined.union(shape.boundingBox) }
        let offsetX = targetCenter.x - (combined.minX + combined.width / 2)
        let offsetY = targetCenter.y - (combined.minY + combined.height / 2)
        let translatedShapes = shapes.map { shape in
            VectorShape(subPaths: shape.subPaths.map { sp in
                SubPath(points: sp.points.map { Point2D($0.x + offsetX, $0.y + offsetY) }, closed: sp.closed)
            })
        }
        let parameters = StitchGenerationParameters()
        // One stitch type for the whole run (see `classifyLetteringRun`'s
        // doc comment), not classified letter-by-letter -- a hole letter
        // (O, P, R...) is the one unavoidable exception, handled per-glyph
        // by `classifyGlyphInRun`.
        let runStitchType = StitchTypeClassifier.classifyLetteringRun(shapes: translatedShapes, parameters: parameters, capHeightMM: spec.fontSizeMM)
        return translatedShapes.enumerated().map { i, translated -> EmbroideryObject in
            let stitchType = StitchTypeClassifier.classifyGlyphInRun(shape: translated, runStitchType: runStitchType)
            return EmbroideryObject(name: "Letter \(i + 1)", shape: translated, stitchType: stitchType,
                                     threadColor: threadColor, parameters: parameters)
        }
    }

    /// Generates real vector letterforms directly from a font's own
    /// outline (`LetteringGenerator`) and adds them to the current
    /// document as new objects -- one per glyph, each independently
    /// classified and stitched exactly like any other imported shape.
    /// This is the actual fix for text that raster tracing can never get
    /// right regardless of resolution or physical size (see
    /// CHANGELOG.md): instead of tracing an already-rendered image of
    /// text, generate the letterforms directly from the font, clean at
    /// any size or curve.
    func addLettering(spec: LetteringSpec, threadColor: ThreadColor) {
        do {
            // Center the new lettering in the current design; for a
            // brand-new document (no prior import), figure the center out
            // after generation, once the lettering's own size is known.
            var targetCenter = Point2D(physicalWidthMM / 2, physicalHeightMM / 2)
            let isNewDocument = document == nil || document!.boundingBox.isEmpty
            if isNewDocument {
                let previewShapes = try LetteringGenerator.generateShapes(spec: spec)
                var combined = BoundingBox.empty
                for shape in previewShapes { combined = combined.union(shape.boundingBox) }
                targetCenter = Point2D(combined.width / 2, combined.height / 2)
            }
            let newObjects = try generateLetteringObjects(spec: spec, threadColor: threadColor, targetCenter: targetCenter)
            commitImmediateUndoSnapshot()

            if var current = document, !isNewDocument {
                current.objects.append(contentsOf: newObjects)
                document = current
            } else {
                var combined = BoundingBox.empty
                for object in newObjects { combined = combined.union(object.shape.boundingBox) }
                lastRawShapes = []
                lastName = spec.text
                physicalWidthMM = combined.width + 20
                physicalHeightMM = combined.height + 20
                document = StitchDocument(name: spec.text, physicalWidthMM: physicalWidthMM, physicalHeightMM: physicalHeightMM, objects: newObjects)
            }
            selectedObjectIDs = Set(newObjects.map { $0.id })
            scheduleLiveRegenerate()
            statusMessage = "Added \"\(spec.text)\" as \(newObjects.count) lettering object(s)."
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// Like `addLettering`, but first removes `objectIDsToReplace` --
    /// offered by the Add Lettering sheet whenever objects are already
    /// selected when it's opened, so replacing a raster-traced fragment
    /// (or several) with correct, real lettering is one action instead of
    /// a separate manual delete before or after adding it. The new
    /// lettering is centered on the removed objects' own combined area,
    /// not the whole document, so it lands where they were.
    func addLettering(spec: LetteringSpec, threadColor: ThreadColor, replacing objectIDsToReplace: Set<EmbroideryObject.ID>) {
        guard !objectIDsToReplace.isEmpty, let current = document else {
            addLettering(spec: spec, threadColor: threadColor)
            return
        }
        do {
            var replacedBounds = BoundingBox.empty
            for object in current.objects where objectIDsToReplace.contains(object.id) {
                replacedBounds = replacedBounds.union(object.shape.boundingBox)
            }
            let targetCenter = replacedBounds.isEmpty ? Point2D(physicalWidthMM / 2, physicalHeightMM / 2) : replacedBounds.center
            let newObjects = try generateLetteringObjects(spec: spec, threadColor: threadColor, targetCenter: targetCenter)
            commitImmediateUndoSnapshot()

            var updated = current
            updated.objects.removeAll { objectIDsToReplace.contains($0.id) }
            updated.objects.append(contentsOf: newObjects)
            document = updated
            selectedObjectIDs = Set(newObjects.map { $0.id })
            scheduleLiveRegenerate()
            statusMessage = "Replaced \(objectIDsToReplace.count) object(s) with \"\(spec.text)\" as \(newObjects.count) lettering object(s)."
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// Converts a `TextDetector`-found region's pixel-space bounding box
    /// into the same mm-space every current object already lives in --
    /// the identical scale-and-center math `VectorShape.fitToPhysicalSize`
    /// applies to the original raw import, so a detected region's box
    /// lines up with whichever traced objects actually occupy that same
    /// area of the design. `nil` when there's no raw-import geometry to
    /// map against (a loaded project, or lettering-only document).
    private func mmBoundingBox(forPixelBox pixelBox: BoundingBox) -> BoundingBox? {
        guard !lastCombinedBounds.isEmpty, lastCombinedBounds.width > 0, lastCombinedBounds.height > 0 else { return nil }
        let scale = min(physicalWidthMM / lastCombinedBounds.width, physicalHeightMM / lastCombinedBounds.height)
        let offsetX = -lastCombinedBounds.minX * scale + (physicalWidthMM - lastCombinedBounds.width * scale) / 2
        let offsetY = -lastCombinedBounds.minY * scale + (physicalHeightMM - lastCombinedBounds.height * scale) / 2
        return BoundingBox(minX: pixelBox.minX * scale + offsetX, minY: pixelBox.minY * scale + offsetY,
                            maxX: pixelBox.maxX * scale + offsetX, maxY: pixelBox.maxY * scale + offsetY)
    }

    /// A reasonable starting letter height (in mm) for a detected text
    /// region -- its own pixel height mapped through the same scale
    /// `mmBoundingBox` uses. Approximate (a region's box typically spans
    /// ascenders/descenders, not just cap height), meant as a starting
    /// point in the review UI, not a precise measurement.
    func suggestedLetterHeightMM(for region: DetectedTextRegion) -> Double {
        guard lastCombinedBounds.width > 0, lastCombinedBounds.height > 0 else { return 10 }
        let scale = min(physicalWidthMM / lastCombinedBounds.width, physicalHeightMM / lastCombinedBounds.height)
        return max(2, region.boundingBoxPixels.height * scale)
    }

    /// Replaces whichever existing objects occupy a detected text
    /// region's own area with real generated lettering (`LetteringGenerator`)
    /// positioned to match that same spot -- the actual fix for text
    /// raster tracing left illegible, applied directly to the region it
    /// came from rather than requiring the user to delete the old
    /// fragments and re-add lettering by hand.
    func replaceDetectedText(_ region: DetectedTextRegion, spec: LetteringSpec, threadColor: ThreadColor) {
        guard let current = document else { return }
        do {
            let mmBox = mmBoundingBox(forPixelBox: region.boundingBoxPixels)
            let targetCenter = mmBox?.center ?? Point2D(physicalWidthMM / 2, physicalHeightMM / 2)
            let newObjects = try generateLetteringObjects(spec: spec, threadColor: threadColor, targetCenter: targetCenter)
            commitImmediateUndoSnapshot()

            var updated = current
            if let mmBox {
                // An object counts as "part of" this detected region (and
                // gets removed in favor of the new lettering) once at
                // least a third of its own area falls inside the region's
                // box -- close enough to catch the actual raster-traced
                // fragments this text produced without also sweeping up
                // an unrelated object that merely brushes the edge.
                let overlapFraction = 0.3
                updated.objects.removeAll { object in
                    let objBox = object.shape.boundingBox
                    let objArea = objBox.width * objBox.height
                    guard objArea > 0 else { return false }
                    let ix = max(0, min(objBox.maxX, mmBox.maxX) - max(objBox.minX, mmBox.minX))
                    let iy = max(0, min(objBox.maxY, mmBox.maxY) - max(objBox.minY, mmBox.minY))
                    return (ix * iy) / objArea > overlapFraction
                }
            }
            updated.objects.append(contentsOf: newObjects)
            document = updated
            selectedObjectIDs = Set(newObjects.map { $0.id })
            detectedTextRegions.removeAll { $0.id == region.id }
            scheduleLiveRegenerate()
            statusMessage = "Replaced \"\(region.text)\" with \(newObjects.count) lettering object(s)."
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    // MARK: - Undo

    /// Snapshots only what a user-visible edit can actually change: the
    /// document's contents, the finished-size fields, and the selection.
    /// Settings like the color preset, hoop, or thread-library toggle are
    /// deliberately left out of undo's scope -- they're not edits to the
    /// design itself, and folding them in would make "undo" revert things
    /// the user didn't just do.
    private struct UndoSnapshot {
        var document: StitchDocument?
        var physicalWidthMM: Double
        var physicalHeightMM: Double
        var selectedObjectIDs: Set<EmbroideryObject.ID>
    }

    @Published private(set) var canUndo = false
    private var undoStack: [UndoSnapshot] = []
    private let maxUndoDepth = 20
    private var pendingUndoSnapshot: UndoSnapshot?
    private var undoCommitTask: Task<Void, Never>?

    private func currentUndoSnapshot() -> UndoSnapshot {
        UndoSnapshot(document: document, physicalWidthMM: physicalWidthMM, physicalHeightMM: physicalHeightMM, selectedObjectIDs: selectedObjectIDs)
    }

    /// For edits that arrive as a rapid burst -- a slider drag firing on
    /// every intermediate value, or a text field committing on every
    /// keystroke -- capturing the state *before the drag started* once and
    /// only pushing it to the stack after things settle, rather than on
    /// every call, so one drag becomes one undo step instead of dozens.
    private func beginUndoableChange() {
        if pendingUndoSnapshot == nil {
            pendingUndoSnapshot = currentUndoSnapshot()
        }
        undoCommitTask?.cancel()
        undoCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.commitPendingUndoSnapshot()
        }
    }

    private func commitPendingUndoSnapshot() {
        guard let snapshot = pendingUndoSnapshot else { return }
        undoStack.append(snapshot)
        if undoStack.count > maxUndoDepth { undoStack.removeFirst(undoStack.count - maxUndoDepth) }
        canUndo = true
        pendingUndoSnapshot = nil
    }

    /// For one-shot actions (delete, merge, resize, import, open, redo) that
    /// never arrive as a burst -- pushes immediately rather than waiting out
    /// the debounce a slider drag needs, so e.g. deleting an object is its
    /// own undo step right away. Flushes any still-pending debounced edit
    /// first so it isn't silently dropped from the stack.
    private func commitImmediateUndoSnapshot() {
        if let pending = pendingUndoSnapshot {
            undoCommitTask?.cancel()
            undoStack.append(pending)
            pendingUndoSnapshot = nil
        }
        undoStack.append(currentUndoSnapshot())
        if undoStack.count > maxUndoDepth { undoStack.removeFirst(undoStack.count - maxUndoDepth) }
        canUndo = true
    }

    /// Steps back one edit. If an edit is still mid-burst (the debounce in
    /// `beginUndoableChange` hasn't committed it yet), undoes straight to
    /// the state from before that burst began rather than to some
    /// intermediate value the user never intentionally stopped on.
    func undo() {
        undoCommitTask?.cancel()
        if let pending = pendingUndoSnapshot {
            pendingUndoSnapshot = nil
            restore(pending)
            statusMessage = "Undid last change."
            return
        }
        guard let snapshot = undoStack.popLast() else { return }
        restore(snapshot)
        canUndo = !undoStack.isEmpty
        statusMessage = "Undid last change."
    }

    private func restore(_ snapshot: UndoSnapshot) {
        document = snapshot.document
        physicalWidthMM = snapshot.physicalWidthMM
        physicalHeightMM = snapshot.physicalHeightMM
        selectedObjectIDs = snapshot.selectedObjectIDs
        scheduleLiveRegenerate()
    }

    private var liveRegenerateTask: Task<Void, Never>?
    /// How many `scheduleLiveRegenerate` cycles are currently in flight
    /// (waiting out the debounce, or actually regenerating) -- a simple
    /// bool would risk an older, superseded cycle's own completion
    /// clearing `isRegeneratingPreview` while a newer one it overlapped
    /// with is still genuinely working. Only reaching zero (every
    /// outstanding cycle accounted for) clears it.
    private var regenerateInFlightCount = 0

    /// Debounced regeneration so the preview updates on its own after an
    /// edit -- a density slider drag, a stitch-type change, a color merge
    /// -- without the user needing a separate manual "regenerate" step
    /// (spec: the one-click promise extends to editing, not just the
    /// initial digitize). A short delay means a fast slider drag only runs
    /// the actual per-object generation pass once it settles, not on every
    /// intermediate value while dragging. `isRegeneratingPreview` flips on
    /// immediately (not just once the debounce elapses) so the canvas can
    /// show "refreshing" feedback right from the edit itself.
    private func scheduleLiveRegenerate() {
        guard document != nil else { return }
        liveRegenerateTask?.cancel()
        regenerateInFlightCount += 1
        isRegeneratingPreview = true
        liveRegenerateTask = Task { [weak self] in
            defer { self?.finishedOneRegenerateAttempt() }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await self?.autoDigitizeInBackground()
        }
    }

    private func finishedOneRegenerateAttempt() {
        regenerateInFlightCount = max(0, regenerateInFlightCount - 1)
        if regenerateInFlightCount == 0 { isRegeneratingPreview = false }
    }

    /// Same end result as `autoDigitize()`, except the expensive part --
    /// re-running `DigitizePipeline` over every object in the document --
    /// happens off the main actor, so a live edit (a slider drag, a color
    /// merge, a paint stroke) doesn't visibly block the UI while it
    /// computes; `stitchPlan`/`lastColorSequence`/`readinessReport` are
    /// only assigned once it finishes, back on the main actor. Only used
    /// by the debounced live-preview path (`scheduleLiveRegenerate`) --
    /// every explicit "digitize now and use the result immediately" action
    /// (Click to Create, Redo from Original, import, open project) keeps
    /// calling the synchronous `autoDigitize()`, since those need
    /// `stitchPlan` set before they return, not sometime after.
    ///
    /// If a newer edit arrives (and cancels `liveRegenerateTask`) while
    /// this is still computing, the in-flight background work isn't
    /// interrupted -- `DigitizePipeline` has no mid-run cancellation
    /// points to interrupt at -- but its result is discarded once it
    /// finishes rather than clobbering whatever the newer edit produces,
    /// via the `Task.isCancelled` check below.
    private func autoDigitizeInBackground() async {
        guard let document else { return }
        // The edit generation this exact `document` snapshot represents --
        // captured now, before the async gap below, so the result can only
        // ever be credited to the generation it was actually computed
        // from, not whatever generation happens to be current once it
        // finishes (see `stitchPlanGeneration`'s doc comment).
        let capturedGeneration = documentEditGeneration
        errorMessage = nil
        let hoopWidthMM = selectedHoop?.widthMM
        let hoopHeightMM = selectedHoop?.heightMM
        let generation = Task.detached(priority: .userInitiated) { () throws -> (StitchPlan, [ThreadColor]) in
            try DigitizePipeline.flattenWithColors(document)
        }
        do {
            let (plan, colors) = try await generation.value
            guard !Task.isCancelled else { return }
            stitchPlan = plan
            stitchPlanGeneration = capturedGeneration
            lastColorSequence = colors
            readinessReport = QualityAnalyzer.analyze(plan, hoopWidthMM: hoopWidthMM, hoopHeightMM: hoopHeightMM)
            statusMessage = "\(plan.stitchCount) stitches, \(plan.colorChangeCount) color change(s)."
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// Discards the current design and returns to a blank slate (spec: let
    /// the user start a new project without quitting and relaunching).
    /// StitchPilot has no "unsaved changes" tracking yet, so this doesn't
    /// prompt to save first -- matching every other full-state reset here
    /// (a fresh import, opening a different project), which already
    /// discard in-progress edits the same way.
    func newProject() {
        commitImmediateUndoSnapshot()
        liveRegenerateTask?.cancel()
        document = nil
        stitchPlan = nil
        stitchPlanGeneration = nil
        readinessReport = nil
        lastColorSequence = []
        selectedObjectIDs = []
        lastRawShapes = []
        lastFillColors = []
        lastCombinedBounds = .empty
        lastImportedURL = nil
        physicalWidthMM = 100
        physicalHeightMM = 100
        errorMessage = nil
        statusMessage = "Drag in an image or SVG file, use Add Lettering for a text-only design, then click Click to Create."
    }

    private func isRasterURL(_ url: URL) -> Bool { url.pathExtension.lowercased() != "svg" }

    func openArtworkWithPanel() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.svg, .png, .jpeg, .tiff, .bmp, .gif]
        if let webp = UTType(filenameExtension: "webp") { types.append(webp) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            importFile(url: url)
        }
    }

    func importFile(url: URL) {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        commitImmediateUndoSnapshot()
        lastImportedURL = url

        do {
            let data = try Data(contentsOf: url)
            var rawShapes: [VectorShape]
            var fillColors: [StitchPilotCore.RGBColor?]

            detectedTextRegions = []
            if !isRasterURL(url) {
                let result = try SVGImporter.importShapes(from: data)
                rawShapes = result.shapes
                fillColors = result.fillColors
            } else {
                let result = try ImageImporter.importShapes(from: data, maxColors: colorPreset.defaultMaxColors)
                rawShapes = result.shapes
                fillColors = result.fillColors
                // Best-effort: text detection failing (or finding nothing)
                // should never block the import itself -- it's an
                // enhancement on top of raster tracing, not a requirement
                // for it. Only text Vision is genuinely confident about is
                // worth surfacing; see TextDetector's own doc comment on
                // why curved ring text and precise font matching are
                // deliberately out of scope rather than guessed at.
                detectedTextRegions = (try? TextDetector.detectTextRegions(from: data, minConfidence: 0.7)) ?? []
            }

            guard !rawShapes.isEmpty else {
                errorMessage = "No usable shapes were found in this file."
                return
            }

            var combined = BoundingBox.empty
            for s in rawShapes { combined = combined.union(s.boundingBox) }
            sourceAspectRatio = combined.height > 0 ? combined.width / combined.height : 1
            // Size the design from its own detail, not a fixed default --
            // a plain bold logo stays at the normal default size, but
            // artwork with fine detail (small text, a ring of curved
            // lettering) gets scaled up enough that its thinnest real
            // stroke has a chance of surviving as an actual stitch rather
            // of running stitch collapsing into an illegible squiggle at a
            // size no digitizer, automatic or human, could sew cleanly.
            // The Finished Size panel still lets the user override this
            // immediately after -- this only sets where they start from.
            physicalWidthMM = SizeRecommender.recommendedWidthMM(for: rawShapes, currentWidthMM: defaultPhysicalWidthMM)
            if lockAspectRatio {
                physicalHeightMM = sourceAspectRatio > 0 ? physicalWidthMM / sourceAspectRatio : physicalWidthMM
            }

            rebuildDocument(rawShapes: rawShapes, fillColors: fillColors, combinedBounds: combined, name: url.deletingPathExtension().lastPathComponent)
            statusMessage = "Imported \(rawShapes.count) shape(s) from \(url.lastPathComponent)."
            // Digitize right away rather than waiting for a separate manual
            // step -- the preview should reflect what's on screen without
            // the user needing to know to ask for it (spec: the one-click
            // promise starts at import, not just at export).
            autoDigitize()
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// Re-fits stored source shapes to the current physical size and
    /// rebuilds objects. Called on import and whenever the user changes size
    /// — regenerating from geometry, never scaling stitch coordinates
    /// (spec §39).
    private var lastRawShapes: [VectorShape] = []
    private var lastFillColors: [StitchPilotCore.RGBColor?] = []
    private var lastCombinedBounds: BoundingBox = .empty
    private var lastName: String = "Design"

    private func rebuildDocument(rawShapes: [VectorShape], fillColors: [StitchPilotCore.RGBColor?], combinedBounds: BoundingBox, name: String) {
        lastRawShapes = rawShapes
        lastFillColors = fillColors
        lastCombinedBounds = combinedBounds
        lastName = name
        regenerateFromStoredGeometry()
    }

    /// Resizes the *current* document, whatever its origin (a fresh import
    /// or a loaded `.stitchpilot` project) — regenerating each object's
    /// geometry from the document's own current bounding box, never scaling
    /// already-generated stitch coordinates (spec §39). This works
    /// uniformly for both cases because it always re-derives from
    /// `document` itself rather than depending on cached raw-import state,
    /// which a loaded project doesn't have.
    func applyPhysicalSizeChange() {
        guard let current = document else { return }
        let currentBounds = current.boundingBox
        guard !currentBounds.isEmpty else { return }
        commitImmediateUndoSnapshot()

        let resizedObjects = current.objects.map { object -> EmbroideryObject in
            var resized = object
            resized.shape = object.shape.fitToPhysicalSize(widthMM: physicalWidthMM, heightMM: physicalHeightMM, within: currentBounds)
            // A shape's stitch width in mm changes with the document's
            // physical size even though nothing about the shape itself
            // changed -- a stroke that was too thin for satin at a small
            // size can clear that bar once scaled up (or the reverse,
            // scaling down). Re-classifying here, exactly like a fresh
            // import already does in `regenerateFromStoredGeometry`, is
            // what actually fixes small text/detail on resize -- without
            // it, an object stayed stuck with whatever stitch type its
            // *original* size happened to produce, so scaling up a design
            // that was digitized too small kept its illegible running-
            // stitch text illegible even at a size that could have sewn it
            // as clean satin.
            //
            // But once the user has explicitly picked a stitch type for
            // this object in the inspector, that choice is durable --
            // resizing must not silently overwrite it back to whatever
            // auto-classification would have produced.
            if !resized.stitchTypeIsManualOverride {
                resized.stitchType = StitchTypeClassifier.classify(shape: resized.shape, parameters: resized.parameters)
            }
            return resized
        }
        document = StitchDocument(name: current.name, physicalWidthMM: physicalWidthMM, physicalHeightMM: physicalHeightMM, objects: resizedObjects)
        scheduleLiveRegenerate()
    }

    /// A standard placement size (left chest, cap front, sleeve, etc.) sets
    /// *both* dimensions explicitly, unlike a manual width edit which
    /// respects "lock aspect ratio" and derives the other side -- a preset
    /// already encodes a deliberate width/height pair, so it should apply
    /// exactly as specified rather than being reshaped by that toggle.
    func applyGarmentSizePreset(_ preset: GarmentSizePreset) {
        physicalWidthMM = preset.widthMM
        physicalHeightMM = preset.heightMM
        applyPhysicalSizeChange()
    }

    // MARK: - Project-wide density

    /// A standalone "set every matching object to this value" control, not
    /// a live readout of the document's actual (possibly varied) per-object
    /// densities -- the point is a fast way to push one density across the
    /// whole project at once, which per-object editing in the Object
    /// Inspector doesn't give you. Individual objects can still be tuned
    /// afterward without this drifting or fighting them.
    @Published var globalSatinDensityMM: Double = 0.4 {
        didSet {
            guard oldValue != globalSatinDensityMM else { return }
            applyGlobalSatinDensity()
        }
    }
    @Published var globalFillSpacingMM: Double = 0.4 {
        didSet {
            guard oldValue != globalFillSpacingMM else { return }
            applyGlobalFillSpacing()
        }
    }

    private func applyGlobalSatinDensity() {
        guard var current = document, current.objects.contains(where: { $0.stitchType == .satin }) else { return }
        beginUndoableChange()
        for i in current.objects.indices where current.objects[i].stitchType == .satin {
            current.objects[i].parameters.satinDensityMM = globalSatinDensityMM
        }
        document = current
        scheduleLiveRegenerate()
    }

    private func applyGlobalFillSpacing() {
        guard var current = document, current.objects.contains(where: { $0.stitchType == .tatamiFill }) else { return }
        beginUndoableChange()
        for i in current.objects.indices where current.objects[i].stitchType == .tatamiFill {
            current.objects[i].parameters.fillSpacingMM = globalFillSpacingMM
        }
        document = current
        scheduleLiveRegenerate()
    }

    private func regenerateFromStoredGeometry() {
        var objects: [EmbroideryObject] = []
        for (i, shape) in lastRawShapes.enumerated() {
            let fitted = shape.fitToPhysicalSize(widthMM: physicalWidthMM, heightMM: physicalHeightMM, within: lastCombinedBounds)
            let detectedRGB = (i < lastFillColors.count ? lastFillColors[i] : nil) ?? StitchPilotCore.RGBColor(hex: 0x000000)
            let threadColor: StitchPilotCore.ThreadColor
            if matchToThreadLibrary, let matched = ThreadLibrary.nearestMatch(to: detectedRGB, in: effectivePalette) {
                threadColor = matched
            } else {
                threadColor = .generic(detectedRGB, name: "Imported Color \(i + 1)")
            }
            let parameters = StitchGenerationParameters()
            let stitchType = StitchTypeClassifier.classify(shape: fitted, parameters: parameters)
            let object = EmbroideryObject(name: "Object \(i + 1)", shape: fitted, stitchType: stitchType,
                                           threadColor: threadColor, parameters: parameters)
            objects.append(object)
        }
        document = StitchDocument(name: lastName, physicalWidthMM: physicalWidthMM, physicalHeightMM: physicalHeightMM, objects: objects)
    }

    /// Whether there's an originally-imported source to redo from. A
    /// project opened from a `.stitchpilot` file has no raw import behind
    /// it (its objects already carry final geometry), so `false` there.
    var hasOriginalArtwork: Bool { !lastRawShapes.isEmpty }

    /// Discards every edit made since the original file was imported --
    /// per-object overrides, color merges, deletions, thread-library
    /// rematches -- and rebuilds the document fresh from the *originally
    /// imported* artwork at the current physical size, rather than from
    /// whatever the document happens to look like now. This is "redo" in
    /// the sense of re-running the one-click creation process again from
    /// scratch, not a generic redo of the last undone edit (see `undo()`
    /// for that); the emphasis on the *original* file matters because
    /// naively re-digitizing the current (possibly hand-edited) document
    /// would just reproduce the same edits, not actually start over.
    func redoEmbroideryFileCreation() {
        guard hasOriginalArtwork else {
            errorMessage = "No original artwork to redo from — import a file first."
            return
        }
        commitImmediateUndoSnapshot()
        selectedObjectIDs = []
        regenerateFromStoredGeometry()
        autoDigitize()
        statusMessage = "Redone from the original artwork — edits made since import were discarded."
    }

    func autoDigitize() {
        guard let document else { return }
        errorMessage = nil
        do {
            // Computes the plan and color sequence together in one pass --
            // see `flattenWithColors`'s doc comment on why that matters for
            // a design with many objects (a detailed raster import
            // especially): generating every object's stitches twice over
            // (once here, again whenever something needs the colors) was a
            // real, user-visible slowdown. `lastColorSequence` lets export
            // and the canvas preview reuse this same result instead of
            // recomputing it themselves.
            let (plan, colors) = try DigitizePipeline.flattenWithColors(document)
            stitchPlan = plan
            stitchPlanGeneration = documentEditGeneration
            lastColorSequence = colors
            // Quality analysis (spec §33/§76) runs automatically right
            // after generation, not as a separate manual step — the user
            // should see whether a design is ready to sew as part of
            // seeing the preview, not have to remember to ask for it.
            readinessReport = QualityAnalyzer.analyze(plan, hoopWidthMM: selectedHoop?.widthMM, hoopHeightMM: selectedHoop?.heightMM)
            statusMessage = "\(plan.stitchCount) stitches, \(plan.colorChangeCount) color change(s)."
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    /// The One-Click Stitch action (spec: OneClickStitch's whole promise —
    /// "turn any image into embroidery," fast/easy/affordable): runs Auto
    /// Digitize and then immediately prompts to save the result, combining
    /// what would otherwise be two separate manual steps (Auto Digitize,
    /// then Export from a menu) into the single button most users actually
    /// want. The save panel offers both machine formats via its own format
    /// picker rather than committing to one up front, so this one action
    /// still covers both Tajima and Brother/Baby Lock machines.
    func createEmbroideryFile() {
        guard document != nil else {
            errorMessage = "Import artwork first, then click Click to Create."
            return
        }
        autoDigitize()
        guard stitchPlan != nil else { return } // autoDigitize already set errorMessage on failure
        exportChoosingFormat()
    }

    private func exportChoosingFormat() {
        guard let plan = stitchPlan, let document else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.name + ".dst"
        panel.allowedContentTypes = [UTType(filenameExtension: "dst") ?? .data, UTType(filenameExtension: "pes") ?? .data,
                                      UTType(filenameExtension: "exp") ?? .data, UTType(filenameExtension: "jef") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            switch url.pathExtension.lowercased() {
            case "pes":
                data = try PESFormat.write(plan, designName: document.name, threadColors: lastColorSequence.map { $0.rgb })
                _ = try PESFormat.read(data) // self-validate before ever handing the file to the user (spec §59)
            case "exp":
                data = try EXPFormat.write(plan, designName: document.name)
                _ = try EXPFormat.read(data)
            case "jef":
                data = try JEFFormat.write(plan, designName: document.name, threadColors: lastColorSequence.map { $0.rgb })
                _ = try JEFFormat.read(data)
            default:
                data = try DSTFormat.write(plan, designName: document.name)
                _ = try DSTFormat.read(data)
            }
            try data.write(to: url)
            statusMessage = "Created \(url.lastPathComponent)."
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    func exportDST() {
        guard let plan = stitchPlan, let document else {
            errorMessage = "Import artwork first — OneClickStitch digitizes it automatically."
            return
        }
        do {
            let data = try DSTFormat.write(plan, designName: document.name)
            // Self-validate before ever handing the file to the user (spec §59).
            _ = try DSTFormat.read(data)
            saveExportedFile(data, suggestedName: document.name + ".dst", extension: "dst")
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    func exportPES() {
        guard let plan = stitchPlan, let document else {
            errorMessage = "Import artwork first — OneClickStitch digitizes it automatically."
            return
        }
        do {
            let data = try PESFormat.write(plan, designName: document.name, threadColors: lastColorSequence.map { $0.rgb })
            // Self-validate before ever handing the file to the user (spec §59).
            _ = try PESFormat.read(data)
            saveExportedFile(data, suggestedName: document.name + ".pes", extension: "pes")
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    func exportEXP() {
        guard let plan = stitchPlan, let document else {
            errorMessage = "Import artwork first — OneClickStitch digitizes it automatically."
            return
        }
        do {
            let data = try EXPFormat.write(plan, designName: document.name)
            // Self-validate before ever handing the file to the user (spec §59).
            _ = try EXPFormat.read(data)
            saveExportedFile(data, suggestedName: document.name + ".exp", extension: "exp")
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    func exportJEF() {
        guard let plan = stitchPlan, let document else {
            errorMessage = "Import artwork first — OneClickStitch digitizes it automatically."
            return
        }
        do {
            let data = try JEFFormat.write(plan, designName: document.name, threadColors: lastColorSequence.map { $0.rgb })
            // Self-validate before ever handing the file to the user (spec §59).
            _ = try JEFFormat.read(data)
            saveExportedFile(data, suggestedName: document.name + ".jef", extension: "jef")
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    // MARK: - Sharing (spec: let the user send the file, not just save it
    // locally -- AirDrop, Mail, Messages, etc. via the system share sheet).

    enum ShareFormat { case dst, pes, exp, jef }

    /// Presents Apple's native share sheet for the current design's
    /// embroidery file. The share sheet needs a real file on disk (not
    /// in-memory data), so this writes to a temporary location first --
    /// same self-validating write-then-read-back as the Save panel exports,
    /// since a file about to be handed to someone else deserves the same
    /// spec §59 guarantee as one saved locally.
    func shareCurrentFile(format: ShareFormat) {
        guard let plan = stitchPlan, let document else {
            errorMessage = "Import artwork first — OneClickStitch digitizes it automatically."
            return
        }
        do {
            let data: Data
            let ext: String
            switch format {
            case .dst:
                data = try DSTFormat.write(plan, designName: document.name)
                _ = try DSTFormat.read(data)
                ext = "dst"
            case .pes:
                data = try PESFormat.write(plan, designName: document.name, threadColors: lastColorSequence.map { $0.rgb })
                _ = try PESFormat.read(data)
                ext = "pes"
            case .exp:
                data = try EXPFormat.write(plan, designName: document.name)
                _ = try EXPFormat.read(data)
                ext = "exp"
            case .jef:
                data = try JEFFormat.write(plan, designName: document.name, threadColors: lastColorSequence.map { $0.rgb })
                _ = try JEFFormat.read(data)
                ext = "jef"
            }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(document.name)
                .appendingPathExtension(ext)
            try data.write(to: tempURL, options: .atomic)

            guard let contentView = NSApp.keyWindow?.contentView else { return }
            let picker = NSSharingServicePicker(items: [tempURL])
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    // MARK: - Project file (spec §6: the .stitchpilot editable master)

    func saveProject() {
        guard let document else {
            errorMessage = "Nothing to save yet."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.name + "." + ProjectFile.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectFile.fileExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectFileFormat.write(document).write(to: url)
            statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    func openProjectWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectFile.fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url: url)
    }

    func openProject(url: URL) {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        commitImmediateUndoSnapshot()
        do {
            let loaded = try ProjectFileFormat.read(try Data(contentsOf: url))
            document = loaded
            physicalWidthMM = loaded.physicalWidthMM
            physicalHeightMM = loaded.physicalHeightMM
            // A loaded project's objects already carry final geometry,
            // classification, and thread colors -- there's no "original
            // raw import" to revert to, so the color-preset/thread-matching
            // toggles simply have no effect until a new file is imported.
            lastRawShapes = []
            lastFillColors = []
            lastCombinedBounds = .empty
            lastImportedURL = nil
            statusMessage = "Opened \(url.lastPathComponent)."
            autoDigitize()
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    private func saveExportedFile(_ data: Data, suggestedName: String, extension ext: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            statusMessage = "Exported \(url.lastPathComponent)."
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
