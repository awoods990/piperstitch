import Foundation

/// Estimates pull compensation — spec §17: fabric pulls inward, perpendicular
/// to the stitch direction, as it's sewn, so a satin column or fill region
/// sews narrower/smaller than digitized unless the digitized geometry is
/// expanded outward to compensate first.
///
/// This is a first-pass *heuristic*, not a calibrated physical model: real
/// pull depends on fabric weight/stretch, hooping tension, and thread type
/// -- the manual sew-out calibration system in spec §68 is the intended way
/// to eventually replace this heuristic with numbers measured from actual
/// sew-outs. The formula below captures the two effects that are true
/// regardless of fabric (denser stitching pulls more, the same absolute
/// pull is a bigger relative distortion on a narrower object), then
/// `fabricType` (spec's Phase 5) scales the whole result directionally for
/// how stretchy/stable the target material is -- still not calibrated
/// per-fabric data, just a documented direction and rough magnitude.
public enum PullCompensationCalculator {
    /// The un-scaled ceiling -- `.standard` fabric never recommends more
    /// than this, beyond which compensation itself starts visibly
    /// distorting the design rather than correcting for pull.
    private static let baseMaxCompensationMM = 0.6
    /// An absolute ceiling regardless of fabric type or how far
    /// `FabricType.compensationMultiplier` would otherwise push it --
    /// even a very stretchy fabric shouldn't get compensation large
    /// enough to itself become the dominant source of distortion.
    private static let hardCeilingCompensationMM = 1.0
    private static let baseCompensationMM = 0.15

    public static func estimate(stitchType: StitchType, densityMM: Double, objectWidthMM: Double, fabricType: FabricType = .standard) -> Double {
        guard stitchType == .satin || stitchType == .tatamiFill else { return 0 }
        let effectiveMax = min(hardCeilingCompensationMM, baseMaxCompensationMM * fabricType.compensationMultiplier)
        guard densityMM > 0 else { return min(effectiveMax, baseCompensationMM * fabricType.compensationMultiplier) }

        // Denser stitching (smaller spacing) pulls fabric together more.
        let densityFactor = max(0, (0.5 - densityMM)) * 0.6
        // The same absolute pull distorts a narrow object proportionally
        // more than a wide one; scale up for narrow columns, cap the effect
        // for very wide ones so compensation doesn't keep shrinking toward zero.
        let widthFactor = objectWidthMM > 0 ? min(1.5, max(0.6, 4.0 / objectWidthMM)) : 1.0

        let estimate = min(effectiveMax, (baseCompensationMM + densityFactor) * widthFactor * fabricType.compensationMultiplier)
        // Lettering-width satin (the manual's own row: "lettering 0.2 -
        // 0.3 mm"): the width factor above rightly grows compensation on
        // narrow columns, but a small letter's stroke over-widened by 0.4
        // mm reads as bold, so cap it at 0.30 mm on standard fabric
        // (scaled up with the fabric, never down).
        if stitchType == .satin, objectWidthMM > 0, objectWidthMM < narrowColumnWidthMM {
            // ...and on the finest columns -- a 4 mm letter's 0.5-0.65 mm
            // strokes -- no more than a share of the width: 0.30 mm on a
            // 0.5 mm stroke is a 60 % gain, and every small letter sewed
            // fat. Digitizers run small lettering at 0.1-0.15 mm.
            let proportional = max(narrowColumnFloorMM, objectWidthMM * narrowColumnShare)
            return min(estimate, narrowColumnCapMM * max(1, fabricType.compensationMultiplier), proportional * max(1, fabricType.compensationMultiplier))
        }
        return estimate
    }

    private static let narrowColumnWidthMM = 3.0
    private static let narrowColumnCapMM = 0.30
    private static let narrowColumnShare = 0.3
    private static let narrowColumnFloorMM = 0.1

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
    public static func estimatePush(stitchType: StitchType, densityMM: Double, objectLengthMM: Double, fabricType: FabricType = .standard) -> Double {
        estimate(stitchType: stitchType, densityMM: densityMM, objectWidthMM: objectLengthMM, fabricType: fabricType)
    }
}
