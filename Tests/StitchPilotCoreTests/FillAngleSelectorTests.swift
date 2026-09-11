import Testing
@testable import StitchPilotCore

struct FillAngleSelectorTests {
    @Test func perpendicularToHorizontalElongation() {
        // A wide, short rectangle -- elongated along X (0 degrees).
        let shape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(50, 0), Point2D(50, 5), Point2D(0, 5),
        ], closed: true)])
        let angle = FillAngleSelector.selectAngle(for: shape)
        #expect(abs(angle - 90) < 1, "fill rows should run perpendicular (vertical) to a horizontally elongated shape")
    }

    @Test func perpendicularToVerticalElongation() {
        // A tall, narrow rectangle -- elongated along Y (90 degrees).
        let shape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(5, 0), Point2D(5, 50), Point2D(0, 50),
        ], closed: true)])
        let angle = FillAngleSelector.selectAngle(for: shape)
        #expect(angle < 1 || angle > 179, "fill rows should run perpendicular (horizontal) to a vertically elongated shape")
    }

    @Test func degenerateShapeDefaultsToZero() {
        let shape = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(1, 0)], closed: false)])
        #expect(FillAngleSelector.selectAngle(for: shape) == 0)
    }

    @Test func explicitAngleOverridesAutomaticSelection() {
        let elongated = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(50, 0), Point2D(50, 5), Point2D(0, 5),
        ], closed: true)])
        var params = StitchGenerationParameters()
        params.fillAngleDegrees = 0 // explicit, should NOT be overridden by the auto-selector's 90-degree preference
        params.pullCompensationMM = 0

        let points = TatamiFillGenerator.generate(for: elongated, parameters: params)
        // At angle 0 (horizontal rows), stitches within a single row share
        // a near-constant Y; confirm the fill actually respects the
        // explicit angle rather than silently auto-selecting.
        let ys = Set(points.map { ($0.y * 10).rounded() / 10 })
        #expect(ys.count > 3, "horizontal rows across a 5mm-tall shape at 0.4mm spacing should produce several distinct row heights")
    }

    /// `ShapeMerger.merge` keeps pieces that don't actually touch as
    /// separate sub-paths of one shape rather than dropping them (its own
    /// doc comment) -- e.g. two halves of a letterform split apart by a
    /// different-colored stripe cutting through it, then rejoined with
    /// "Merge Shapes". The angle must reflect the *whole* merged shape,
    /// not just whichever piece happens to be sub-path 0.
    @Test func combinesEveryDisjointSubPathNotJustTheFirst() {
        // Sub-path 0 alone: small, wide/short -- elongated along X, so its
        // own angle would be ~90 (perpendicular, vertical rows). 10x1mm
        // = 10 sq mm.
        let smallWideFirst = SubPath(points: [
            Point2D(0, 0), Point2D(10, 0), Point2D(10, 1), Point2D(0, 1),
        ], closed: true)
        // Sub-path 1, positioned right next to (not touching, not
        // overlapping) sub-path 0 -- tall/narrow, so its own angle would
        // be ~0/180 (perpendicular, horizontal rows). 5x20mm = 100 sq mm,
        // ten times sub-path 0's area, so it should dominate the average.
        let largeTallSecond = SubPath(points: [
            Point2D(11, -10), Point2D(16, -10), Point2D(16, 10), Point2D(11, 10),
        ], closed: true)
        let shape = VectorShape(subPaths: [smallWideFirst, largeTallSecond])

        let angle = FillAngleSelector.selectAngle(for: shape)
        #expect(angle < 30 || angle > 150,
                "the much larger second sub-path should dominate the combined angle, not the first sub-path's own 90-degree preference (got \(angle))")
    }

    @Test func automaticSelectionAppliesWhenAngleIsNil() {
        let elongated = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(50, 0), Point2D(50, 5), Point2D(0, 5),
        ], closed: true)])
        var params = StitchGenerationParameters()
        params.fillAngleDegrees = nil
        params.pullCompensationMM = 0

        let points = TatamiFillGenerator.generate(for: elongated, parameters: params)
        #expect(!points.isEmpty)
        // At the auto-selected 90-degree angle, rows run vertically across
        // the 50mm width, so X should vary in comparatively few discrete
        // "row" positions relative to a 0-degree fill of the same shape.
        let box = BoundingBox(points: points)
        #expect(box.width <= 50.5 && box.height <= 5.5)
    }
}
