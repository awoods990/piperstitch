import Foundation

public enum DigitizePipelineError: Error, LocalizedError {
    case unsupportedStitchType(StitchType)

    public var errorDescription: String? {
        switch self {
        case .unsupportedStitchType(let type):
            return "Stitch type \(type.rawValue) is not yet implemented by the engine."
        }
    }
}

/// Flattens a `StitchDocument` (the object-based master) into a `StitchPlan`
/// (the flat manufacturing stitch list) — the last few stages of the
/// auto-digitize pipeline in ARCHITECTURE.md: stitch generation, then basic
/// sequencing between objects. Object segmentation, stitch-type selection,
/// underlay, compensation, and quality analysis are separate modules added
/// in later phases; this is intentionally the minimal Phase 1/2 slice.
public enum DigitizePipeline {
    /// A same-color jump longer than this gets a trim inserted before it
    /// (spec §26: "insert trim commands where supported... maximum jump
    /// without trim"). A jump this long would otherwise drag a visible
    /// strand of thread across the gap between two same-color objects that
    /// happen to be far apart — trimming there costs a little production
    /// time but avoids thread carry across exposed fabric (spec §25: "Never
    /// place obvious travel stitches across exposed design areas"). This
    /// doesn't shorten the physical travel itself, only whether the thread
    /// stays attached across it — `QualityAnalyzer` separately flags long
    /// jumps regardless of whether they got trimmed, since the machine
    /// still has to travel there either way.
    public static let defaultMaxJumpWithoutTrimMM = 15.0

    /// The distinct thread colors in sewing order, one per color *run*
    /// (consecutive same-color objects collapse to a single entry) —
    /// exactly the color-change structure `flatten` produces, exposed
    /// separately because format adapters that need thread color (PES;
    /// DST doesn't) work from `StitchPlan` alone and have no other way to
    /// recover which color a given run belongs to. Length always equals
    /// `flatten(document).colorChangeCount + 1`.
    public static func colorSequence(for document: StitchDocument) throws -> [ThreadColor] {
        var colors: [ThreadColor] = []
        for entry in try sequencedGeneratedObjects(document, maxJumpWithoutTrimMM: defaultMaxJumpWithoutTrimMM) {
            let color = entry.object.threadColor
            if colors.last?.rgb != color.rgb {
                colors.append(color)
            }
        }
        return colors
    }

    public static func flatten(_ document: StitchDocument, maxJumpWithoutTrimMM: Double = defaultMaxJumpWithoutTrimMM) throws -> StitchPlan {
        try flattenWithColors(document, maxJumpWithoutTrimMM: maxJumpWithoutTrimMM).plan
    }

