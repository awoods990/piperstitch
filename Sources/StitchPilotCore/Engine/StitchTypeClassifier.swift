import Foundation

/// Automatically decides which stitch technique best represents a shape —
/// spec §11 "The software should decide which embroidery technique best
/// represents each object" — rather than requiring the caller to choose
/// `stitchType` by hand for every imported object.
///
/// The heuristic: estimate the shape's average width as `area / length`
/// along its principal (elongation) axis — the same measurement a person
/// eyeballing a shape uses ("that's a thin stroke" vs. "that's a big
/// blob") — and bucket by width, roughly matching standard digitizing
/// practice (very thin line <~1.5mm: triple-run; narrow shape ~1.5-8mm:
/// satin; medium ~8-12mm: satin or tatami depending on the shape; wide
/// >~12mm: tatami):
/// - narrower than `parameters.minSatinWidthMM` (default 1.5mm): too thin
///   even for satin, sews as a `.tripleRun` outline instead of a single
///   `.runningStitch` pass (spec §19 "small object management" — a
///   hairline stroke). A single pass around a thin closed shape's own
///   boundary is a hollow, faint outline -- fine for a genuinely open line,
///   but for a small raster-traced glyph or fine illustration detail
///   (identical geometry: a thin closed shape) it reads as sparse scribble
///   rather than a legible mark. `classifyLetteringRun` already reached
///   this same conclusion for text typed through Add Lettering (see its
///   own doc comment) -- raster import never went through that path, so a
///   logo's own small tagline text, imported as ordinary artwork, kept
///   getting the single-pass outline that a real digitizer would never
///   ship (found directly against a real customer logo whose tagline came
///   back "not even readable").
/// - has one or more holes: tatami fill, regardless of width -- see below.
/// - up to `satinUniformWidthThresholdMM` (8mm): satin outright.
/// - up to `parameters.maxSatinWidthMM` (default 12mm): satin only if the
///   shape's width is fairly *uniform* along its length (a real column,
///   which still lays down fine as satin even toward the wider end of the
///   practical range); a shape whose width varies a lot from one end to
///   the other — its average landing in this medium band doesn't mean
///   every part of it is medium-width — goes to tatami instead, since a
///   real column is what satin actually sews well, not just "something
///   whose average width happens to fit."
/// - wider than that: tatami fill.
///
/// A shape with holes always routes to tatami fill, never satin: unlike
/// `TatamiFillGenerator` (even-odd across every sub-path), `Satin
/// ColumnGenerator` only ever looks at the outer boundary
/// (`shape.subPaths.first`) and has no way to represent a hole at all — a
/// letterform counter (the enclosed hole inside O, P, R, A, D, B, Q...)
/// would get silently filled in solid, and satin's rail-fitting (which
/// assumes a simple, roughly-elongated column shape) can produce genuine
/// nonsense for a boundary shaped like a ring rather than a column. An
/// earlier version of this classifier didn't check for holes at all — real
/// small-lettering artwork with counter-bearing glyphs classified as satin
/// came out structurally wrong (not just visually rough), found by
/// rendering a real logo's tagline text and finding it illegible in a way
/// no amount of "just make satin denser" would fix (see CHANGELOG.md).
/// Note this only catches a shape whose *average* width is too thin; a
/// shape whose average is fine but that narrows below the minimum in one
/// section (e.g. a tapering stroke) still classifies as `.satin` here and
/// is instead caught per-section by `SatinColumnGenerator.generatePartial`.
public enum StitchTypeClassifier {
    /// Below this width, a shape stays satin regardless of how uniform it
    /// is — commercial digitizing guidance treats ~1.5-8mm as squarely
    /// satin's territory. Above it (up to `maxSatinWidthMM`), satin is
    /// still viable but only for a shape that's actually a uniform column,
    /// not just "average width happens to land under 12mm."
    private static let satinUniformWidthThresholdMM = 8.0
    /// How much a shape's width may vary along its length (as a fraction
    /// of its widest point) and still count as "uniform enough" for satin
    /// in the 8-12mm band — generous enough for a letter stroke's natural
    /// taper at serifs/joins, tight enough to route a genuinely blob-shaped
    /// region (whose average width just happens to fall in this band) to
    /// tatami instead.
    private static let uniformWidthToleranceFraction = 0.35
    private static let widthProfileSamples = 12

