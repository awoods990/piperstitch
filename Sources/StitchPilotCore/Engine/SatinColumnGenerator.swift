import Foundation

public enum SatinGenerationError: Error, LocalizedError {
    case shapeNotSuitable(String)
    case columnTooWide(maxWidthMM: Double, limitMM: Double)

    public var errorDescription: String? {
        switch self {
        case .shapeNotSuitable(let reason):
            return "This shape isn't a usable satin column: \(reason)"
        case .columnTooWide(let width, let limit):
            return String(format: "This satin column is %.1fmm wide at its widest point, beyond the %.1fmm practical satin limit. Split it into sections or convert it to a fill.", width, limit)
        }
    }
}

/// Generates satin-column stitches for a shape — spec §11/§12. Satin sews a
/// zigzag between two "rails" running the length of a narrow column (a
/// letter stroke, a logo outline segment, a star point), crossing from one
/// rail to the other at regular intervals along the column.
///
/// This first implementation derives the two rails heuristically from a
/// single closed boundary rather than from an author-specified centerline:
/// it finds the shape's elongation direction (principal axis via PCA), then
/// finds the two boundary *edges* whose average position is most extreme
/// along that axis — the column's two end caps — and splits the polygon
/// there, using each end cap's midpoint as the shared start/end point of
/// both rails. Splitting at edges (not vertices) matters: picking whichever
/// two *vertices* are extremal fails on the simplest possible case, an
/// axis-aligned rectangle, where the two vertices of the short "end" side
/// tie in projection and there's no vertex at the true end-cap
/// midpoint — you have to actually find that side (the edge) and cut there.
/// This works well for the common "sausage" case — a single long, roughly
/// symmetric outline (letter strokes, simple logo strokes, star points) —
/// but will misbehave on branching or very irregular shapes; robust
/// centerline/skeleton-based detection for arbitrary geometry is a
/// follow-up (see DIGITIZING_ENGINE.md).
///
/// Known limitation: both rails share a single point at each end cap, so
/// width always tapers to exactly 0 at the very tip. That's correct for a
/// genuinely pointed end (a star point, a leaf tip) but is an approximation
/// for a flat/square-capped column (e.g. a plain rectangle) — real
/// digitizing software typically sews a full-width closing stitch straight
/// across a square end instead of tapering into it. Distinguishing "this
/// end cap is a point" from "this end cap is a flat edge that needs a
/// squared crossing" is a follow-up refinement.
public enum SatinColumnGenerator {
    public static func generate(for shape: VectorShape, parameters: StitchGenerationParameters) throws -> [Point2D] {
        guard let sub = shape.subPaths.first else {
            throw SatinGenerationError.shapeNotSuitable("no outline was provided")
        }
        var polygon = sub.points
        if polygon.count > 1, polygon.first == polygon.last { polygon.removeLast() }
        guard polygon.count >= 4 else {
            throw SatinGenerationError.shapeNotSuitable("the outline needs at least 4 distinct points")
        }

        let (axis, mean) = principalAxis(polygon)
        let (startEdge, endEdge) = endCapEdges(polygon, axis: axis, mean: mean)
        guard startEdge != endEdge else {
            throw SatinGenerationError.shapeNotSuitable("couldn't identify two distinct ends for this outline")
        }

        let n = polygon.count
        let startMid = midpoint(polygon[startEdge], polygon[(startEdge + 1) % n])
        let endMid = midpoint(polygon[endEdge], polygon[(endEdge + 1) % n])

        let railACore = walkForward(polygon, from: (startEdge + 1) % n, to: endEdge)
        let railBCore = Array(walkForward(polygon, from: (endEdge + 1) % n, to: startEdge).reversed())
        let railA = [startMid] + railACore + [endMid]
        let railB = [startMid] + railBCore + [endMid]

        let density = max(parameters.satinDensityMM, 0.1)
        let approxLength = max(pathLength(railA), pathLength(railB))
        let crossingCount = max(2, Int((approxLength / density).rounded()))

        let resampledA = resampleByCount(railA, count: crossingCount)
        let resampledB = resampleByCount(railB, count: crossingCount)

        var maxWidth = 0.0
        var stitches: [Point2D] = []
        for i in 0...crossingCount {
            let a = resampledA[i], b = resampledB[i]
            maxWidth = max(maxWidth, a.distance(to: b))
            stitches.append(a)
            stitches.append(b)
        }

        if maxWidth > parameters.maxSatinWidthMM {
            throw SatinGenerationError.columnTooWide(maxWidthMM: maxWidth, limitMM: parameters.maxSatinWidthMM)
        }

        return stitches
    }

    private static func midpoint(_ a: Point2D, _ b: Point2D) -> Point2D {
        Point2D((a.x + b.x) / 2, (a.y + b.y) / 2)
    }

    /// The polygon's elongation direction (unit vector) via the covariance
    /// matrix's principal eigenvector, and its centroid.
    private static func principalAxis(_ polygon: [Point2D]) -> (axis: Point2D, mean: Point2D) {
        let n = Double(polygon.count)
        let meanX = polygon.reduce(0) { $0 + $1.x } / n
        let meanY = polygon.reduce(0) { $0 + $1.y } / n

        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in polygon {
            let dx = p.x - meanX, dy = p.y - meanY
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }

        // Closed-form principal-axis angle for a 2x2 symmetric covariance matrix.
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        return (Point2D(cos(angle), sin(angle)), Point2D(meanX, meanY))
    }

    /// The two boundary edges whose average projection onto `axis` is most
    /// extreme — the column's two end caps.
    private static func endCapEdges(_ polygon: [Point2D], axis: Point2D, mean: Point2D) -> (Int, Int) {
        func proj(_ p: Point2D) -> Double { (p.x - mean.x) * axis.x + (p.y - mean.y) * axis.y }
        let n = polygon.count
        var startEdge = 0, startVal = Double.infinity
        var endEdge = 0, endVal = -Double.infinity
        for i in 0..<n {
            let avg = (proj(polygon[i]) + proj(polygon[(i + 1) % n])) / 2
            if avg < startVal { startVal = avg; startEdge = i }
            if avg > endVal { endVal = avg; endEdge = i }
        }
        return (startEdge, endEdge)
    }

    /// Walks the closed polygon's boundary forward (increasing index,
    /// wrapping) from `from` to `to`, inclusive of both endpoints.
    private static func walkForward(_ polygon: [Point2D], from: Int, to: Int) -> [Point2D] {
        var result: [Point2D] = [polygon[from]]
        var i = from
        while i != to {
            i = (i + 1) % polygon.count
            result.append(polygon[i])
        }
        return result
    }

    private static func pathLength(_ points: [Point2D]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count { total += points[i - 1].distance(to: points[i]) }
        return total
    }

    /// Resamples a polyline into exactly `count + 1` points, evenly spaced
    /// by fraction of total arc length (not by fixed stitch length) — used
    /// here so both rails produce the same number of points for 1:1
    /// pairing regardless of their individual lengths.
    private static func resampleByCount(_ points: [Point2D], count: Int) -> [Point2D] {
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
