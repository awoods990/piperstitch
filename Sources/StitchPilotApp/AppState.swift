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
            stitchPlan = nil
            readinessReport = nil
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

    @Published var statusMessage: String = "Drag in an image or SVG file, then click Create Embroidery File."
    @Published var errorMessage: String?
    @Published var isBusy = false

    /// The object list's current selection, for manual per-object parameter
    /// overrides (the Object Inspector). Self-healing rather than reset
    /// everywhere a new object set replaces the old one (import, resize,
    /// project load all mint fresh `EmbroideryObject` ids): `selectedObject`
    /// below simply returns nil once the id no longer matches anything in
    /// the current document, which naturally clears the inspector.
    @Published var selectedObjectID: EmbroideryObject.ID?

    var selectedObject: EmbroideryObject? {
        guard let id = selectedObjectID, let document else { return nil }
        return document.objects.first { $0.id == id }
    }

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
        transform(&current.objects[index])
        document = current
    }

    /// Removes the selected object entirely (spec: let the user edit the
    /// file, not just tweak per-object parameters) -- e.g. dropping a
    /// mis-detected speck or a background shape the auto-import picked up.
    /// Like `updateSelectedObject`, only touches the master document; the
    /// stitch plan (if any) is now stale until the next Auto Digitize, same
    /// as any other manual edit.
    func deleteSelectedObject() {
        guard let id = selectedObjectID, var current = document,
              let index = current.objects.firstIndex(where: { $0.id == id }) else { return }
        current.objects.remove(at: index)
        document = current
        selectedObjectID = nil
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
            statusMessage = "Imported \(rawShapes.count) shape(s) from \(url.lastPathComponent). Adjust the size if needed, then click Create Embroidery File."
            stitchPlan = nil
            readinessReport = nil
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

        let resizedObjects = current.objects.map { object -> EmbroideryObject in
            var resized = object
            resized.shape = object.shape.fitToPhysicalSize(widthMM: physicalWidthMM, heightMM: physicalHeightMM, within: currentBounds)
            return resized
        }
        document = StitchDocument(name: current.name, physicalWidthMM: physicalWidthMM, physicalHeightMM: physicalHeightMM, objects: resizedObjects)
        stitchPlan = nil
        readinessReport = nil
    }

    private func regenerateFromStoredGeometry() {
        var objects: [EmbroideryObject] = []
        for (i, shape) in lastRawShapes.enumerated() {
            let fitted = shape.fitToPhysicalSize(widthMM: physicalWidthMM, heightMM: physicalHeightMM, within: lastCombinedBounds)
            let detectedRGB = (i < lastFillColors.count ? lastFillColors[i] : nil) ?? StitchPilotCore.RGBColor(hex: 0x000000)
            let threadColor: StitchPilotCore.ThreadColor
            if matchToThreadLibrary, let matched = ThreadLibrary.nearestMatch(to: detectedRGB) {
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
            errorMessage = "Import artwork first, then click Create Embroidery File."
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
        panel.allowedContentTypes = [UTType(filenameExtension: "dst") ?? .data, UTType(filenameExtension: "pes") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if url.pathExtension.lowercased() == "pes" {
                data = try PESFormat.write(plan, designName: document.name, threadColors: lastColorSequence.map { $0.rgb })
                _ = try PESFormat.read(data) // self-validate before ever handing the file to the user (spec §59)
            } else {
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
            errorMessage = "Click Auto Digitize before exporting."
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
            errorMessage = "Click Auto Digitize before exporting."
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
            stitchPlan = nil
            readinessReport = nil
            statusMessage = "Opened \(url.lastPathComponent)."
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