    public static func classify(shape: VectorShape, parameters: StitchGenerationParameters) -> StitchType {
        guard let outer = shape.subPaths.first, outer.points.count >= 3 else { return .runningStitch }

        let area = abs(PolygonGeometry.signedArea(outer.points))
        let (axis, mean) = PolygonGeometry.principalAxis(outer.points)
        let (lo, hi) = PolygonGeometry.projectionRange(outer.points, axis: axis, mean: mean)
        let length = hi - lo

        guard length > 0, area > 0 else { return .runningStitch }
        let averageWidth = area / length

        if averageWidth < parameters.minSatinWidthMM { return .tripleRun }
        if shape.subPaths.count > 1 { return .tatamiFill }
        guard averageWidth <= parameters.maxSatinWidthMM else { return .tatamiFill }

        // A shape's *average* width along one global axis is silent about
        // whether it's actually one straight-ish column at all -- an "L"
        // (a vertical stroke and a horizontal stroke meeting at a right
        // angle, exactly the branching case `canRepresentAsSingleSatinColumn`
        // exists to catch) can average out to a perfectly narrow, "uniform"
        // width by this measurement alone despite having no single pair of
        // rails a real satin column could follow. Found directly against a
        // real raster-imported logo: the L's own bent corner produced a
        // long diagonal stitch cutting straight across its open notch --
        // `SatinColumnGenerator` silently railing the shape's boundary in
        // an order that doesn't correspond to a real column, not merely a
        // texture/density issue. `classifyLetteringRun` already gates its
        // own satin decision on this same check (see its doc comment on
        // "H") -- this was the one caller of a `.satin` verdict that
        // didn't, because raster import never goes through the lettering
        // path at all.
        guard SatinColumnGenerator.canRepresentAsSingleSatinColumn(shape: shape, parameters: parameters) else { return .tatamiFill }

        guard averageWidth > satinUniformWidthThresholdMM else { return .satin }

        let widths = widthProfile(outer.points, axis: axis, mean: mean, lo: lo, hi: hi, samples: widthProfileSamples)
        guard let maxWidth = widths.max(), let minWidth = widths.min(), maxWidth > 0 else { return .satin }
        return (maxWidth - minWidth) / maxWidth <= uniformWidthToleranceFraction ? .satin : .tatamiFill
    }

    /// Below this letter height, commercial digitizing guidance treats
    /// satin as unreliable -- the column narrows past what a machine lays
    /// down evenly and reads as a blob rather than a crisp letterform.
    /// `classifyLetteringRun` routes an entire run smaller than this to
    /// `.tripleRun` instead, which stays legible at any size since it
    /// traces the letterform's outline rather than trying to fill it.
    private static let minimumSatinCapHeightMM = 5.0

    /// Decides ONE stitch type for an entire lettering run -- every glyph
    /// shape `LetteringGenerator` produces for one `LetteringSpec` -- rather
    /// than classifying each glyph independently. This matches how real
    /// lettering is actually digitized: a whole word/alphabet is authored
    /// as one style (satin lettering, block/fill lettering, or a fine
    /// outline for tiny text), never a mix of stitch categories from one
    /// letter to the next within the same run. Two letters sewn in
    /// different stitch types read as two different textures/sheens
    /// sitting side by side in the same word -- visibly wrong even when
    /// each one, judged in isolation, was a defensible classification of
    /// its own shape.
    ///
    /// An earlier version of this classified each glyph on its own and
    /// downgraded a multi-stroke letter (T, L, E, F, H, X...) to tatami
    /// fill whenever its width wasn't uniform along a single global axis
    /// -- technically correct in isolation (`SatinColumnGenerator` really
    /// does fit one direction across a glyph's whole outer boundary, which
    /// looks lumpy on a shape whose strokes run in genuinely different
    /// directions), but it meant a word like "MILITARY" could sew most
    /// letters in satin and "T"/"R" in fill, which reads as a mistake, not
    /// as two individually-reasonable choices. A later version fixed the
    /// worst of that (see git history) but still let a genuinely
    /// *branching* letter (H's two stems joined by a crossbar, which
    /// `SatinColumnGenerator.canRepresentAsSingleSatinColumn` really can't
    /// rail-fit as one column, not just "lumpy" but structurally broken)
    /// fall back to running-stitch on its own -- same visible-mistake
    /// problem, just a thinner-vs-bold mismatch instead of a
    /// satin-vs-fill one.
    ///
    /// This version checks EVERY glyph up front, not just measures width:
    /// if any glyph in the run genuinely can't be a single satin column --
    /// branching, or more than one hole -- the WHOLE run falls back to
    /// tatami fill together, rather than one letter alone. Unlike satin
    /// (real structural limits: one boundary for an open column, one hole
    /// for a ring), tatami fill has none -- `TatamiFillGenerator`'s
    /// even-odd scanline fill handles any number of holes or any branching
    /// complexity correctly, so it's the one stitch type genuinely
    /// guaranteed to represent every glyph in a run the same way. True
    /// per-stroke skeleton segmentation (letting a branching letter itself
    /// become clean multi-segment satin, matching commercial digitizing
    /// software) remains a substantially larger, separate undertaking.
    ///
    /// Otherwise gates satin-vs-fill for the whole run on its widest
    /// *simple* (no-hole) glyph -- the shape that would actually be first
    /// to fail a satin column's practical width limit.
    public static func classifyLetteringRun(shapes: [VectorShape], parameters: StitchGenerationParameters, capHeightMM: Double) -> StitchType {
        guard capHeightMM >= minimumSatinCapHeightMM else { return .tripleRun }

        var widestSimpleGlyphAverageWidth = 0.0
        for shape in shapes {
            if shape.subPaths.count > 2 { return .tatamiFill }
            guard shape.subPaths.count == 1, let outer = shape.subPaths.first, outer.points.count >= 3 else { continue }
            guard SatinColumnGenerator.canRepresentAsSingleSatinColumn(shape: shape, parameters: parameters) else { return .tatamiFill }
            let area = abs(PolygonGeometry.signedArea(outer.points))
            let (axis, mean) = PolygonGeometry.principalAxis(outer.points)
            let (lo, hi) = PolygonGeometry.projectionRange(outer.points, axis: axis, mean: mean)
            let length = hi - lo
            guard length > 0, area > 0 else { continue }
            widestSimpleGlyphAverageWidth = max(widestSimpleGlyphAverageWidth, area / length)
        }
        // No measurable simple glyph at all (e.g. a run that's entirely
        // holed letters, or entirely spaces) -- satin is the sensible
        // default; every glyph already passed the checks above.
        guard widestSimpleGlyphAverageWidth > 0 else { return .satin }
        return widestSimpleGlyphAverageWidth <= parameters.maxSatinWidthMM ? .satin : .tatamiFill
    }

