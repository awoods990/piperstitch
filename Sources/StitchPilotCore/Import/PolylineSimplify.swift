import Foundation

/// Ramer–Douglas–Peucker polyline simplification. Used after raster contour
/// tracing to turn a one-point-per-pixel boundary into a clean set of
/// vertices — spec §7/§71 are explicit that StitchPilot must not "merely
/// trace every pixel."
public enum PolylineSimplify {
    public static func douglasPeucker(_ points: [Point2D], epsilon: Double) -> [Point2D] {
        guard points.count > 2, epsilon > 0 else { return points }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        simplifySegment(points, 0, points.count - 1, epsilon, &keep)
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func simplifySegment(_ points: [Point2D], _ start: Int, _ end: Int, _ epsilon: Double, _ keep: inout [Bool]) {
        guard end > start + 1 else { return }
        let a = points[start], b = points[end]
        var maxDist = 0.0
        var maxIndex = start

        for i in (start + 1)..<end {
            let d = perpendicularDistance(points[i], a, b)
            if d > maxDist { maxDist = d; maxIndex = i }
        }

        if maxDist > epsilon {
            keep[maxIndex] = true
            simplifySegment(points, start, maxIndex, epsilon, &keep)
            simplifySegment(points, maxIndex, end, epsilon, &keep)
        }
    }

    private static func perpendicularDistance(_ p: Point2D, _ a: Point2D, _ b: Point2D) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 { return p.distance(to: a) }
        let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        let proj = Point2D(a.x + t * dx, a.y + t * dy)
        return p.distance(to: proj)
    }
}