    /// `flatten` and `colorSequence` together, sharing the one expensive
    /// generation-and-sequencing pass instead of each independently redoing
    /// it — calling both separately (as every caller originally did) means
    /// generating every object's stitches twice, which for a design with
    /// hundreds of small objects (a detailed raster import especially) is a
    /// real, user-visible slowdown, not just wasted CPU cycles. Callers that
    /// need both should prefer this over `flatten(_:)` + `colorSequence(for:)`.
    public static func flattenWithColors(_ document: StitchDocument, maxJumpWithoutTrimMM: Double = defaultMaxJumpWithoutTrimMM) throws -> (plan: StitchPlan, colors: [ThreadColor]) {
        // Hidden travel routing (spec §25/§26): a same-color gap long
        // enough to otherwise need a trim gets routed as buried running
        // stitch instead, when the path is entirely covered by the next
        // object's own upcoming stitching — see `HiddenTravelRouter`. Uses
        // the *actual* trim threshold this call is using, since bridging a
        // gap that wouldn't have been trimmed anyway just adds stitches
        // for no benefit.
        let bridged = HiddenTravelRouter.bridgeSameColorGaps(try sequencedGeneratedObjects(document, maxJumpWithoutTrimMM: maxJumpWithoutTrimMM), thresholdMM: maxJumpWithoutTrimMM)
        let generated = bridged.map { (color: $0.object.threadColor, runs: $0.runs) }

        var colors: [ThreadColor] = []
        for entry in generated where colors.last?.rgb != entry.color.rgb {
            colors.append(entry.color)
        }

        var commands: [StitchCommand] = []
        var previousColor: ThreadColor?

        for (index, entry) in generated.enumerated() {
            guard !entry.runs.isEmpty, !entry.runs[0].isEmpty else { continue }
            let isFirstInRun = index == 0 || generated[index - 1].color.rgb != entry.color.rgb
            let isLastInRun = index == generated.count - 1 || generated[index + 1].color.rgb != entry.color.rgb

            var objectRuns = entry.runs
            // Tie-in/tie-off (spec §27): anchor the thread at the start and
            // end of each color engagement, not every individual object —
            // same-color objects sewn back to back share one continuous
            // thread with nothing to re-anchor between them. An object with
            // more than one internal run (a tatami fill broken at a wide
            // hole-crossing connector — see `TatamiFillGenerator.
            // generateRuns`) still anchors only at its true first/last
            // stitch, not at every internal run boundary.
            if isFirstInRun { objectRuns[0] = TieStitchGenerator.applyTieIn(to: objectRuns[0]) }
            if isLastInRun {
                let lastIndex = objectRuns.count - 1
                objectRuns[lastIndex] = TieStitchGenerator.applyTieOff(to: objectRuns[lastIndex])
            }

            if let prev = previousColor, !commands.isEmpty {
                if prev.rgb != entry.color.rgb {
                    commands.append(.trim)
                    commands.append(.colorChange)
                } else {
                    let jumpDistance = commands.last?.point?.distance(to: objectRuns[0][0]) ?? 0
                    if jumpDistance > maxJumpWithoutTrimMM {
                        commands.append(.trim)
                    }
                    commands.append(.jump(objectRuns[0][0]))
                }
            }

            for (runIndex, runPoints) in objectRuns.enumerated() {
                if runIndex > 0 {
                    // A break the generator deliberately introduced because
                    // this connector was too long to sew as a plain stitch
                    // (e.g. a tatami fill's two sides of a wide hole) —
                    // cut the thread and jump rather than bridging it,
                    // mirroring how a same-color gap between two separate
                    // objects is handled above.
                    commands.append(.trim)
                    commands.append(.jump(runPoints[0]))
                }
                for (i, p) in runPoints.enumerated() {
                    if i == 0, case .jump = commands.last {
                        continue // the jump just above already targets this point
                    }
                    if i == 0, commands.isEmpty {
                        commands.append(.jump(p)) // move to the design's first stitch location
                    }
                    commands.append(.stitch(p))
                }
            }
            previousColor = entry.color
        }

        commands.append(.trim)
        commands.append(.end)
        return (StitchPlan(commands: commands), colors)
    }

    /// Generates every object's stitch points first, independently of
    /// order (generation never depends on what sews before/after an
    /// object), then sequences the *results* with
    /// `ObjectSequencer.sequenceGenerated` — which uses each path's real
    /// first/last points (and can reverse a path to enter from whichever
    /// end is closer) rather than a bounding-box-center proxy, since the
    /// actual points now exist to measure from. Filtering out objects that
    /// produced no stitches happens here, before sequencing, so tie-in/
    /// tie-off "is this the first/last object in its color run" lookahead
    /// in `flatten` is based on what will actually appear in the output,
    /// not on `document.objects`' raw indices — an empty-output object in
    /// between would otherwise misplace a lock stitch.
    private static func sequencedGeneratedObjects(_ document: StitchDocument, maxJumpWithoutTrimMM: Double) throws -> [(object: EmbroideryObject, runs: [[Point2D]])] {
        var perObject: [(object: EmbroideryObject, runs: [[Point2D]])] = []
        for object in document.objects {
            let runs = try stitchRuns(for: object, breakThresholdMM: maxJumpWithoutTrimMM)
            guard !runs.isEmpty else { continue }
            perObject.append((object, runs))
        }
        return ObjectSequencer.sequenceGenerated(perObject)
    }

    /// An object's stitching as one or more disjoint runs — almost always
    /// exactly one continuous run, except a tatami fill that had to break
    /// around a wide hole (see `TatamiFillGenerator.generateRuns`), where a
    /// run boundary becomes a real trim+jump in `flattenWithColors` instead
    /// of a long stitch bridged across open fabric.
    private static func stitchRuns(for object: EmbroideryObject, breakThresholdMM: Double) throws -> [[Point2D]] {
        let raw = try rawStitchRuns(for: object, breakThresholdMM: breakThresholdMM)
        // General stitch filtering (spec §30), applied per run after
        // generation regardless of which generator produced the points:
        // merges sub-minimum stitches (including, usefully, the exact-
        // duplicate point every triple-run reversal leaves at its
        // turnaround) and splits anything longer than the practical
        // maximum -- e.g. the transition between an underlay's endpoint and
        // the main stitching's start point, which isn't guaranteed to be
        // short. Applied within each run independently so a run boundary
        // itself is never smoothed away or merged back together.
        return raw
            .map { StitchFilter.apply($0, minLengthMM: object.parameters.minStitchLengthMM, maxLengthMM: object.parameters.maxStitchLengthMM) }
            .filter { !$0.isEmpty }
    }

