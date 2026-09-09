import Testing
@testable import StitchPilotCore

struct TieStitchGeneratorTests {
    @Test func tieInPrependsThereAndBackBeforeRealSequence() {
        let points = [Point2D(0, 0), Point2D(10, 0), Point2D(20, 0)]
        let result = TieStitchGenerator.applyTieIn(to: points)
        // Only "there" (`forward`) is a genuinely new point -- "back"
        // lands on `start`, which `points[0]` already provides; adding a
        // second, separate point at that exact same coordinate would be a
        // real zero-length stitch, not a real one. See CHANGELOG.md.
        #expect(result.count == points.count + 2)
        #expect(result[0] == Point2D(0, 0))
        #expect(result[2] == Point2D(0, 0)) // back to the anchor point -- points[0] itself, not a duplicate of it
        #expect(result[1].x > 0 && result[1].x < 10) // stepped toward the real direction, not past it
        // The real sequence follows unmodified.
        #expect(Array(result.suffix(3)) == points)
    }

    /// Direct regression test for the actual bug: `applyTieIn`'s own output
    /// must never contain two consecutive identical points -- a genuine
    /// zero-length stitch, always under the 0.15mm quality-warning
    /// threshold (`QualityAnalyzer`) regardless of anything about the
    /// design's own artwork or settings, which is exactly why editing
    /// color/density/etc. could never make that particular warning go
    /// away: it was never caused by the design. See CHANGELOG.md.
    @Test func tieInNeverProducesAZeroLengthStitch() {
        let points = [Point2D(0, 0), Point2D(10, 0), Point2D(20, 0)]
        let result = TieStitchGenerator.applyTieIn(to: points)
        for i in 1..<result.count {
            #expect(result[i - 1].distance(to: result[i]) > 0.15, "consecutive tie-in points must not coincide")
        }
    }

    @Test func tieOffAppendsOvershootThenReturn() {
        let points = [Point2D(0, 0), Point2D(10, 0), Point2D(20, 0)]
        let result = TieStitchGenerator.applyTieOff(to: points)
        #expect(result.count == points.count + 2)
        #expect(Array(result.prefix(3)) == points)
        #expect(result.last == Point2D(20, 0)) // returns to the true endpoint
        #expect(result[3].x > 20) // overshoots past the endpoint first
    }

    @Test func tooFewPointsIsANoOp() {
        #expect(TieStitchGenerator.applyTieIn(to: [Point2D(0, 0)]) == [Point2D(0, 0)])
        #expect(TieStitchGenerator.applyTieOff(to: []).isEmpty)
    }

    @Test func degenerateDirectionIsANoOp() {
        // Coincident points give no direction to step in.
        let points = [Point2D(5, 5), Point2D(5, 5), Point2D(10, 5)]
        #expect(TieStitchGenerator.applyTieIn(to: points) == points)
    }

    @Test func onlyRunBoundariesGetTieStitchesInDigitizePipeline() throws {
        // Two same-color, congruent objects sewn back to back share one
        // thread run: exactly one tie-in (at the very start) and one
        // tie-off (at the very end) for the whole run, not one pair per
        // object -- so total stitches should be 2x one object's *raw*
        // count plus the 4 tie stitches (2 tie-in + 2 tie-off) exactly
        // once, not twice.
        let color = ThreadColor.generic(RGBColor(hex: 0xFF0000))
        func makeObject(offsetX: Double) -> EmbroideryObject {
            let shape = VectorShape(subPaths: [SubPath(points: [Point2D(offsetX, 0), Point2D(offsetX + 10, 0)], closed: false)])
            return EmbroideryObject(name: "Obj", shape: shape, stitchType: .runningStitch, threadColor: color)
        }

        let singleDoc = StitchDocument(name: "Single", physicalWidthMM: 10, physicalHeightMM: 10, objects: [makeObject(offsetX: 0)])
        let withOneObject = try DigitizePipeline.flatten(singleDoc)
        let rawPerObject = withOneObject.stitchCount - 4 // subtract this object's own tie-in(2) + tie-off(2)

        let twoObjectDoc = StitchDocument(name: "Two", physicalWidthMM: 30, physicalHeightMM: 10,
                                           objects: [makeObject(offsetX: 0), makeObject(offsetX: 20)])
        let withTwoObjects = try DigitizePipeline.flatten(twoObjectDoc)

        #expect(withTwoObjects.stitchCount == rawPerObject * 2 + 4)
    }

    @Test func colorChangeGetsTieOffBeforeAndTieInAfter() throws {
        let shape1 = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 5)], closed: false)])
        let shape2 = VectorShape(subPaths: [SubPath(points: [Point2D(20, 0), Point2D(30, 0), Point2D(30, 5)], closed: false)])
        let obj1 = EmbroideryObject(name: "A", shape: shape1, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0xFF0000)))
        let obj2 = EmbroideryObject(name: "B", shape: shape2, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0x0000FF)))
        let doc = StitchDocument(name: "TwoColor", physicalWidthMM: 30, physicalHeightMM: 10, objects: [obj1, obj2])

        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.colorChangeCount == 1)
        #expect(plan.trimCount == 2) // one before the color change, one at the very end
    }
}
