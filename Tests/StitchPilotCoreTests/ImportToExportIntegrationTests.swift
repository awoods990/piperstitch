import Testing
import Foundation
@testable import StitchPilotCore

/// End-to-end smoke test: a real SVG file from TestArtwork/ -> import ->
/// fit to a finished physical size -> object model -> Auto Digitize ->
/// DST export -> independent read-back -> sanity checks. This exercises
/// exactly the Phase 1 vertical slice described in ARCHITECTURE.md, using
/// actual file I/O rather than in-code fixtures, so a regression anywhere
/// in the chain (import, fitting, pipeline, or format adapter) shows up
/// here even if the more targeted unit tests above all still pass.
struct ImportToExportIntegrationTests {
    private func testArtworkURL(_ name: String) -> URL {
        // Tests/StitchPilotCoreTests/../../TestArtwork/<name>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestArtwork")
            .appendingPathComponent(name)
    }

    @Test func simpleSquareLogoEndToEnd() throws {
        let url = testArtworkURL("simple_square_logo.svg")
        let data = try Data(contentsOf: url)
        let imported = try SVGImporter.importShapes(from: data)
        #expect(imported.shapes.count == 1)

        var combined = BoundingBox.empty
        for s in imported.shapes { combined = combined.union(s.boundingBox) }

        let finishedSizeMM = 90.0
        let fitted = imported.shapes[0].fitToPhysicalSize(widthMM: finishedSizeMM, heightMM: finishedSizeMM, within: combined)
        let object = EmbroideryObject(name: "Logo", shape: fitted, stitchType: .runningStitch,
                                       threadColor: .generic(imported.fillColors[0] ?? RGBColor(hex: 0x000000)))
        let document = StitchDocument(name: "SimpleSquareLogo", physicalWidthMM: finishedSizeMM, physicalHeightMM: finishedSizeMM, objects: [object])

        let plan = try DigitizePipeline.flatten(document)
        #expect(plan.stitchCount > 20, "a 90mm square outline at 3mm stitch length should produce well over 20 stitches")
        #expect(plan.maxStitchLength() <= 3.5, "no stitch should be much longer than the configured stitch length")

        let dstData = try DSTFormat.write(plan, designName: document.name)
        let decoded = try DSTFormat.read(dstData)
        let decodedStitchCount = decoded.commands.filter { if case .stitch = $0 { return true }; return false }.count
        #expect(decodedStitchCount == plan.stitchCount)

        // The design must fit within the hoop-scale size it was digitized for.
        let box = plan.boundingBox
        #expect(box.width <= finishedSizeMM + 0.5)
        #expect(box.height <= finishedSizeMM + 0.5)
    }

    @Test func multiColorBadgeProducesMultipleObjectsAndColorChanges() throws {
        let url = testArtworkURL("multi_color_badge.svg")
        let data = try Data(contentsOf: url)
        let imported = try SVGImporter.importShapes(from: data)
        #expect(imported.shapes.count == 4, "3 circles + 1 rect")

        var combined = BoundingBox.empty
        for s in imported.shapes { combined = combined.union(s.boundingBox) }

        let objects = imported.shapes.enumerated().map { i, shape in
            EmbroideryObject(name: "Object \(i)", shape: shape.fitToPhysicalSize(widthMM: 80, heightMM: 80, within: combined),
                              stitchType: .runningStitch, threadColor: .generic(imported.fillColors[i] ?? RGBColor(hex: 0x000000)))
        }
        let document = StitchDocument(name: "Badge", physicalWidthMM: 80, physicalHeightMM: 80, objects: objects)
        let plan = try DigitizePipeline.flatten(document)

        // 4 distinct fill colors -> 3 color changes between them.
        #expect(plan.colorChangeCount == 3)

        let dstData = try DSTFormat.write(plan, designName: document.name)
        let decoded = try DSTFormat.read(dstData)
        let decodedColorChanges = decoded.commands.filter { if case .colorChange = $0 { return true }; return false }.count
        #expect(decodedColorChanges == 3)
    }
}
