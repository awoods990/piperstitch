import Testing
@testable import StitchPilotCore

struct StitchFilterTests {
    @Test func mergesTinyStitches() {
        let points = [Point2D(0, 0), Point2D(0.01, 0), Point2D(10, 0)]
        let filtered = StitchFilter.mergeTinyStitches(points, minLengthMM: 0.4)
        for i in 1..<filtered.count {
            #expect(filtered[i - 1].distance(to: filtered[i]) >= 0.39)
        }
        #expect(filtered.last == Point2D(10, 0))
    }

    /// The exact case `mergeTinyStitches`'s old `count > 2` guard silently
    /// skipped: the smallest possible run, exactly two points, close
    /// enough together to be a sub-minimum stitch. A genuinely tiny/
    /// near-degenerate fragment object (common once fragmentation is
    /// common at all -- confirmed directly against the PiperStitch bird
    /// mark, whose readiness report flagged under-0.15mm stitches this
    /// filter is supposed to make impossible) can easily produce a run
    /// this small. Must collapse to the single true endpoint, the same
    /// outcome a longer run's own too-close trailing points already
    /// collapse to -- not sail through unfiltered just because there
    /// happen to be only two points.
    @Test func mergesATwoPointRunThatsPathologicallyClose() {
        let points = [Point2D(0, 0), Point2D(0.01, 0)]
        let filtered = StitchFilter.mergeTinyStitches(points, minLengthMM: 0.4)
        #expect(filtered.count == 1)
        #expect(filtered == [Point2D(0.01, 0)])
    }

    /// The mirror case: a genuine two-point stitch that's already a real,
    /// intentional length must be left alone -- this isn't "always
    /// collapse two-point runs," only "still apply the same minimum-length
    /// rule to them."
    @Test func leavesATwoPointRunOfARealLengthUntouched() {
        let points = [Point2D(0, 0), Point2D(3, 0)]
        #expect(StitchFilter.mergeTinyStitches(points, minLengthMM: 0.4) == points)
    }

    @Test func splitsLongStitches() {
        let points = [Point2D(0, 0), Point2D(50, 0)]
        let split = StitchFilter.splitLongStitches(points, maxLengthMM: 12)
        #expect(split.first == Point2D(0, 0))
        #expect(split.last == Point2D(50, 0))
        for i in 1..<split.count {
            #expect(split[i - 1].distance(to: split[i]) <= 12.0001)
        }
        // 50mm / 12mm needs at least 5 segments (ceil(50/12) = 5) -> 6 points.
        #expect(split.count >= 6)
    }

    @Test func leavesShortStitchesUntouched() {
        let points = [Point2D(0, 0), Point2D(3, 0), Point2D(6, 0)]
        #expect(StitchFilter.apply(points, minLengthMM: 0.4, maxLengthMM: 12) == points)
    }

    @Test func applyRunsBothPassesTogether() {
        // A tiny stitch followed by an excessively long one -- both problems in one input.
        let points = [Point2D(0, 0), Point2D(0.01, 0), Point2D(40, 0)]
        let result = StitchFilter.apply(points, minLengthMM: 0.4, maxLengthMM: 12)
        #expect(result.first == Point2D(0, 0))
        #expect(result.last == Point2D(40, 0))
        for i in 1..<result.count {
            let d = result[i - 1].distance(to: result[i])
            #expect(d >= 0.39 && d <= 12.0001)
        }
    }

    @Test func overlongStitchIsSplitInDigitizePipeline() throws {
        // A running-stitch object with an artificially huge stitch length
        // parameter produces one long straight stitch per segment; the
        // filter should still cap it regardless of what the generator asked for.
        let shape = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(50, 0)], closed: false)])
        var params = StitchGenerationParameters()
        params.stitchLengthMM = 100 // deliberately absurd: one giant stitch
        params.maxStitchLengthMM = 12
        let object = EmbroideryObject(name: "Long", shape: shape, stitchType: .runningStitch,
                                       threadColor: .generic(RGBColor(hex: 0x000000)), parameters: params)
        let doc = StitchDocument(name: "Test", physicalWidthMM: 50, physicalHeightMM: 1, objects: [object])
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.maxStitchLength() <= 12.0001)
    }
}
