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

    /// The thread is physically cut at a trim -- the first stitch of the run
    /// that follows a colorChange doesn't continue a physical stitch from
    /// wherever the previous color's thread ended, no matter how far apart
    /// the two points are. A real bug had `checkStitchLengths` (and
    /// `StitchPlan.maxStitchLength()`/`totalStitchLength`) measure straight
    /// across that gap, misreporting an ordinary multi-color design as
    /// having an enormous stitch — found via `DigitizeCLI` test cycles
    /// against `TestArtwork/multi_color_badge.svg` (a 38mm phantom "stitch"
    /// that vanished once this was fixed; see CHANGELOG.md).
    @Test func distantStitchesAcrossATrimDoNotFalselyFlagAsOneLongStitch() {
        var plan = StitchPlan()
        plan.commands = [
            .jump(Point2D(0, 0)), .stitch(Point2D(0, 0)), .stitch(Point2D(1, 0)),
            .trim, .colorChange,
            .stitch(Point2D(50, 50)), .stitch(Point2D(51, 50)),
            .end,
        ]
        #expect(plan.maxStitchLength() < 12.5)
        let report = QualityAnalyzer.analyze(plan)
        #expect(!report.issues.contains { $0.message.contains("exceed 12.5mm") })
    }

    // MARK: - checkFragmentation

    private func tinySquare(at origin: Point2D) -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [
            Point2D(origin.x, origin.y), Point2D(origin.x + 1, origin.y),
            Point2D(origin.x + 1, origin.y + 1), Point2D(origin.x, origin.y + 1),
        ], closed: true)])
    }

    private func normalSquare(at origin: Point2D, sizeMM: Double = 15) -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [
            Point2D(origin.x, origin.y), Point2D(origin.x + sizeMM, origin.y),
            Point2D(origin.x + sizeMM, origin.y + sizeMM), Point2D(origin.x, origin.y + sizeMM),
        ], closed: true)])
    }

    /// The actual regression this check exists to catch automatically:
    /// anti-aliased boundaries in detail-heavy or curved artwork
    /// fragmenting into a swarm of stray sub-2mm objects (confirmed
    /// directly against three real logos -- see `ImageImporter`'s own fix
    /// for the root cause). Before this check existed, a design with
    /// exactly this defect could still score 100/100 "Ready to Sew."
    @Test func manyTinyObjectsAreFlaggedAsFragmentation() throws {
        let color = RGBColor(hex: 0x0A1F44)
        var objects = (0..<10).map { i in
            EmbroideryObject(name: "Speck\(i)", shape: tinySquare(at: Point2D(Double(i) * 3, 0)),
                              stitchType: .runningStitch, threadColor: .generic(color))
        }
        objects.append(EmbroideryObject(name: "Real", shape: normalSquare(at: Point2D(0, 10)), stitchType: .tatamiFill, threadColor: .generic(color)))
        let doc = StitchDocument(name: "Fragmented", physicalWidthMM: 40, physicalHeightMM: 30, objects: objects)
        let plan = try DigitizePipeline.flatten(doc)

        let report = QualityAnalyzer.analyze(plan, document: doc)
        #expect(report.issues.contains { $0.message.contains("fragmentation") })
    }

    /// A couple of genuinely tiny accents in ordinary artwork (a dot, a
    /// fine serif) must not trip this -- only a real *pattern* of
    /// fragmentation, not the occasional small legitimate detail.
    @Test func aFewTinyObjectsAreNotFlaggedAsFragmentation() throws {
        let color = RGBColor(hex: 0x0A1F44)
        var objects = (0..<2).map { i in
            EmbroideryObject(name: "Dot\(i)", shape: tinySquare(at: Point2D(Double(i) * 3, 0)),
                              stitchType: .runningStitch, threadColor: .generic(color))
        }
        objects.append(contentsOf: (0..<6).map { i in
            EmbroideryObject(name: "Real\(i)", shape: normalSquare(at: Point2D(Double(i) * 20, 10)), stitchType: .tatamiFill, threadColor: .generic(color))
        })
        let doc = StitchDocument(name: "MostlyClean", physicalWidthMM: 140, physicalHeightMM: 30, objects: objects)
        let plan = try DigitizePipeline.flatten(doc)

        let report = QualityAnalyzer.analyze(plan, document: doc)
        #expect(!report.issues.contains { $0.message.contains("fragmentation") })
    }

    // MARK: - checkSameColorStitchTypeConsistency

    /// The other real regression this round of work fixed at the source
    /// (`StitchTypeClassifier.harmonizeSameColorFillConsistency`): letters
    /// of one word, the same thread color, independently landing on
    /// different stitch types -- confirmed directly against a real
    /// customer wordmark ("LIBBi"). This check is the safety net for paths
    /// that don't go through harmonization (a manual per-object override
    /// in the editor, say).
    @Test func mixedSatinAndFillInTheSameColorGroupIsFlagged() throws {
        let color = RGBColor(hex: 0x0A1F44)
        let objects = [
            EmbroideryObject(name: "L", shape: normalSquare(at: Point2D(0, 0), sizeMM: 4), stitchType: .satin, threadColor: .generic(color)),
            // Letter-sized: a 15 mm square would be an area, which the
            // check leaves alone (`StitchTypeClassifier.isWideShortBlob`).
            EmbroideryObject(name: "B", shape: normalSquare(at: Point2D(10, 0), sizeMM: 6), stitchType: .tatamiFill, threadColor: .generic(color)),
        ]
        let doc = StitchDocument(name: "Mixed", physicalWidthMM: 30, physicalHeightMM: 20, objects: objects)
        let plan = try DigitizePipeline.flatten(doc)

        let report = QualityAnalyzer.analyze(plan, document: doc)
        #expect(report.issues.contains { $0.message.contains("mix satin and fill") })
    }

    @Test func sameColorSameStitchTypeIsNotFlagged() throws {
        let color = RGBColor(hex: 0x0A1F44)
        let objects = [
            EmbroideryObject(name: "A", shape: normalSquare(at: Point2D(0, 0)), stitchType: .tatamiFill, threadColor: .generic(color)),
            EmbroideryObject(name: "B", shape: normalSquare(at: Point2D(20, 0)), stitchType: .tatamiFill, threadColor: .generic(color)),
        ]
        let doc = StitchDocument(name: "Consistent", physicalWidthMM: 40, physicalHeightMM: 20, objects: objects)
        let plan = try DigitizePipeline.flatten(doc)

        let report = QualityAnalyzer.analyze(plan, document: doc)
        #expect(!report.issues.contains { $0.message.contains("mix satin and fill") })
    }

    /// Different colors mixing satin and fill is completely ordinary (a
    /// design's satin border and tatami-filled body, say) -- only *same*-
    /// color disagreement is the defect this check exists to catch.
    @Test func differentColorsWithDifferentStitchTypesAreNotFlagged() throws {
        let objects = [
            EmbroideryObject(name: "A", shape: normalSquare(at: Point2D(0, 0), sizeMM: 4), stitchType: .satin, threadColor: .generic(RGBColor(hex: 0x0A1F44))),
            EmbroideryObject(name: "B", shape: normalSquare(at: Point2D(10, 0)), stitchType: .tatamiFill, threadColor: .generic(RGBColor(hex: 0xB1521E))),
        ]
        let doc = StitchDocument(name: "TwoColors", physicalWidthMM: 30, physicalHeightMM: 20, objects: objects)
        let plan = try DigitizePipeline.flatten(doc)

        let report = QualityAnalyzer.analyze(plan, document: doc)
        #expect(!report.issues.contains { $0.message.contains("mix satin and fill") })
    }
}
