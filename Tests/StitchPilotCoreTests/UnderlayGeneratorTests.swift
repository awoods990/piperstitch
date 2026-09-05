import Testing
@testable import StitchPilotCore

struct UnderlayGeneratorTests {
    @Test func centerRunFollowsRectangleColumnCenterline() {
        let rect = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4),
        ], closed: true)])
        var params = StitchGenerationParameters()
        params.underlayInsetMM = 1.0
        params.underlayStitchLengthMM = 3.0

        let underlay = UnderlayGenerator.generate(for: rect, stitchType: .satin, parameters: params)
        #expect(!underlay.isEmpty)

        // Centerline of a 30x4 rectangle is y=2 all the way across.
        for p in underlay {
            #expect(abs(p.y - 2.0) <= 0.05)
        }
        let box = BoundingBox(points: underlay)
        // Inset by 1mm from each end (0 and 30).
        #expect(box.minX >= 0.9)
        #expect(box.maxX <= 29.1)
    }

    @Test func edgeRunStaysInsideBoundary() {
        let square = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20),
        ], closed: true)])
        var params = StitchGenerationParameters()
        params.underlayInsetMM = 1.5

        let underlay = UnderlayGenerator.generate(for: square, stitchType: .tatamiFill, parameters: params)
        #expect(!underlay.isEmpty)
        let box = BoundingBox(points: underlay)
        #expect(box.minX >= 1.0 && box.minY >= 1.0)
        #expect(box.maxX <= 19.0 && box.maxY <= 19.0)
    }

    @Test func noneTypeProducesNoUnderlay() {
        let square = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)], closed: true)])
        var params = StitchGenerationParameters()
        params.underlayType = UnderlayType.none
        #expect(UnderlayGenerator.generate(for: square, stitchType: .satin, parameters: params).isEmpty)
    }

    @Test func runningStitchGetsNoUnderlayByDefault() {
        let line = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 1), Point2D(0, 1)], closed: true)])
        let params = StitchGenerationParameters()
        #expect(UnderlayGenerator.generate(for: line, stitchType: .runningStitch, parameters: params).isEmpty)
    }

    @Test func tooShortColumnProducesNoCenterRunUnderlay() {
        // A column shorter than 2x the inset can't have anything trimmed off both ends.
        let tiny = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(1, 0), Point2D(1, 0.5), Point2D(0, 0.5)], closed: true)])
        var params = StitchGenerationParameters()
        params.underlayInsetMM = 1.0
        #expect(UnderlayGenerator.generate(for: tiny, stitchType: .satin, parameters: params).isEmpty)
    }

    @Test func wideSatinColumnGetsZigzagUnderlayAutomatically() {
        // 30mm long, 8mm wide -- above the 4mm default zigzag threshold.
        let wideColumn = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 8), Point2D(0, 8),
        ], closed: true)])
        var params = StitchGenerationParameters()
        params.underlayInsetMM = 1.0

        let underlay = UnderlayGenerator.generate(for: wideColumn, stitchType: .satin, parameters: params)
        #expect(!underlay.isEmpty)

        // A center-run underlay would sit exactly on y=4 throughout; a
        // zigzag alternates between points inset from each rail (near y=1
        // and near y=7), so it must visit points meaningfully off-center.
        let offCenterCount = underlay.filter { abs($0.y - 4.0) > 1.0 }.count
        #expect(offCenterCount > 0, "a zigzag underlay should not run in a single straight centerline")
    }

    @Test func narrowSatinColumnKeepsCenterRunUnderlay() {
        // 30mm long, 3mm wide -- below the 4mm default zigzag threshold.
        let narrowColumn = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 3), Point2D(0, 3),
        ], closed: true)])
        let params = StitchGenerationParameters()
        let underlay = UnderlayGenerator.generate(for: narrowColumn, stitchType: .satin, parameters: params)
        #expect(!underlay.isEmpty)
        for p in underlay {
            #expect(abs(p.y - 1.5) <= 0.05, "a narrow column should still get plain center-run underlay, not zigzag")
        }
    }

    @Test func zigzagUnderlayStaysWithinRailBounds() {
        let wideColumn = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 10), Point2D(0, 10),
        ], closed: true)])
        var params = StitchGenerationParameters()
        params.underlayType = UnderlayType.zigzag
        params.underlayInsetMM = 1.0

        let underlay = UnderlayGenerator.generate(for: wideColumn, stitchType: .satin, parameters: params)
        #expect(!underlay.isEmpty)
        let box = BoundingBox(points: underlay)
        // Inset from the 0...10 rail span by ~1mm on each side.
        #expect(box.minY >= 0.5 && box.maxY <= 9.5)
    }

    @Test func satinObjectFlattensWithUnderlayIncluded() throws {
        let rect = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4)], closed: true)])
        let object = EmbroideryObject(name: "Satin", shape: rect, stitchType: .satin, threadColor: .generic(RGBColor(hex: 0x0000FF)))
        let doc = StitchDocument(name: "Test", physicalWidthMM: 30, physicalHeightMM: 4, objects: [object])

        let withUnderlay = try DigitizePipeline.flatten(doc)

        var noUnderlayObject = object
        noUnderlayObject.parameters.underlayType = UnderlayType.none
        let withoutUnderlay = try DigitizePipeline.flatten(StitchDocument(name: "Test2", physicalWidthMM: 30, physicalHeightMM: 4, objects: [noUnderlayObject]))

        #expect(withUnderlay.stitchCount > withoutUnderlay.stitchCount)
    }
}