    /// Applies the whole run's shared `runStitchType` (from
    /// `classifyLetteringRun`) to one glyph, with the one case that can't
    /// simply follow the run: a glyph with MORE THAN ONE hole (two
    /// separate counters -- B, 8) can't be represented by a satin column
    /// in this engine, whose ring support (`SatinColumnGenerator.
    /// computeRails`) only handles a single enclosed hole -- so it falls
    /// back to tatami fill regardless of what the rest of the run is
    /// doing, a structural necessity rather than a style choice.
    ///
    /// A glyph with exactly ONE hole (a single letterform counter -- O, P,
    /// R, A, D, Q...) follows the run normally: `SatinColumnGenerator`
    /// represents it as a genuine closed-loop ring column around the
    /// hole, not a solid disc. `.tripleRun`/`.runningStitch` and
    /// `.tatamiFill` all already stitch every one of a shape's sub-paths
    /// correctly regardless of hole count (see
    /// `DigitizePipeline.rawStitchRuns`), so this only ever differs from
    /// `runStitchType` when it's `.satin` on a multi-hole glyph.
    public static func classifyGlyphInRun(shape: VectorShape, runStitchType: StitchType) -> StitchType {
        guard runStitchType == .satin, shape.subPaths.count > 2 else { return runStitchType }
        return .tatamiFill
    }

