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
        var commands: [StitchCommand] = []
        var previousColor: ThreadColor?

        for object in document.objects {
            let objectPoints = try stitchPoints(for: object)
            guard !objectPoints.isEmpty else { continue }

            if let prev = previousColor, !commands.isEmpty {
                if prev.rgb != object.threadColor.rgb {
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
            previousColor = object.threadColor
        }

        commands.append(.trim)
        commands.append(.end)
        return StitchPlan(commands: commands)
    }

    private static func stitchPoints(for object: EmbroideryObject) throws -> [Point2D] {
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
            return TatamiFillGenerator.generate(for: object.shape, parameters: object.parameters)
        case .satin:
            throw DigitizePipelineError.unsupportedStitchType(object.stitchType)
        }
    }
}
