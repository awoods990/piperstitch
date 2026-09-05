import Foundation

/// Shared polygon measurements used by both stitch-type classification and
/// satin-column generation, so the two don't drift into computing "shape
/// elongation" two different ways.
public enum PolygonGeometry {
    /// Signed area via the shoelace formula (positive for counter-clockwise
    /// winding, matching standard math convention — sign is discarded by
    /// callers that just want magnitude).
    public static func signedArea(_ points: [Point2D]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<points.count {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// The polygon's elongation direction (unit vector) via the covariance
    /// matrix's principal eigenvector, and its centroid.
    public static func principalAxis(_ points: [Point2D]) -> (axis: Point2D, mean: Point2D) {
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n

        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            let dx = p.x - meanX, dy = p.y - meanY
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }

        // Closed-form principal-axis angle for a 2x2 symmetric covariance matrix.
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        return (Point2D(cos(angle), sin(angle)), Point2D(meanX, meanY))
    }

    /// The range of projections of `points` onto `axis` (relative to `mean`) — the shape's extent along that axis.
    public static func projectionRange(_ points: [Point2D], axis: Point2D, mean: Point2D) -> (min: Double, max: Double) {
        var lo = Double.infinity, hi = -Double.infinity
        for p in points {
            let proj = (p.x - mean.x) * axis.x + (p.y - mean.y) * axis.y
            lo = min(lo, proj)
            hi = max(hi, proj)
        }
        return (lo, hi)
    }

    public static func pathLength(_ points: [Point2D]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count { total += points[i - 1].distance(to: points[i]) }
        return total
    }

    /// Resamples a polyline into exactly `count + 1` points, evenly spaced
    /// by fraction of total arc length (not by fixed stitch length) —
    /// shared by `SatinColumnGenerator` (to pair two rails point-for-point
    /// regardless of their individual lengths) and `UnderlayGenerator` (to
    /// derive a satin column's centerline from the same rails).
    public static func resampleByCount(_ points: [Point2D], count: Int) -> [Point2D] {
        guard points.count > 1, count > 0 else { return points }
        let total = pathLength(points)
        guard total > 0 else { return Array(repeating: points[0], count: count + 1) }

        var result: [Point2D] = []
        var segIndex = 0
        var segStart = points[0]
        var distanceCoveredBeforeSeg = 0.0
        var segLength = points[1].distance(to: points[0])

        for step in 0...count {
            let targetDistance = total * Double(step) / Double(count)
            while distanceCoveredBeforeSeg + segLength < targetDistance, segIndex < points.count - 2 {
                distanceCoveredBeforeSeg += segLength
                segIndex += 1
                segStart = points[segIndex]
                segLength = points[segIndex + 1].distance(to: points[segIndex])
            }
            if segLength <= 0 {
                result.append(segStart)
            } else {
                let t = min(1, max(0, (targetDistance - distanceCoveredBeforeSeg) / segLength))
                let end = points[segIndex + 1]
                result.append(Point2D(segStart.x + (end.x - segStart.x) * t, segStart.y + (end.y - segStart.y) * t))
            }
        }
        return result
    }
}
