import Foundation

/// Routes a same-color travel gap as buried running stitch instead of a
/// jump, when doing so avoids a trim — real digitizing software's "travel
/// under" technique: a path that will be covered by stitching sewn
/// immediately afterward doesn't need to be cut and rejoined, since the
/// buried stitches vanish once that later stitching covers them.
///
/// This implements the single case that's provably safe without reasoning
/// about the whole document: a same-color pair `(A, B)` adjacent in sewing
/// order, where the straight path from A's exit point to B's entry point
/// lies entirely inside B's *own* shape. Since B is sewn immediately
/// afterward, its own stitching (fill scanlines, satin crossings) is
/// guaranteed to cover that exact area moments later — no assumption about
/// any other, later object is needed. The general case (any later object,
/// not just the immediate next one, potentially even a different color if
/// it's opaque enough) is real, unscoped design work — see
/// `EMBROIDERY_ALGORITHM_REFERENCE.md`'s "recommended next improvements."
///
/// Only worth doing when the plain alternative would have cost a trim: a
/// same-color jump under `maxJumpWithoutTrimMM` already gets sewn as an
/// untrimmed thread carry, which ends up buried under B's stitching just
/// the same once B covers it — bridging that case would only add stitches
/// for no benefit. This only fires above that threshold, where the plain
/// alternative was a real trim (cut, reposition, tie in again).
public enum HiddenTravelRouter {
    /// How many points to sample *strictly between* the two endpoints when
    /// checking whether a candidate path is covered by the upcoming
    /// object's shape. The endpoints themselves are excluded deliberately:
    /// A's exit and B's entry are fixed regardless of this decision (a
    /// plain jump travels between the same two points), and B's entry in
    /// particular is essentially always sitting on or right at B's own
    /// boundary by construction (every stitch generator starts exactly at
    /// the shape's edge) — checking it with even-odd ray-casting is a
    /// numerically ambiguous edge case that has no bearing on the actual
    /// decision anyway. A straight segment can still dip outside a concave
    /// shape's boundary between two interior-ish points, so multiple
    /// interior samples (not just a midpoint) are checked.
    private static let interiorSampleCount = 6

    public static func bridgeSameColorGaps(_ items: [(object: EmbroideryObject, runs: [[Point2D]])], thresholdMM: Double) -> [(object: EmbroideryObject, runs: [[Point2D]])] {
        guard items.count > 1 else { return items }
        var result = items

        for i in 1..<result.count {
            let previous = result[i - 1]
            let next = result[i]
            guard previous.object.threadColor.rgb == next.object.threadColor.rgb,
                  let exit = previous.runs.last?.last, let entry = next.runs.first?.first,
                  exit.distance(to: entry) > thresholdMM else { continue }

            guard pathIsCoveredByShape(from: exit, to: entry, shape: next.object.shape) else { continue }

            let stitchLength = max(next.object.parameters.stitchLengthMM, 0.3)
            let bridge = RunningStitchGenerator.generate(
                for: SubPath(points: [exit, entry], closed: false),
                stitchLengthMM: stitchLength,
                minStitchLengthMM: next.object.parameters.minStitchLengthMM
            )
            // Drop both endpoints: `exit` already duplicates the previous
            // object's own last point, and `entry` already duplicates
            // `next.runs.first.first` — keep only the genuinely new
            // in-between stitches.
            let bridgePoints = Array(bridge.dropFirst().dropLast())
            guard !bridgePoints.isEmpty else { continue }

            result[i].runs[0] = bridgePoints + next.runs[0]
        }
        return result
    }

    private static func pathIsCoveredByShape(from a: Point2D, to b: Point2D, shape: VectorShape) -> Bool {
        let polygons = shape.subPaths.map { $0.points }
        guard !polygons.isEmpty else { return false }
        for step in 1...interiorSampleCount {
            let t = Double(step) / Double(interiorSampleCount + 1)
            let sample = Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            guard PolygonGeometry.pointInPolygons(sample, polygons: polygons) else { return false }
        }
        return true
    }
}
