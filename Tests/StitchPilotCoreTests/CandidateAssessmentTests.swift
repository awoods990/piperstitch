import Testing
import Foundation
@testable import StitchPilotCore

/// `CandidateAssessment`: a photograph, a scan or a soft low-resolution
/// image is told apart from artwork before the setup steps, from the
/// importer's colour statistics and the trace's fragmentation.
struct CandidateAssessmentTests {
    private func result(shapes: Int, tiny: Int, width: Int = 800, height: Int = 600, meanDE: Double = 2, ambiguous: Double = 0.05) -> ImageImportResult {
        var list: [VectorShape] = []
        for i in 0..<shapes {
            let big = i >= tiny
            let x = Double(i % 40) * 20, y = Double(i / 40) * 20
            let s = big ? 30.0 : 2.0
            list.append(VectorShape(subPaths: [SubPath(points: [Point2D(x, y), Point2D(x + s, y), Point2D(x + s, y + s), Point2D(x, y + s)], closed: true)]))
        }
        var r = ImageImportResult(shapes: list, fillColors: Array(repeating: RGBColor(hex: 0x203060), count: shapes), pixelWidth: width, pixelHeight: height)
        r.colorStatistics.foregroundPixels = width * height / 4
        r.colorStatistics.meanColorDistance = meanDE
        r.colorStatistics.ambiguousFraction = ambiguous
        return r
    }

    @Test func aFlatLogoIsAGoodCandidate() {
        let a = CandidateAssessment.assess(importResult: result(shapes: 30, tiny: 2))
        #expect(a.verdict == .good && a.reasons.isEmpty)
    }

    @Test func aPhotographIsPoorWithTheNumbersInTheReason() {
        let a = CandidateAssessment.assess(importResult: result(shapes: 6, tiny: 0, meanDE: 8.8, ambiguous: 0.31))
        #expect(a.verdict == .poor)
        #expect(a.reasons.first?.code == "photograph")
        #expect(a.reasons.first?.message.contains("31%") == true)
    }

    @Test func aScanTracedIntoDustIsPoor() {
        let a = CandidateAssessment.assess(importResult: result(shapes: 400, tiny: 350, meanDE: 5, ambiguous: 0.1))
        #expect(a.verdict == .poor)
        #expect(a.reasons.contains { $0.code == "fragmented" && $0.message.contains("400") })
    }

    @Test func aSmallSoftImageIsACaution() {
        let a = CandidateAssessment.assess(importResult: result(shapes: 20, tiny: 0, width: 160, height: 120, meanDE: 5, ambiguous: 0.2))
        #expect(a.verdict == .caution)
        #expect(a.reasons.first?.code == "lowResolution")
        // ...but a tiny simple mark (the 96 px Red Sox "B") is not.
        let b = CandidateAssessment.assess(importResult: result(shapes: 3, tiny: 0, width: 96, height: 96, meanDE: 1, ambiguous: 0.02))
        #expect(b.verdict == .good)
    }

    @Test func aPoorReadinessScoreIsPoorWithTheLargestIssues() {
        let report = EmbroideryReadinessReport(score: 42, issues: [
            QualityIssue(severity: .warning, message: "Too many tiny objects.", scorePenalty: 30),
            QualityIssue(severity: .info, message: "Stabilizer advice.", scorePenalty: 0),
            QualityIssue(severity: .warning, message: "Mixed textures.", scorePenalty: 10),
        ])
        let a = CandidateAssessment.assess(report: report)
        #expect(a.verdict == .poor)
        #expect(a.reasons.first?.message.contains("42") == true)
        #expect(a.reasons.dropFirst().map(\.message) == ["Too many tiny objects.", "Mixed textures."])
        #expect(CandidateAssessment.assess(report: EmbroideryReadinessReport(score: 80, issues: [])).verdict == .good)
    }
}
