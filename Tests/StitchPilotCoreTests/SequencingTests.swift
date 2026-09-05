import Testing
@testable import StitchPilotCore

struct SequencingTests {
    private func makeObject(offsetX: Double, color: RGBColor) -> EmbroideryObject {
        let shape = VectorShape(subPaths: [SubPath(points: [Point2D(offsetX, 0), Point2D(offsetX + 5, 0)], closed: false)])
        return EmbroideryObject(name: "Obj", shape: shape, stitchType: .runningStitch, threadColor: .generic(color))
    }

    @Test func shortSameColorJumpGetsNoTrim() throws {
        let color = RGBColor(hex: 0xFF0000)
        let doc = StitchDocument(name: "Close", physicalWidthMM: 20, physicalHeightMM: 5,
                                  objects: [makeObject(offsetX: 0, color: color), makeObject(offsetX: 10, color: color)])
        let plan = try DigitizePipeline.flatten(doc)
        // Just the final trim at the end of the design -- no color change, gap is short.
        #expect(plan.trimCount == 1)
    }

    @Test func longSameColorJumpGetsATrimInserted() throws {
        let color = RGBColor(hex: 0xFF0000)
        let doc = StitchDocument(name: "Far", physicalWidthMM: 100, physicalHeightMM: 5,
                                  objects: [makeObject(offsetX: 0, color: color), makeObject(offsetX: 80, color: color)])
        let plan = try DigitizePipeline.flatten(doc)
        // One extra trim before the long same-color jump, plus the final trim.
        #expect(plan.trimCount == 2)
        #expect(plan.colorChangeCount == 0) // still the same color -- no color change
    }

    @Test func customThresholdIsRespected() throws {
        let color = RGBColor(hex: 0xFF0000)
        let doc = StitchDocument(name: "Medium", physicalWidthMM: 30, physicalHeightMM: 5,
                                  objects: [makeObject(offsetX: 0, color: color), makeObject(offsetX: 10, color: color)])

        let withDefaultThreshold = try DigitizePipeline.flatten(doc)
        #expect(withDefaultThreshold.trimCount == 1) // ~5mm gap, under the 15mm default

        let withTightThreshold = try DigitizePipeline.flatten(doc, maxJumpWithoutTrimMM: 2.0)
        #expect(withTightThreshold.trimCount == 2) // same gap now exceeds a 2mm threshold
    }
}
