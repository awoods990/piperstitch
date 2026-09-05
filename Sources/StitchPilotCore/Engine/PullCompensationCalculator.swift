import Foundation

/// Estimates pull compensation — spec §17: fabric pulls inward, perpendicular
/// to the stitch direction, as it's sewn, so a satin column or fill region
/// sews narrower/smaller than digitized unless the digitized geometry is
/// expanded outward to compensate first.
///
/// This is a first-pass *heuristic*, not a calibrated physical model: real
/// pull depends on fabric weight/stretch, hooping tension, and thread type,
/// none of which StitchPilot has data for yet (fabric profiles are Phase 5;
/// the manual sew-out calibration system in spec §68 is the intended way to
/// eventually replace this heuristic with numbers measured from actual
/// sew-outs). The formula below only captures the two effects that are
/// true regardless of fabric: denser stitching pulls more, and the same
/// absolute pull is a bigger relative distortion on a narrower object.
public enum PullCompensationCalculator {
    /// Never recommends more than this — beyond it, compensation itself
    /// starts visibly distorting the design rather than correcting for pull.
    private static let maxCompensationMM = 0.6
    private static let baseCompensationMM = 0.15

    public static func estimate(stitchType: StitchType, densityMM: Double, objectWidthMM: Double) -> Double {
        guard stitchType == .satin || stitchType == .tatamiFill else { return 0 }
        guard densityMM > 0 else { return baseCompensationMM }

        // Denser stitching (smaller spacing) pulls fabric together more.
        let densityFactor = max(0, (0.5 - densityMM)) * 0.6
        // The same absolute pull distorts a narrow object proportionally
        // more than a wide one; scale up for narrow columns, cap the effect
        // for very wide ones so compensation doesn't keep shrinking toward zero.
        let widthFactor = objectWidthMM > 0 ? min(1.5, max(0.6, 4.0 / objectWidthMM)) : 1.0

        return min(maxCompensationMM, (baseCompensationMM + densityFactor) * widthFactor)
    }

    /// Push compensation's counterpart to `estimate` above: fabric doesn't
    /// only pull together perpendicular to the stitching direction, it also
    /// pushes apart *along* it, so a satin column or fill region sews
    /// slightly longer (in its direction of travel) than digitized unless
    /// that length is shortened first. Same two physical drivers as pull
    /// (denser stitching distorts more; a shorter object is distorted
    /// proportionally more for the same absolute push), just measured along
    /// the length axis instead of the width axis — reuses the identical
    /// formula rather than inventing a differently-shaped one with no
    /// calibration data to justify it (see this type's own caveat above).
    public static func estimatePush(stitchType: StitchType, densityMM: Double, objectLengthMM: Double) -> Double {
        estimate(stitchType: stitchType, densityMM: densityMM, objectWidthMM: objectLengthMM)
    }
}
