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
    public static func selectAngle(for shape: VectorShape) -> Double {
        guard let outer = shape.subPaths.first, outer.points.count >= 3 else { return 0 }
        let (axis, _) = PolygonGeometry.principalAxis(outer.points)
        let axisAngleDegrees = atan2(axis.y, axis.x) * 180 / .pi
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
