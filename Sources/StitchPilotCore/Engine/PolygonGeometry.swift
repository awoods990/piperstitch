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

    /// Naive per-vertex polygon offset: moves each vertex along the average
    /// of its two adjacent edges' inward normals, scaled by `offsetMM`.
    /// Positive shrinks the polygon (used by underlay's edge-run inset),
    /// negative grows it (used by pull compensation's outward expansion) —
    /// same code either way, since growing is just an inward offset run
    /// backward. This is an approximation: it doesn't handle
    /// self-intersection on sharp concave corners the way a true
    /// straight-skeleton/Minkowski offset would, which is adequate for the
    /// sub-millimeter offsets both callers use on typical logo/lettering
    /// shapes but would need replacing for more aggressive offsets.
    public static func offsetPolygon(_ polygon: [Point2D], by offsetMM: Double) -> [Point2D] {
        guard polygon.count >= 3, offsetMM != 0 else { return polygon }
        var pts = polygon
        if pts.first == pts.last { pts.removeLast() }
        let n = pts.count
        guard n >= 3 else { return polygon }

        // Inward normal direction depends on winding: CCW interior is to
        // the left of each directed edge, CW interior is to the right.
        let isCCW = signedArea(pts) > 0

        func inwardNormal(_ a: Point2D, _ b: Point2D) -> Point2D {
            let dx = b.x - a.x, dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0 else { return .zero }
            let (nx, ny) = isCCW ? (-dy / len, dx / len) : (dy / len, -dx / len)
            return Point2D(nx, ny)
        }

        var result: [Point2D] = []
        for i in 0..<n {
            let prev = pts[(i - 1 + n) % n], cur = pts[i], next = pts[(i + 1) % n]
            let n1 = inwardNormal(prev, cur), n2 = inwardNormal(cur, next)
            var avg = Point2D(n1.x + n2.x, n1.y + n2.y)
            let avgLen = avg.length
            avg = avgLen > 0.0001 ? Point2D(avg.x / avgLen, avg.y / avgLen) : n1
            result.append(Point2D(cur.x + avg.x * offsetMM, cur.y + avg.y * offsetMM))
        }
        return result
    }
}
