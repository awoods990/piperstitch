import Foundation

/// How long a design will take to sew -- docs/WILCOM_MANUAL_REVIEW.md C5
/// (Wilcom's "Runtime Estimates"). A shop quotes jobs on this number,
/// so it is a *production* estimate, not a stopwatch: sewing time at the
/// machine's running speed, plus a fixed cost per trim and per colour
/// change. Machine speed is a parameter because it is the one thing
/// that really varies (a home machine runs 600-750 spm, a commercial
/// single-head 800-1000, a multi-head 650-800 on caps).
public struct RunTimeEstimate: Codable, Sendable, Equatable {
    public var sewingSeconds: Double
    public var trimSeconds: Double
    public var colorChangeSeconds: Double
    public var stitchesPerMinute: Double

    public var totalSeconds: Double { sewingSeconds + trimSeconds + colorChangeSeconds }

    /// "4 min 20 s", "1 h 12 min", "45 s".
    public var formatted: String { RunTimeEstimator.format(seconds: totalSeconds) }
}

public enum RunTimeEstimator {
    public static let defaultStitchesPerMinute = 800.0
    /// An automatic trim: stop, cut, pick up again.
    public static let secondsPerTrim = 3.0
    /// An automatic colour change on a multi-needle machine (a single-
    /// needle machine re-threaded by hand takes several times longer;
    /// the estimate does not try to guess which the customer owns).
    public static let secondsPerColorChange = 20.0
    /// Machines slow down for long stitches: a 12 mm stitch cannot be
    /// sewn at the speed of a 2 mm one because the pantograph has to
    /// move further between needle penetrations. Above this average
    /// stitch length the running speed is scaled down proportionally.
    public static let fullSpeedStitchLengthMM = 4.0

    public static func estimate(_ plan: StitchPlan, stitchesPerMinute: Double = defaultStitchesPerMinute) -> RunTimeEstimate {
        let spm = max(60, stitchesPerMinute)
        let stitches = plan.stitchCount
        let averageLength = stitches > 0 ? plan.totalStitchLength / Double(stitches) : 0
        let speedFactor = averageLength > fullSpeedStitchLengthMM ? fullSpeedStitchLengthMM / averageLength : 1
        let effectiveSPM = spm * speedFactor
        return RunTimeEstimate(
            sewingSeconds: Double(stitches) / effectiveSPM * 60,
            trimSeconds: Double(plan.trimCount) * secondsPerTrim,
            colorChangeSeconds: Double(plan.colorChangeCount) * secondsPerColorChange,
            stitchesPerMinute: spm
        )
    }

    public static func format(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return secs > 0 ? "\(minutes) min \(secs) s" : "\(minutes) min" }
        return "\(secs) s"
    }
}

/// Scale a whole design's density to hit a target stitch count --
/// docs/WILCOM_MANUAL_REVIEW.md C5 (Wilcom's "Process Stitches"). The
/// stitch count of satin and fill is very nearly proportional to
/// 1/spacing, so the spacing that gives `target` stitches is the current
/// spacing × current/target. Running-stitch objects and underlay are
/// left alone (they contribute little and their spacing is a quality
/// setting, not a cost one), so the result lands close to the target
/// rather than exactly on it; call it again on the new plan to converge.
public enum StitchBudget {
    /// The tightest and loosest spacing the scaler will set, regardless
    /// of how far the target is from the current count: tighter than
    /// 0.2 mm is outside what ordinary machines handle, looser than
    /// 1.0 mm shows fabric between the rows.
    public static let minSpacingMM = 0.2
    public static let maxSpacingMM = 1.0

    /// Multiplier for every satin density and fill row spacing that
    /// brings `currentStitchCount` to about `targetStitchCount`.
    public static func spacingScale(currentStitchCount: Int, targetStitchCount: Int) -> Double {
        guard currentStitchCount > 0, targetStitchCount > 0 else { return 1 }
        return Double(currentStitchCount) / Double(targetStitchCount)
    }

    /// Applies `scale` to every satin and fill object's spacing, clamped
    /// to `minSpacingMM...maxSpacingMM`. Objects whose spacing was set by
    /// hand are scaled too -- the point of a budget is the whole design.
    public static func apply(scale: Double, to document: inout StitchDocument) {
        guard scale > 0, scale != 1 else { return }
        for i in document.objects.indices {
            switch document.objects[i].stitchType {
            case .satin:
                let current = document.objects[i].parameters.satinDensityMM
                document.objects[i].parameters.satinDensityMM = min(maxSpacingMM, max(minSpacingMM, current * scale))
            case .tatamiFill:
                let current = document.objects[i].parameters.fillSpacingMM
                document.objects[i].parameters.fillSpacingMM = min(maxSpacingMM, max(minSpacingMM, current * scale))
            default:
                break
            }
        }
    }
}
