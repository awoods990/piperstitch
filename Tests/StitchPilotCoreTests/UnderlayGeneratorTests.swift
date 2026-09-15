import Testing
@testable import StitchPilotCore

struct UnderlayGeneratorTests {
    @Test func centerRunFollowsRectangleColumnCenterline() {
        // 2mm wide: in the center-run band (1.2...2.5mm) of
        // `UnderlayGenerator.plan` -- a small letter's stroke.
        let rect = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 2), Point2D(0, 2),
        ], closed: true)])
        var params = StitchGenerationParameters()
        params.underlayInsetMM = 1.0
        params.underlayStitchLengthMM = 3.0

        #expect(UnderlayGenerator.plan(for: rect, stitchType: .satin, parameters: params) == .init(first: .centerRun, second: nil))
        let underlay = UnderlayGenerator.generate(for: rect, stitchType: .satin, parameters: params)
        #expect(!underlay.isEmpty)

        // Centerline of a 30x2 rectangle is y=1 all the way across.
        for p in underlay {
            #expect(abs(p.y - 1.0) <= 0.05)
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

        let layers = UnderlayGenerator.generateLayers(for: square, stitchType: .tatamiFill, parameters: params)
        let edgeRun = layers.first { $0.type == .edgeRun }?.runs.first ?? []
        #expect(!edgeRun.isEmpty)
        let box = BoundingBox(points: edgeRun)
        #expect(box.minX >= 1.0 && box.minY >= 1.0)
        #expect(box.maxX <= 19.0 && box.maxY <= 19.0)
        // The tatami layer this 400mm² fill also gets stays inside the
        // shape with a (looser) margin of its own.
        if let tatami = layers.first(where: { $0.type == .tatami }) {
            let all = BoundingBox(points: tatami.runs.flatMap { $0 })
            #expect(all.minX >= 0.5 && all.minY >= 0.5 && all.maxX <= 19.5 && all.maxY <= 19.5)
        }
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

    @Test func mediumSatinColumnGetsEdgeRunNotZigzag() {
        // 30mm long, 3mm wide -- above the center-run band, below the 4mm
        // default zigzag threshold: an edge run (the manual's underlay for
        // letters over ~10mm tall).
        let column = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 3), Point2D(0, 3),
        ], closed: true)])
        let params = StitchGenerationParameters()
        #expect(UnderlayGenerator.plan(for: column, stitchType: .satin, parameters: params) == .init(first: .edgeRun, second: nil))
        let underlay = UnderlayGenerator.generate(for: column, stitchType: .satin, parameters: params)
        #expect(!underlay.isEmpty)
        let box = BoundingBox(points: underlay)
        #expect(box.minY >= 0.6 && box.maxY <= 2.4, "edge run stays inset from both rails")
        #expect(underlay.contains { $0.y < 1.2 } && underlay.contains { $0.y > 1.8 }, "an edge run traces both sides, not one centerline")
    }

    @Test func tinyAndHairlineSatinGetsNoUnderlay() {
        // Under 5mm in every direction: nothing to stabilise.
        let tiny = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(4, 0), Point2D(4, 2), Point2D(0, 2)], closed: true)])
        #expect(UnderlayGenerator.plan(for: tiny, stitchType: .satin, parameters: .init()).first == UnderlayType.none)
        // Long but hairline (1mm): a small letter's stroke -- no underlay.
        let hairline = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 1), Point2D(0, 1)], closed: true)])
        #expect(UnderlayGenerator.plan(for: hairline, stitchType: .satin, parameters: .init()).first == UnderlayType.none)
        #expect(UnderlayGenerator.generate(for: hairline, stitchType: .satin, parameters: .init()).isEmpty)
    }

    @Test func wideSatinOnKnitGetsASecondLayer() {
        let wide = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 5), Point2D(0, 5)], closed: true)])
        var params = StitchGenerationParameters()
        #expect(UnderlayGenerator.plan(for: wide, stitchType: .satin, parameters: params) == .init(first: .zigzag, second: nil))
        params.fabricType = .knit
        #expect(UnderlayGenerator.plan(for: wide, stitchType: .satin, parameters: params) == .init(first: .zigzag, second: .edgeRun))
        let veryWide = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 8), Point2D(0, 8)], closed: true)])
        #expect(UnderlayGenerator.plan(for: veryWide, stitchType: .satin, parameters: .init()) == .init(first: .zigzag, second: .edgeRun))
        // Both layers are generated, in order.
        let layers = UnderlayGenerator.generateLayers(for: veryWide, stitchType: .satin, parameters: .init())
        #expect(layers.count == 2 && layers[0].type == .zigzag && layers[1].type == .edgeRun)
        #expect(layers[0].runs[0].contains { abs($0.y - 4) > 1.5 }, "first layer zigzags")
        let second = BoundingBox(points: layers[1].runs[0])
        #expect(second.maxY <= 7.4 && second.minY >= 0.6, "second layer is the inset edge run")
    }

    @Test func largeFillGetsTatamiUnderlayAndKnitsGetCrossHatch() {
        let small = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(15, 0), Point2D(15, 15), Point2D(0, 15)], closed: true)])  // 225mm²
        let large = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 30), Point2D(0, 30)], closed: true)])  // 900mm²
        var params = StitchGenerationParameters()
        #expect(UnderlayGenerator.plan(for: small, stitchType: .tatamiFill, parameters: params) == .init(first: .edgeRun, second: nil))
        #expect(UnderlayGenerator.plan(for: large, stitchType: .tatamiFill, parameters: params) == .init(first: .edgeRun, second: .tatami))
        params.fabricType = .knit
        #expect(UnderlayGenerator.plan(for: small, stitchType: .tatamiFill, parameters: params) == .init(first: .edgeRun, second: .tatami), "stretchy fabric lowers the size bar")
        params.fabricType = .beanie
        #expect(UnderlayGenerator.plan(for: large, stitchType: .tatamiFill, parameters: params) == .init(first: .edgeRun, second: .doubleTatami))

        // The tatami underlay is open rows, inset, running across the cover angle.
        params.fabricType = .standard
        params.fillAngleDegrees = 0
        params.underlayInsetMM = 1.0
        let layers = UnderlayGenerator.generateLayers(for: large, stitchType: .tatamiFill, parameters: params)
        #expect(layers.count == 2 && layers[1].type == .tatami)
        let tatami = layers[1].runs.flatMap { $0 }
        let box = BoundingBox(points: tatami)
        #expect(box.minX >= 0.6 && box.maxX <= 29.4 && box.minY >= 0.6 && box.maxY <= 29.4)
        // Rows at 90° to a 0° cover run vertically: distinct x positions ~3mm apart.
        let xs = Set(tatami.map { ($0.x * 10).rounded() / 10 })
        #expect(xs.count < 15, "open rows, not a dense fill (saw \(xs.count) distinct x)")
        // Far fewer stitches than the cover fill would use.
        let cover = TatamiFillGenerator.generate(for: large, parameters: params)
        #expect(tatami.count < cover.count / 4)

        // Forcing the second layer off wins over the automatic choice.
        params.secondUnderlayType = UnderlayType.none
        #expect(UnderlayGenerator.plan(for: large, stitchType: .tatamiFill, parameters: params).second == nil)
    }

    @Test func tatamiUnderlayNeverBridgesAHole() {
        // A 40x40 fill with a 20x20 hole: the underlay rows on either
        // side of the hole must come back as separate runs, never joined
        // by a stitch across the open middle.
        let outer = SubPath(points: [Point2D(0, 0), Point2D(40, 0), Point2D(40, 40), Point2D(0, 40)], closed: true)
        let hole = SubPath(points: [Point2D(10, 10), Point2D(30, 10), Point2D(30, 30), Point2D(10, 30)], closed: true)
        var params = StitchGenerationParameters()
        params.fillAngleDegrees = 0
        let layers = UnderlayGenerator.generateLayers(for: VectorShape(subPaths: [outer, hole]), stitchType: .tatamiFill, parameters: params)
        let tatami = layers.first { $0.type == .tatami }
        #expect(tatami != nil)
        for run in tatami?.runs ?? [] {
            for (a, b) in zip(run, run.dropFirst()) {
                let mid = Point2D((a.x + b.x) / 2, (a.y + b.y) / 2)
                let insideHole = mid.x > 11 && mid.x < 29 && mid.y > 11 && mid.y < 29
                #expect(!insideHole, "underlay stitch \(a)->\(b) crosses the hole")
            }
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
