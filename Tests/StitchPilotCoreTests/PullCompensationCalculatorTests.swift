import Testing
@testable import StitchPilotCore

struct PullCompensationCalculatorTests {
    @Test func standardFabricMatchesUnscaledBaseline() {
        let standard = PullCompensationCalculator.estimate(stitchType: .satin, densityMM: 0.4, objectWidthMM: 5, fabricType: .standard)
        let unspecified = PullCompensationCalculator.estimate(stitchType: .satin, densityMM: 0.4, objectWidthMM: 5)
        #expect(standard == unspecified, "`.standard` (and omitting fabricType, which defaults to it) must reproduce the exact pre-fabric-type estimate -- existing designs are unaffected unless fabric type is set explicitly")
    }

    @Test func stretchierFabricRecommendsMoreCompensationThanStandard() {
        let standard = PullCompensationCalculator.estimate(stitchType: .satin, densityMM: 0.4, objectWidthMM: 5, fabricType: .standard)
        let stretchy = PullCompensationCalculator.estimate(stitchType: .satin, densityMM: 0.4, objectWidthMM: 5, fabricType: .stretchKnit)
        #expect(stretchy > standard)
    }

    @Test func moreStableFabricRecommendsLessCompensationThanStandard() {
        let standard = PullCompensationCalculator.estimate(stitchType: .satin, densityMM: 0.4, objectWidthMM: 5, fabricType: .standard)
        let stable = PullCompensationCalculator.estimate(stitchType: .satin, densityMM: 0.4, objectWidthMM: 5, fabricType: .stableWoven)
        #expect(stable < standard)
    }

    /// Even the stretchiest fabric type must never push compensation past
    /// a hard absolute ceiling -- compensation itself becoming the
    /// dominant source of distortion would defeat its own purpose.
    @Test func evenTheStretchiestFabricStaysUnderTheHardCeiling() {
        // Deliberately extreme inputs (very dense stitching, very narrow
        // object) that would otherwise push the estimate as high as the
        // formula allows, to actually exercise the ceiling.
        let compensation = PullCompensationCalculator.estimate(stitchType: .satin, densityMM: 0.1, objectWidthMM: 0.5, fabricType: .stretchKnit)
        #expect(compensation <= 1.0)
    }

    @Test func nonSatinNonFillStitchTypesStayZeroRegardlessOfFabric() {
        let compensation = PullCompensationCalculator.estimate(stitchType: .runningStitch, densityMM: 0.4, objectWidthMM: 5, fabricType: .stretchKnit)
        #expect(compensation == 0)
    }

    @Test func estimatePushAppliesTheSameFabricScalingAsEstimate() {
        let pull = PullCompensationCalculator.estimate(stitchType: .tatamiFill, densityMM: 0.4, objectWidthMM: 5, fabricType: .terry)
        let push = PullCompensationCalculator.estimatePush(stitchType: .tatamiFill, densityMM: 0.4, objectLengthMM: 5, fabricType: .terry)
        #expect(pull == push, "estimatePush delegates to estimate with the same axis value, so the two must agree for matching inputs")
    }
}
