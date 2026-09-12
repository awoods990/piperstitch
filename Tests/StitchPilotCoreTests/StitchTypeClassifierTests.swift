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

    /// A genuinely branching shape (`canRepresentAsSingleSatinColumn`'s own
    /// case: two rails that visibly cross and re-cross each other, not
    /// just an ordinary bend) still correctly falls back to tatami fill
    /// through the plain per-shape `classify` entry point, not just
    /// through `classifyLetteringRun`'s own, separate whole-run gate --
    /// this is the fix for raster-imported artwork (which never goes
    /// through the lettering path at all) hitting the exact same
    /// structural problem lettering already guarded against. A bent shape
    /// like "L" that merely has a right-angle corner, though, is NOT
    /// caught here -- `computeCrossings`' own crossing generation already
    /// rail-fits it safely; the corresponding real defect (an "L"'s
    /// underlay cutting a visible diagonal through its own open notch)
    /// was in the underlay/crossings *concatenation* seam instead -- see
    /// `DigitizePipelineTests`'s own regression test for that.
    @Test func trueBranchingShapeDoesNotBecomeSatinThroughThePlainClassifier() {
        // Two vertical stems joined by a horizontal crossbar -- an "H",
        // built directly rather than through `LetteringGenerator` so this
        // test doesn't depend on any particular font's own outline.
        let hShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(4, 0), Point2D(4, 13), Point2D(16, 13), Point2D(16, 0),
            Point2D(20, 0), Point2D(20, 30), Point2D(16, 30), Point2D(16, 17), Point2D(4, 17),
            Point2D(4, 30), Point2D(0, 30),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: hShape, parameters: defaultParams) != .satin)
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

    // MARK: - classifyLetteringRun / classifyGlyphInRun

    /// A run with a genuinely branching glyph (a synthetic "H" -- two
    /// parallel stems joined by a crossbar, same shape used in
    /// `SatinColumnGeneratorTests.branchingHShapeIsRejectedRatherThan
    /// ProducingTwistedRails`) alongside otherwise-simple letters must
    /// fall back the WHOLE run to tatami fill, not just that one letter --
    /// otherwise the branching letter alone falls back to a thin
    /// running-stitch outline while its neighbors stay bold satin, the
    /// same visible-mistake problem `classifyLetteringRun` exists to
    /// avoid, just satin-vs-outline instead of satin-vs-fill.
    @Test func runContainingABranchingGlyphFallsBackEntirelyToTatami() {
        let simpleLetter = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(3, 0), Point2D(3, 20), Point2D(0, 20),
        ], closed: true)])
        let hShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(3, 0), Point2D(3, 8.5), Point2D(12, 8.5), Point2D(12, 0),
            Point2D(15, 0), Point2D(15, 20), Point2D(12, 20), Point2D(12, 11.5), Point2D(3, 11.5),
            Point2D(3, 20), Point2D(0, 20),
        ], closed: true)])
        let runType = StitchTypeClassifier.classifyLetteringRun(shapes: [simpleLetter, hShape], parameters: defaultParams, capHeightMM: 20)
        #expect(runType == .tatamiFill)
    }

    /// The stem from `mediumColumnBecomesSatin` above (satin at full size)
    /// -- an entire run made of just this shape at a 3mm letter height
    /// (below the 5mm satin floor) should decide triple-run for the run.
    @Test func smallCapHeightRunBecomesTripleRun() {
        let column = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4),
        ], closed: true)])
        #expect(StitchTypeClassifier.classifyLetteringRun(shapes: [column], parameters: defaultParams, capHeightMM: 3) == .tripleRun)
    }

    /// The core behavior the user's own report drove this design toward:
    /// a run containing both a simple single-stroke letter ("l") and a
    /// "T"-shaped multi-stroke letter (strokes running in genuinely
    /// different directions -- historically the case that made an
    /// isolated per-glyph classifier downgrade just that one letter to
    /// tatami fill) must land on ONE shared stitch type for every glyph in
    /// the run, not a mix -- real lettering is authored as one style
    /// (satin or fill), never switched letter-by-letter within a word.
    @Test func multiStrokeAndSimpleGlyphsInARunShareOneStitchType() {
        let stem = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(2, 0), Point2D(2, 20), Point2D(0, 20),
        ], closed: true)])
        let tShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(9, 0), Point2D(11, 0), Point2D(11, 17), Point2D(20, 17),
            Point2D(20, 20), Point2D(0, 20), Point2D(0, 17), Point2D(9, 17),
        ], closed: true)])
        let runType = StitchTypeClassifier.classifyLetteringRun(shapes: [stem, tShape], parameters: defaultParams, capHeightMM: 20)
        #expect(runType == .satin)
        #expect(StitchTypeClassifier.classifyGlyphInRun(shape: stem, runStitchType: runType) == .satin)
        #expect(StitchTypeClassifier.classifyGlyphInRun(shape: tShape, runStitchType: runType) == .satin)
    }

    /// A run whose widest simple glyph is over `maxSatinWidthMM` (a bold
    /// block-lettering run) decides fill for the whole run, matching
    /// commercial guidance that wide block letters use fill, not satin.
    @Test func runWithAWideGlyphBecomesTatamiFillForTheWholeRun() {
        let narrowLetter = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(4, 0), Point2D(4, 20), Point2D(0, 20),
        ], closed: true)])
        let wideBlockLetter = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20),
        ], closed: true)])
        let runType = StitchTypeClassifier.classifyLetteringRun(shapes: [narrowLetter, wideBlockLetter], parameters: defaultParams, capHeightMM: 20)
        #expect(runType == .tatamiFill)
    }

    /// A holed glyph (a letterform counter -- O, P, R...) can never be a
    /// satin column in this engine regardless of what the rest of an
    /// otherwise-satin run is doing -- the one unavoidable per-glyph
    /// exception `classifyGlyphInRun` makes.
    /// A single-hole glyph (a letterform counter -- O, P, R, A, D, Q...)
    /// now follows an otherwise-satin run instead of being forced to
    /// tatami: `SatinColumnGenerator` can represent it as a genuine ring
    /// column around the one hole.
    @Test func singleHoledGlyphStaysSatinInASatinRun() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 20), Point2D(0, 20)], closed: true)
        let hole = SubPath(points: [Point2D(3, 5), Point2D(7, 5), Point2D(7, 15), Point2D(3, 15)], closed: true)
        let oShape = VectorShape(subPaths: [outer, hole])
        #expect(StitchTypeClassifier.classifyGlyphInRun(shape: oShape, runStitchType: .satin) == .satin)
    }

    /// A glyph with TWO separate holes (B, 8 -- two counters) is still
    /// beyond what a single ring column can represent, so it still falls
    /// back to tatami fill even in an otherwise-satin run.
    @Test func multiHoledGlyphFallsBackToTatamiEvenInASatinRun() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 20), Point2D(0, 20)], closed: true)
        let upperHole = SubPath(points: [Point2D(2, 11), Point2D(8, 11), Point2D(8, 18), Point2D(2, 18)], closed: true)
        let lowerHole = SubPath(points: [Point2D(2, 2), Point2D(8, 2), Point2D(8, 9), Point2D(2, 9)], closed: true)
        let bShape = VectorShape(subPaths: [outer, upperHole, lowerHole])
        #expect(StitchTypeClassifier.classifyGlyphInRun(shape: bShape, runStitchType: .satin) == .tatamiFill)
    }

    /// The same holed glyph must NOT be force-downgraded when the run
    /// itself already isn't satin -- `.tripleRun` and `.tatamiFill` both
    /// already stitch every one of a shape's sub-paths correctly (see
    /// `DigitizePipeline.rawStitchRuns`), so a hole letter in a small
    /// (triple-run) run should stay triple-run like the rest of it.
    @Test func holedGlyphStaysWithTheRunWhenTheRunIsAlreadyNotSatin() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 20), Point2D(0, 20)], closed: true)
        let hole = SubPath(points: [Point2D(3, 5), Point2D(7, 5), Point2D(7, 15), Point2D(3, 15)], closed: true)
        let oShape = VectorShape(subPaths: [outer, hole])
        #expect(StitchTypeClassifier.classifyGlyphInRun(shape: oShape, runStitchType: .tripleRun) == .tripleRun)
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

    /// A self-intersecting "bowtie" quad has zero signed area (the two
    /// triangular lobes cancel in the shoelace formula) despite a normal
    /// 20x20mm bounding box -- exactly the kind of raster-tracing artifact
    /// a branching letterform like "T" or "H" can produce, which
    /// `classify` alone sends to `.runningStitch` via its `area > 0` guard
    /// regardless of how large the shape actually is.
    private func bowtieShape(sizeMM: Double = 20) -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(sizeMM, sizeMM), Point2D(sizeMM, 0), Point2D(0, sizeMM),
        ], closed: true)])
    }

    private func solidSquare(sizeMM: Double, at origin: Point2D = .zero) -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [
            Point2D(origin.x, origin.y), Point2D(origin.x + sizeMM, origin.y),
            Point2D(origin.x + sizeMM, origin.y + sizeMM), Point2D(origin.x, origin.y + sizeMM),
        ], closed: true)])
    }

    /// The main case this exists for: an outlier that independently
    /// classifies as `.runningStitch` despite real bulk, grouped by color
    /// with enough same-color siblings that already agree on one bulkier
    /// stitch type, is corrected to match them.
    @Test func bulkyOutlierSharingAColorWithSeveralTatamiSiblingsIsCorrected() {
        let color = RGBColor(hex: 0x102040)
        let outlier = bowtieShape()
        #expect(StitchTypeClassifier.classify(shape: outlier, parameters: defaultParams) == .runningStitch,
                "the bowtie fixture must actually reproduce the independent-misclassification bug this test guards")

        var objects = [EmbroideryObject(name: "Outlier", shape: outlier, stitchType: .runningStitch, threadColor: .generic(color))]
        for i in 0..<3 {
            let square = solidSquare(sizeMM: 20, at: Point2D(Double(i) * 25, 0))
            let type = StitchTypeClassifier.classify(shape: square, parameters: defaultParams)
            objects.append(EmbroideryObject(name: "Sibling\(i)", shape: square, stitchType: type, threadColor: .generic(color)))
        }
        #expect(objects.dropFirst().allSatisfy { $0.stitchType == .tatamiFill })

        let reconciled = StitchTypeClassifier.reconcileRunningStitchOutliers(objects)
        #expect(reconciled[0].stitchType == .tatamiFill)
    }

    /// A genuinely tiny same-color shape (a real hairline accent, not a
    /// misclassified bulky one) must be left alone -- correcting it would
    /// force fill coverage onto something that may have been deliberately
    /// thin.
    @Test func tinyOutlierIsLeftAlone() {
        let color = RGBColor(hex: 0x102040)
        let tinyLine = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(1, 0.2)], closed: false)])
        var objects = [EmbroideryObject(name: "Tiny", shape: tinyLine, stitchType: .runningStitch, threadColor: .generic(color))]
        for i in 0..<3 {
            let square = solidSquare(sizeMM: 20, at: Point2D(Double(i) * 25, 0))
            objects.append(EmbroideryObject(name: "Sibling\(i)", shape: square, stitchType: .tatamiFill, threadColor: .generic(color)))
        }
        let reconciled = StitchTypeClassifier.reconcileRunningStitchOutliers(objects)
        #expect(reconciled[0].stitchType == .runningStitch)
    }

    /// Only one same-color sibling already agreeing on a bulkier type
    /// isn't a real consensus -- the outlier stays as independently
    /// classified rather than following a single coincidental match.
    @Test func singleSiblingIsNotEnoughConsensusToCorrect() {
        let color = RGBColor(hex: 0x102040)
        let outlier = bowtieShape()
        let square = solidSquare(sizeMM: 20)
        let objects = [
            EmbroideryObject(name: "Outlier", shape: outlier, stitchType: .runningStitch, threadColor: .generic(color)),
            EmbroideryObject(name: "OnlySibling", shape: square, stitchType: .tatamiFill, threadColor: .generic(color)),
        ]
        let reconciled = StitchTypeClassifier.reconcileRunningStitchOutliers(objects)
        #expect(reconciled[0].stitchType == .runningStitch)
    }

    /// Siblings of a *different* color must never influence an outlier --
    /// grouping is by thread color specifically because that's what
    /// raster import uses to signal "these belong together."
    @Test func differentColoredSiblingsDoNotInfluenceAnOutlier() {
        let outlier = bowtieShape()
        var objects = [EmbroideryObject(name: "Outlier", shape: outlier, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0x102040)))]
        for i in 0..<3 {
            let square = solidSquare(sizeMM: 20, at: Point2D(Double(i) * 25, 0))
            objects.append(EmbroideryObject(name: "Sibling\(i)", shape: square, stitchType: .tatamiFill, threadColor: .generic(RGBColor(hex: 0xA0A0A0))))
        }
        let reconciled = StitchTypeClassifier.reconcileRunningStitchOutliers(objects)
        #expect(reconciled[0].stitchType == .runningStitch)
    }
}