    private static func rawStitchRuns(for object: EmbroideryObject, breakThresholdMM: Double) throws -> [[Point2D]] {
        switch object.stitchType {
        case .runningStitch:
            return [object.shape.subPaths.flatMap {
                RunningStitchGenerator.generate(for: $0, stitchLengthMM: object.parameters.stitchLengthMM,
                                                 minStitchLengthMM: object.parameters.minStitchLengthMM)
            }]
        case .tripleRun:
            return [object.shape.subPaths.flatMap { subPath -> [Point2D] in
                let base = RunningStitchGenerator.generate(for: subPath, stitchLengthMM: object.parameters.stitchLengthMM,
                                                            minStitchLengthMM: object.parameters.minStitchLengthMM)
                guard base.count > 1 else { return base }
                // Forward, back, forward again — the standard "triple run"
                // technique for a stronger, more visible outline.
                return base + base.reversed() + base
            }]
        case .tatamiFill:
            let underlay = UnderlayGenerator.generate(for: object.shape, stitchType: .tatamiFill, parameters: object.parameters)
            let fillRuns = TatamiFillGenerator.generateRuns(for: object.shape, parameters: object.parameters, breakThresholdMM: breakThresholdMM)
            // Edge-run underlay (the default for fill) traces a *closed*
            // loop, so its start/end point is arbitrary -- any point along
            // it can be the seam without changing physical coverage at
            // all. Left at wherever the trace happened to start, the seam
            // can land far from the fill's own first row, and since this
            // whole object is one continuous same-color run, that gap
            // becomes a single very long "stitch" (not a jump) that
            // StitchFilter then chops into several segments spanning most
            // of the design -- a real, visible diagonal thread that has
            // nothing to do with the actual artwork. Rotating the loop to
            // end as close as possible to the fill's own start avoids it.
            // Only safe for a genuinely closed-loop underlay (edge-run,
            // fill's default) -- centerRun/zigzag are open paths whose
            // endpoints are physically meaningful, not arbitrary.
            let effectiveUnderlay = object.parameters.underlayType ?? .edgeRun
            let alignedUnderlay = effectiveUnderlay == .edgeRun
                ? rotateClosedLoopToEndNear(underlay, target: fillRuns.first?.first)
                : underlay
            guard !fillRuns.isEmpty else { return alignedUnderlay.isEmpty ? [] : [alignedUnderlay] }
            var runs = fillRuns
            runs[0] = alignedUnderlay + runs[0]
            return runs
        case .satin:
            // Spec: "automatically divide or convert excessively wide satin
            // regions to another stitch type." generatePartial keeps
            // whatever sections of the column fit as real satin and
            // converts only the sections that don't to tatami fill sub-
            // regions, rather than converting the whole object the moment
            // any part of it is too wide — see SatinColumnGenerator's doc
            // comment and EMBROIDERY_ALGORITHM_REFERENCE.md.
            let underlay = UnderlayGenerator.generate(for: object.shape, stitchType: .satin, parameters: object.parameters)
            return [underlay + (try SatinColumnGenerator.generatePartial(for: object.shape, parameters: object.parameters))]
        }
    }

    /// Rotates a *closed-loop* point sequence (traced start-to-end back to
    /// roughly its own start) so it ends as close as possible to `target`
    /// instead of wherever it happened to start — physically identical
    /// coverage either way, since a loop's seam point is arbitrary, but it
    /// avoids handing the caller a long, unrelated transition distance to
    /// whatever comes next. Only meaningful for a genuine closed loop; an
    /// open path's endpoints are physically significant and must not be
    /// reordered this way.
    private static func rotateClosedLoopToEndNear(_ loop: [Point2D], target: Point2D?) -> [Point2D] {
        guard let target, loop.count > 2 else { return loop }
        var bestIndex = 0
        var bestDistance = Double.infinity
        for (i, p) in loop.enumerated() {
            let d = p.distance(to: target)
            if d < bestDistance { bestDistance = d; bestIndex = i }
        }
        return Array(loop[(bestIndex + 1)...]) + Array(loop[...bestIndex])
    }
}
