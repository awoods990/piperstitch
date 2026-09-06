import Foundation

/// Ramer–Douglas–Peucker polyline simplification. Used after raster contour
/// tracing to turn a one-point-per-pixel boundary into a clean set of
/// vertices — spec §7/§71 are explicit that StitchPilot must not "merely
/// trace every pixel."
public enum PolylineSimplify {
    /// Exact Douglas-Peucker is worst-case O(n²) (a range whose farthest
    /// point sits right next to one end barely shrinks the next recursive
    /// range) — rare for hand-drawn vector paths, but a raster-traced pixel
    /// boundary's near-collinear staircase steps are exactly the kind of
    /// input that triggers it, and one degenerate 126,017-point boundary
    /// from a single tiny fragment of `SMA Logo.webp` took minutes here
    /// alone (see CHANGELOG.md; the boundary itself was also a bug, now
    /// fixed in `ImageImporter.traceBoundary`, but this bound stays as
    /// insurance against any other pathologically large input). Above this
    /// many points, pre-decimate to a uniform stride first so the exact
    /// O(n²) pass only ever runs on a bounded input; embroidery stitch
    /// width is coarser than pixel-level detail anyway, so losing sub-pixel
    /// fidelity here costs nothing visible.
    private static let maxExactInputPoints = 3000

    public static func douglasPeucker(_ points: [Point2D], epsilon: Double) -> [Point2D] {
        guard points.count > 2, epsilon > 0 else { return points }
        let input = points.count > maxExactInputPoints ? decimate(points, to: maxExactInputPoints) : points

        var keep = [Bool](repeating: false, count: input.count)
        keep[0] = true
        keep[input.count - 1] = true

        // Iterative (explicit stack) rather than recursive: the same
        // degenerate input that makes this O(n²) in time can also recurse
        // as deep as `input.count` in the worst case, which would overflow
        // the call stack long before it finished anyway.
        var stack: [(Int, Int)] = [(0, input.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            let a = input[start], b = input[end]
            var maxDist = 0.0
            var maxIndex = start

            for i in (start + 1)..<end {
                let d = perpendicularDistance(input[i], a, b)
                if d > maxDist { maxDist = d; maxIndex = i }
            }

            if maxDist > epsilon {
                keep[maxIndex] = true
                stack.append((start, maxIndex))
                stack.append((maxIndex, end))
            }
        }
        return input.indices.filter { keep[$0] }.map { input[$0] }
    }

    /// Uniform-stride downsampling to at most `target` points, always
    /// keeping the first and last point (so a closed loop stays closed).
    private static func decimate(_ points: [Point2D], to target: Int) -> [Point2D] {
        guard points.count > target, target > 1 else { return points }
        let stride = Double(points.count - 1) / Double(target - 1)
        return (0..<target).map { points[Int((Double($0) * stride).rounded())] }
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
