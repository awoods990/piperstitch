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

    /// A shape with no real branch (a plain rectangle) already has a
    /// direct, simpler, better-proven satin path -- `canRepresentAs
    /// BranchingSatinColumn` should decline it rather than routing a shape
    /// that doesn't need decomposition through the newer, less-proven
    /// mechanism.
    @Test func nonBranchingShapeIsDeclinedByTheBranchingPath() {
        let rect = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(3, 0), Point2D(3, 20), Point2D(0, 20),
        ], closed: true)])
        #expect(!SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: rect, parameters: params()))
    }

    /// A shape with a hole but no real junction (a plain ring, no
    /// branching stem attached) is declined for the same reason a
    /// holeless non-branching shape is -- no junction to decompose, not
    /// because it has a hole at all. `computeRingRails`'s own dedicated
    /// path already handles exactly this case directly and should keep
    /// doing so; this just confirms the branching path doesn't
    /// needlessly duplicate it. See `branchingHoleyBShapeIsAcceptedByTheBranchingPath`
    /// for the case this path actually exists for: a hole *combined
    /// with* real branching structure.
    @Test func plainRingWithNoJunctionIsDeclinedByTheBranchingPath() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)], closed: true)
        let hole = SubPath(points: [Point2D(7, 7), Point2D(13, 7), Point2D(13, 13), Point2D(7, 13)], closed: true)
        let ring = VectorShape(subPaths: [outer, hole])
        #expect(!SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: ring, parameters: params()))
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

    /// `computeSegmentCrossings` has no equivalent of `generatePartial`'s
    /// per-crossing width splitting (converting only the too-wide
    /// sections of a column to a local fill sub-region) -- a segment
    /// that's too wide anywhere must reject cleanly (the same strict,
    /// all-or-nothing check `generate` itself uses), not silently emit
    /// impractically wide "satin" zigzag stitches. Found directly
    /// against a real large logo shape (a bold "A," genuinely a wide
    /// tapering blob rather than a letter stroke) whose segment reached
    /// 20mm+ wide in places.
    @Test func branchingDeclinesASegmentWiderThanMaxSatinWidth() {
        var narrow = params()
        narrow.maxSatinWidthMM = 1.0
        #expect(!SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: hShape(), parameters: narrow))

        var normal = params()
        normal.maxSatinWidthMM = 12.0
        #expect(SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: hShape(), parameters: normal))
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
}
