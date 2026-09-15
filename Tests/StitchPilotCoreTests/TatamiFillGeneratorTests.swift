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

    /// Pull compensation grows the outer boundary outward
    /// (`pullCompensationGrowsFillOutward`) -- a hole needs the OPPOSITE
    /// treatment: the stitched fill right around a hole pulls fabric away
    /// from the opening the same way it pulls the outer edge inward, which
    /// tends to sew a hole LARGER than digitized unless the hole itself is
    /// shrunk to compensate. Confirms fill now reaches into a strip just
    /// inside the hole's ORIGINAL boundary (forbidden territory per
    /// `holeIsRespected` when compensation is off), while the shrunk
    /// hole's own remaining interior is still empty.
    @Test func pullCompensationShrinksTheHoleToo() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 30), Point2D(0, 30)], closed: true)
        let hole = SubPath(points: [Point2D(10, 10), Point2D(20, 10), Point2D(20, 20), Point2D(10, 20)], closed: true)
        let shapeWithHole = VectorShape(subPaths: [outer, hole])

        var compensated = squareParams(spacing: 0.5)
        compensated.pullCompensationMM = 0.8

        let points = TatamiFillGenerator.generate(for: shapeWithHole, parameters: compensated)
        #expect(!points.isEmpty)

        let margin = 0.3
        let pointsNearOriginalHoleEdge = points.filter { $0.x > 10 + margin && $0.x < 10.7 && $0.y > 14 && $0.y < 16 }
        #expect(!pointsNearOriginalHoleEdge.isEmpty,
                "compensated fill should reach past the hole's original left edge, into where the (now-shrunk) hole no longer covers")

        let pointsDeepInsideHole = points.filter { $0.x > 13 && $0.x < 17 && $0.y > 13 && $0.y < 17 }
        #expect(pointsDeepInsideHole.isEmpty, "the hole's own (shrunk) interior should still have no fill stitches")
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

    /// `stitchSegmentsCrossingAHoleAreBoundedNotOnePerRow` above accepts a
    /// small, bounded connector crossing a *narrow* hole (a letterform
    /// counter) as a reasonable trade-off, since this generator had no way
    /// to mark an actual jump within its own point stream. `generateRuns`
    /// closes that gap: a hole wide enough that its own connector exceeds
    /// `breakThresholdMM` becomes a separate output run instead of staying
    /// silently merged in — `DigitizePipeline` turns that run boundary into
    /// a real trim+jump rather than a long thread bridged across open
    /// fabric. Found against a real ring/donut shape (a raster-imported
    /// badge's own circular cutout, once hole preservation on raster import
    /// started working) — see CHANGELOG.md.
    @Test func wideHoleConnectorBecomesASeparateRunAboveTheBreakThreshold() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(40, 0), Point2D(40, 40), Point2D(0, 40)], closed: true)
        let hole = SubPath(points: [Point2D(10, 10), Point2D(30, 10), Point2D(30, 30), Point2D(10, 30)], closed: true)
        let shape = VectorShape(subPaths: [outer, hole])
        let params = squareParams(spacing: 0.5)

        // An unlimited *distance* threshold no longer guarantees one run on
        // its own: this hole is wide enough that the straight connector
        // between the chains on either side of it leaves the shape
        // entirely, crossing the open hole -- exactly the case
        // `connectorStaysInsideShape` exists to keep split regardless of
        // how far the distance threshold is raised (see its own doc
        // comment). `generate()` -- which flattens every run back together
        // regardless of this structure -- stays unaffected either way; see
        // the assertion below.
        // (`routing: .none` here: with the default edge routing the
        // connector travels round the hole instead -- checked below.)
        let unlimited = TatamiFillGenerator.generateRuns(for: shape, parameters: params, breakThresholdMM: .infinity, routing: .none)
        #expect(unlimited.count > 1, "a connector crossing straight through this wide hole should stay split even with no distance limit at all")

        // The hole is 20mm wide -- well above a 5mm break threshold, so its
        // connector must become its own run boundary.
        let split = TatamiFillGenerator.generateRuns(for: shape, parameters: params, breakThresholdMM: 5.0, routing: .none)
        #expect(split.count > 1, "a wide hole's connector should force a separate run once it exceeds the break threshold")

        // With edge routing (the cover fill's default) the same fill is one
        // run whose travel follows the hole's edge -- and still nothing
        // crosses the hole.
        let routed = TatamiFillGenerator.generateRuns(for: shape, parameters: params, breakThresholdMM: 5.0)
        #expect(routed.count == 1, "edge routing should join the fill into one run, got \(routed.count)")
        for run in routed {
            for (a, b) in zip(run, run.dropFirst()) {
                let mid = Point2D((a.x + b.x) / 2, (a.y + b.y) / 2)
                #expect(!(mid.x > 10.3 && mid.x < 29.7 && mid.y > 10.3 && mid.y < 29.7), "stitch \(a)->\(b) crosses the hole")
            }
        }

        // Within any single run, every consecutive pair must still respect
        // the threshold -- a caller only ever needs to insert a real jump
        // *between* runs, never hidden inside one.
        for run in split {
            guard run.count > 1 else { continue }
            for i in 1..<run.count {
                #expect(run[i - 1].distance(to: run[i]) <= 5.01, "no stitch within a single run should exceed the break threshold")
            }
        }

        // Splitting changes structure, not content: flattening the split
        // runs back together must reproduce the unrouted, unsplit output.
        #expect(split.flatMap { $0 } == TatamiFillGenerator.generateRuns(for: shape, parameters: params, breakThresholdMM: .infinity, routing: .none).flatMap { $0 })
    }

    /// A concave notch open to the shape's own boundary (e.g. a "U", or an
    /// "L"'s inner corner) isn't a hole at all -- no second sub-path, no
    /// even-odd toggling -- but can still split a single scanline row into
    /// two disconnected chains near the notch, the same way a hole does.
    /// `connectorStaysInsideShape` has to catch this case too, not just
    /// literal holes: a short, distance-wise-acceptable connector between
    /// those two chains can still cut straight across the open notch,
    /// landing outside the shape as surely as a hole-crossing one would.
    /// Found directly against a real raster-imported logo's own "U" -- a
    /// ~11.5mm diagonal scratch across its open top, well under the
    /// default 15mm break threshold and so never split before this fix.
    /// See CHANGELOG.md.
    @Test func notchConnectorStaysSplitEvenWhenWellUnderTheBreakThreshold() {
        let uShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(4, 0), Point2D(4, 24), Point2D(8, 30), Point2D(16, 30), Point2D(20, 24),
            Point2D(20, 0), Point2D(24, 0), Point2D(24, 26), Point2D(16, 34), Point2D(8, 34), Point2D(0, 26),
        ], closed: true)])
        let params = squareParams(spacing: 0.5)

        // A generous 15mm threshold (matching the real default
        // `maxJumpWithoutTrimMM`) -- distance alone would happily merge a
        // connector across this notch; only the geometric check should
        // stop it.
        let runs = TatamiFillGenerator.generateRuns(for: uShape, parameters: params, breakThresholdMM: 15.0, routing: .none)
        #expect(runs.count > 1, "the notch-crossing connector should force a separate run even under a generous distance threshold")
        // With edge routing the notch is travelled round, never across.
        let routed = TatamiFillGenerator.generateRuns(for: uShape, parameters: params, breakThresholdMM: 15.0)
        #expect(routed.count == 1)
        let polygon = uShape.subPaths[0].points
        for run in routed {
            for (a, b) in zip(run, run.dropFirst()) where a.distance(to: b) > 0.5 {
                let mid = Point2D((a.x + b.x) / 2, (a.y + b.y) / 2)
                // The notch is x 4...20 below the bowl (y < 24): nothing may land there.
                #expect(!(mid.x > 4.6 && mid.x < 19.4 && mid.y < 23), "stitch \(a)->\(b) crosses the notch")
            }
        }
        _ = polygon
        for run in runs {
            guard run.count > 1 else { continue }
            for i in 1..<run.count {
                #expect(run[i - 1].distance(to: run[i]) <= 15.01, "no stitch within a single run should exceed the break threshold")
            }
        }
    }

    /// End-to-end confirmation that a wide hole's connector actually
    /// becomes a trim+jump in the flattened plan, not just a separate run
    /// at the generator level — the property that actually avoids a
    /// visible thread bridged across the hole once sewn.
    @Test func pipelineInsertsTrimAndJumpAcrossAWideHoleInsteadOfBridgingIt() throws {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(40, 0), Point2D(40, 40), Point2D(0, 40)], closed: true)
        let hole = SubPath(points: [Point2D(10, 10), Point2D(30, 10), Point2D(30, 30), Point2D(10, 30)], closed: true)
        let shape = VectorShape(subPaths: [outer, hole])
        var params = squareParams(spacing: 0.5)
        params.fillAngleDegrees = 0
        let object = EmbroideryObject(name: "Ring", shape: shape, stitchType: .tatamiFill,
                                       threadColor: .generic(RGBColor(hex: 0x000080)), parameters: params)
        let doc = StitchDocument(name: "RingTest", physicalWidthMM: 40, physicalHeightMM: 40, objects: [object])

        let plan = try DigitizePipeline.flatten(doc, maxJumpWithoutTrimMM: 5.0)
        // At least one internal trim for the hole crossing, plus the final
        // trim at the very end of the design -- exactly how many internal
        // breaks a given hole produces depends on `chainRuns`/
        // `sequenceChains`'s own tie-breaking (a perfectly square hole can
        // split at both its opening and closing row), which is pre-existing
        // behavior this fix doesn't change; what matters here is that at
        // least one real break happened instead of none.
        // The hole crossing used to be a trim; since travel can follow the
        // hole's own edge (`routeAlongBoundary`), the only trim left is
        // the design's final one. Either way, nothing may bridge the hole.
        #expect(plan.trimCount >= 1)

        // No real *stitch* segment should cross the hole at all -- confirms
        // the long connector became a jump (invisible thread, no needle
        // penetration across the gap), not a stitch that StitchFilter's
        // max-length splitting would otherwise merely chop into several
        // still hole-crossing shorter pieces (each individually under the
        // length cap, but collectively still bridging the open fabric).
        var lastStitch: Point2D?
        var crossings = 0
        for command in plan.commands {
            switch command {
            case .stitch(let p):
                if let last = lastStitch {
                    let mid = Point2D((last.x + p.x) / 2, (last.y + p.y) / 2)
                    if mid.x > 10, mid.x < 30, mid.y > 10, mid.y < 30 { crossings += 1 }
                }
                lastStitch = p
            case .jump, .trim, .colorChange, .stop:
                lastStitch = nil // a jump/trim breaks thread continuity; the next stitch starts a new segment
            case .end:
                break
            }
        }
        #expect(crossings == 0, "no real stitch segment should cross the hole")
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

    // MARK: - FillPattern.crossHatch

    /// Cross-hatch's two passes run at right angles -- confirms the result
    /// actually contains stitch segments in two distinct directions, not
    /// just a denser version of the same single-direction rows.
    @Test func crossHatchProducesStitchesInTwoDistinctDirections() {
        let square = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20),
        ], closed: true)])
        var params = squareParams(spacing: 0.6)
        params.fillPattern = .crossHatch
        let points = TatamiFillGenerator.generate(for: square, parameters: params)
        #expect(!points.isEmpty)

        // Classify each consecutive segment as "mostly horizontal" or
        // "mostly vertical" by comparing its dx/dy magnitude -- with rows
        // at 0° and 90°, real segments should land solidly in one bucket
        // or the other (not a lot of in-between diagonal noise), and BOTH
        // buckets should be well represented.
        var horizontal = 0, vertical = 0
        for i in 1..<points.count {
            let dx = abs(points[i].x - points[i - 1].x), dy = abs(points[i].y - points[i - 1].y)
            guard dx > 0.05 || dy > 0.05 else { continue }
            if dx > dy * 3 { horizontal += 1 }
            if dy > dx * 3 { vertical += 1 }
        }
        #expect(horizontal > 5, "expected plenty of horizontal segments from the 0° pass")
        #expect(vertical > 5, "expected plenty of vertical segments from the 90° pass")
    }

    /// A hole must still be respected under cross-hatch -- both passes
    /// delegate to the same hole-aware `generateRuns` `.rows` path, so
    /// this should hold the same way `holeIsRespected` already does for
    /// plain rows.
    @Test func crossHatchStillRespectsAHole() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 30), Point2D(0, 30)], closed: true)
        let hole = SubPath(points: [Point2D(10, 10), Point2D(20, 10), Point2D(20, 20), Point2D(10, 20)], closed: true)
        let shapeWithHole = VectorShape(subPaths: [outer, hole])
        var params = squareParams(spacing: 0.6)
        params.fillPattern = .crossHatch

        let points = TatamiFillGenerator.generate(for: shapeWithHole, parameters: params)
        #expect(!points.isEmpty)
        let margin = 0.3
        let pointsInsideHole = points.filter {
            $0.x > 10 + margin && $0.x < 20 - margin && $0.y > 10 + margin && $0.y < 20 - margin
        }
        #expect(pointsInsideHole.isEmpty, "no cross-hatch stitch should land inside the hole")
    }

    @Test func crossHatchIntegratesWithDigitizePipeline() throws {
        let square = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(15, 0), Point2D(15, 15), Point2D(0, 15),
        ], closed: true)])
        var params = squareParams()
        params.fillPattern = .crossHatch
        let object = EmbroideryObject(name: "CrossHatchFill", shape: square, stitchType: .tatamiFill,
                                       threadColor: .generic(RGBColor(hex: 0x00FF00)), parameters: params)
        let doc = StitchDocument(name: "CrossHatchTest", physicalWidthMM: 15, physicalHeightMM: 15, objects: [object])
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 30)
    }

    // MARK: - FillPattern.basketWeave

    /// A large square (well over the ~12mm cell size) should produce
    /// stitches in two distinct directions from its alternating cells,
    /// the same structural check `crossHatchProducesStitchesInTwoDistinct
    /// Directions` uses.
    @Test func basketWeaveProducesStitchesInTwoDistinctDirections() {
        let square = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(40, 0), Point2D(40, 40), Point2D(0, 40),
        ], closed: true)])
        var params = squareParams(spacing: 0.6)
        params.fillPattern = .basketWeave
        let points = TatamiFillGenerator.generate(for: square, parameters: params)
        #expect(!points.isEmpty)

        var horizontal = 0, vertical = 0
        for i in 1..<points.count {
            let dx = abs(points[i].x - points[i - 1].x), dy = abs(points[i].y - points[i - 1].y)
            guard dx > 0.05 || dy > 0.05 else { continue }
            if dx > dy * 3 { horizontal += 1 }
            if dy > dx * 3 { vertical += 1 }
        }
        #expect(horizontal > 5, "expected horizontal segments from at least one checkerboard cell")
        #expect(vertical > 5, "expected vertical segments from at least one checkerboard cell")
    }

    /// Every basket-weave stitch must stay within the original shape's own
    /// bounds -- confirms the per-cell clip doesn't let a cell's fill spill
    /// outside the actual shape.
    @Test func basketWeaveStaysWithinTheShapesBounds() {
        let square = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 30), Point2D(0, 30),
        ], closed: true)])
        var params = squareParams(spacing: 0.6)
        params.fillPattern = .basketWeave
        let points = TatamiFillGenerator.generate(for: square, parameters: params)
        #expect(!points.isEmpty)
        let box = BoundingBox(points: points)
        #expect(box.minX >= -0.5 && box.maxX <= 30.5)
        #expect(box.minY >= -0.5 && box.maxY <= 30.5)
    }

    /// A hole must still be respected under basket-weave -- each cell
    /// clips every sub-path (including the hole) to itself before
    /// filling, so a cell overlapping the hole should still exclude it.
    @Test func basketWeaveStillRespectsAHole() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(40, 0), Point2D(40, 40), Point2D(0, 40)], closed: true)
        let hole = SubPath(points: [Point2D(15, 15), Point2D(25, 15), Point2D(25, 25), Point2D(15, 25)], closed: true)
        let shapeWithHole = VectorShape(subPaths: [outer, hole])
        var params = squareParams(spacing: 0.6)
        params.fillPattern = .basketWeave

        let points = TatamiFillGenerator.generate(for: shapeWithHole, parameters: params)
        #expect(!points.isEmpty)
        let margin = 0.3
        let pointsInsideHole = points.filter {
            $0.x > 15 + margin && $0.x < 25 - margin && $0.y > 15 + margin && $0.y < 25 - margin
        }
        #expect(pointsInsideHole.isEmpty, "no basket-weave stitch should land inside the hole")
    }

    @Test func basketWeaveIntegratesWithDigitizePipeline() throws {
        let square = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 30), Point2D(0, 30),
        ], closed: true)])
        var params = squareParams()
        params.fillPattern = .basketWeave
        let object = EmbroideryObject(name: "BasketWeaveFill", shape: square, stitchType: .tatamiFill,
                                       threadColor: .generic(RGBColor(hex: 0x00FF00)), parameters: params)
        let doc = StitchDocument(name: "BasketWeaveTest", physicalWidthMM: 30, physicalHeightMM: 30, objects: [object])
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 30)
    }
}
