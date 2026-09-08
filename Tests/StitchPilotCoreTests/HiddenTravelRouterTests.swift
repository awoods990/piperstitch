import Testing
@testable import StitchPilotCore

struct HiddenTravelRouterTests {
    /// A dense satin-column strip -- the one stitch type
    /// `nextObjectCanHideATravelPath` actually trusts to hide a buried
    /// travel stitch (crossings run 0.3-0.5mm apart, tight enough to read
    /// as solid regardless of which direction a buried stitch crosses it).
    /// Entry point computed from the real generator, not hand-derived, so
    /// tests aren't coupled to rail-fitting internals -- matches
    /// `makeFillObject`'s own approach below.
    private func makeSatinObject(name: String, color: UInt32 = 0x000000) -> (object: EmbroideryObject, runs: [[Point2D]]) {
        var params = StitchGenerationParameters()
        params.pullCompensationMM = 0
        params.pushCompensationMM = 0
        params.satinDensityMM = 0.4
        let shape = VectorShape(subPaths: [SubPath(points: [
            Point2D(-2, -15), Point2D(2, -15), Point2D(2, 15), Point2D(-2, 15),
        ], closed: true)])
        let object = EmbroideryObject(name: name, shape: shape, stitchType: .satin, threadColor: .generic(RGBColor(hex: color)), parameters: params)
        let runs = try! SatinColumnGenerator.generatePartial(for: shape, parameters: params)
        return (object, [runs])
    }

    /// A tatami-fill rectangle -- textured "Rows" coverage with real,
    /// intentional gaps between rows, exactly the case
    /// `nextObjectCanHideATravelPath` now excludes: found directly against
    /// real lettering, where a same-color bridge between two non-adjacent
    /// letters cut a visible diagonal scratch across the letters in
    /// between, since the buried stitch ran diagonally across the fill's
    /// own row gaps instead of hiding within a row. See CHANGELOG.md.
    private func makeFillObject(name: String, color: UInt32 = 0x000000) -> (object: EmbroideryObject, runs: [[Point2D]]) {
        var params = StitchGenerationParameters()
        params.pullCompensationMM = 0
        params.pushCompensationMM = 0
        // Pin the angle explicitly: for a perfect (symmetric) square, the
        // automatic selector's principal-axis analysis is ambiguous and
        // defaults to 90 degrees (vertical rows), which would break every
        // "same row, entry.x = box.minX" assumption these tests rely on.
        params.fillAngleDegrees = 0
        // No underlay: DigitizePipeline prepends underlay points before the
        // fill itself for a real .tatamiFill object, which would make the
        // object's actual entry point the underlay's start rather than the
        // fill's -- these tests need `bEntry` (computed straight from
        // TatamiFillGenerator) to match the object's real first point.
        params.underlayType = UnderlayType.none
        let shape = VectorShape(subPaths: [SubPath(points: [
            Point2D(-15, -15), Point2D(15, -15), Point2D(15, 15), Point2D(-15, 15),
        ], closed: true)])
        let object = EmbroideryObject(name: name, shape: shape, stitchType: .tatamiFill, threadColor: .generic(RGBColor(hex: color)), parameters: params)
        return (object, [TatamiFillGenerator.generate(for: shape, parameters: params)])
    }

