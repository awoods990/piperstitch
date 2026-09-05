import Testing
@testable import StitchPilotCore

struct RunningStitchGeneratorTests {
    @Test func evenSpacingAlongStraightLine() {
        let subPath = SubPath(points: [Point2D(0, 0), Point2D(30, 0)], closed: false)
        let stitches = RunningStitchGenerator.generate(for: subPath, stitchLengthMM: 3, minStitchLengthMM: 0.4)

        #expect(stitches.first == Point2D(0, 0))
        #expect(stitches.last == Point2D(30, 0))
        for i in 1..<stitches.count {
            let d = stitches[i - 1].distance(to: stitches[i])
            #expect(d <= 3.01)
        }
        // 30mm / 3mm = 10 segments = 11 points.
        #expect(stitches.count == 11)
    }

    @Test func closedShapeReturnsToStart() {
        let subPath = SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 10), Point2D(0, 10)], closed: true)
        let stitches = RunningStitchGenerator.generate(for: subPath, stitchLengthMM: 2, minStitchLengthMM: 0.4)
        #expect(stitches.first == stitches.last)
    }

    @Test func tinyStitchesAreMerged() {
        // A single 10.01mm segment at 5mm stitch length lands its last
        // resampled point 0.02mm from the true endpoint -- exactly the
        // sub-minimum stitch this pass exists to remove.
        let subPath = SubPath(points: [Point2D(0, 0), Point2D(10.01, 0)], closed: false)
        let stitches = RunningStitchGenerator.generate(for: subPath, stitchLengthMM: 5, minStitchLengthMM: 0.4)
        for i in 1..<stitches.count {
            #expect(stitches[i - 1].distance(to: stitches[i]) >= 0.39)
        }
        // The true endpoint must still be exactly represented.
        #expect(stitches.last == Point2D(10.01, 0))
    }
}
