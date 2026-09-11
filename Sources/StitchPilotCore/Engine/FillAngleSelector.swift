import Foundation

/// Automatically picks a tatami fill angle from shape geometry, instead of
/// always defaulting to a fixed angle (spec §6: "do not always use a single
/// fixed fill angle").
///
/// **This is original work, not a technique borrowed from Ink/Stitch** —
/// worth stating explicitly, since `EMBROIDERY_ALGORITHM_REFERENCE.md`
/// documents studying Ink/Stitch's fill implementation in detail and its
/// fill angle is a plain user-set parameter with no automatic selection
/// logic anywhere in that codebase. The heuristic here (rows run
/// perpendicular to the shape's principal/elongation axis) reflects general
/// digitizing guidance — concentrating stitch crossings across the *short*
/// dimension resists pull along the *long* dimension, which is usually the
/// direction most worth stabilizing — but it is a heuristic, not a
/// universally correct choice (a "flowing" look sometimes calls for fill
/// running *along* elongation instead, which is exactly the kind of
/// judgment call a professional digitizer makes per-design). It is
/// deliberately easy to override: `parameters.fillAngleDegrees` still wins
/// whenever it's set, matching every other "nil = automatic" parameter in
/// `StitchGenerationParameters`.
public enum FillAngleSelector {
    /// Considers *every* sub-path, not just the first -- a shape with more
    /// than one sub-path is usually a single outer boundary plus holes
    /// sharing one natural orientation, but `ShapeMerger.merge` also
    /// produces multi-sub-path shapes for pieces that don't actually touch
    /// (its own doc comment: pieces that don't connect are kept as
    /// separate sub-paths rather than silently dropped). Reading only the
    /// first sub-path there picked an angle from whichever piece happened
    /// to be traced first, applied uniformly across every piece -- fine
    /// when they share an orientation, visibly wrong when they don't (two
    /// legs of a merged letterform leaning opposite ways, one stitched at
    /// the other's angle). Found against a real merge (two halves of a
    /// logo's letterform, split and rejoined around a color that cuts
    /// through it) where the second piece's fill ran at a visibly
    /// mismatched angle. See CHANGELOG.md.
    ///
    /// Each sub-path's *own* principal axis is computed independently and
    /// combined by an area-weighted circular mean, rather than pooling
    /// every sub-path's raw points into one cloud first -- pooling points
    /// directly would let the *distance between* far-apart, disjoint
    /// pieces dominate the result (their centroids being far apart adds
    /// its own spurious "elongation" unrelated to either piece's actual
    /// shape), and would let a letterform's holes -- usually much smaller
    /// than the outer boundary, but contributing just as many raw points
    /// -- pull the axis away from the outer boundary's orientation more
    /// than their small area should. Weighting by each sub-path's own area
    /// keeps a large outer boundary dominant over its own small holes
    /// (matching the old first-sub-path-only behavior for the common
    /// single-shape case) while still letting a second, similarly-sized
    /// disjoint piece pull the average toward a real compromise angle
    /// instead of being ignored outright.
    public static func selectAngle(for shape: VectorShape) -> Double {
        var sumX = 0.0, sumY = 0.0
        var totalWeight = 0.0
        for subPath in shape.subPaths {
            guard subPath.points.count >= 3 else { continue }
            let (axis, _) = PolygonGeometry.principalAxis(subPath.points)
            let angleRad = atan2(axis.y, axis.x)
            let weight = abs(PolygonGeometry.signedArea(subPath.points))
            // An axis has no direction (0 and 180 degrees are the same row
            // orientation), so averaging raw angles can cancel out or land
            // exactly between two nearly-opposite axes instead of near
            // either one -- doubling the angle before averaging (and
            // halving the result back) is the standard fix for averaging
            // undirected lines.
            sumX += weight * cos(2 * angleRad)
            sumY += weight * sin(2 * angleRad)
            totalWeight += weight
        }
        guard totalWeight > 0 else { return 0 }
        let axisAngleDegrees = (atan2(sumY, sumX) / 2) * 180 / .pi
        // Perpendicular to the elongation axis, normalized to [0, 180) --
        // fill angle is a line direction, so 90 and 270 are the same row
        // orientation and there's no reason to report a value outside a
        // single half-turn.
        var perpendicular = axisAngleDegrees + 90
        perpendicular = perpendicular.truncatingRemainder(dividingBy: 180)
        if perpendicular < 0 { perpendicular += 180 }
        return perpendicular
    }
}