    /// Raster import classifies every detected shape independently (unlike
    /// Add Lettering, which already shares one stitch type across a whole
    /// run -- see `classifyLetteringRun`/`classifyGlyphInRun` above), so
    /// two letters of the same word can land on different, individually
    /// defensible stitch types: a "B"'s two counters force it to tatami
    /// fill (this engine's satin ring support only covers a single hole),
    /// while a neighboring "L" or "I" has no hole at all and classifies
    /// satin on its own narrow, uniform-width merits. Each choice is
    /// correct in isolation, but the two textures sewn side by side in one
    /// word reads as a mistake, not a style choice -- found directly
    /// against a real customer wordmark ("LIBBi") whose "B"s sewed as
    /// visibly different fill texture next to their satin neighbors, and
    /// whose tagline line below it mixed the same way.
    ///
    /// Applies `classifyLetteringRun`'s real rule to shapes raster import
    /// already classified, rather than re-deriving a separate, looser one:
    /// if ANY same-color sibling genuinely can't be a single satin column
    /// (more than one hole, or a branching outline
    /// `SatinColumnGenerator.canRepresentAsSingleSatinColumn` rejects),
    /// the WHOLE group sews as tatami fill together, since fill is the one
    /// stitch type actually guaranteed to represent every member the same
    /// way; otherwise the group's widest simple (no-hole) member decides
    /// satin-vs-fill for everyone, mirroring `classifyLetteringRun` exactly.
    ///
    /// Only reconsiders siblings already `.satin` or `.tatamiFill` --
    /// a `.runningStitch`/`.tripleRun` sibling is `reconcileRunningStitch
    /// Outliers`'s own, more careful territory (it only corrects a
    /// genuinely bulky outlier, deliberately leaving a real hairline
    /// accent alone), so this runs *before* that pass: harmonizing the
    /// bulkier siblings first gives the outlier reconciliation a more
    /// reliable, already-consistent consensus to correct outliers toward.
    public static func harmonizeSameColorFillConsistency(_ objects: [EmbroideryObject]) -> [EmbroideryObject] {
        var groupsByColor: [RGBColor: [Int]] = [:]
        for (index, object) in objects.enumerated() {
            groupsByColor[object.threadColor.rgb, default: []].append(index)
        }

        var result = objects
        for indices in groupsByColor.values {
            let candidates = indices.filter { objects[$0].stitchType == .satin || objects[$0].stitchType == .tatamiFill }
            guard candidates.count > 1 else { continue }

            var anyStructurallyFillOnly = false
            var widestSimpleWidth = 0.0
            let maxSatinWidthMM = objects[candidates[0]].parameters.maxSatinWidthMM
            for index in candidates {
                let shape = objects[index].shape
                let parameters = objects[index].parameters
                if shape.subPaths.count > 2 { anyStructurallyFillOnly = true; continue }
                guard shape.subPaths.count == 1, let outer = shape.subPaths.first, outer.points.count >= 3 else { continue }
                guard SatinColumnGenerator.canRepresentAsSingleSatinColumn(shape: shape, parameters: parameters) else {
                    anyStructurallyFillOnly = true
                    continue
                }
                let area = abs(PolygonGeometry.signedArea(outer.points))
                let (axis, mean) = PolygonGeometry.principalAxis(outer.points)
                let (lo, hi) = PolygonGeometry.projectionRange(outer.points, axis: axis, mean: mean)
                let length = hi - lo
                guard length > 0, area > 0 else { continue }
                widestSimpleWidth = max(widestSimpleWidth, area / length)
            }

            let groupType: StitchType
            if anyStructurallyFillOnly {
                groupType = .tatamiFill
            } else if widestSimpleWidth > 0 {
                groupType = widestSimpleWidth <= maxSatinWidthMM ? .satin : .tatamiFill
            } else {
                groupType = .satin
            }

            for index in candidates {
                // A member that itself has more than one hole can never be
                // satin regardless of the group's decision -- the same
                // structural exception `classifyGlyphInRun` makes.
                let finalType: StitchType = (groupType == .satin && result[index].shape.subPaths.count > 2) ? .tatamiFill : groupType
                result[index].stitchType = finalType
            }
        }
        return result
    }

    /// A shape below this size in either dimension is small enough that
    /// `.runningStitch`/`.tripleRun` is plausibly the right call on its own
    /// merits (a genuine hairline accent, a tiny dot) -- `reconcileRunning
    /// StitchOutliers` below leaves anything this small alone rather than
    /// forcing it to match bulkier siblings it may never have been meant to
    /// match.
    private static let minimumBulkDimensionMM = 3.0
    /// How many same-color siblings already agreeing on one of `.satin`/
    /// `.tatamiFill` counts as a real consensus, not a coincidence -- one
    /// matching sibling alone isn't enough to override an independent
    /// per-shape classification.
    private static let minimumSiblingConsensusCount = 2

