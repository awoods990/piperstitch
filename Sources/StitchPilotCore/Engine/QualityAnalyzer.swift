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

    /// `document` is optional (and defaults to nil) purely for source
    /// compatibility with existing callers/tests that only ever had a
    /// flattened `StitchPlan` to give this -- `checkFabricSuitability`
    /// below is the one check that actually needs it (fabric type and
    /// per-object shape width aren't recoverable from stitch commands
    /// alone) and simply does nothing without it.
    public static func analyze(_ plan: StitchPlan, hoopWidthMM: Double? = nil, hoopHeightMM: Double? = nil, document: StitchDocument? = nil) -> EmbroideryReadinessReport {
        var issues: [QualityIssue] = []

        checkStitchLengths(plan, into: &issues)
        checkJumps(plan, into: &issues)
        checkTrimCount(plan, into: &issues)
        checkStitchCount(plan, into: &issues)
        checkHoopFit(plan, hoopWidthMM: hoopWidthMM, hoopHeightMM: hoopHeightMM, into: &issues)
        checkEmptyDesign(plan, into: &issues)
        checkFabricSuitability(document, into: &issues)
        checkFragmentation(document, into: &issues)
        checkSameColorStitchTypeConsistency(document, into: &issues)
        addStabilizerAdvice(document, into: &issues)
        checkLaydown(document, into: &issues)

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

    /// Below this width, a satin/fill region reads as "fine detail" --
    /// the practical threshold real digitizers use for "don't try this on
    /// a difficult substrate."
    private static let fineDetailThresholdMM = 3.0
    /// Fabrics whose own pull-compensation multiplier already marks them
    /// as meaningfully distorting (`FabricType.compensationMultiplier`)
    /// -- terry/plush for its pile height (fine stitching can sink into
    /// or get swallowed by the pile entirely, a physical substrate
    /// problem no amount of coordinate-level pull compensation can
    /// correct for), stretch knit for how much the fabric itself moves
    /// under the hoop.
    private static let challengingFabrics: Set<FabricType> = [.terry, .stretchKnit, .beanie]

    /// Static coordinate-level pull/push compensation (`PullCompensation
    /// Calculator`) is a best-effort estimate, not a physical simulation
    /// -- it shifts where each stitch lands, but can't add stitching that
    /// isn't there, and can't account for a fabric's own pile or weave
    /// swallowing thin coverage. A design's *realistic* on-screen preview
    /// renders the exact digitized coordinates, so it has no way to show
    /// this kind of real-world gap either -- it isn't a bug in the
    /// preview, just the limit of what a flat render of stitch positions
    /// can represent. Found directly against a real Brother-machine
    /// sew-out that showed letter gaps the app's own preview never hinted
    /// at. This can only warn, not fix the underlying physical mismatch
    /// -- the actionable options are a bolder/larger design, denser
    /// stitching, or a stabilizer topping, all decisions only the person
    /// holding the fabric can actually make. See CHANGELOG.md.
    private static func checkFabricSuitability(_ document: StitchDocument?, into issues: inout [QualityIssue]) {
        guard let document else { return }
        var narrowest: (widthMM: Double, fabric: FabricType)?
        for object in document.objects {
            guard challengingFabrics.contains(object.parameters.fabricType),
                  object.stitchType == .satin || object.stitchType == .tatamiFill,
                  let outer = object.shape.subPaths.first, outer.points.count >= 3 else { continue }
            let area = abs(PolygonGeometry.signedArea(outer.points))
            let (axis, mean) = PolygonGeometry.principalAxis(outer.points)
            let (lo, hi) = PolygonGeometry.projectionRange(outer.points, axis: axis, mean: mean)
            let length = hi - lo
            guard length > 0, area > 0 else { continue }
            let width = area / length
            guard width < fineDetailThresholdMM else { continue }
            if narrowest == nil || width < narrowest!.widthMM {
                narrowest = (width, object.parameters.fabricType)
            }
        }
        guard let narrowest else { return }
        issues.append(QualityIssue(
            severity: .warning,
            // Interpolated rather than `%@`-formatted: identical text, but
            // `%@` with a Swift String is Darwin-only bridging the Linux
            // server build (see server/) can't rely on.
            message: "Fine detail (as narrow as \(String(format: "%.1f", narrowest.widthMM))mm) on \(narrowest.fabric.shortName) fabric often doesn't sew cleanly -- the pile or stretch can swallow or distort thin satin/fill in a way this preview can't show. Consider a bolder design, a larger size, or a stabilizer topping.",
            scorePenalty: 8
        ))
    }

    /// A napped fabric with no laydown (docs/WILCOM_MANUAL_REVIEW.md C1):
    /// the pile swallows fine stitching. A real risk, but a production
    /// choice, so a small penalty and a pointer at the fix.
    private static func checkLaydown(_ document: StitchDocument?, into issues: inout [QualityIssue]) {
        guard let document, document.laydown == nil,
              let fabric = document.objects.first?.parameters.fabricType, LaydownSettings.isRecommended(for: fabric) else { return }
        issues.append(QualityIssue(
            severity: .warning,
            message: "No laydown stitch on \(fabric.shortName.lowercased()) -- the pile can swallow fine detail. Turn on \"Flatten the nap first\" (Laydown) so a light open fill holds the pile down under the design.",
            scorePenalty: 4
        ))
    }

    /// Not a defect -- a reminder, carried on the report because the
    /// stabiliser is the one production choice this file can't make for
    /// the customer and the one most often got wrong (docs/
    /// WILCOM_MANUAL_REVIEW.md C6). Costs no points.
    private static func addStabilizerAdvice(_ document: StitchDocument?, into issues: inout [QualityIssue]) {
        guard let document, let fabric = document.objects.first?.parameters.fabricType else { return }
        issues.append(QualityIssue(
            severity: .info,
            message: "Stabilizer for \(fabric.shortName.lowercased()): \(fabric.stabilizerAdvice)",
            scorePenalty: 0
        ))
    }

    /// Below this size in *both* dimensions, an object reads as
    /// fragmentation noise rather than an intended design element at
    /// typical embroidery scale -- a genuine tiny accent (a single dot, a
    /// fine serif) is rare and usually still clears this in at least one
    /// dimension.
    private static let fragmentSizeThresholdMM = 2.0
    /// Only worth flagging once fragmentation is a real pattern, not the
    /// one or two genuinely tiny accents ordinary artwork can have --
    /// both an absolute floor and a share-of-the-design floor, so a huge
    /// design with a handful of small accents doesn't trip this, and
    /// neither does a tiny two-object design where one happens to be small.
    private static let minimumFragmentCount = 6
    private static let minimumFragmentFraction = 0.15

    /// Would have caught, automatically, every one of a real string of
    /// import-quality regressions before their root cause was ever found:
    /// anti-aliased boundaries in detail-heavy or curved artwork
    /// fragmenting into dozens of stray sub-2mm objects (confirmed
    /// directly against the PiperStitch bird mark, the Amerus logo, and
    /// the LIBBi wordmark -- see `ImageImporter`'s own fix for the root
    /// cause). A design with this defect could previously still score
    /// 100/100 "Ready to Sew," since nothing checked object *count* against
    /// object *size* -- only total stitch/trim counts, which a swarm of
    /// tiny objects doesn't obviously blow past on its own. This is a
    /// safety net, not a substitute for fixing root causes: it exists so a
    /// *different*, not-yet-discovered fragmentation source still surfaces
    /// as a visible readiness warning instead of silently shipping.
    private static func checkFragmentation(_ document: StitchDocument?, into issues: inout [QualityIssue]) {
        guard let document, !document.objects.isEmpty else { return }
        let fragments = document.objects.filter { object in
            let box = object.shape.boundingBox
            return box.width < fragmentSizeThresholdMM && box.height < fragmentSizeThresholdMM
        }
        guard fragments.count >= minimumFragmentCount,
              Double(fragments.count) / Double(document.objects.count) >= minimumFragmentFraction else { return }
        issues.append(QualityIssue(
            severity: .warning,
            message: "\(fragments.count) of \(document.objects.count) objects are smaller than \(String(format: "%.0f", fragmentSizeThresholdMM))mm in both directions -- likely import fragmentation (anti-aliasing noise or overly fine detail) rather than intended design elements. Consider re-importing at a lower color count, or merging the small pieces.",
            scorePenalty: min(15, fragments.count / 2)
        ))
    }

    /// The other half of the same real regression this round of work fixed
    /// at the source (see `StitchTypeClassifier.
    /// harmonizeSameColorFillConsistency`): letters of one word, the same
    /// thread color, independently landing on different stitch types --
    /// confirmed directly against a real customer wordmark ("LIBBi") whose
    /// multi-hole "B"s sewed as visibly different fill texture next to
    /// their satin neighbors. `harmonizeSameColorFillConsistency` already
    /// prevents this for a freshly-imported document, but this check is a
    /// safety net for the cases that pass wouldn't catch: a user manually
    /// overriding one object's stitch type afterward in the editor (which
    /// harmonization never gets a chance to re-run against), or any future
    /// code path that builds a `StitchDocument` without going through
    /// raster import at all.
    private static func checkSameColorStitchTypeConsistency(_ document: StitchDocument?, into issues: inout [QualityIssue]) {
        guard let document else { return }
        var groupsByColor: [RGBColor: [EmbroideryObject]] = [:]
        for object in document.objects where object.stitchType == .satin || object.stitchType == .tatamiFill {
            groupsByColor[object.threadColor.rgb, default: []].append(object)
        }

        var inconsistentGroupCount = 0
        var inconsistentObjectCount = 0
        for group in groupsByColor.values where group.count > 1 {
            guard Set(group.map(\.stitchType)).count > 1 else { continue }
            inconsistentGroupCount += 1
            inconsistentObjectCount += group.count
        }
        guard inconsistentGroupCount > 0 else { return }
        issues.append(QualityIssue(
            severity: .warning,
            message: "\(inconsistentObjectCount) objects across \(inconsistentGroupCount) same-color group(s) mix satin and fill stitching -- usually reads as an inconsistent texture within one word or shape rather than a deliberate style choice.",
            scorePenalty: min(10, inconsistentGroupCount * 3)
        ))
    }
}
