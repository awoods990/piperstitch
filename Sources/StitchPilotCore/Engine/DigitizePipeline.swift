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
    public static func flatten(_ document: StitchDocument) throws -> StitchPlan {
        // Generate first (filtering out objects that produced no stitches)
        // so tie-in/tie-off "is this the first/last object in its color
        // run" lookahead is based on what will actually appear in the
        // output, not on document.objects' raw indices — an empty-output
        // object in between would otherwise misplace a lock stitch.
        var generated: [(color: ThreadColor, points: [Point2D])] = []
        for object in document.objects {
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
            let underlay = UnderlayGenerator.generate(for: object.shape, stitchType: .satin, parameters: object.parameters)
            return underlay + (try SatinColumnGenerator.generate(for: object.shape, parameters: object.parameters))
        }
    }
}
