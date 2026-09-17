import Foundation

/// Automatically decides which stitch technique best represents a shape —
/// spec §11 "The software should decide which embroidery technique best
/// represents each object" — rather than requiring the caller to choose
/// `stitchType` by hand for every imported object.
///
/// The heuristic: satin is the *default* whenever a shape can structurally
/// be one (spec §12 read together with commercial digitizing practice —
/// satin is the higher-quality, more defined stitch wherever it's actually
/// sewable; fill is the fallback for what genuinely can't be satin, not an
/// equally-weighted alternative). Concretely:
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
/// - has more than one hole (two or more separate counters -- B, 8): tatami
///   fill, regardless of width -- see below.
/// - has exactly one hole (a single letterform counter -- O, P, R, A, D,
///   Q...): satin, as a genuine closed-loop ring column around the hole
///   (`SatinColumnGenerator.computeRails`/`computeRingRails`), not a solid
///   disc -- the same ring support `classifyLetteringRun`/
///   `classifyGlyphInRun` already trust for Add-Lettering text, extended
///   here to raster-imported shapes too (an earlier version forced every
///   hole-bearing shape to tatami fill regardless of hole count, which
///   meant a raster-imported single-hole letter like "A" or "R" sewed as a
///   visibly rougher fill texture than the exact same glyph typed through
///   Add Lettering, despite the engine having real ring-column support the
///   whole time). `canRepresentAsSingleSatinColumn` can't validate this --
///   it only checks a single, holeless boundary (see its own guard) -- so
///   this is trusted the same way `classifyLetteringRun` trusts it, with
///   `DigitizePipeline`'s existing `catch SatinGenerationError
///   .shapeNotSuitable` as the safety net if a genuinely irregular hole
///   (an off-center or oddly-shaped counter `computeRingRails`'s radial
///   sweep can't trace consistently) can't actually rail as a ring at
///   generation time.
/// - otherwise (no hole): satin, as long as `SatinColumnGenerator.
///   canRepresentAsSingleSatinColumn` confirms the outline actually
///   rail-fits as one real column (see that guard's own comment) --
///   *regardless of width or how uniform that width is*. This classifier
///   used to reject a shape outright to tatami fill once its average width
///   passed `maxSatinWidthMM`, or (in an 8-12mm band) once its width
///   varied "too much" along its length -- a whole-shape approximation of
///   a decision `SatinColumnGenerator.generatePartial` already makes for
///   real, per crossing: it classifies every individual crossing along the
///   column as satin, too-narrow (a triple-run centerline), or too-wide (a
///   local tatami-fill sub-region built from that run's own rail points),
///   so a column that's narrow at one end and genuinely too wide at the
///   other already sews satin where it fits and fill only where it
///   doesn't -- see that function's own doc comment. Rejecting the whole
///   shape here first, before generation ever gets a chance to make that
///   finer-grained call, second-guesses a decision the generator is
///   already equipped to make correctly -- it can only make the shape
///   *look worse* than trusting it (an otherwise-satin-eligible letter or
///   logo stroke downgraded to fill entirely because one section, or its
///   overall average, happened to cross a fixed width line), never better.
///
/// A shape with *more than one* hole always routes to tatami fill, never
/// satin: `SatinColumnGenerator.computeRails` ring support
/// (`computeRingRails`) only ever traces one hole against the outer
/// boundary, so a two-counter glyph (B, 8) has no single-column
/// representation -- `TatamiFillGenerator`'s even-odd fill across every
/// sub-path is the one stitch type actually guaranteed to represent it
/// correctly. A shape with *exactly one* hole is a genuine ring, not this
/// problem -- see `classify`'s own doc comment above. An earlier version of
/// this classifier didn't check hole count at all and let satin's
/// single-boundary rail-fitting run on a multi-hole shape, silently filling
/// every counter in solid rather than representing them -- real
/// small-lettering artwork with counter-bearing glyphs classified as satin
/// came out structurally wrong (not just visually rough), found by
/// rendering a real logo's tagline text and finding it illegible in a way
/// no amount of "just make satin denser" would fix (see CHANGELOG.md).
public enum StitchTypeClassifier {
    public static func classify(shape: VectorShape, parameters: StitchGenerationParameters) -> StitchType {
        guard let outer = shape.subPaths.first, outer.points.count >= 3 else { return .runningStitch }

        let area = abs(PolygonGeometry.signedArea(outer.points))
        let (axis, mean) = PolygonGeometry.principalAxis(outer.points)
        let (lo, hi) = PolygonGeometry.projectionRange(outer.points, axis: axis, mean: mean)
        let length = hi - lo

        guard length > 0, area > 0 else { return .runningStitch }
        let averageWidth = area / length

        if averageWidth < parameters.minSatinWidthMM { return .tripleRun }
        if shape.subPaths.count > 2 {
            // `allowBranchingSatin` (stage 4 — see DIGITIZING_ENGINE.md):
            // a shape with more than one hole (B, R with two counters in
            // some fonts) was an unconditional hard limit before this
            // stage, since `computeRingRails`'s ring support only ever
            // traces one hole against the outer boundary — but
            // `StrokeTopologyAnalyzer`'s general topology graph, and
            // `SatinColumnGenerator.generateBranching`'s per-segment
            // rail-fitting built on it, don't share that limit: a
            // multi-hole shape with real branching structure (a stem
            // feeding two bowls) decomposes into ordinary segments plus
            // one self-loop edge per hole, same as the single-hole case
            // stage 3 already extended this way. Still gated behind the
            // same opt-in as every other branching-path use here.
            if parameters.allowBranchingSatin, SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: shape, parameters: parameters) {
                return .satin
            }
            return .tatamiFill
        }
        if shape.subPaths.count == 2 {
            // A ring is satin only if it is narrow enough to be one: its
            // mean width is the band's area over its mean circumference.
            // A 100 mm disc with a letter-shaped hole used to be solid (the
            // importer stripped holes covered by other shapes) and is now a
            // 20 mm-wide ring, which is an area, not a column.
            let holePerimeter = PolygonGeometry.pathLength(shape.subPaths[1].points + [shape.subPaths[1].points[0]])
            let outerPerimeter = PolygonGeometry.pathLength(outer.points + [outer.points[0]])
            let ringArea = area - abs(PolygonGeometry.signedArea(shape.subPaths[1].points))
            let meanCircumference = (holePerimeter + outerPerimeter) / 2
            let ringWidth = meanCircumference > 0 ? ringArea / meanCircumference : averageWidth
            guard ringWidth <= parameters.maxSatinWidthMM else { return .tatamiFill }
            // ...and only if the radial ring rails actually cover it (a
            // ribbon with a loop at one end is not a ring). Otherwise the
            // branching path may still sew it as satin, if allowed.
            if SatinColumnGenerator.canRepresentAsRingSatinColumn(shape: shape) { return .satin }
            if parameters.allowBranchingSatin, SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: shape, parameters: parameters) {
                return .satin
            }
            return .tatamiFill
        }

        // A shape's *average* width along one global axis is silent about
        // whether it's actually one straight-ish column at all -- an "L"
        // (a vertical stroke and a horizontal stroke meeting at a right
        // angle, exactly the branching case `canRepresentAsSingleSatinColumn`
        // exists to catch) can average out to a perfectly narrow width by
        // this measurement alone despite having no single pair of rails a
        // real satin column could follow. Found directly against a real
        // raster-imported logo: the L's own bent corner produced a long
        // diagonal stitch cutting straight across its open notch --
        // `SatinColumnGenerator` silently railing the shape's boundary in
        // an order that doesn't correspond to a real column, not merely a
        // texture/density issue. `classifyLetteringRun` already gates its
        // own satin decision on this same check (see its doc comment on
        // "H") -- this was the one caller of a `.satin` verdict that
        // didn't, because raster import never goes through the lettering
        // path at all.
        // Far too wide for any column -- a 100 mm disc came back "satin"
        // here (the single-column rail fit succeeds on a convex blob) and
        // only sewed as fill because the satin generator converts over-wide
        // sections. Call it what it is. (`averageWidth` is the outer
        // polygon's, so this test belongs only here, on hole-free shapes.)
        if averageWidth > parameters.maxSatinWidthMM * 1.5 { return .tatamiFill }
        if SatinColumnGenerator.canRepresentAsSingleSatinColumn(shape: shape, parameters: parameters) { return .satin }
        // `allowBranchingSatin` (default false — see its own doc comment
        // on `StitchGenerationParameters`): a genuinely branching outline
        // (a letter like "A," "B," "R," "H") that the single-column check
        // above just rejected can still be real satin via
        // `SatinColumnGenerator.generateBranching`'s stroke-segment
        // decomposition (see DIGITIZING_ENGINE.md's staged rollout for
        // this) -- gated behind an explicit opt-in rather than wired in
        // unconditionally, since this path is newer and far less proven
        // against real artwork than the single-column/ring paths above.
        if parameters.allowBranchingSatin, SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: shape, parameters: parameters) {
            return .satin
        }
        return .tatamiFill
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
    /// Otherwise satin for the whole run: once every glyph clears the
    /// structural checks above, width is no longer a reason to reject satin
    /// outright -- `SatinColumnGenerator.generatePartial` (which every
    /// `.satin` object, lettering included, actually renders through; see
    /// `DigitizePipeline`) already makes the width call for real, per
    /// crossing, converting only the genuinely-too-wide *sections* of a
    /// bold letter to a local fill sub-region rather than the whole glyph.
    /// An earlier version measured each glyph's own average width and
    /// downgraded the entire run to fill the moment the widest simple
    /// glyph's average crossed `maxSatinWidthMM` -- a coarser, whole-glyph
    /// approximation of a decision the generator already makes correctly
    /// at the crossing level; see `classify`'s own doc comment for the
    /// identical reasoning applied to raster-imported shapes.
    public static func classifyLetteringRun(shapes: [VectorShape], parameters: StitchGenerationParameters, capHeightMM: Double) -> StitchType {
        guard capHeightMM >= minimumSatinCapHeightMM else { return .tripleRun }

        for shape in shapes {
            if shape.subPaths.count > 2 { return .tatamiFill }
            guard shape.subPaths.count == 1, shape.subPaths.first!.points.count >= 3 else { continue }
            guard SatinColumnGenerator.canRepresentAsSingleSatinColumn(shape: shape, parameters: parameters) else { return .tatamiFill }
        }
        return .satin
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
    /// Strokes narrower than this are sewn as satin and areas wider than it
    /// as fill when one imported region contains both -- see
    /// `separateStrokesFromAreas`. Professional practice on the reference
    /// designs: the alligator's 1 mm keyline is satin, its 3-5 mm collar
    /// and belly bands are fill, and nothing wider than about this is
    /// ever a single satin column.
    public static let strokeSplitWidthMM = 3.0

    /// How far a separated stroke grows back over the area it was cut
    /// from, so the satin lands on fill rather than beside it.
    public static let strokeAreaOverlapMM = 0.4

    /// Narrowest satin a separated stroke may be (see
    /// `separateStrokesFromAreas`); below this it is a bean stitch.
    public static let strokeMinimumSatinWidthMM = 1.0

    /// A separated piece smaller than this in both directions is a tracing
    /// sliver, not a design element.
    public static let minimumPieceDimensionMM = 1.0

    /// An outline smaller than this (polygon area, mm²) or narrower than
    /// `minimumPieceDimensionMM` in both directions is not sewn
    /// (`DigitizePipeline` skips it; `QualityAnalyzer` reports what was
    /// left out). The importer keeps components down to 8 image pixels,
    /// which at a typical 15 px/mm is a 0.3 mm speck; sewn as a
    /// triple-run outline that is three penetrations in one hole plus
    /// lock stitches and a trim -- a knot on the fabric and a thread tail
    /// to pick out, for a mark no one can see. Two such slivers sat at
    /// the head of the Oholi bird (0.2 x 0.3 mm and 1.3 x 0.5 mm) on the
    /// first sew-out; a 1 mm dot over an "i" (area ~0.8 mm²) stays. The
    /// objects themselves stay in the document: they are the artwork,
    /// and at a larger size they sew.
    public static let minimumObjectAreaMM2 = 0.6

    /// A sub-path whose mean width (twice its area over its perimeter)
    /// is under this is a hairline, whatever its length: the navy of the
    /// Oholi "O" showing along the bird's neck is 3.8 mm long and 0.2 to
    /// 0.8 mm wide, and sewn it is a wobbling near-run stitch that reads
    /// as a stray thread. A 1 mm dot (mean width just under 0.5) stays.
    public static let minimumMeanWidthMM = 0.45

    /// See `minimumObjectAreaMM2` and `minimumMeanWidthMM`.
    public static func isSewableSize(_ subPath: SubPath) -> Bool {
        let box = subPath.boundingBox
        guard max(box.width, box.height) >= minimumPieceDimensionMM else { return false }
        // An open path is a running-stitch line with no area of its own;
        // its length is all that matters.
        guard subPath.closed else { return true }
        let area = abs(PolygonGeometry.signedArea(subPath.points))
        guard area >= minimumObjectAreaMM2 else { return false }
        var perimeter = 0.0
        for i in subPath.points.indices {
            perimeter += subPath.points[i].distance(to: subPath.points[(i + 1) % subPath.points.count])
        }
        return perimeter <= 0 || 2 * area / perimeter >= minimumMeanWidthMM
    }

    /// The shape without its unsewable sub-paths, or nil when nothing
    /// sewable is left. A sub-path is judged on its own: a hairline
    /// sliver of the Oholi "O" showing between the bird's neck and beak
    /// (0.3 mm wide, 3 mm long) is a separate outline of the same object,
    /// and sewn it became three satin fragments, two trims and a knot at
    /// the crossing. A hole that small is below the fill's own
    /// `TatamiFillGenerator.minHoleAreaMM2` and was being ignored anyway.
    public static func droppingUnsewable(_ shape: VectorShape) -> VectorShape? {
        let kept = shape.subPaths.filter(isSewableSize)
        return kept.isEmpty ? nil : VectorShape(subPaths: kept)
    }

    /// Splits each fill-classified object into its area (fill) and its
    /// strokes (satin), the way a digitizer treats a colour that is both
    /// a solid and a line -- a cartoon whose dark green is the jacket AND
    /// the keyline round every other colour, imported as one shape. Left
    /// whole, that shape can only be fill (short choppy rows across the
    /// 1 mm line) or satin (fans across the 25 mm jacket); the
    /// professionally digitized version of exactly that artwork fills the
    /// jacket and runs a satin outline over everything, and the outline is
    /// nearly half its stitches. `ShapeMerger.splitThickAndThin` does the
    /// geometry; this decides what each part becomes.
    ///
    /// A shape that turns out to be *all* stroke -- a letter, a keyline
    /// with nothing solid attached -- is not split, but is allowed the
    /// branching-satin path (`allowBranchingSatin`), which is how a
    /// stroke network becomes satin at all. That path stays off for
    /// everything else: measured thinness is a far better gate for it than
    /// the shape's hole count, and the same alligator shows what it does to
    /// an area (see DIGITIZING_ENGINE.md, "professional samples"). Strokes
    /// that still can't be satin fall back to fill, as before.
    ///
    public static func separateStrokesFromAreas(_ objects: [EmbroideryObject]) -> [EmbroideryObject] {
        var result: [EmbroideryObject] = []
        for object in objects {
            guard object.stitchType == .tatamiFill,
                  let split = ShapeMerger.splitThickAndThin(object.shape, thinWidthMM: strokeSplitWidthMM, overlapMM: strokeAreaOverlapMM) else {
                result.append(object)
                continue
            }
            var strokeParameters = object.parameters
            strokeParameters.allowBranchingSatin = true
            // A 1 mm keyline is satin in professional work (the alligator's
            // is ~1.2 mm); the general minimum stays where it is.
            strokeParameters.minSatinWidthMM = min(strokeParameters.minSatinWidthMM, strokeMinimumSatinWidthMM)
            func strokeObject(_ shape: VectorShape, name: String) -> EmbroideryObject {
                var type = classify(shape: shape, parameters: strokeParameters)
                // A stroke that can't be satin is a bean-stitch line along
                // its own edges -- never fill: tatami rows across a 1 mm
                // line are the one result that is worse than either.
                if type == .tatamiFill { type = .tripleRun }
                if ProcessInfo.processInfo.environment["DEBUG_CLASSIFY"] != nil, type != .satin {
                    print("  stroke \(name): \(type.rawValue); subPaths=\(shape.subPaths.count); branching: \(SatinColumnGenerator.branchingSatinRejection(shape: shape, parameters: strokeParameters) ?? "eligible")")
                }
                // Decided by measured geometry: the sibling-consensus passes
                // that follow must not fold it back into its area's fill.
                return EmbroideryObject(name: name, shape: shape, stitchType: type, threadColor: object.threadColor,
                                        parameters: strokeParameters, stitchTypeIsManualOverride: true)
            }
            if split.thick.isEmpty {
                // All stroke: keep the object, let it try branching satin.
                let type = classify(shape: object.shape, parameters: strokeParameters)
                if ProcessInfo.processInfo.environment["DEBUG_CLASSIFY"] != nil {
                    print("  all-stroke \(object.name): \(type.rawValue); subPaths=\(object.shape.subPaths.count); branching: \(SatinColumnGenerator.branchingSatinRejection(shape: object.shape, parameters: strokeParameters) ?? "eligible")")
                }
                var stroke = object
                if type == .satin { stroke.stitchType = .satin; stroke.parameters = strokeParameters; stroke.stitchTypeIsManualOverride = true }
                result.append(stroke)
                continue
            }
            if split.thin.isEmpty { result.append(object); continue }
            // Tracing the two masks can leave sub-millimetre slivers along
            // the cut; nothing that small is sewable.
            func isSubstantial(_ piece: VectorShape) -> Bool {
                let box = piece.boundingBox
                return max(box.width, box.height) >= minimumPieceDimensionMM
            }
            // Areas first, strokes after, so the satin overlaps onto sewn
            // fill rather than the fill covering the satin's edge.
            let areas = split.thick.filter(isSubstantial), strokes = split.thin.filter(isSubstantial)
            for (i, piece) in areas.enumerated() {
                var area = object
                area.shape = piece
                area.name = areas.count == 1 ? "\(object.name) (area)" : "\(object.name) (area \(i + 1))"
                area.stitchTypeIsManualOverride = true
                result.append(area)
            }
            for (i, piece) in strokes.enumerated() {
                result.append(strokeObject(piece, name: strokes.count == 1 ? "\(object.name) (outline)" : "\(object.name) (outline \(i + 1))"))
            }
        }
        return result
    }

    public static func harmonizeSameColorFillConsistency(_ objects: [EmbroideryObject]) -> [EmbroideryObject] {
        var groupsByColor: [RGBColor: [Int]] = [:]
        for (index, object) in objects.enumerated() {
            groupsByColor[object.threadColor.rgb, default: []].append(index)
        }

        var result = objects
        for indices in groupsByColor.values {
            // An explicit choice -- the user's, or `separateStrokesFromAreas`'s
            // geometry-based one -- is not up for a sibling vote.
            let candidates = indices.filter { !objects[$0].stitchTypeIsManualOverride && (objects[$0].stitchType == .satin || objects[$0].stitchType == .tatamiFill) }
            guard candidates.count > 1 else { continue }

            var anyStructurallyFillOnly = false
            var widestSimpleWidth = 0.0
            let maxSatinWidthMM = objects[candidates[0]].parameters.maxSatinWidthMM
            for index in candidates {
                let shape = objects[index].shape
                let parameters = objects[index].parameters
                if shape.subPaths.count > 2 {
                    // `allowBranchingSatin` (stage 4): a multi-hole
                    // member (B, R with two counters in some fonts) gets
                    // the exact same neutral treatment as a branching
                    // single-hole member just below, rather than an
                    // unconditional fill-only mark -- see `classify`'s
                    // own doc comment on this same allowance.
                    if parameters.allowBranchingSatin, SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: shape, parameters: parameters) {
                        continue
                    }
                    anyStructurallyFillOnly = true
                    continue
                }
                guard shape.subPaths.count == 1, let outer = shape.subPaths.first, outer.points.count >= 3 else { continue }
                guard SatinColumnGenerator.canRepresentAsSingleSatinColumn(shape: shape, parameters: parameters) else {
                    // `allowBranchingSatin` members don't have a single
                    // whole-shape "width" the way a simple column does
                    // (see `classify`'s own doc comment on this same
                    // trade-off) -- treated like a single-hole ring
                    // member below: neither forcing the group to fill
                    // nor contributing to `widestSimpleWidth`, just
                    // following whatever the group's other, genuinely
                    // "simple" members decide.
                    if parameters.allowBranchingSatin, SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: shape, parameters: parameters) {
                        continue
                    }
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
                // A member with more than one hole can't inherit the
                // group's own satin decision unless it's independently
                // branching-eligible (`allowBranchingSatin`) -- the same
                // structural exception `classifyGlyphInRun` makes for
                // Add-Lettering text, extended here the same way the
                // loop above already was.
                let member = result[index]
                let multiHoleBlocksIt = member.shape.subPaths.count > 2
                    && !(member.parameters.allowBranchingSatin && SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: member.shape, parameters: member.parameters))
                let finalType: StitchType = (groupType == .satin && multiHoleBlocksIt) ? .tatamiFill : groupType
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
                guard !object.stitchTypeIsManualOverride else { continue }
                guard object.stitchType == .runningStitch || object.stitchType == .tripleRun else { continue }
                let box = object.shape.boundingBox
                guard box.width >= minimumBulkDimensionMM, box.height >= minimumBulkDimensionMM else { continue }

                if consensusType == .satin,
                   object.shape.subPaths.count > 2 || !SatinColumnGenerator.canRepresentAsSingleSatinColumn(shape: object.shape, parameters: object.parameters),
                   // `allowBranchingSatin` override: a rejection above
                   // from the single-column check alone doesn't rule out
                   // a genuinely branching outline (any number of holes,
                   // since stage 4 — see `classify`'s own doc comment on
                   // this same allowance) that decomposes fine via
                   // `generateBranching`.
                   !(object.parameters.allowBranchingSatin
                     && SatinColumnGenerator.canRepresentAsBranchingSatinColumn(shape: object.shape, parameters: object.parameters)) {
                    result[index].stitchType = .tatamiFill
                } else {
                    result[index].stitchType = consensusType
                }
            }
        }
        return result
    }
}
