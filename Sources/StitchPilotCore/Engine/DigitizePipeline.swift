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
        for object in ObjectSequencer.sequence(document.objects) {
            let points = try stitchPoints(for: object)
            guard !points.isEmpty else { continue }
            if colors.last?.rgb != object.threadColor.rgb {
                colors.append(object.threadColor)
            }
        }
        return colors
    }

    public static func flatten(_ document: StitchDocument, maxJumpWithoutTrimMM: Double = defaultMaxJumpWithoutTrimMM) throws -> StitchPlan {
        // Sequence first (spec §23: background/containing objects before
        // the foreground details they contain — see ObjectSequencer), then
        // generate (filtering out objects that produced no stitches) so
        // tie-in/tie-off "is this the first/last object in its color run"
        // lookahead is based on what will actually appear in the output,
        // not on document.objects' raw indices — an empty-output object in
        // between would otherwise misplace a lock stitch.
        var generated: [(color: ThreadColor, points: [Point2D])] = []
        for object in ObjectSequencer.sequence(document.objects) {
            let points = try stitchPoints(for: object)
            guard !points.isEmpty else { continue }
            generated.append((object.threadColor, points))
        }

        var commands: [StitchCommand] = []
        var previousColor: ThreadColor?

        for (index, entry) in generated.enumerated() {
            let isFirstInRun = index == 0 || generated[index - 1].color.rgb != entry.color.rgb
            let isLastInRun = index == generated.count - 1 || generated[index + 1].color.rgb != entry.color.rgb

            var objectPoints = entry.points
            // Tie-in/tie-off (spec §27): anchor the thread at the start and
            // end of each color engagement, not every individual object —
            // same-color objects sewn back to back share one continuous
            // thread with nothing to re-anchor between them.
            if isFirstInRun { objectPoints = TieStitchGenerator.applyTieIn(to: objectPoints) }
            if isLastInRun { objectPoints = TieStitchGenerator.applyTieOff(to: objectPoints) }

            if let prev = previousColor, !commands.isEmpty {
                if prev.rgb != entry.color.rgb {
                    commands.append(.trim)
                    commands.append(.colorChange)
                } else {
                    let jumpDistance = commands.last?.point?.distance(to: objectPoints[0]) ?? 0
                    if jumpDistance > maxJumpWithoutTrimMM {
                        commands.append(.trim)
                    }
                    commands.append(.jump(objectPoints[0]))
                }
            }

            for (i, p) in objectPoints.enumerated() {
                if i == 0, case .jump = commands.last {
                    continue // the bridging jump above already targets this point
                }
                if i == 0, commands.isEmpty {
                    commands.append(.jump(p)) // move to the design's first stitch location
                }
                commands.append(.stitch(p))
            }
            previousColor = entry.color
        }

        commands.append(.trim)
        commands.append(.end)
        return StitchPlan(commands: commands)
    }

    private static func stitchPoints(for object: EmbroideryObject) throws -> [Point2D] {
        let raw = try rawStitchPoints(for: object)
        // General stitch filtering (spec §30), applied after generation
        // regardless of which generator produced the points: merges
        // sub-minimum stitches (including, usefully, the exact-duplicate
        // point every triple-run reversal leaves at its turnaround) and
        // splits anything longer than the practical maximum -- e.g. the
        // transition between an underlay's endpoint and the main stitching's
        // start point, which isn't guaranteed to be short.
        return StitchFilter.apply(raw, minLengthMM: object.parameters.minStitchLengthMM, maxLengthMM: object.parameters.maxStitchLengthMM)
    }

    private static func rawStitchPoints(for object: EmbroideryObject) throws -> [Point2D] {
        switch object.stitchType {
        case .runningStitch:
            return object.shape.subPaths.flatMap {
                RunningStitchGenerator.generate(for: $0, stitchLengthMM: object.parameters.stitchLengthMM,
                                                 minStitchLengthMM: object.parameters.minStitchLengthMM)
            }
        case .tripleRun:
            return object.shape.subPaths.flatMap { subPath -> [Point2D] in
                let base = RunningStitchGenerator.generate(for: subPath, stitchLengthMM: object.parameters.stitchLengthMM,
                                                            minStitchLengthMM: object.parameters.minStitchLengthMM)
                guard base.count > 1 else { return base }
                // Forward, back, forward again — the standard "triple run"
                // technique for a stronger, more visible outline.
                return base + base.reversed() + base
            }
        case .tatamiFill:
            let underlay = UnderlayGenerator.generate(for: object.shape, stitchType: .tatamiFill, parameters: object.parameters)
            return underlay + TatamiFillGenerator.generate(for: object.shape, parameters: object.parameters)
        case .satin:
            do {
                let underlay = UnderlayGenerator.generate(for: object.shape, stitchType: .satin, parameters: object.parameters)
                return underlay + (try SatinColumnGenerator.generate(for: object.shape, parameters: object.parameters))
            } catch SatinGenerationError.columnTooWide {
                // Spec: "automatically divide or convert excessively wide
                // satin regions to another stitch type" — a shape too wide
                // for satin is very often still a perfectly good fill
                // region (the classifier's average-width estimate can miss
                // a shape whose width varies enough that some crossings
                // exceed the limit even though the average doesn't). Fall
                // back rather than abandon the object with an error; a
                // proper *partial* fallback (keep the narrow sections as
                // satin, only convert where it's actually too wide) is
                // real algorithmic work — see EMBROIDERY_ALGORITHM_REFERENCE.md's
                // "known remaining weaknesses" — this is the honest
                // whole-object version of that idea.
                let underlay = UnderlayGenerator.generate(for: object.shape, stitchType: .tatamiFill, parameters: object.parameters)
                return underlay + TatamiFillGenerator.generate(for: object.shape, parameters: object.parameters)
            }
        }
    }
}
