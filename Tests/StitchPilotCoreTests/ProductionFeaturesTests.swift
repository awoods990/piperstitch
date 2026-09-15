import Foundation
import Testing
@testable import StitchPilotCore

/// Run-time estimate and stitch budget (C5), start/end at hoop centre
/// (C4) and stabiliser advice (C6) -- docs/WILCOM_MANUAL_REVIEW.md.
struct ProductionFeaturesTests {
    private func square(_ x: Double, _ y: Double, size: Double) -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [Point2D(x, y), Point2D(x + size, y), Point2D(x + size, y + size), Point2D(x, y + size)], closed: true)])
    }

    private func document(startAtCenter: Bool) -> StitchDocument {
        var p = StitchGenerationParameters()
        p.fabricType = .knit
        let a = EmbroideryObject(name: "A", shape: square(2, 2, size: 12), stitchType: .tatamiFill, threadColor: .generic(RGBColor(hex: 0xFF0000)), parameters: p)
        let b = EmbroideryObject(name: "B", shape: square(30, 2, size: 12), stitchType: .tatamiFill, threadColor: .generic(RGBColor(hex: 0x0000FF)), parameters: p)
        return StitchDocument(name: "T", physicalWidthMM: 50, physicalHeightMM: 20, objects: [a, b], startAndEndAtCenter: startAtCenter)
    }

    @Test func runTimeAddsSewingTrimsAndColourChanges() {
        var commands: [StitchCommand] = [.jump(Point2D(0, 0))]
        for i in 1...800 { commands.append(.stitch(Point2D(Double(i % 2) * 2, Double(i) * 0.01))) }
        commands += [.trim, .colorChange, .stitch(Point2D(5, 5)), .stitch(Point2D(7, 5)), .trim, .end]
        let plan = StitchPlan(commands: commands)
        let estimate = RunTimeEstimator.estimate(plan, stitchesPerMinute: 800)
        #expect(abs(estimate.sewingSeconds - 60.15) < 0.2)     // 802 stitches at 800 spm
        #expect(estimate.trimSeconds == 2 * RunTimeEstimator.secondsPerTrim)
        #expect(estimate.colorChangeSeconds == RunTimeEstimator.secondsPerColorChange)
        #expect(estimate.formatted == "1 min 26 s")
        #expect(RunTimeEstimator.format(seconds: 3725) == "1 h 2 min")
        #expect(RunTimeEstimator.format(seconds: 45.4) == "45 s")
    }

    @Test func longStitchesSlowTheMachineDown() {
        var short: [StitchCommand] = [.jump(Point2D(0, 0))]
        var long: [StitchCommand] = [.jump(Point2D(0, 0))]
        for i in 1...100 {
            short.append(.stitch(Point2D(Double(i % 2) * 2, 0)))
            long.append(.stitch(Point2D(Double(i % 2) * 10, 0)))
        }
        let s = RunTimeEstimator.estimate(StitchPlan(commands: short + [.end]))
        let l = RunTimeEstimator.estimate(StitchPlan(commands: long + [.end]))
        #expect(l.sewingSeconds > s.sewingSeconds * 2, "10mm stitches should sew well under half speed")
    }

    @Test func stitchBudgetScalesSpacingTowardTheTarget() throws {
        var doc = document(startAtCenter: false)
        let before = try DigitizePipeline.flatten(doc).stitchCount
        let target = before / 2
        StitchBudget.apply(scale: StitchBudget.spacingScale(currentStitchCount: before, targetStitchCount: target), to: &doc)
        let after = try DigitizePipeline.flatten(doc).stitchCount
        // Underlay and edge stitches don't scale, so "near" rather than exact.
        #expect(Double(after) < Double(before) * 0.72 && Double(after) > Double(before) * 0.35, "before \(before), after \(after)")
        // Clamped: an absurd target can't push spacing past the limits.
        StitchBudget.apply(scale: 100, to: &doc)
        #expect(doc.objects.allSatisfy { $0.parameters.fillSpacingMM == StitchBudget.maxSpacingMM })
        StitchBudget.apply(scale: 0.0001, to: &doc)
        #expect(doc.objects.allSatisfy { $0.parameters.fillSpacingMM == StitchBudget.minSpacingMM })
    }

    @Test func startAndEndAtCenterBracketsThePlanWithJumps() throws {
        let plain = try DigitizePipeline.flatten(document(startAtCenter: false))
        let centred = try DigitizePipeline.flatten(document(startAtCenter: true))
        let center = Point2D(25, 10)
        #expect(centred.commands.first == .jump(center))
        #expect(centred.commands.dropLast().last == .jump(center))
        #expect(centred.commands.last == .end)
        #expect(centred.commands.count == plain.commands.count + 2)
        #expect(centred.stitchCount == plain.stitchCount)
        // The centre jump is followed by the plan's own first jump, never a stitch at the centre.
        if case .jump = centred.commands[1] {} else { Issue.record("expected the original first jump second") }
    }

    @Test func documentsSavedBeforeTheFlagDecodeAsOff() throws {
        let json = """
        {"schemaVersion":1,"name":"old","physicalWidthMM":10,"physicalHeightMM":10,"objects":[]}
        """.data(using: .utf8)!
        let doc = try JSONDecoder().decode(StitchDocument.self, from: json)
        #expect(doc.startAndEndAtCenter == false)
        let roundTrip = try JSONDecoder().decode(StitchDocument.self, from: JSONEncoder().encode(document(startAtCenter: true)))
        #expect(roundTrip.startAndEndAtCenter == true)
    }

    @Test func readinessReportCarriesStabilizerAdviceWithoutPenalty() throws {
        let doc = document(startAtCenter: false)
        let report = QualityAnalyzer.analyze(try DigitizePipeline.flatten(doc), document: doc)
        let advice = report.issues.filter { $0.message.hasPrefix("Stabilizer for knit:") }
        #expect(advice.count == 1)
        #expect(advice.first?.scorePenalty == 0 && advice.first?.severity == .info)
        #expect(advice.first?.message.contains("cut-away") == true)
        for fabric in FabricType.allCases { #expect(!fabric.stabilizerAdvice.isEmpty) }
    }
}
