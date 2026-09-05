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

    @Published var statusMessage: String = "Drag in an image or SVG file to begin."
    @Published var errorMessage: String?
    @Published var isBusy = false

    private func isRasterURL(_ url: URL) -> Bool { url.pathExtension.lowercased() != "svg" }

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
            statusMessage = "Imported \(rawShapes.count) shape(s) from \(url.lastPathComponent). Set size and click Auto Digitize."
            stitchPlan = nil
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

    func applyPhysicalSizeChange() {
        guard !lastRawShapes.isEmpty else { return }
        regenerateFromStoredGeometry()
        stitchPlan = nil
    }

    private func regenerateFromStoredGeometry() {
        var objects: [EmbroideryObject] = []
        for (i, shape) in lastRawShapes.enumerated() {
            let fitted = shape.fitToPhysicalSize(widthMM: physicalWidthMM, heightMM: physicalHeightMM, within: lastCombinedBounds)
            let rgb = (i < lastFillColors.count ? lastFillColors[i] : nil) ?? StitchPilotCore.RGBColor(hex: 0x000000)
            let parameters = StitchGenerationParameters()
            let stitchType = StitchTypeClassifier.classify(shape: fitted, parameters: parameters)
            let object = EmbroideryObject(name: "Object \(i + 1)", shape: fitted, stitchType: stitchType,
                                           threadColor: .generic(rgb, name: "Imported Color \(i + 1)"), parameters: parameters)
            objects.append(object)
        }
        document = StitchDocument(name: lastName, physicalWidthMM: physicalWidthMM, physicalHeightMM: physicalHeightMM, objects: objects)
    }

    func autoDigitize() {
        guard let document else { return }
        errorMessage = nil
        do {
            stitchPlan = try DigitizePipeline.flatten(document)
            statusMessage = "\(stitchPlan?.stitchCount ?? 0) stitches, \(stitchPlan?.colorChangeCount ?? 0) color change(s)."
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

            let panel = NSSavePanel()
            panel.nameFieldStringValue = document.name + ".dst"
            panel.allowedContentTypes = [UTType(filenameExtension: "dst") ?? .data]
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
                statusMessage = "Exported \(url.lastPathComponent)."
            }
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