    private func makeLineObject(name: String, from a: Point2D, to b: Point2D, color: UInt32 = 0x000000) -> (object: EmbroideryObject, runs: [[Point2D]]) {
        let shape = VectorShape(subPaths: [SubPath(points: [a, b], closed: false)])
        let object = EmbroideryObject(name: name, shape: shape, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: color)))
        return (object, [[a, b]])
    }

    @Test func bridgesGapWhenCoveredBySatin() {
        let b = makeSatinObject(name: "b")
        let bEntry = b.runs[0].first!
        // Near the opposite end of B's 30mm-tall strip from wherever its
        // rails happened to start -- far enough to clear the threshold,
        // and (the strip being a plain rectangle, convex) the straight
        // line between the two stays entirely inside B's own shape
        // regardless of which end `bEntry` turned out to be.
        let aExit = Point2D(0, bEntry.y > 0 ? -13 : 13)
        let a = makeLineObject(name: "a", from: Point2D(aExit.x - 10, aExit.y), to: aExit)

        let bridged = HiddenTravelRouter.bridgeSameColorGaps([a, b], thresholdMM: 5.0)

        #expect(bridged[1].runs[0].count > b.runs[0].count, "bridging should prepend extra stitch points")
        #expect(bridged[1].runs[0].last == b.runs[0].last, "B's own generated points must still end exactly where they did")
        let prependedCount = bridged[1].runs[0].count - b.runs[0].count
        for p in bridged[1].runs[0].prefix(prependedCount) {
            #expect(p.x > -2 && p.x < 2 && p.y > -15 && p.y < 15, "every prepended bridge point should land inside B's satin strip")
        }
    }

    /// The actual bug this guards against: a shape geometrically covering
    /// the travel path isn't enough on its own -- a textured fill (Rows,
    /// and Cross-Hatch/Basket Weave built the same way) has real gaps
    /// between its own stitching, so a buried travel stitch through it
    /// stays visibly exposed instead of getting hidden. Same "well inside
    /// B, along what would be a covered row" geometry
    /// `bridgesGapWhenCoveredBySatin` (and this file's own previous
    /// version, before this fix) used for satin -- only the covering
    /// object's own stitch type differs.
    @Test func doesNotBridgeGapEvenWhenCoveredByTatamiFill() {
        let b = makeFillObject(name: "b")
        let bEntry = b.runs[0].first!
        let aExit = Point2D(bEntry.x + 20, bEntry.y)
        let a = makeLineObject(name: "a", from: Point2D(aExit.x - 10, aExit.y), to: aExit)

        let bridged = HiddenTravelRouter.bridgeSameColorGaps([a, b], thresholdMM: 5.0)
        #expect(bridged[1].runs == b.runs, "a textured fill's own row gaps can't reliably hide a buried travel stitch, so this must fall back to a plain (later trimmed) jump instead")
    }

    @Test func doesNotBridgeWhenPathLeavesShape() {
        let b = makeSatinObject(name: "b")
        let bEntry = b.runs[0].first!
        // Far outside B's strip entirely -- most of the straight path to
        // B's entry crosses exposed fabric, not B's own area.
        let aExit = Point2D(bEntry.x - 100, bEntry.y)
        let a = makeLineObject(name: "a", from: Point2D(aExit.x - 10, aExit.y), to: aExit)

        let bridged = HiddenTravelRouter.bridgeSameColorGaps([a, b], thresholdMM: 5.0)
        #expect(bridged[1].runs == b.runs)
    }

    @Test func doesNotBridgeShortGapsEvenWhenCovered() {
        let b = makeSatinObject(name: "b")
        let bEntry = b.runs[0].first!
        // Covered, but the gap itself is short enough that the plain
        // alternative (an untrimmed jump) would already end up buried
        // under B's own stitching just the same -- bridging adds nothing.
        let aExit = Point2D(0, bEntry.y > 0 ? bEntry.y - 3 : bEntry.y + 3)
        let a = makeLineObject(name: "a", from: Point2D(aExit.x - 5, aExit.y), to: aExit)

        let bridged = HiddenTravelRouter.bridgeSameColorGaps([a, b], thresholdMM: 15.0)
        #expect(bridged[1].runs == b.runs)
    }

    @Test func doesNotBridgeAcrossAColorChange() {
        let b = makeSatinObject(name: "b", color: 0xFF0000)
        let bEntry = b.runs[0].first!
        let aExit = Point2D(0, bEntry.y > 0 ? -13 : 13)
        let a = makeLineObject(name: "a", from: Point2D(aExit.x - 10, aExit.y), to: aExit, color: 0x000000)

        let bridged = HiddenTravelRouter.bridgeSameColorGaps([a, b], thresholdMM: 5.0)
        #expect(bridged[1].runs == b.runs)
    }

    @Test func pipelineAvoidsTrimWhenTravelIsCoveredBySatin() throws {
        let b = makeSatinObject(name: "b")
        let bEntry = b.runs[0].first!
        let aExit = Point2D(0, bEntry.y > 0 ? -13 : 13)
        // A's own *shape* (not just its final stitch) must start well
        // outside B's bounding box: otherwise a degenerate line shape
        // sitting entirely inside B's box gets spuriously classified as
        // "contained" by B (a zero-area shape trivially passes the
        // containment area check), which would force B to sew *first* --
        // exactly backwards from the scenario this test means to set up.
        let aShape = VectorShape(subPaths: [SubPath(points: [Point2D(aExit.x - 100, aExit.y), aExit], closed: false)])
        let aObject = EmbroideryObject(name: "a", shape: aShape, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0x000000)))

        let doc = StitchDocument(name: "Covered", physicalWidthMM: 150, physicalHeightMM: 60, objects: [aObject, b.object])
        let plan = try DigitizePipeline.flatten(doc, maxJumpWithoutTrimMM: 5.0)
        // Only the final trim at the end of the design -- the long
        // same-color gap didn't need one since it got bridged.
        #expect(plan.trimCount == 1)
    }

    @Test func pipelineStillTrimsWhenTravelIsCoveredByTatamiFillOnly() throws {
        let b = makeFillObject(name: "b")
        let bEntry = b.runs[0].first!
        let aExit = Point2D(bEntry.x + 20, bEntry.y)
        let aShape = VectorShape(subPaths: [SubPath(points: [Point2D(aExit.x - 100, aExit.y), aExit], closed: false)])
        let aObject = EmbroideryObject(name: "a", shape: aShape, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0x000000)))

        let doc = StitchDocument(name: "CoveredByFillOnly", physicalWidthMM: 200, physicalHeightMM: 60, objects: [aObject, b.object])
        let plan = try DigitizePipeline.flatten(doc, maxJumpWithoutTrimMM: 5.0)
        // Geometrically covered by B's own tatami fill, but that's not
        // enough on its own any more -- still needs the gap's own trim,
        // plus the final one.
        #expect(plan.trimCount == 2)
    }

    @Test func pipelineStillTrimsWhenTravelIsNotCovered() throws {
        let b = makeSatinObject(name: "b")
        let bEntry = b.runs[0].first!
        let aExit = Point2D(bEntry.x - 100, bEntry.y)
        let aShape = VectorShape(subPaths: [SubPath(points: [Point2D(aExit.x - 10, aExit.y), aExit], closed: false)])
        let aObject = EmbroideryObject(name: "a", shape: aShape, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0x000000)))

        let doc = StitchDocument(name: "NotCovered", physicalWidthMM: 200, physicalHeightMM: 60, objects: [aObject, b.object])
        let plan = try DigitizePipeline.flatten(doc, maxJumpWithoutTrimMM: 5.0)
        // The long, uncovered gap still needs its own trim, plus the final one.
        #expect(plan.trimCount == 2)
    }
}
