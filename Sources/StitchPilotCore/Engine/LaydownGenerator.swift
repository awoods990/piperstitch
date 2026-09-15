import Foundation

/// The laydown stitch itself -- see `LaydownSettings`. The footprint is
/// the union of every object's outline grown by the margin
/// (`ShapeMerger.dilatedUnion`), filled with one or two layers of open
/// tatami at opposing angles, no underlay, no compensation. Runs are
/// returned the way an object's own runs are, so `DigitizePipeline`
/// sews them first as a separate colour block.
public enum LaydownGenerator {
    public static let firstLayerAngleDegrees = 0.0
    public static let secondLayerAngleDegrees = 90.0

    public static func footprint(for document: StitchDocument, settings: LaydownSettings) -> VectorShape? {
        ShapeMerger.dilatedUnion(document.objects.map { $0.shape }, marginMM: settings.marginMM, fillHoles: settings.coverHoles)
    }

    public static func generateRuns(for document: StitchDocument, settings: LaydownSettings, breakThresholdMM: Double) -> [[Point2D]] {
        guard let shape = footprint(for: document, settings: settings) else { return [] }
        var parameters = StitchGenerationParameters()
        parameters.fillSpacingMM = max(1.0, settings.spacingMM)
        parameters.stitchLengthMM = max(2.0, settings.stitchLengthMM)
        parameters.fillPattern = .rows
        parameters.underlayType = UnderlayType.none
        parameters.secondUnderlayType = nil
        parameters.pullCompensationMM = 0
        parameters.pushCompensationMM = 0
        parameters.fabricType = document.objects.first?.parameters.fabricType ?? .terry

        var runs: [[Point2D]] = []
        let angles = settings.twoLayers ? [firstLayerAngleDegrees, secondLayerAngleDegrees] : [firstLayerAngleDegrees]
        for angle in angles {
            parameters.fillAngleDegrees = angle
            let layer = TatamiFillGenerator.generateRuns(for: shape, parameters: parameters, breakThresholdMM: breakThresholdMM, routeConnectorsAlongEdges: true)
            runs.append(contentsOf: layer.filter { $0.count > 1 })
        }
        return runs
    }
}
