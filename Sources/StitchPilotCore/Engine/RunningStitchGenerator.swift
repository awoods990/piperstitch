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

        return mergeTinyStitches(result, minLengthMM: minStitchLengthMM)
    }

    /// Removes near-duplicate points that would otherwise produce
    /// sub-minimum stitches (spec §30 "stitch filtering": too-short stitches
    /// cause thread breaks and don't add visible detail).
    private static func mergeTinyStitches(_ points: [Point2D], minLengthMM: Double) -> [Point2D] {
        guard points.count > 2 else { return points }
        var out: [Point2D] = [points[0]]
        for p in points.dropFirst() {
            if let last = out.last, last.distance(to: p) < minLengthMM {
                continue
            }
            out.append(p)
        }
        if let last = out.last, let realLast = points.last, last != realLast {
            if last.distance(to: realLast) < minLengthMM {
                // Snap instead of appending: adding realLast here would
                // reintroduce exactly the sub-minimum stitch this pass
                // exists to remove.
                out[out.count - 1] = realLast
            } else {
                out.append(realLast)
            }
        }
        return out
    }
}
