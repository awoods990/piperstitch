import Testing
import Foundation
@testable import StitchPilotCore

struct StitchTypeClassifierTests {
    let defaultParams = StitchGenerationParameters() // maxSatinWidthMM = 12.0

    @Test func thinStrokeBecomesTripleRun() {
        // 20mm long, 0.5mm wide -- a hairline, too narrow even for satin.
        // Triple-run, not a single running-stitch pass: one pass around a
        // thin closed shape's boundary is a faint, hollow outline -- see
        // this file's own doc comment on why that reads as sparse scribble
        // rather than a legible hairline mark.
        let hairline = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 0.5), Point2D(0, 0.5),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: hairline, parameters: defaultParams) == .tripleRun)
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
    @Test func widthJustBelowTheRaisedMinimumBecomesTripleRun() {
        let almostThinEnough = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 1.2), Point2D(0, 1.2),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: almostThinEnough, parameters: defaultParams) == .tripleRun)
    }

    /// The actual regression this fix exists for: a real customer logo's
    /// small tagline text ("PERSONAL AI" / "ALWAYS READY.") -- ordinary
    /// raster artwork, not typed through Add Lettering -- classified every
    /// letter `.runningStitch` (each glyph's own average width was below
    /// `minSatinWidthMM` at the size it was imported at) and sewed as a
    /// single hollow pass around each letter's outline, reported back as
    /// "very sparse... the last line of letters is not even readable."
    /// Guards that the fix (triple-run, not a single running pass, for
    /// anything this thin) actually produces roughly triple the stitch
    /// density end-to-end through `DigitizePipeline` -- not just a
    /// different enum case nothing downstream treats any differently.
    @Test func thinRasterTracedGlyphFlattensAsTripleDensityNotASingleSparsePass() throws {
        // A small letter-stroke-shaped rectangle, well under
        // minSatinWidthMM -- representative of one glyph of small tagline
        // text traced from raster artwork (never goes through
        // classifyLetteringRun, which is Add-Lettering-only).
        let glyph = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(0.6, 0), Point2D(0.6, 6), Point2D(0, 6),
        ], closed: true)])
        let type = StitchTypeClassifier.classify(shape: glyph, parameters: defaultParams)
        #expect(type == .tripleRun)

        let color = RGBColor(hex: 0x000000)
        let tripleRunPlan = try DigitizePipeline.flatten(StitchDocument(
            name: "Tagline", physicalWidthMM: 10, physicalHeightMM: 10,
            objects: [EmbroideryObject(name: "Glyph", shape: glyph, stitchType: type, threadColor: .generic(color))]))
        let singlePassPlan = try DigitizePipeline.flatten(StitchDocument(
            name: "Tagline", physicalWidthMM: 10, physicalHeightMM: 10,
            objects: [EmbroideryObject(name: "Glyph", shape: glyph, stitchType: .runningStitch, threadColor: .generic(color))]))

        #expect(tripleRunPlan.stitchCount >= singlePassPlan.stitchCount * 2,
                "triple-run must sew noticeably denser than a single running-stitch pass, or the fix regresses to the sparse/illegible outline this test exists to catch")
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
    /// with its actual width varying enormously along its length -- exactly
    /// the case satin is the *default* for now: width (uniform or not) is
    /// no longer a classification-time reason to reject satin outright, on
    /// the strength that `SatinColumnGenerator.generatePartial` already
    /// makes the real per-crossing call downstream, sewing genuinely narrow
    /// sections as satin and genuinely wide ones as a local fill
    /// sub-region -- see `classify`'s own doc comment.
    @Test func wildlyTaperingShapeInTheMediumBandStillClassifiesSatin() {
        let taperingBlob = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, -1), Point2D(40, -9), Point2D(40, 9), Point2D(0, 1),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: taperingBlob, parameters: defaultParams) == .satin)
    }

    /// A wide, roughly square blob classifies `.tatamiFill` outright. It
    /// used to come back `.satin` -- a convex square rail-fits without
    /// twisting, and width was never a classification-time reason on its
    /// own -- and only sewed as fill because `generatePartial` converted
    /// every over-wide crossing. A 100 mm disc labelled "satin" in the
    /// object list was the visible symptom; a shape whose average width is
    /// far past `maxSatinWidthMM` is an area and is now called one.
    @Test func wideBlobClassifiesAsFill() {
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
        #expect(StitchTypeClassifier.classify(shape: column, parameters: params) == .tripleRun)
    }

    /// A shape with exactly one hole (a single letterform counter: O, P, R,
    /// A, D, Q...) classifies as satin, as a genuine closed-loop ring
    /// column around the hole (`SatinColumnGenerator.computeRingRails`) --
    /// the same ring support `classifyLetteringRun`/`classifyGlyphInRun`
    /// already trust for Add-Lettering text. See `classify`'s own doc
    /// comment.
    @Test func singleHoledShapeClassifiesAsSatinRingColumn() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 8), Point2D(0, 8)], closed: true)
        let hole = SubPath(points: [Point2D(10, 2), Point2D(20, 2), Point2D(20, 6), Point2D(10, 6)], closed: true)
        let letterformWithCounter = VectorShape(subPaths: [outer, hole])
        #expect(StitchTypeClassifier.classify(shape: letterformWithCounter, parameters: defaultParams) == .satin)
    }

    /// A shape with *more than one* hole (two separate counters: B, 8) has
    /// no single-column representation -- `SatinColumnGenerator`'s ring
    /// support only ever traces one hole against the outer boundary -- so
    /// it must route to tatami fill regardless of width. Found against
    /// real small lettering that read as different letters entirely once
    /// rendered, not just "rough" ones -- see CHANGELOG.md.
    @Test func columnWidthShapeWithTwoHolesBecomesTatamiFillNotSatin() {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 8), Point2D(0, 8)], closed: true)
        let holeA = SubPath(points: [Point2D(4, 2), Point2D(12, 2), Point2D(12, 6), Point2D(4, 6)], closed: true)
        let holeB = SubPath(points: [Point2D(18, 2), Point2D(26, 2), Point2D(26, 6), Point2D(18, 6)], closed: true)
        let letterformWithTwoCounters = VectorShape(subPaths: [outer, holeA, holeB])
        #expect(StitchTypeClassifier.classify(shape: letterformWithTwoCounters, parameters: defaultParams) == .tatamiFill)
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

    /// A run with a bold block letter well over `maxSatinWidthMM` still
    /// decides satin for the whole run -- satin is the default whenever
    /// every glyph structurally rail-fits, regardless of width;
    /// `SatinColumnGenerator.generatePartial` converts the block letter's
    /// own too-wide interior to a local fill sub-region at render time
    /// (see `classify`'s and `classifyLetteringRun`'s own doc comments),
    /// so nothing about this decision forces the wide letter to render as
    /// a hollow or broken shape -- it just isn't rejected to fill
    /// wholesale purely for being wide.
    @Test func runWithAWideGlyphStillClassifiesSatinForTheWholeRun() {
        let narrowLetter = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(4, 0), Point2D(4, 20), Point2D(0, 20),
        ], closed: true)])
        let wideBlockLetter = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20),
        ], closed: true)])
        let runType = StitchTypeClassifier.classifyLetteringRun(shapes: [narrowLetter, wideBlockLetter], parameters: defaultParams, capHeightMM: 20)
        #expect(runType == .satin)
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

    // MARK: - harmonizeSameColorFillConsistency

    /// The actual regression this exists for: a real customer wordmark
    /// ("LIBBi") whose "B"s -- forced to tatami fill by their two counters,
    /// a structural limit this engine's satin rings can't represent -- sewed
    /// as visibly different fill texture next to their satin "L"/"I"
    /// neighbors of the exact same color. Raster import classifies every
    /// shape independently with no notion "these are letters of one word,"
    /// unlike Add Lettering's `classifyLetteringRun`. This pins that a
    /// same-color "L", "I", and "B" -- "B" alone classifying `.tatamiFill`,
    /// the others independently classifying `.satin` -- all end up
    /// `.tatamiFill` together once harmonized, matching
    /// `classifyLetteringRun`'s real rule (any structurally fill-only
    /// member pulls the whole group to fill) rather than a majority vote.
    @Test func multiHoleSiblingPullsWholeSameColorGroupToTatami() {
        let color = RGBColor(hex: 0x0A1F44)
        let lShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(4, 0), Point2D(4, 20), Point2D(0, 20),
        ], closed: true)])
        let iShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(3, 0), Point2D(3, 20), Point2D(0, 20),
        ], closed: true)])
        // "B": an outer boundary with two separate counters (subPaths.count
        // == 3), exactly like `multiHoledGlyphFallsBackToTatamiEvenInASatinRun`'s
        // fixture above.
        let bOuter = SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 20), Point2D(0, 20)], closed: true)
        let bUpperHole = SubPath(points: [Point2D(2, 11), Point2D(8, 11), Point2D(8, 18), Point2D(2, 18)], closed: true)
        let bLowerHole = SubPath(points: [Point2D(2, 2), Point2D(8, 2), Point2D(8, 9), Point2D(2, 9)], closed: true)
        let bShape = VectorShape(subPaths: [bOuter, bUpperHole, bLowerHole])

        var objects = [lShape, iShape, bShape].enumerated().map { index, shape in
            EmbroideryObject(name: "Letter\(index)", shape: shape,
                              stitchType: StitchTypeClassifier.classify(shape: shape, parameters: defaultParams),
                              threadColor: .generic(color))
        }
        // Confirm the baseline mismatch this test guards against actually
        // reproduces before harmonizing.
        #expect(objects[0].stitchType == .satin)
        #expect(objects[1].stitchType == .satin)
        #expect(objects[2].stitchType == .tatamiFill)

        objects = StitchTypeClassifier.harmonizeSameColorFillConsistency(objects)
        #expect(objects.allSatisfy { $0.stitchType == .tatamiFill },
                "every same-color sibling must share one stitch type once a structurally fill-only member is in the group")
    }

    /// Without any structural blocker, the group's widest *simple* member
    /// decides satin-vs-fill for everyone -- mirroring
    /// `classifyLetteringRun` exactly, not re-deriving a looser rule. Two
    /// narrow columns that already agree stay satin; harmonizing a
    /// same-color group that's already consistent must be a no-op.
    @Test func alreadyConsistentSameColorGroupIsUnaffected() {
        let color = RGBColor(hex: 0x0A1F44)
        let lShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(4, 0), Point2D(4, 20), Point2D(0, 20),
        ], closed: true)])
        let iShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(3, 0), Point2D(3, 20), Point2D(0, 20),
        ], closed: true)])
        var objects = [lShape, iShape].enumerated().map { index, shape in
            EmbroideryObject(name: "Letter\(index)", shape: shape,
                              stitchType: StitchTypeClassifier.classify(shape: shape, parameters: defaultParams),
                              threadColor: .generic(color))
        }
        #expect(objects.allSatisfy { $0.stitchType == .satin })

        let harmonized = StitchTypeClassifier.harmonizeSameColorFillConsistency(objects)
        #expect(harmonized.map(\.stitchType) == objects.map(\.stitchType))
    }

    /// A genuinely tiny/hairline same-color sibling that classified
    /// `.runningStitch`/`.tripleRun` on its own merits is
    /// `reconcileRunningStitchOutliers`'s own territory (which deliberately
    /// leaves a real hairline accent alone) -- this pass must not touch it,
    /// only siblings already `.satin`/`.tatamiFill`.
    @Test func runningOrTripleRunSiblingsAreLeftForTheOtherReconciliationPass() {
        let color = RGBColor(hex: 0x0A1F44)
        let bOuter = SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 20), Point2D(0, 20)], closed: true)
        let bUpperHole = SubPath(points: [Point2D(2, 11), Point2D(8, 11), Point2D(8, 18), Point2D(2, 18)], closed: true)
        let bLowerHole = SubPath(points: [Point2D(2, 2), Point2D(8, 2), Point2D(8, 9), Point2D(2, 9)], closed: true)
        let bShape = VectorShape(subPaths: [bOuter, bUpperHole, bLowerHole])
        let hairline = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(1, 0.2)], closed: false)])

        let objects = [
            EmbroideryObject(name: "B", shape: bShape, stitchType: .tatamiFill, threadColor: .generic(color)),
            EmbroideryObject(name: "Hairline", shape: hairline, stitchType: .runningStitch, threadColor: .generic(color)),
        ]
        let harmonized = StitchTypeClassifier.harmonizeSameColorFillConsistency(objects)
        #expect(harmonized[1].stitchType == .runningStitch)
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

    /// A square with two punched-out holes -- reliably classifies
    /// `.tatamiFill` regardless of width under the current (satin-by-
    /// default) rules: `SatinColumnGenerator`'s ring support only ever
    /// traces *one* hole against the outer boundary (see `classify`'s own
    /// doc comment), so two holes is a hard structural limit it can't
    /// represent at all, unlike a solid square's mere width (no longer a
    /// rejection reason on its own) or a single hole (a genuine ring
    /// column). Used wherever a fixture specifically needs to classify
    /// tatami via the real classifier, not just be assigned that type
    /// directly.
    private func solidSquareWithTwoHoles(sizeMM: Double, at origin: Point2D = .zero) -> VectorShape {
        let outer = SubPath(points: [
            Point2D(origin.x, origin.y), Point2D(origin.x + sizeMM, origin.y),
            Point2D(origin.x + sizeMM, origin.y + sizeMM), Point2D(origin.x, origin.y + sizeMM),
        ], closed: true)
        let holeSize = sizeMM * 0.2
        let holeA = SubPath(points: [
            Point2D(origin.x + sizeMM * 0.15, origin.y + sizeMM * 0.4), Point2D(origin.x + sizeMM * 0.15 + holeSize, origin.y + sizeMM * 0.4),
            Point2D(origin.x + sizeMM * 0.15 + holeSize, origin.y + sizeMM * 0.4 + holeSize), Point2D(origin.x + sizeMM * 0.15, origin.y + sizeMM * 0.4 + holeSize),
        ], closed: true)
        let holeB = SubPath(points: [
            Point2D(origin.x + sizeMM * 0.65, origin.y + sizeMM * 0.4), Point2D(origin.x + sizeMM * 0.65 + holeSize, origin.y + sizeMM * 0.4),
            Point2D(origin.x + sizeMM * 0.65 + holeSize, origin.y + sizeMM * 0.4 + holeSize), Point2D(origin.x + sizeMM * 0.65, origin.y + sizeMM * 0.4 + holeSize),
        ], closed: true)
        return VectorShape(subPaths: [outer, holeA, holeB])
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
            let square = solidSquareWithTwoHoles(sizeMM: 20, at: Point2D(Double(i) * 25, 0))
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

    /// A big blob with a small hole is an area with a hole, not a ring: its
    /// area-over-perimeter "width" is small only because a spiky outline
    /// inflates the perimeter (an eagle's head with the eye cut out, sewn as
    /// a satin ring -- an outline round nothing).
    @Test func aWideBlobWithASmallHoleIsFillNotARingSatin() {
        var outer: [Point2D] = []
        for k in 0..<72 {
            let a = Double(k) / 72 * .pi * 2
            let r = (k % 2 == 0) ? 30.0 : 24.0   // spiky
            outer.append(Point2D(35 + r * cos(a), 35 + r * sin(a)))
        }
        var hole: [Point2D] = []
        for k in 0..<24 { let a = Double(k) / 24 * .pi * 2; hole.append(Point2D(45 + 4 * cos(a), 30 + 4 * sin(a))) }
        let shape = VectorShape(subPaths: [SubPath(points: outer, closed: true), SubPath(points: hole, closed: true)])
        #expect(StitchTypeClassifier.classify(shape: shape, parameters: StitchGenerationParameters()) == .tatamiFill)
    }
}
