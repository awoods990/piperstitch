import Testing
import Foundation
@testable import StitchPilotCore

/// Exercises the exact sequence of StitchPilotCore calls AppState makes for
/// the full workflow spec §47 describes (import -> size -> Auto Digitize ->
/// quality check against a hoop -> save project -> reopen -> resize ->
/// export), using real file I/O. StitchPilotApp itself can't be unit tested
/// directly (it's a separate target with no test coverage, and there's no
/// way to drive the native macOS UI in this environment), so this is the
/// closest thing to an end-to-end check of what "opening the app and using
/// it" actually does under the hood.
struct AppWorkflowIntegrationTests {
    private func testArtworkURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestArtwork")
            .appendingPathComponent(name)
    }

    @Test func fullWorkflowImportToExport() throws {
        // 1. Import (as AppState.importFile does for an SVG).
        let data = try Data(contentsOf: testArtworkURL("multi_color_badge.svg"))
        let imported = try SVGImporter.importShapes(from: data)
        #expect(imported.shapes.count == 4)

        var combined = BoundingBox.empty
        for s in imported.shapes { combined = combined.union(s.boundingBox) }

        // 2. Fit to a finished size, classify, and match thread colors (as
        // AppState.regenerateFromStoredGeometry does).
        let sizeMM = 80.0
        var objects: [EmbroideryObject] = []
        for (i, shape) in imported.shapes.enumerated() {
            let fitted = shape.fitToPhysicalSize(widthMM: sizeMM, heightMM: sizeMM, within: combined)
            let detected = imported.fillColors[i] ?? RGBColor(hex: 0x000000)
            let thread = ThreadLibrary.nearestMatch(to: detected) ?? .generic(detected)
            let params = StitchGenerationParameters()
            let stitchType = StitchTypeClassifier.classify(shape: fitted, parameters: params)
            objects.append(EmbroideryObject(name: "Object \(i)", shape: fitted, stitchType: stitchType, threadColor: thread, parameters: params))
        }
        var document = StitchDocument(name: "WorkflowTest", physicalWidthMM: sizeMM, physicalHeightMM: sizeMM, objects: objects)

        // 3. Auto Digitize + quality check against a hoop (as AppState.autoDigitize does).
        var plan = try DigitizePipeline.flatten(document)
        #expect(plan.stitchCount > 0)
        let hoop = HoopProfile.commonHoops[2] // 6x10in = 160x260mm -- an 80x80mm design fits easily
        var report = QualityAnalyzer.analyze(plan, hoopWidthMM: hoop.widthMM, hoopHeightMM: hoop.heightMM)
        #expect(report.isReadyToSew)

        // 4. Save the project, then reopen it as a fresh document (as
        // AppState.saveProject / openProject do) -- the whole point of the
        // .stitchpilot format is that this round trip doesn't lose the
        // digitizing decisions already made.
        let projectData = try ProjectFileFormat.write(document)
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("workflow_test_\(UUID().uuidString).stitchpilot")
        try projectData.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let reloaded = try ProjectFileFormat.read(try Data(contentsOf: tmpFile))
        #expect(reloaded.objects.count == document.objects.count)
        #expect(reloaded.objects.map { $0.stitchType } == document.objects.map { $0.stitchType })

        // 5. Resize the *reopened* document (as AppState.applyPhysicalSizeChange
        // does) -- this must work from the document's own geometry alone,
        // with no cached "raw import" state available (a loaded project has none).
        let newSizeMM = 120.0
        let reloadedBounds = reloaded.boundingBox
        let resizedObjects = reloaded.objects.map { object -> EmbroideryObject in
            var resized = object
            resized.shape = object.shape.fitToPhysicalSize(widthMM: newSizeMM, heightMM: newSizeMM, within: reloadedBounds)
            return resized
        }
        document = StitchDocument(name: reloaded.name, physicalWidthMM: newSizeMM, physicalHeightMM: newSizeMM, objects: resizedObjects)

        plan = try DigitizePipeline.flatten(document)
        let box = plan.boundingBox
        #expect(box.width <= newSizeMM + 1 && box.height <= newSizeMM + 1, "resizing must regenerate from geometry, not scale stale stitch coordinates (spec §39)")

        // Now the larger design should trip the smaller hoop that used to fit it fine.
        report = QualityAnalyzer.analyze(plan, hoopWidthMM: 100, hoopHeightMM: 100)
        #expect(!report.isReadyToSew, "a 120mm design must be flagged as not fitting a 100mm hoop")

        // 6. Export to both formats and self-validate (as AppState.exportDST/exportPES do).
        let dstData = try DSTFormat.write(plan, designName: document.name)
        _ = try DSTFormat.read(dstData)

        let colors = try DigitizePipeline.colorSequence(for: document)
        let pesData = try PESFormat.write(plan, designName: document.name, threadColors: colors.map { $0.rgb })
        _ = try PESFormat.read(pesData)
    }
}
