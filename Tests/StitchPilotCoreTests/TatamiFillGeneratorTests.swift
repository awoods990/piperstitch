import Testing
@testable import StitchPilotCore

struct TatamiFillGeneratorTests {
    /// Pull and push compensation default to off here so these tests check
    /// pure fill geometry against exact bounds; `pullCompensationGrowsFillOutward`
    /// and `pushCompensationShrinksRowSpan` below test compensation itself.
    func squareParams(spacing: Double = 0.4, stitchLength: Double = 3.0, angle: Double = 0) -> StitchGenerationParameters {
        var p = StitchGenerationParameters()
        p.fillSpacingMM = spacing
        p.stitchLengthMM = stitchLength
        p.fillAngleDegrees = angle
        p.fillRowStaggerMM = 1.2
        p.pullCompensationMM = 0
        p.pushCompensationMM = 0
        return p
    }

    @Test func pushCompensationShrinksRowSpan() {
        // angle: 0 -- rows run horizontally (along x), so push compensation
        // (which acts along the row direction) should pull both the left
        // and right edges of the fill inward, without affecting its height.
        let square = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20),
        ], closed: true)])
        var params = squareParams()
        params.pushCompensationMM = 0.5

        let plain = TatamiFillGenerator.generate(for: square, parameters: squareParams())
        let shrunk = TatamiFillGenerator.generate(for: square, parameters: params)

        let plainBox = BoundingBox(points: plain)
        let shrunkBox = BoundingBox(points: shrunk)
        #expect(shrunkBox.minX > plainBox.minX + 0.15)
        #expect(shrunkBox.maxX < plainBox.maxX - 0.15)
        #expect(abs(shrunkBox.height - plainBox.height) < 0.05, "push compensation shouldn't affect the perpendicular (row-stacking) axis")
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

    /// `holeIsRespected` above only checks that no fill *point* lands
    /// inside the hole -- it doesn't check the *segments between*
    /// consecutive points, so it couldn't catch a real bug: every row that
    /// crossed the hole was split into two separate runs (correctly, one on
    /// each side), but both runs got flattened into one row's stitch
    /// sequence regardless, so the needle stitched a straight, dense
    /// segment *through* the hole on every single row that crossed it —
    /// individually unremarkable, but repeated across the hole's full
    /// height at normal row spacing, visually filling it back in even
    /// though no single stitch *point* was ever inside it. Found against a
    /// real letterform ("B", two counters) in a user's logo — see
    /// CHANGELOG.md.
    ///
    /// Fixed by grouping same-side runs into their own connected "chains"
    /// across rows and splicing each chain in right next to the row it
    /// split from, rather than flattening every row's runs together
    /// regardless. That eliminates the *systematic, one-per-row* crossing,
    /// but for a hole with no narrower "pinch point" to route the
    /// transition through (a perfect rectangle, worst case, at every row) a
    /// small, *bounded* number of connector stitches -- one where a
    /// side-chain splits off, one where it rejoins -- can still legitimately
    /// cross the hole once each: this generator has no way to mark an
    /// actual jump within a single object's own point stream, only real
    /// jump support (a larger, separate change) removes them completely.
    /// A real rounded letter counter tapers at top and bottom exactly where
    /// that splice happens, so in practice this residual is far smaller
    /// than this deliberately-worst-case rectangular hole exercises -- see
    /// CHANGELOG.md for the actual rendered result. This test asserts the
    /// property that's actually fixed: crossings bounded to a small
    /// constant, not one per row.
    @Test func stitchSegmentsCrossingAHoleAreBoundedNotOnePerRow() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 30), Point2D(0, 30)], closed: true)
        let hole = SubPath(points: [Point2D(10, 10), Point2D(20, 10), Point2D(20, 20), Point2D(10, 20)], closed: true)
        let shapeWithHole = VectorShape(subPaths: [outer, hole])

        let points = TatamiFillGenerator.generate(for: shapeWithHole, parameters: squareParams(spacing: 0.5))
        #expect(points.count > 1)

        let crossings = countSegmentsCrossingHole(points, hole: (minX: 10, minY: 10, maxX: 20, maxY: 20))
        // The hole is 10mm tall at 0.5mm row spacing -- roughly 20 rows
        // cross it, so the old per-row bug would show ~20 crossings here.
        #expect(crossings <= 2, "expected at most one entry + one exit connector, found \(crossings)")
    }

    /// The real bug this guards against involved a shape with *two*
    /// non-overlapping holes at different heights (a "B"'s two counters) --
    /// a case the single-hole tests above don't exercise, since chaining
    /// runs across rows must correctly split into a *new* chain each time a
    /// second hole opens, not just track one split/merge pair.
    @Test func multipleNonOverlappingHolesAreEachBoundedNotOnePerRow() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 40), Point2D(0, 40)], closed: true)
        let upperHole = SubPath(points: [Point2D(5, 5), Point2D(15, 5), Point2D(15, 15), Point2D(5, 15)], closed: true)
        let lowerHole = SubPath(points: [Point2D(5, 25), Point2D(15, 25), Point2D(15, 35), Point2D(5, 35)], closed: true)
        let shape = VectorShape(subPaths: [outer, upperHole, lowerHole])

        let points = TatamiFillGenerator.generate(for: shape, parameters: squareParams(spacing: 0.5))
        #expect(points.count > 1)

        let upperCrossings = countSegmentsCrossingHole(points, hole: (minX: 5, minY: 5, maxX: 15, maxY: 15))
        let lowerCrossings = countSegmentsCrossingHole(points, hole: (minX: 5, minY: 25, maxX: 15, maxY: 35))
        #expect(upperCrossings <= 2, "expected at most one entry + one exit connector for the upper hole, found \(upperCrossings)")
        #expect(lowerCrossings <= 2, "expected at most one entry + one exit connector for the lower hole, found \(lowerCrossings)")
    }

    /// A rectangular hole's left/right edges never move, so the same side
    /// always wins `chainRuns`' overlap-based continuation at both its
    /// opening and closing row -- the one chain spanning the whole shape
    /// (`sequenceChains`'s "root") always happens to start at row 0. A
    /// *slanted* hole can flip which side wins between opening and closing
    /// (here: the narrow sliver at the top is on the left, but by the
    /// bottom it's on the right, so the side that keeps more overlap with
    /// the surrounding solid rows switches), which can make the winning
    /// "biggest" chain start partway through the shape instead of at row 0
    /// -- silently dropping the *other* chain's entire region, a real bug
    /// confirmed against a real letterform (see CHANGELOG.md), since
    /// nothing in `sequenceChains`'s main splice loop ever visits row 0 to
    /// find it. This checks fill actually reaches both sides of the hole
    /// at its very top and very bottom, not just somewhere in the middle.
    @Test func slantedHoleWhoseWinningSideFlipsStillGetsFullyFilledAroundIt() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 45), Point2D(0, 45)], closed: true)
        // Narrow sliver on the left at the top (y=5: left width 2, right width 10),
        // narrow sliver on the right at the bottom (y=25: left width 10, right width 2).
        let hole = SubPath(points: [Point2D(2, 5), Point2D(10, 5), Point2D(18, 25), Point2D(10, 25)], closed: true)
        let shape = VectorShape(subPaths: [outer, hole])

        let points = TatamiFillGenerator.generate(for: shape, parameters: squareParams(spacing: 0.5))
        #expect(points.count > 1)

        // Near the hole's top: fill should reach close to both x=0 and x=20
        // somewhere in y=[4,6] -- i.e. neither side was dropped.
        func reachesBothSides(nearY: Double) -> Bool {
            let nearby = points.filter { abs($0.y - nearY) < 1.0 }
            guard !nearby.isEmpty else { return false }
            let minX = nearby.map { $0.x }.min() ?? .infinity
            let maxX = nearby.map { $0.x }.max() ?? -.infinity
            return minX < 3 && maxX > 17
        }
        #expect(reachesBothSides(nearY: 5), "fill should reach both sides of the shape near the hole's top, not just one")
        #expect(reachesBothSides(nearY: 25), "fill should reach both sides of the shape near the hole's bottom, not just one")
    }

    /// Counts stitch segments whose midpoint falls inside `hole` -- a
    /// reasonable approximation for the near-horizontal/vertical fill
    /// segments this generator produces.
    private func countSegmentsCrossingHole(_ points: [Point2D], hole: (minX: Double, minY: Double, maxX: Double, maxY: Double)) -> Int {
        guard points.count > 1 else { return 0 }
        var count = 0
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let mid = Point2D((a.x + b.x) / 2, (a.y + b.y) / 2)
            if mid.x > hole.minX, mid.x < hole.maxX, mid.y > hole.minY, mid.y < hole.maxY { count += 1 }
        }
        return count
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
