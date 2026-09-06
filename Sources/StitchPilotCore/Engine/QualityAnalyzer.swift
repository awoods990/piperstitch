import Foundation

public enum IssueSeverity: String, Sendable {
    case info
    case warning
    case critical
}

/// One concrete, actionable finding — spec §50: "Warnings should be
/// actionable," never a vague "Design has a density problem." Each message
/// names the specific numbers involved so the user (or a future Phase 4
/// auto-repair pass) knows exactly what's wrong and how far from acceptable
/// it is, not just that something, somewhere, might be off.
public struct QualityIssue: Sendable {
    public var severity: IssueSeverity
    public var message: String
    /// Points subtracted from the 100-point readiness score.
    public var scorePenalty: Int
}

public struct EmbroideryReadinessReport: Sendable {
    public var score: Int
    public var issues: [QualityIssue]

    public var isReadyToSew: Bool { issues.allSatisfy { $0.severity != .critical } }
}

/// Runs an automatic quality audit on a generated `StitchPlan` — spec §33
/// "Embroidery Quality Analysis Engine" / §76 "Export Confidence." This is
/// the Phase 4 slice: checks computable purely from stitch geometry and
/// counts. Checks that need data StitchPilot doesn't have yet (fabric
/// suitability, a chosen hoop, small-text detection) are noted as
/// deliberately absent below rather than faked with placeholder logic.
public enum QualityAnalyzer {
    private static let longJumpThresholdMM = 15.0
    private static let manyStitchesThreshold = 50_000
    private static let manyTrimsThreshold = 30

    public static func analyze(_ plan: StitchPlan, hoopWidthMM: Double? = nil, hoopHeightMM: Double? = nil) -> EmbroideryReadinessReport {
        var issues: [QualityIssue] = []

        checkStitchLengths(plan, into: &issues)
        checkJumps(plan, into: &issues)
        checkTrimCount(plan, into: &issues)
        checkStitchCount(plan, into: &issues)
        checkHoopFit(plan, hoopWidthMM: hoopWidthMM, hoopHeightMM: hoopHeightMM, into: &issues)
        checkEmptyDesign(plan, into: &issues)

        let score = max(0, min(100, 100 - issues.reduce(0) { $0 + $1.scorePenalty }))
        return EmbroideryReadinessReport(score: score, issues: issues)
    }

    // MARK: - Individual checks

    /// Stitches under the practical minimum or over the practical maximum
    /// shouldn't reach this stage at all — `StitchFilter` runs before
    /// export — so finding one here means a generator produced something
    /// the shared filter didn't catch, worth surfacing as a real defect
    /// rather than silently exporting it.
    private static func checkStitchLengths(_ plan: StitchPlan, into issues: inout [QualityIssue]) {
        var tooShort = 0
        var tooLong = 0
        var last: Point2D?
        for command in plan.commands {
            switch command {
            case .jump(let p):
                last = p
            case .colorChange, .trim, .stop:
                // Thread's cut here; the next point starts a new, physically
                // disconnected thread, not a continuation of `last`.
                last = nil
            case .stitch(let p):
                if let l = last {
                    let d = l.distance(to: p)
                    if d < 0.15 { tooShort += 1 }
                    if d > 12.5 { tooLong += 1 }
                }
                last = p
            case .end:
                break
            }
        }
        if tooShort > 0 {
            issues.append(QualityIssue(severity: .warning,
                                        message: "\(tooShort) stitch(es) are under 0.15mm — likely thread breaks waiting to happen.",
                                        scorePenalty: min(15, tooShort)))
        }
        if tooLong > 0 {
            issues.append(QualityIssue(severity: .warning,
                                        message: "\(tooLong) stitch(es) exceed 12.5mm — unusually long for a single stitch, may snag.",
                                        scorePenalty: min(15, tooLong * 2)))
        }
    }

    private static func checkJumps(_ plan: StitchPlan, into issues: inout [QualityIssue]) {
        var longJumps: [Double] = []
        var last: Point2D?
        for command in plan.commands {
            switch command {
            case .jump(let p):
                if let l = last {
                    let d = l.distance(to: p)
                    if d > longJumpThresholdMM { longJumps.append(d) }
                }
                last = p
            case .stitch(let p):
                last = p
            case .colorChange, .trim, .stop:
                last = nil
            case .end:
                break
            }
        }
        if !longJumps.isEmpty {
            let maxJump = longJumps.max() ?? 0
            issues.append(QualityIssue(
                severity: .info,
                message: String(format: "%d jump(s) exceed %.0fmm (longest: %.1fmm) — visible thread carry unless trimmed.",
                                longJumps.count, longJumpThresholdMM, maxJump),
                scorePenalty: min(10, longJumps.count)))
        }
    }

    private static func checkTrimCount(_ plan: StitchPlan, into issues: inout [QualityIssue]) {
        if plan.trimCount > manyTrimsThreshold {
            issues.append(QualityIssue(
                severity: .info,
                message: "\(plan.trimCount) trims — more color/section changes than usual, which adds production time.",
                scorePenalty: 5))
        }
    }

    private static func checkStitchCount(_ plan: StitchPlan, into issues: inout [QualityIssue]) {
        if plan.stitchCount > manyStitchesThreshold {
            issues.append(QualityIssue(
                severity: .info,
                message: "\(plan.stitchCount) total stitches — a large design; expect a long run time on the machine.",
                scorePenalty: 5))
        }
    }

    private static func checkHoopFit(_ plan: StitchPlan, hoopWidthMM: Double?, hoopHeightMM: Double?, into issues: inout [QualityIssue]) {
        guard let hoopWidth = hoopWidthMM, let hoopHeight = hoopHeightMM else { return }
        let box = plan.boundingBox
        if box.width > hoopWidth || box.height > hoopHeight {
            issues.append(QualityIssue(
                severity: .critical,
                message: String(format: "Design is %.1f×%.1fmm, larger than the %.0f×%.0fmm hoop — it will not fit.",
                                box.width, box.height, hoopWidth, hoopHeight),
                scorePenalty: 40))
        }
    }

    private static func checkEmptyDesign(_ plan: StitchPlan, into issues: inout [QualityIssue]) {
        if plan.stitchCount == 0 {
            issues.append(QualityIssue(severity: .critical, message: "Design has no stitches.", scorePenalty: 100))
        }
    }
}
