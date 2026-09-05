import Testing
@testable import StitchPilotCore

struct QualityAnalyzerTests {
    @Test func cleanDesignScoresHigh() throws {
        let shape = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)], closed: true)])
        let object = EmbroideryObject(name: "Square", shape: shape, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0x000000)))
        let doc = StitchDocument(name: "Clean", physicalWidthMM: 20, physicalHeightMM: 20, objects: [object])
        let plan = try DigitizePipeline.flatten(doc)

        let report = QualityAnalyzer.analyze(plan)
        #expect(report.score >= 90)
        #expect(report.isReadyToSew)
    }

    @Test func emptyDesignIsCriticalAndZeroScore() {
        let report = QualityAnalyzer.analyze(StitchPlan(commands: [.end]))
        #expect(report.score == 0)
        #expect(!report.isReadyToSew)
        #expect(report.issues.contains { $0.severity == .critical })
    }

    @Test func longJumpIsFlaggedButNotCritical() {
        var plan = StitchPlan()
        plan.commands = [.jump(Point2D(0, 0)), .stitch(Point2D(0, 0)), .jump(Point2D(30, 0)), .stitch(Point2D(30, 0)), .end]
        let report = QualityAnalyzer.analyze(plan)
        #expect(report.issues.contains { $0.message.contains("jump") })
        #expect(report.issues.allSatisfy { $0.severity != .critical })
    }

    @Test func designExceedingHoopIsCritical() throws {
        let shape = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(200, 0), Point2D(200, 200), Point2D(0, 200)], closed: true)])
        let object = EmbroideryObject(name: "Huge", shape: shape, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0x000000)))
        let doc = StitchDocument(name: "TooBig", physicalWidthMM: 200, physicalHeightMM: 200, objects: [object])
        let plan = try DigitizePipeline.flatten(doc)

        let report = QualityAnalyzer.analyze(plan, hoopWidthMM: 100, hoopHeightMM: 100)
        #expect(!report.isReadyToSew)
        #expect(report.issues.contains { $0.severity == .critical && $0.message.contains("hoop") })
    }

    @Test func fittingWithinHoopRaisesNoHoopIssue() throws {
        let shape = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)], closed: true)])
        let object = EmbroideryObject(name: "Small", shape: shape, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0x000000)))
        let doc = StitchDocument(name: "Fits", physicalWidthMM: 20, physicalHeightMM: 20, objects: [object])
        let plan = try DigitizePipeline.flatten(doc)

        let report = QualityAnalyzer.analyze(plan, hoopWidthMM: 100, hoopHeightMM: 100)
        #expect(!report.issues.contains { $0.message.contains("hoop") })
    }

    @Test func scoreNeverGoesBelowZeroOrAboveHundred() {
        var plan = StitchPlan()
        plan.commands = [.end] // empty -> massive penalty, but score should clamp at 0
        let report = QualityAnalyzer.analyze(plan)
        #expect(report.score >= 0 && report.score <= 100)
    }
}
