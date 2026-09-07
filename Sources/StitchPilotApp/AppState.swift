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
    @Published var document: StitchDocument?
    @Published var stitchPlan: StitchPlan?
    @Published var readinessReport: EmbroideryReadinessReport?
    /// The color sequence for the current `stitchPlan`, computed alongside
    /// it in `autoDigitize()` -- exported and the canvas preview both need
    /// this, and recomputing it independently (as they each used to) means
    /// redoing the whole per-object generation pass again just for colors.
    @Published private(set) var lastColorSequence: [ThreadColor] = []
    @Published var physicalWidthMM: Double = 100
    @Published var physicalHeightMM: Double = 100
    @Published var lockAspectRatio: Bool = true
    private var sourceAspectRatio: Double = 1

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

    @Published var statusMessage: String = "Drag in an image or SVG file, then click Click to Create."
    @Published var errorMessage: String?
    @Published var isBusy = false

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

    // MARK: - Paint (manual coverage fix, spec: "shade in the rest of an
    // area if the app only captures part of the shape")

    @Published var isPaintMode = false {
        didSet {
            // Painting and multi-selecting are two different tools sharing
            // the same click-and-drag gesture on the canvas; clearing the
            // selection when entering paint mode keeps the two from
            // fighting over what a drag means, and a fresh multi-selection
            // left over from before wouldn't be an intentional "extend
            // this object" target anyway.
            guard isPaintMode, selectedObjectIDs.count > 1 else { return }
            selectedObjectIDs = []
        }
    }
    @Published var paintBrushRadiusMM: Double = 1.5
    @Published var paintColorRGB = StitchPilotCore.RGBColor(hex: 0x000000)

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

    /// Debounced regeneration so the preview updates on its own after an
    /// edit -- a density slider drag, a stitch-type change, a color merge
    /// -- without the user needing a separate manual "regenerate" step
    /// (spec: the one-click promise extends to editing, not just the
    /// initial digitize). A short delay means a fast slider drag only runs
    /// the actual per-object generation pass once it settles, not on every
    /// intermediate value while dragging.
    private func scheduleLiveRegenerate() {
        guard document != nil else { return }
        liveRegenerateTask?.cancel()
        liveRegenerateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.autoDigitize()
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
        statusMessage = "Drag in an image or SVG file, then click Click to Create."
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

            if !isRasterURL(url) {
                let result = try SVGImporter.importShapes(from: data)
                rawShapes = result.shapes
                fillColors = result.fillColors
            } else {
                let result = try ImageImporter.importShapes(from: data, maxColors: colorPreset.defaultMaxColors)
                rawShapes = result.shapes
                fillColors = result.fillColors
            }

            guard !rawShapes.isEmpty else {
                errorMessage = "No usable shapes were found in this file."
                return
            }

            var combined = BoundingBox.empty
            for s in rawShapes { combined = combined.union(s.boundingBox) }
            sourceAspectRatio = combined.height > 0 ? combined.width / combined.height : 1
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
                                      UTType(filenameExtension: "exp") ?? .data]
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

    // MARK: - Sharing (spec: let the user send the file, not just save it
    // locally -- AirDrop, Mail, Messages, etc. via the system share sheet).

    enum ShareFormat { case dst, pes, exp }

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
