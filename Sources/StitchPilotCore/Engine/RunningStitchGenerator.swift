import Foundation

/// Converts one sub-path into running-stitch `StitchCommand`s by resampling
/// it at (approximately) a fixed stitch length. This is the simplest stitch
/// generator in the engine and the first vertical slice of the auto-digitize
/// pipeline (Phase 1); satin, tatami fill, and the rest of §11 follow in
/// Phase 2 as additional generators selected by `StitchType`.
///
/// Resampling by arc length (not by input vertex) matters: flattened bezier
/// curves have unevenly spaced vertices, and stitching every polyline vertex
/// verbatim would put tiny stitches on tight curves and long stitches on
/// straight runs. Machine embroidery wants roughly even stitch length.
public enum RunningStitchGenerator {
    public static func generate(for subPath: SubPath, stitchLengthMM: Double, minStitchLengthMM: Double) -> [Point2D] {
        guard subPath.points.count > 1, stitchLengthMM > 0 else { return subPath.points }

        var ring = subPath.points
        if subPath.closed, let first = ring.first, ring.last != first {
            ring.append(first)
        }

        var result: [Point2D] = [ring[0]]
        var carry = 0.0 // leftover distance from the previous segment toward the next stitch

        for i in 1..<ring.count {
            let a = ring[i - 1]
            let b = ring[i]
            let segLen = a.distance(to: b)
            guard segLen > 0 else { continue }

            var distanceIntoSegment = stitchLengthMM - carry
            while distanceIntoSegment <= segLen {
                let t = distanceIntoSegment / segLen
                result.append(Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
                distanceIntoSegment += stitchLengthMM
            }
            carry = segLen - (distanceIntoSegment - stitchLengthMM)
        }

        if result.last != ring.last {
            result.append(ring.last!)
        }

        // Sub-minimum-length cleanup is shared with every other generator
        // via StitchFilter (spec §30) rather than duplicated here.
        return StitchFilter.mergeTinyStitches(result, minLengthMM: minStitchLengthMM)
    }
}
