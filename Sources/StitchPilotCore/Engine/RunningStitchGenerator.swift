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
///
/// On a tight curve a full-length straight stitch cuts the corner, so
/// the stitch is shortened until the path between its two ends stays
/// within `chordGapMM` of the stitch (docs/WILCOM_MANUAL_REVIEW.md B5,
/// Wilcom's "chord gap", default 0.07 mm): the stitch ends at the vertex
/// that deviates most (a corner gets a penetration exactly on it), and
/// only when that vertex is too close does the stitch halve instead,
/// never below `minStitchLengthMM`. A straight run is untouched.
public enum RunningStitchGenerator {
    /// Wilcom's default is 0.07 mm on clean vector curves; raster-traced
    /// outlines carry ~0.1 mm of vertex noise, so a little looser here.
    public static let defaultChordGapMM = 0.1
    /// A stitch is never shortened below this for the chord gap: on a
    /// tiny curved fragment, hugging the curve with sub-millimetre
    /// stitches perforates the fabric for no visible gain.
    public static let shortenedStitchFloorMM = 1.0

    public static func generate(for subPath: SubPath, stitchLengthMM: Double, minStitchLengthMM: Double,
                                chordGapMM: Double = defaultChordGapMM) -> [Point2D] {
        guard subPath.points.count > 1, stitchLengthMM > 0 else { return subPath.points }

        var ring = subPath.points
        if subPath.closed, let first = ring.first, ring.last != first {
            ring.append(first)
        }

        // Cumulative arc length at each vertex.
        var s = [0.0]
        s.reserveCapacity(ring.count)
        for i in 1..<ring.count { s.append(s[i - 1] + ring[i - 1].distance(to: ring[i])) }
        let total = s[s.count - 1]
        guard total > 0 else { return [ring[0]] }

        func point(at target: Double, hint: inout Int) -> Point2D {
            while hint + 1 < ring.count, s[hint + 1] < target { hint += 1 }
            guard hint + 1 < ring.count else { return ring[ring.count - 1] }
            let segLen = s[hint + 1] - s[hint]
            let t = segLen > 0 ? (target - s[hint]) / segLen : 0
            return Point2D(ring[hint].x + (ring[hint + 1].x - ring[hint].x) * t, ring[hint].y + (ring[hint + 1].y - ring[hint].y) * t)
        }

        /// The vertex strictly between arc lengths `from` and `to` that
        /// lies furthest from the straight chord between those two
        /// points, with that distance.
        func worstVertex(from: Double, to: Double, a: Point2D, b: Point2D, firstVertex: Int) -> (vertex: Int, deviation: Double) {
            let dx = b.x - a.x, dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 1e-9 else { return (-1, 0) }
            var worst = (vertex: -1, deviation: 0.0)
            var v = firstVertex
            while v < ring.count, s[v] < to {
                if s[v] > from {
                    let d = abs((ring[v].x - a.x) * dy - (ring[v].y - a.y) * dx) / len
                    if d > worst.deviation { worst = (v, d) }
                }
                v += 1
            }
            return worst
        }

        var result: [Point2D] = [ring[0]]
        var position = 0.0
        var hint = 0
        let minLen = max(minStitchLengthMM, 0.1)
        let shortenFloor = max(minLen, shortenedStitchFloorMM)
        while position < total - 1e-9 {
            var length = min(stitchLengthMM, total - position)
            var endHint = hint
            var end = point(at: position + length, hint: &endHint)
            if chordGapMM > 0 {
                let start = result[result.count - 1]
                var guardCount = 0
                while length > shortenFloor * 2, guardCount < 8 {
                    let worst = worstVertex(from: position, to: position + length, a: start, b: end, firstVertex: hint + 1)
                    guard worst.deviation > chordGapMM else { break }
                    guardCount += 1
                    // End on the offending vertex when that still makes a
                    // real stitch; otherwise halve and look again.
                    let atVertex = s[worst.vertex] - position
                    length = atVertex >= shortenFloor ? atVertex : length / 2
                    endHint = hint
                    end = point(at: position + length, hint: &endHint)
                }
            }
            position += length
            hint = endHint
            result.append(end)
        }
        if result.last != ring.last { result.append(ring[ring.count - 1]) }

        // Sub-minimum-length cleanup is shared with every other generator
        // via StitchFilter (spec §30) rather than duplicated here.
        return StitchFilter.mergeTinyStitches(result, minLengthMM: minStitchLengthMM)
    }
}
