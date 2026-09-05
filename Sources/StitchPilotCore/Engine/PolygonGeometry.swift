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
}
