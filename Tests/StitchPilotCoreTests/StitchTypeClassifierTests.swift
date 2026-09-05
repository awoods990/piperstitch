import Testing
@testable import StitchPilotCore

struct StitchTypeClassifierTests {
    let defaultParams = StitchGenerationParameters() // maxSatinWidthMM = 12.0

    @Test func thinStrokeBecomesRunningStitch() {
        // 20mm long, 0.5mm wide -- a hairline, too narrow even for satin.
        let hairline = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 0.5), Point2D(0, 0.5),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: hairline, parameters: defaultParams) == .runningStitch)
    }

    @Test func mediumColumnBecomesSatin() {
        // 30mm long, 4mm wide -- a typical letter-stroke-scale column.
        let column = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: column, parameters: defaultParams) == .satin)
    }

    @Test func wideBlobBecomesTatamiFill() {
        // 40mm x 40mm square -- far too wide for satin.
        let blob = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(40, 0), Point2D(40, 40), Point2D(0, 40),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: blob, parameters: defaultParams) == .tatamiFill)
    }

    @Test func customMinSatinWidthIsRespected() {
        // Same 4mm column that classifies as satin under the default 1.0mm
        // minimum -- raising the per-object minimum should push it below
        // the threshold instead.
        var params = defaultParams
        params.minSatinWidthMM = 5.0
        let column = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4),
        ], closed: true)])
        #expect(StitchTypeClassifier.classify(shape: column, parameters: params) == .runningStitch)
    }

    @Test func degenerateShapeDefaultsToRunningStitch() {
        let line = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(10, 0)], closed: false)])
        #expect(StitchTypeClassifier.classify(shape: line, parameters: defaultParams) == .runningStitch)
    }

    /// Classified output must actually be sew-able by DigitizePipeline
    /// without throwing -- catches a classifier/generator mismatch (e.g.
    /// classifying something as satin that the generator then rejects).
    @Test func classifiedObjectsAllFlattenSuccessfully() throws {
        let shapes: [VectorShape] = [
            VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 0.5), Point2D(0, 0.5)], closed: true)]),
            VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4)], closed: true)]),
            VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(40, 0), Point2D(40, 40), Point2D(0, 40)], closed: true)]),
        ]
        var objects: [EmbroideryObject] = []
        for (i, shape) in shapes.enumerated() {
            let type = StitchTypeClassifier.classify(shape: shape, parameters: defaultParams)
            objects.append(EmbroideryObject(name: "Obj\(i)", shape: shape, stitchType: type, threadColor: .generic(RGBColor(hex: 0x000000))))
        }
        let doc = StitchDocument(name: "Mixed", physicalWidthMM: 40, physicalHeightMM: 40, objects: objects)
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 0)
    }
}
