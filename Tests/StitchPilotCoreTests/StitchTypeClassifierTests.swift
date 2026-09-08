import Testing
@testable import StitchPilotCore

struct StitchTypeClassifierTests {
    let defaultParams = StitchGenerationParameters() // maxSatinWidthMM = 12.0

    @Test func thinStrokeBecomesRunningStitch() {
        // 20mm long, 0.5mm wide -- a hairline, too narrow even for satin.
        let hairline = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 0.5), Point2D(0, 0.5),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: hairline, parameters: defaultParams) == .runningStitch)
    }

    @Test func mediumColumnBecomesSatin() {
        // 30mm long, 4mm wide -- a typical letter-stroke-scale column.
        let column = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: column, parameters: defaultParams) == .satin)
    }

    /// 1.2mm is below the current 1.5mm minimum satin width but was above
    /// the old 1.0mm default -- guards the raised default itself, not just
    /// the classifier logic around it.
    @Test func widthJustBelowTheRaisedMinimumBecomesRunningStitch() {
        let almostThinEnough = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 1.2), Point2D(0, 1.2),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: almostThinEnough, parameters: defaultParams) == .runningStitch)
    }

    /// A uniform 10mm-wide column sits in the "medium, shape-dependent"
    /// 8-12mm band but is exactly the kind of shape that band is meant to
    /// keep as satin -- a real column, not a blob that happens to average
    /// out to a medium width.
    @Test func uniformColumnInTheMediumBandStaysSatin() {
        let uniformColumn = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(40, 0), Point2D(40, 10), Point2D(0, 10),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: uniformColumn, parameters: defaultParams) == .satin)
    }

    /// A trapezoid tapering from 2mm to 18mm wide averages out to the same
    /// 10mm as the uniform column above (matching `area / length` exactly),
    /// but its actual width varies enormously along its length -- this is
    /// the "depends on the shape" case the medium band is supposed to catch
    /// and route to tatami instead, since satin doesn't sew a real 18mm-
    /// wide region well just because the *average* looked medium.
    @Test func wildlyTaperingShapeInTheMediumBandBecomesTatami() {
        let taperingBlob = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, -1), Point2D(40, -9), Point2D(40, 9), Point2D(0, 1),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: taperingBlob, parameters: defaultParams) == .tatamiFill)
    }

    @Test func wideBlobBecomesTatamiFill() {
        // 40mm x 40mm square -- far too wide for satin.
        let blob = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(40, 0), Point2D(40, 40), Point2D(0, 40),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: blob, parameters: defaultParams) == .tatamiFill)
    }

    @Test func customMinSatinWidthIsRespected() {
        // Same 4mm column that classifies as satin under the default 1.5mm
        // minimum -- raising the per-object minimum should push it below
        // the threshold instead.
        var params = defaultParams
        params.minSatinWidthMM = 5.0
        let column = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: column, parameters: params) == .runningStitch)
    }

    /// `SatinColumnGenerator` only ever looks at `shape.subPaths.first` and
    /// has no way to represent a hole at all -- unlike `TatamiFillGenerator`
    /// (even-odd across every sub-path), a hole silently gets filled in
    /// solid, and satin's rail-fitting (built for a simple, roughly-
    /// elongated column) can produce a genuinely wrong shape for a boundary
    /// shaped like a ring instead of a column. A shape at satin-column
    /// width but *with a hole* (a letterform counter: O, P, R, A, D, B,
    /// Q...) must route to tatami fill instead, regardless of width. Found
    /// against real small lettering that read as different letters
    /// entirely once rendered, not just "rough" ones -- see CHANGELOG.md.
    @Test func columnWidthShapeWithAHoleBecomesTatamiFillNotSatin() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 8), Point2D(0, 8)], closed: true)
        let hole = SubPath(points: [Point2D(10, 2), Point2D(20, 2), Point2D(20, 6), Point2D(10, 6)], closed: true)
        let letterformWithCounter = VectorShape(subPaths: [outer, hole])
        #expect(StitchTypeClassifier.classify(shape: letterformWithCounter, parameters: defaultParams) == .tatamiFill)
    }

    // MARK: - classifyLetterform

    @Test func smallCapHeightForcesTripleRunInsteadOfSatin() {
        // Same 4mm column `mediumColumnBecomesSatin` above confirms
        // classifies as satin at full size -- at a 3mm letter height
        // (below the 5mm satin floor) it should downgrade to triple-run.
        let column = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4),
        ], closed: true)])
        #expect(StitchTypeClassifier.classifyLetterform(shape: column, parameters: defaultParams, capHeightMM: 3) == .tripleRun)
    }

    @Test func smallCapHeightHairlineStaysRunningStitchNotTripleRun() {
        // A shape `classify` already routes to running-stitch (too thin
        // even for satin) shouldn't get bumped up to triple-run just
        // because it's also small -- the small-cap-height override only
        // ever downgrades a *satin* verdict, never upgrades a thinner one.
        let hairline = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 0.5), Point2D(0, 0.5),
        ], closed: true)])
        #expect(StitchTypeClassifier.classifyLetterform(shape: hairline, parameters: defaultParams, capHeightMM: 3) == .runningStitch)
    }

    /// A "T" outline -- a narrow 2mm-wide, 17mm-tall stem with a wide
    /// 20mm x 3mm bar across its top, the classic case of a letterform
    /// whose strokes run in genuinely different directions. Its average
    /// width (area/length along the principal axis) lands under 8mm, the
    /// band where plain `classify` skips its own uniformity check and
    /// returns satin outright -- which `SatinColumnGenerator` would then
    /// lay down as ONE straight column across the whole letter, lumpy
    /// right where the bar meets the stem. `classifyLetterform` re-runs
    /// the uniformity check regardless of band for any letterform, and
    /// this shape's width swings from ~2mm (down the stem) to ~20mm
    /// (across the bar) -- routing it to tatami fill instead, which isn't
    /// sensitive to that direction change the way a satin column is.
    @Test func multiStrokeTShapeDowngradesFromSatinToTatami() {
        let tShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(9, 0), Point2D(11, 0), Point2D(11, 17), Point2D(20, 17),
            Point2D(20, 20), Point2D(0, 20), Point2D(0, 17), Point2D(9, 17),
        ], closed: true)])
        // Confirms plain `classify` really does pick satin here -- the
        // baseline this test is guarding against, not just asserting the
        // fixed behavior in isolation.
        #expect(StitchTypeClassifier.classify(shape: tShape, parameters: defaultParams) == .satin)
        #expect(StitchTypeClassifier.classifyLetterform(shape: tShape, parameters: defaultParams, capHeightMM: 20) == .tatamiFill)
    }

    /// A simple single-stroke letterform (e.g. "l", "i", "1") at a legible
    /// size must NOT get swept into the same downgrade -- guards against
    /// the uniformity re-check being so aggressive it second-guesses every
    /// ordinary satin letter, not just genuinely multi-directional ones.
    @Test func singleStrokeLetterformStaysSatinAtLegibleSize() {
        let stem = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(2, 0), Point2D(2, 20), Point2D(0, 20),
        ], closed: true)])
        #expect(StitchTypeClassifier.classifyLetterform(shape: stem, parameters: defaultParams, capHeightMM: 20) == .satin)
    }

    @Test func degenerateShapeDefaultsToRunningStitch() {
        let line = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(10, 0)], closed: false)])
        #expect(StitchTypeClassifier.classify(shape: line, parameters: defaultParams) == .runningStitch)
    }

    /// Classified output must actually be sew-able by DigitizePipeline
    /// without throwing -- catches a classifier/generator mismatch (e.g.
    /// classifying something as satin that the generator then rejects).
    @Test func classifiedObjectsAllFlattenSuccessfully() throws {
        let shapes: [VectorShape] = [
            VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 0.5), Point2D(0, 0.5)], closed: true)]),
            VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4)], closed: true)]),
            VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(40, 0), Point2D(40, 40), Point2D(0, 40)], closed: true)]),
        ]
        var objects: [EmbroideryObject] = []
        for (i, shape) in shapes.enumerated() {
            let type = StitchTypeClassifier.classify(shape: shape, parameters: defaultParams)
            objects.append(EmbroideryObject(name: "Obj\(i)", shape: shape, stitchType: type, threadColor: .generic(RGBColor(hex: 0x000000))))
        }
        let doc = StitchDocument(name: "Mixed", physicalWidthMM: 40, physicalHeightMM: 40, objects: objects)
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 0)
    }
}