    /// Corrects a shape that `classify(shape:parameters:)` independently
    /// routed to `.runningStitch`/`.tripleRun` when it's actually one of a
    /// group of same-color siblings that mostly came out `.satin` or
    /// `.tatamiFill` instead -- both real stitch types with genuine
    /// "dimension or bulk," unlike a thin outline.
    ///
    /// This exists for raster-imported text specifically: `classify` looks
    /// at one shape's own geometry in isolation, with no notion of "this is
    /// one letter of a word that should all sew the same way" the way
    /// `classifyLetteringRun`/`classifyGlyphInRun` above give text typed
    /// through Add Lettering (see their own doc comments) -- raster import
    /// never goes through that path at all, so a single letter whose own
    /// outline confuses the per-shape heuristics (a branching letterform
    /// like T or H, whose crossbar can pull its principal-axis width
    /// calculation down well below `minSatinWidthMM` even though the glyph
    /// itself is large and bold) can come back `.runningStitch` while every
    /// other letter of the same word, in the same color, correctly reads as
    /// `.tatamiFill`/`.satin` -- visibly wrong the same way a mixed-stitch
    /// lettering run is wrong there: one letter in a different, thinner
    /// texture than the word around it, not a defensible independent
    /// choice. Found directly against a real raster-traced logo whose "T"s
    /// sewed as a thin outline while the rest of the word sewed solid.
    ///
    /// Grouping by thread color rather than adjacency/position is
    /// deliberate: raster import already assigns one color per detected
    /// region, so shapes sharing a color are almost always literal letters
    /// of the same word or repeated elements of the same design, not an
    /// incidental coincidence -- the same signal `mergeColors` already
    /// treats as "these belong together" for bulk color reassignment.
    ///
    /// An outlier only gets corrected when it clears `minimumBulkDimensionMM`
    /// in both directions (so a shape that's genuinely tiny/hairline, and
    /// really might belong in a thinner stitch type, is left alone) and its
    /// color has at least `minimumSiblingConsensusCount` siblings already
    /// agreeing on one bulkier stitch type. Correcting toward `.satin`
    /// still re-checks the same structural requirements `classify` itself
    /// enforces (a single boundary, or one hole, that
    /// `SatinColumnGenerator` can actually rail as one column) -- a shape
    /// that fails those falls back to `.tatamiFill` instead, exactly as
    /// `classify` would have decided for it directly.
    public static func reconcileRunningStitchOutliers(_ objects: [EmbroideryObject]) -> [EmbroideryObject] {
        var groupsByColor: [RGBColor: [Int]] = [:]
        for (index, object) in objects.enumerated() {
            groupsByColor[object.threadColor.rgb, default: []].append(index)
        }

        var result = objects
        for indices in groupsByColor.values {
            guard indices.count > 1 else { continue }
            var satinCount = 0
            var tatamiCount = 0
            for index in indices {
                switch objects[index].stitchType {
                case .satin: satinCount += 1
                case .tatamiFill: tatamiCount += 1
                case .runningStitch, .tripleRun: break
                }
            }
            guard max(satinCount, tatamiCount) >= minimumSiblingConsensusCount else { continue }
            let consensusType: StitchType = tatamiCount >= satinCount ? .tatamiFill : .satin

            for index in indices {
                let object = objects[index]
                guard object.stitchType == .runningStitch || object.stitchType == .tripleRun else { continue }
                let box = object.shape.boundingBox
                guard box.width >= minimumBulkDimensionMM, box.height >= minimumBulkDimensionMM else { continue }

                if consensusType == .satin,
                   object.shape.subPaths.count > 2 || !SatinColumnGenerator.canRepresentAsSingleSatinColumn(shape: object.shape, parameters: object.parameters) {
                    result[index].stitchType = .tatamiFill
                } else {
                    result[index].stitchType = consensusType
                }
            }
        }
        return result
    }

    /// Samples the shape's local width at several points along its
    /// principal axis by casting a perpendicular ray through the outer
    /// boundary — a coarse, classification-only measurement (not the
    /// compensated per-crossing widths `SatinColumnGenerator` computes for
    /// actual rail placement) used only to tell "a fairly uniform column"
    /// from "an irregular shape whose average width doesn't represent it."
    private static func widthProfile(_ points: [Point2D], axis: Point2D, mean: Point2D, lo: Double, hi: Double, samples: Int) -> [Double] {
        let perpendicular = Point2D(-axis.y, axis.x)
        guard hi > lo, samples > 0 else { return [] }

        var widths: [Double] = []
        for i in 0..<samples {
            let t = (Double(i) + 0.5) / Double(samples)
            let alongAxis = lo + (hi - lo) * t

            var crossings: [Double] = []
            var j = points.count - 1
            for k in 0..<points.count {
                let a = points[j], b = points[k]
                let pa = (a.x - mean.x) * axis.x + (a.y - mean.y) * axis.y
                let pb = (b.x - mean.x) * axis.x + (b.y - mean.y) * axis.y
                if (pa > alongAxis) != (pb > alongAxis), pb != pa {
                    let segT = (alongAxis - pa) / (pb - pa)
                    let ix = a.x + (b.x - a.x) * segT
                    let iy = a.y + (b.y - a.y) * segT
                    crossings.append((ix - mean.x) * perpendicular.x + (iy - mean.y) * perpendicular.y)
                }
                j = k
            }
            guard crossings.count >= 2 else { continue }
            crossings.sort()
            widths.append(crossings.last! - crossings.first!)
        }
        return widths
    }
}
