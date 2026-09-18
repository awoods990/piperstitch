import Testing
import Foundation
@testable import StitchPilotCore

/// Stages 2 and 4 of the branching-letter satin work (see
/// DIGITIZING_ENGINE.md): `SatinColumnGenerator.
/// canRepresentAsBranchingSatinColumn`/`generateBranching` decompose a
/// genuinely branching shape (built on `StrokeTopologyAnalyzer`'s
/// topology graph, stage 1) into per-segment rails and crossings,
/// concatenated into one flat stitch list. Stage 4 extended this to
/// shapes with holes too -- every real letterform this session tried
/// with real branching structure (B, R, P) turned out to need both at
/// once, not pure holeless branching alone.
struct BranchingSatinGeneratorTests {
    func params(density: Double = 0.4) -> StitchGenerationParameters {
        var p = StitchGenerationParameters()
        p.satinDensityMM = density
        p.pullCompensationMM = 0
        p.pushCompensationMM = 0
        return p
    }

    /// The exact shape `SatinColumnGeneratorTests.
    /// branchingHShapeIsRejectedRatherThanProducingTwistedRails` uses to
    /// prove today's single-column path correctly rejects a branching
    /// letter -- this is the shape the branching path exists to turn back
    /// into real satin instead of falling back to tatami.
    private func hShape() -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(3, 0), Point2D(3, 8.5), Point2D(12, 8.5), Point2D(12, 0),
            Point2D(15, 0), Point2D(15, 20), Point2D(12, 20), Point2D(12, 11.5), Point2D(3, 11.5),
            Point2D(3, 20), Point2D(0, 20),
        ], closed: true)])
    }

    private func tShape() -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 17), Point2D(0, 20), Point2D(20, 20), Point2D(20, 17),
            Point2D(11.5, 17), Point2D(11.5, 0), Point2D(8.5, 0), Point2D(8.5, 17),
        ], closed: true)])
    }

    /// A "P"-style letterform: a stem feeding into a single bowl with its
    /// own hole -- the concrete real-world case stage 4 exists for.
    /// Proportions (stem centered under the bowl, comfortable clearance
    /// between the hole and the stem junction, bowl width just under
    /// `maxSatinWidthMM`'s 12mm default) were tuned empirically against
    /// this exact shape to land under every one of `generateBranching`'s
    /// existing safety checks with real margin, not to the ragged edge of
    /// any one of them.
    private func pShape() -> VectorShape {
        let outer = SubPath(points: [
            Point2D(3, 0), Point2D(6, 0), Point2D(6, 9), Point2D(8.5, 9), Point2D(8.5, 18), Point2D(0, 18), Point2D(0, 9), Point2D(3, 9),
        ], closed: true)
        let hole = SubPath(points: [Point2D(2, 11), Point2D(6.5, 11), Point2D(6.5, 16), Point2D(2, 16)], closed: true)
        return VectorShape(subPaths: [outer, hole])
    }

    /// A "B"-style letterform: a full-height stem with two bowls, each
    /// with its own hole, pinched to the stem's own width at the waist
    /// between them -- the actual real-world case (two holes, not one)
    /// every real branching letterform this session's real-file
    /// investigation found (LIBBi's, the Red Sox logo's) turned out to
    /// need. Same proportion-tuning approach as `pShape` above.
    private func bShape() -> VectorShape {
        let outer = SubPath(points: [
            Point2D(0, 0), Point2D(8.5, 0), Point2D(8.5, 8), Point2D(6, 8), Point2D(6, 10), Point2D(8.5, 10),
            Point2D(8.5, 18), Point2D(0, 18), Point2D(0, 10), Point2D(3, 10), Point2D(3, 8), Point2D(0, 8),
        ], closed: true)
        let holeBottom = SubPath(points: [Point2D(2, 1), Point2D(6.5, 1), Point2D(6.5, 6), Point2D(2, 6)], closed: true)
        let holeTop = SubPath(points: [Point2D(2, 12), Point2D(6.5, 12), Point2D(6.5, 17), Point2D(2, 17)], closed: true)
        return VectorShape(subPaths: [outer, holeBottom, holeTop])
    }

    @Test func branchingHShapeIsRejectedBySingleColumnButAcceptedByBranching() {
        let h = hShape()
        let p = params()
        #expect(!SatinColumnGenerator.canRepresentAsSingleSatinColumn(shape: h, parameters: p))
        #expect(SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: h, parameters: p))
    }

    @Test func generateBranchingProducesStitchesForTheHShape() throws {
        let h = hShape()
        let stitches = try SatinColumnGenerator.generateBranching(for: h, parameters: params())

        #expect(stitches.count > 20, "expected real satin coverage across all three of the H's strokes, got \(stitches.count) points")

        // A generous margin around the shape's own bounding box -- rail
        // crossings sit ON the boundary by construction (before pull
        // compensation, which is zeroed in `params()`), so points should
        // land at or extremely near it, never far outside.
        let box = h.boundingBox
        let margin = 1.0
        for point in stitches {
            #expect(point.x >= box.minX - margin && point.x <= box.maxX + margin, "x=\(point.x) escaped the H's own bounding box")
            #expect(point.y >= box.minY - margin && point.y <= box.maxY + margin, "y=\(point.y) escaped the H's own bounding box")
        }
    }

    /// The junction patch's grain follows the through stroke: on an "H"
    /// the uprights pass through and the crossbar is the branch, so every
    /// stitch at the junction crosses the 3 mm upright rather than
    /// running the length of the patch. Found on the Oholi wordmark's
    /// first render, where the crossbar's junction-inflated width made
    /// it the "widest arm" and the patch was a dozen 7 mm stitches laid
    /// along the upright.
    @Test func junctionPatchStitchesCrossTheThroughStrokeOfAnH() throws {
        let h = hShape()
        let runs = try SatinColumnGenerator.generateBranchingRuns(for: h, parameters: params())
        var longest = 0.0
        for run in runs {
            for i in 1..<run.count { longest = max(longest, run[i - 1].distance(to: run[i])) }
        }
        // The uprights are 3 mm wide and a patch chord reaches at most a
        // little way into the crossbar; the seam from a patch's pole to
        // the crossbar's first crossing is the longest thing left. A
        // chord laid along the upright would be 6-7 mm.
        #expect(longest <= 5.0, "longest stitch \(longest)mm -- junction patch stitches should cross the 3 mm upright, not run along it")
    }

    /// A stroke network whose walk has to hop somewhere sews the loop
    /// first and hops last, so the hop is short: a ribbon with a loop
    /// (Oholi's, in miniature) has one 0.8 mm hop rather than a 26 mm
    /// jump back to the loop after sewing past it to the far end.
    @Test func branchingWalkSewsALoopBeforeContinuingRatherThanJumpingBack() throws {
        // A 2 mm-wide bar from x=0 to x=60 with a ring hanging under it at
        // x=30 -- the ring's two junctions with the bar are 4 mm apart.
        var points: [Point2D] = [Point2D(0, 0), Point2D(60, 0), Point2D(60, 2), Point2D(32, 2)]
        // Outer ring boundary, clockwise from the bar's underside.
        for step in 0...20 {
            let angle = Double.pi / 2 - Double(step) / 20 * Double.pi * 2 * 0.86 - 0.44
            points.append(Point2D(30 + 6 * cos(angle), 7 + 6 * sin(angle)))
        }
        points.append(contentsOf: [Point2D(28, 2), Point2D(0, 2)])
        var hole: [Point2D] = []
        for step in 0..<24 {
            let angle = Double(step) / 24 * Double.pi * 2
            hole.append(Point2D(30 + 4 * cos(angle), 7 + 4 * sin(angle)))
        }
        let shape = VectorShape(subPaths: [SubPath(points: points, closed: true), SubPath(points: hole, closed: true)])
        var p = params()
        p.allowBranchingSatin = true
        let runs = try SatinColumnGenerator.generateBranchingRuns(for: shape, parameters: p)
        // Every hop the walk could not avoid is either sewn (one run) or
        // short; a 30 mm jump back would show as a second run starting
        // far from where the first ended.
        for i in 1..<runs.count {
            guard let end = runs[i - 1].last, let start = runs[i].first else { continue }
            #expect(end.distance(to: start) < 12, "run \(i) starts \(end.distance(to: start))mm from where the previous run ended")
        }
    }

    /// A block-letter "B" with square corners and two rectangular
    /// counters, 6 mm strokes: the LIBBi wordmark in miniature. Its bowl
    /// segments run round a sharp outside corner while the inner rail
    /// stalls on the counter's corner; matching the rails by their own
    /// arc lengths crossed them 15 mm apart and the letter was rejected
    /// ("rails twist"). Paired rails keep each crossing's two ends
    /// together, and no stitch is longer than the widest satin allowed.
    @Test func squareCorneredBWithCountersIsBranchingSatin() throws {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(16, 0), Point2D(22, 3), Point2D(22, 10), Point2D(19, 13), Point2D(22, 16), Point2D(22, 23), Point2D(16, 26), Point2D(0, 26)], closed: true)
        let top = SubPath(points: [Point2D(6, 6), Point2D(15, 6), Point2D(16, 7), Point2D(16, 9), Point2D(15, 10), Point2D(6, 10)], closed: true)
        let bottom = SubPath(points: [Point2D(6, 16), Point2D(15, 16), Point2D(16, 17), Point2D(16, 19), Point2D(15, 20), Point2D(6, 20)], closed: true)
        let b = VectorShape(subPaths: [outer, top, bottom])
        var p = params()
        p.allowBranchingSatin = true
        #expect(SatinColumnGenerator.branchingSatinRejection(shape: b, parameters: p) == nil, "\(SatinColumnGenerator.branchingSatinRejection(shape: b, parameters: p) ?? "")")
        let runs = try SatinColumnGenerator.generateBranchingRuns(for: b, parameters: p)
        var longest = 0.0, total = 0
        for run in runs {
            total += run.count
            for i in 1..<run.count { longest = max(longest, run[i - 1].distance(to: run[i])) }
        }
        #expect(total > 400, "expected real coverage, got \(total) points")
        #expect(longest <= p.maxSatinWidthMM, "longest stitch \(longest)mm")
    }

    @Test func generateBranchingProducesStitchesForTheTShape() throws {
        let t = tShape()
        let stitches = try SatinColumnGenerator.generateBranching(for: t, parameters: params())
        #expect(stitches.count > 10)

        let box = t.boundingBox
        let margin = 1.0
        for point in stitches {
            #expect(point.x >= box.minX - margin && point.x <= box.maxX + margin)
            #expect(point.y >= box.minY - margin && point.y <= box.maxY + margin)
        }
    }

    /// A shape with no real branch (a plain rectangle) is accepted by the
    /// branching path too -- one skeleton edge with perpendicular rails --
    /// and sews as a sound column. It used to be declined for having no
    /// junction, on the grounds that the single-column path is the better
    /// proven one; the single-column path is still tried first everywhere
    /// (`StitchTypeClassifier.classify`, `DigitizePipeline`), but a long
    /// curved stroke that path can't rail-fit (a ribbon, a keyline
    /// fragment) needs this one to say yes, or it falls to fill.
    @Test func nonBranchingShapeIsAcceptedByTheBranchingPath() throws {
        let rect = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(3, 0), Point2D(3, 20), Point2D(0, 20),
        ], closed: true)])
        #expect(SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: rect, parameters: params()))
        let stitches = try SatinColumnGenerator.generateBranchingRuns(for: rect, parameters: params()).flatMap { $0 }
        #expect(stitches.count > 10)
        for point in stitches {
            #expect(point.x >= -1 && point.x <= 4 && point.y >= -1 && point.y <= 21)
        }
    }

    /// A ring with no junction is accepted for the same reason a plain
    /// rectangle now is (see above): its skeleton is one closed loop, and
    /// the loop gets radial ring rails, or perpendicular ones where the
    /// radial sweep can't reach the whole loop. `computeRingRails`'s
    /// dedicated path is still tried first for a one-hole shape.
    @Test func plainRingWithNoJunctionIsAcceptedByTheBranchingPath() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)], closed: true)
        let hole = SubPath(points: [Point2D(7, 7), Point2D(13, 7), Point2D(13, 13), Point2D(7, 13)], closed: true)
        let ring = VectorShape(subPaths: [outer, hole])
        #expect(SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: ring, parameters: params()))
    }

    /// Stage 4's actual target case: a stem *and* a hole together (a "P"
    /// letterform), not pure holeless branching. A hole's own loop is
    /// rail-fit via a radial sweep from its own center
    /// (`computeSegmentRingRails`), the same technique `computeRingRails`
    /// already uses for a plain ring — walking the loop's own polyline
    /// with a local-tangent perpendicular ray (what a non-loop segment
    /// uses) reliably produced twisted rails instead, for the same reason
    /// `computeRingRails`'s own doc comment already gives for why a ring
    /// needs angular correspondence from a fixed center rather than
    /// arc-length-local pairing.
    @Test func branchingAcceptsAPLetterformWithAStemAndOneHole() throws {
        let p = pShape()
        let parameters = params()
        #expect(!SatinColumnGenerator.canRepresentAsSingleSatinColumn(shape: p, parameters: parameters))
        #expect(SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: p, parameters: parameters))

        let stitches = try SatinColumnGenerator.generateBranching(for: p, parameters: parameters)
        #expect(stitches.count > 50, "expected real satin coverage across both the stem and the bowl's ring, got \(stitches.count) points")

        let box = p.boundingBox
        let margin = 1.5
        for point in stitches {
            #expect(point.x >= box.minX - margin && point.x <= box.maxX + margin, "x=\(point.x) escaped the P's own bounding box")
            #expect(point.y >= box.minY - margin && point.y <= box.maxY + margin, "y=\(point.y) escaped the P's own bounding box")
        }
    }

    /// The actual real-world target: a two-hole "B," not just the
    /// simpler one-hole "P" case above. Succeeded on the first attempt
    /// once the P-shape's three underlying bugs were fixed, confirming
    /// the fixes were genuine and general rather than curve-fit to one
    /// specific fixture.
    @Test func branchingAcceptsABLetterformWithAStemAndTwoHoles() throws {
        let b = bShape()
        let parameters = params()
        #expect(!SatinColumnGenerator.canRepresentAsSingleSatinColumn(shape: b, parameters: parameters))
        #expect(SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: b, parameters: parameters))

        let stitches = try SatinColumnGenerator.generateBranching(for: b, parameters: parameters)
        #expect(stitches.count > 100, "expected real satin coverage across the stem and both bowls' rings, got \(stitches.count) points")

        let box = b.boundingBox
        let margin = 1.5
        for point in stitches {
            #expect(point.x >= box.minX - margin && point.x <= box.maxX + margin, "x=\(point.x) escaped the B's own bounding box")
            #expect(point.y >= box.minY - margin && point.y <= box.maxY + margin, "y=\(point.y) escaped the B's own bounding box")
        }
    }

    /// Width is not a rejection reason for a branch segment, exactly as
    /// it isn't for a single column: the too-wide stretch sews as a local
    /// fill sub-region (`generatePartial`'s own per-crossing split, shared
    /// via `stitchesSplittingByWidth`) and the rest stays satin. This used
    /// to be a strict all-or-nothing rejection -- found directly against
    /// a real cap-logo "B" at 100mm whose bowls reached ~16mm against the
    /// 12mm cap, which sent the ENTIRE letter to tatami rather than just
    /// its two widest stretches. Every stitch must still land inside the
    /// shape either way: the fill sub-region is built from the very same
    /// rail points the satin would have used.
    @Test func branchingSewsAnOverWideStretchAsLocalFillRatherThanRejecting() throws {
        var narrow = params()
        narrow.maxSatinWidthMM = 1.0
        #expect(SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: hShape(), parameters: narrow))

        let h = hShape()
        let stitches = try SatinColumnGenerator.generateBranching(for: h, parameters: narrow)
        #expect(stitches.count > 100, "expected real coverage across all three strokes, got \(stitches.count) points")
        let box = h.boundingBox
        let margin = 1.5
        for point in stitches {
            #expect(point.x >= box.minX - margin && point.x <= box.maxX + margin, "x=\(point.x) escaped the H's own bounding box")
            #expect(point.y >= box.minY - margin && point.y <= box.maxY + margin, "y=\(point.y) escaped the H's own bounding box")
        }
    }

    @Test func generateBranchingThrowsRatherThanCrashingOnAnUnsuitableShape() {
        let degenerate = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(0, 0), Point2D(0, 0),
        ], closed: true)])
        #expect(throws: SatinGenerationError.self) {
            _ = try SatinColumnGenerator.generateBranching(for: degenerate, parameters: params())
        }
    }

    /// `allowBranchingSatin` defaults to `false` -- classifying the H
    /// shape should still fall back to tatami fill exactly as before
    /// unless a caller explicitly opts in, unaffected by
    /// `generateBranching` existing alongside it.
    @Test func classifierIsUnaffectedByTheNewBranchingPathByDefault() {
        var p = StitchGenerationParameters()
        p.satinDensityMM = 0.4
        #expect(!p.allowBranchingSatin)
        let type = StitchTypeClassifier.classify(shape: hShape(), parameters: p)
        #expect(type == .tatamiFill)
    }

    // MARK: - Stage 3: wiring behind `allowBranchingSatin`

    @Test func classifierReturnsSatinForTheHShapeWhenBranchingIsAllowed() {
        var p = params()
        p.allowBranchingSatin = true
        let type = StitchTypeClassifier.classify(shape: hShape(), parameters: p)
        #expect(type == .satin)
    }

    /// The classifier deciding `.satin` is only half the wiring --
    /// `DigitizePipeline` itself has to actually call `generateBranching`
    /// rather than hitting `generatePartial`'s `shapeNotSuitable` and
    /// falling back to tatami. A flattened plan with real satin-density
    /// stitch coverage (not just a handful of fill-underlay points) is
    /// the end-to-end proof this held together.
    @Test func pipelineProducesRealSatinCoverageForTheHShapeWhenBranchingIsAllowed() throws {
        var p = params()
        p.allowBranchingSatin = true
        let object = EmbroideryObject(name: "H", shape: hShape(), stitchType: .satin,
                                       threadColor: .generic(RGBColor(hex: 0x000000)), parameters: p)
        let doc = StitchDocument(name: "BranchingH", physicalWidthMM: 15, physicalHeightMM: 20, objects: [object])
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 40, "expected dense satin-density coverage across all three strokes, got \(plan.stitchCount) stitches")
    }

    /// Without the flag, the exact same object still falls back to
    /// tatami through the pipeline's existing safety net -- the flag
    /// change is additive, not a replacement of the fallback.
    @Test func pipelineStillFallsBackToTatamiForTheHShapeWithoutTheFlag() throws {
        let p = params()
        #expect(!p.allowBranchingSatin)
        let object = EmbroideryObject(name: "H", shape: hShape(), stitchType: .satin,
                                       threadColor: .generic(RGBColor(hex: 0x000000)), parameters: p)
        let doc = StitchDocument(name: "BranchingH", physicalWidthMM: 15, physicalHeightMM: 20, objects: [object])
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 0)
    }

    /// A branching-eligible member sharing a color with an ordinary
    /// simple (single-column) satin sibling should be pulled into the
    /// group's own decision rather than unconditionally dragging it to
    /// fill -- the specific gap `harmonizeSameColorFillConsistency`'s
    /// `allowBranchingSatin` allowance exists to close.
    @Test func harmonizePreservesSatinForABranchingMemberAlongsideASimpleSibling() {
        var p = params()
        p.allowBranchingSatin = true
        let color = RGBColor(hex: 0x203040)
        let simpleColumn = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(3, 0), Point2D(3, 20), Point2D(0, 20),
        ], closed: true)])

        let objects = [hShape(), simpleColumn].enumerated().map { index, shape in
            EmbroideryObject(name: "Obj\(index)", shape: shape,
                              stitchType: StitchTypeClassifier.classify(shape: shape, parameters: p),
                              threadColor: .generic(color), parameters: p)
        }
        #expect(objects[0].stitchType == .satin)
        #expect(objects[1].stitchType == .satin)

        let harmonized = StitchTypeClassifier.harmonizeSameColorFillConsistency(objects)
        #expect(harmonized[0].stitchType == .satin, "the branching H should stay satin, not get dragged to fill by its simple sibling")
        #expect(harmonized[1].stitchType == .satin)
    }

    // MARK: - Stage 4: multi-hole wiring behind `allowBranchingSatin`

    /// The real target of stage 4's wiring: a two-hole "B," which before
    /// this stage was an unconditional `classify` hard limit
    /// (`subPaths.count > 2 → .tatamiFill`) regardless of the flag.
    @Test func classifierReturnsSatinForTheBShapeWhenBranchingIsAllowed() {
        var p = params()
        p.allowBranchingSatin = true
        let type = StitchTypeClassifier.classify(shape: bShape(), parameters: p)
        #expect(type == .satin)
    }

    @Test func classifierStillReturnsTatamiForTheBShapeWithoutTheFlag() {
        let p = params()
        #expect(!p.allowBranchingSatin)
        let type = StitchTypeClassifier.classify(shape: bShape(), parameters: p)
        #expect(type == .tatamiFill)
    }

    @Test func pipelineProducesRealSatinCoverageForTheBShapeWhenBranchingIsAllowed() throws {
        var p = params()
        p.allowBranchingSatin = true
        let object = EmbroideryObject(name: "B", shape: bShape(), stitchType: .satin,
                                       threadColor: .generic(RGBColor(hex: 0x000000)), parameters: p)
        let doc = StitchDocument(name: "BranchingB", physicalWidthMM: 8.5, physicalHeightMM: 18, objects: [object])
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 100, "expected dense satin-density coverage across the stem and both bowls' rings, got \(plan.stitchCount) stitches")
    }

    /// A two-hole branching member sharing a color with an ordinary
    /// single-hole ring sibling should be pulled into the group's own
    /// decision rather than unconditionally dragging it to fill --
    /// `harmonizeSameColorFillConsistency`'s multi-hole allowance.
    @Test func harmonizePreservesSatinForATwoHoleBranchingMemberAlongsideARingSibling() {
        var p = params()
        p.allowBranchingSatin = true
        let color = RGBColor(hex: 0x304050)
        let ringSibling = VectorShape(subPaths: [
            SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)], closed: true),
            SubPath(points: [Point2D(7, 7), Point2D(13, 7), Point2D(13, 13), Point2D(7, 13)], closed: true),
        ])

        let objects = [bShape(), ringSibling].enumerated().map { index, shape in
            EmbroideryObject(name: "Obj\(index)", shape: shape,
                              stitchType: StitchTypeClassifier.classify(shape: shape, parameters: p),
                              threadColor: .generic(color), parameters: p)
        }
        #expect(objects[0].stitchType == .satin)
        #expect(objects[1].stitchType == .satin)

        let harmonized = StitchTypeClassifier.harmonizeSameColorFillConsistency(objects)
        #expect(harmonized[0].stitchType == .satin, "the two-hole B should stay satin, not get dragged to fill by its ring sibling")
        #expect(harmonized[1].stitchType == .satin)
    }

    // MARK: - Real-file regression: raster-tracing noise near corners/curves

    private func testArtworkURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestArtwork")
            .appendingPathComponent(name)
    }

    /// The real file that drove this whole rail-fitting hardening pass:
    /// `bShape()`'s clean synthetic geometry above passed on the very
    /// first attempt once stage 4's core bugs were fixed, but every real
    /// raster-traced "B" tried against it still failed `isTwisted` for
    /// reasons the synthetic fixture never exercised -- a corner in the
    /// real boundary that a fixed-direction ray only ever finds from one
    /// exact angle (fixed by `nearestBoundaryPoint` replacing ray-casting
    /// with a nearest-point search), a curving stem needing denser
    /// crossings than a straight run at the same density (fixed by
    /// reusing `computeCrossings`' own curvature-weighted resampling for
    /// branch segments), and the resulting rails still faithfully
    /// tracking a real sharp facet for long enough to pinch against a
    /// neighboring rail (fixed by `smoothedPolyline` applied to the
    /// output rails, not just the input centerline). This test locks in
    /// that real-file result directly, since none of the synthetic
    /// fixtures above are sensitive to it.
    @Test func classifierReturnsSatinForARealRasterTracedBLogoWhenBranchingIsAllowed() throws {
        let data = try Data(contentsOf: testArtworkURL("Boston Red Sox.png"))
        let imported = try ImageImporter.importShapes(from: data, maxColors: 8)
        var combined = BoundingBox.empty
        for shape in imported.shapes { combined = combined.union(shape.boundingBox) }

        // Object 2 in this file is the red "B" -- the one with two real
        // holes (its bowls' counters) that stage 4 exists for.
        let bIndex = imported.shapes.firstIndex { $0.subPaths.count == 3 }
        let index = try #require(bIndex, "expected to find the B's own shape (outer + two hole subpaths) among the imported shapes")
        let fitted = imported.shapes[index].fitToPhysicalSize(widthMM: 100, heightMM: 100, within: combined)

        var p = params()
        p.allowBranchingSatin = true
        #expect(SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: fitted, parameters: p),
                "the real Red Sox B should now rail-fit as branching satin")
        let type = StitchTypeClassifier.classify(shape: fitted, parameters: p)
        #expect(type == .satin)

        let stitches = try SatinColumnGenerator.generateBranching(for: fitted, parameters: p)
        #expect(stitches.count > 200, "expected dense real coverage across the B's stem and both bowls, got \(stitches.count) points")
    }

    /// A second real Red Sox "B" -- the cap logo, a chunkier cut of the
    /// same letterform on a solid navy ground -- at a realistic cap size,
    /// which exposed three separate gaps at once (see DIGITIZING_ENGINE.md):
    /// a 3.1mm thinning-residue loop just over the old 3.0mm residue
    /// threshold that rejected the whole letter at 70mm specifically; the
    /// old strict width cap rejecting it at 100mm; and, once it branched,
    /// hops between pieces sewn straight across its counters as visible
    /// lines. The last is the one only `generateBranchingRuns` can show:
    /// every hop between consecutive points of a run must stay on the
    /// shape's own material -- a hop that would leave it (across a
    /// counter) has to be a run break instead.
    @Test func realCapLogoBBranchesAtCapSizeWithNoRunSewnAcrossItsCounters() throws {
        let data = try Data(contentsOf: testArtworkURL("Boston Red Sox Cap.png"))
        let imported = try ImageImporter.importShapes(from: data, maxColors: 8)
        var combined = BoundingBox.empty
        for shape in imported.shapes { combined = combined.union(shape.boundingBox) }
        let bIndex = imported.shapes.firstIndex { $0.subPaths.count == 3 }
        let index = try #require(bIndex, "expected to find the B's own shape (outer + two counters) among the imported shapes")
        let fitted = imported.shapes[index].fitToPhysicalSize(widthMM: 70, heightMM: 70, within: combined)

        var p = params()
        p.allowBranchingSatin = true
        #expect(StitchTypeClassifier.classify(shape: fitted, parameters: p) == .satin)

        let runs = try SatinColumnGenerator.generateBranchingRuns(for: fitted, parameters: p)
        let polygons = fitted.subPaths.map { $0.points }
        var total = 0
        for run in runs {
            total += run.count
            for i in 1..<run.count {
                let a = run[i - 1], b = run[i]
                // A satin crossing's midpoint is on the stroke's own
                // centerline; a fan spoke's is halfway to the junction
                // center; only a hop sewn straight across a counter has
                // its midpoint on open fabric. A connector under
                // `DigitizePipeline.visibleConnectorMM` is allowed to
                // clip a concave notch, as it is between objects.
                guard a.distance(to: b) > DigitizePipeline.visibleConnectorMM else { continue }
                let mid = Point2D((a.x + b.x) / 2, (a.y + b.y) / 2)
                #expect(PolygonGeometry.pointInPolygons(mid, polygons: polygons),
                        "a \(String(format: "%.1f", a.distance(to: b)))mm stitch is sewn across open fabric, midpoint (\(mid.x), \(mid.y))")
            }
        }
        #expect(total > 1000, "expected dense real coverage across the whole letter, got \(total) points in \(runs.count) runs")
    }

    /// The same letter's centre-run underlay: its skeleton is three
    /// separate loops (the stem-and-bowls network plus one ring round each
    /// counter), and walking from one to the next used to stitch a 3 mm
    /// running line straight across the counter -- found as one blue
    /// thread across each counter of a sewn-out sample. Each such hop
    /// must be a run break; every stitch of every underlay run stays on
    /// the letter's own material.
    @Test func realCapLogoBUnderlayNeverRunsAcrossItsCounters() throws {
        // The outlined cut of the logo: its navy border is a ring round
        // the letter plus a separate ring round each counter -- three
        // skeleton loops with no skeleton path between them.
        let data = try Data(contentsOf: testArtworkURL("boston-red-sox-logo.png"))
        let imported = try ImageImporter.importShapes(from: data, maxColors: 4)
        var combined = BoundingBox.empty
        for shape in imported.shapes { combined = combined.union(shape.boundingBox) }
        let index = try #require(imported.shapes.indices.max { imported.shapes[$0].subPaths.count < imported.shapes[$1].subPaths.count })
        let fitted = imported.shapes[index].fitToPhysicalSize(widthMM: 55.6, heightMM: 80.1, within: combined)
        var p = params()
        p.allowBranchingSatin = true
        p.underlayType = .centerRun

        let runs = SatinColumnGenerator.branchingCenterRunUnderlayRuns(for: fitted, parameters: p)
        let polygons = fitted.subPaths.map { $0.points }
        #expect(runs.count >= 2, "the counters' rings can't be reached along the skeleton, so the underlay must break into runs; got \(runs.count)")
        for run in runs {
            for i in 1..<run.count {
                let a = run[i - 1], b = run[i]
                // Sub-1.5 mm stitches can't be a stray line (the artwork
                // also carries two 1 mm specks whose jagged outlines a
                // stitch along their own skeleton can just miss).
                guard a.distance(to: b) >= 1.5 else { continue }
                let mid = Point2D((a.x + b.x) / 2, (a.y + b.y) / 2)
                #expect(PolygonGeometry.pointInPolygons(mid, polygons: polygons),
                        "a \(String(format: "%.1f", a.distance(to: b)))mm underlay stitch crosses open fabric, midpoint (\(mid.x), \(mid.y))")
            }
        }
        // The flat form is unchanged for callers that want one polyline.
        #expect(SatinColumnGenerator.branchingCenterRunUnderlay(for: fitted, parameters: p).count == runs.reduce(0) { $0 + $1.count })
    }
}
