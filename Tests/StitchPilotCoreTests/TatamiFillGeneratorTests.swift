import Testing
@testable import StitchPilotCore

struct TatamiFillGeneratorTests {
    /// Pull compensation defaults to off here so these tests check pure
    /// fill geometry against exact bounds; `pullCompensationGrowsFillOutward`
    /// below tests compensation itself.
    func squareParams(spacing: Double = 0.4, stitchLength: Double = 3.0, angle: Double = 0) -> StitchGenerationParameters {
        var p = StitchGenerationParameters()
        p.fillSpacingMM = spacing
        p.stitchLengthMM = stitchLength
        p.fillAngleDegrees = angle
        p.fillRowStaggerMM = 1.2
        p.pullCompensationMM = 0
        return p
    }

    @Test func pullCompensationGrowsFillOutward() {
        let square = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20),
        ], closed: true)])
        var params = squareParams()
        params.pullCompensationMM = 0.3

        let points = TatamiFillGenerator.generate(for: square, parameters: params)
        // Checking minX rather than minY: within a scanline row, the
        // resampled stitches reach essentially exactly the offset
        // boundary's edge, but rows themselves are centered `spacing/2`
        // inward from the polygon's own extent by design (rows don't sew
        // exactly on the perpendicular-to-scan edge) -- that centering
        // would swamp a small compensation amount if checked on minY
        // instead, even though the compensation is working correctly.
        let box = BoundingBox(points: points)
        #expect(box.minX < -0.15) // grown outward from x=0 by close to the full 0.3mm compensation
    }

    @Test func fillsASimpleSquare() {
        let square = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20),
        ], closed: true)])
        let points = TatamiFillGenerator.generate(for: square, parameters: squareParams())

        #expect(points.count > 50, "a 20x20mm square at 0.4mm row spacing should produce many stitches")
        let box = BoundingBox(points: points)
        // All generated points must stay within the shape's bounds.
        #expect(box.minX >= -0.01 && box.maxX <= 20.01)
        #expect(box.minY >= -0.01 && box.maxY <= 20.01)
    }

    @Test func rotatedFillStaysWithinBounds() {
        let square = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20),
        ], closed: true)])
        let points = TatamiFillGenerator.generate(for: square, parameters: squareParams(angle: 37))
        #expect(!points.isEmpty)
        let box = BoundingBox(points: points)
        #expect(box.minX >= -0.5 && box.maxX <= 20.5)
        #expect(box.minY >= -0.5 && box.maxY <= 20.5)
    }

    /// A square with a smaller square hole punched in the middle: the hole
    /// region must contain no fill stitches (spec §21 negative space).
    @Test func holeIsRespected() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 30), Point2D(0, 30)], closed: true)
        let hole = SubPath(points: [Point2D(10, 10), Point2D(20, 10), Point2D(20, 20), Point2D(10, 20)], closed: true)
        let shapeWithHole = VectorShape(subPaths: [outer, hole])

        let points = TatamiFillGenerator.generate(for: shapeWithHole, parameters: squareParams(spacing: 0.5))
        #expect(!points.isEmpty)

        let margin = 0.3 // stitches can legitimately land right at the hole boundary
        let pointsInsideHole = points.filter {
            $0.x > 10 + margin && $0.x < 20 - margin && $0.y > 10 + margin && $0.y < 20 - margin
        }
        #expect(pointsInsideHole.isEmpty, "no fill stitches should land inside the hole")

        // Sanity: without the hole, the same shape would have plenty of
        // points in that region -- confirms the hole is actually being
        // subtracted, not that fill is empty everywhere for some other reason.
        let solidPoints = TatamiFillGenerator.generate(for: VectorShape(subPaths: [outer]), parameters: squareParams(spacing: 0.5))
        let solidPointsInHoleRegion = solidPoints.filter {
            $0.x > 10 + margin && $0.x < 20 - margin && $0.y > 10 + margin && $0.y < 20 - margin
        }
        #expect(!solidPointsInHoleRegion.isEmpty)
    }

    @Test func emptyShapeProducesNoStitches() {
        let tiny = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(0.01, 0), Point2D(0.01, 0.01)], closed: true)])
        let points = TatamiFillGenerator.generate(for: tiny, parameters: squareParams())
        #expect(points.isEmpty)
    }

    @Test func integratesWithDigitizePipeline() throws {
        let square = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(15, 0), Point2D(15, 15), Point2D(0, 15),
        ], closed: true)])
        let object = EmbroideryObject(name: "Fill", shape: square, stitchType: .tatamiFill,
                                       threadColor: .generic(RGBColor(hex: 0x00FF00)), parameters: squareParams())
        let doc = StitchDocument(name: "FillTest", physicalWidthMM: 15, physicalHeightMM: 15, objects: [object])
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 30)
    }
}
