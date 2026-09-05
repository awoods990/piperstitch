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
    /// Splits a shape's outer boundary into two rails — see the type-level
    /// doc comment for the PCA + edge-based end-cap algorithm. Exposed
    /// (module-internal) so `UnderlayGenerator` can derive a satin column's
    /// centerline from the same two rails `generate` sews between, instead
    /// of recomputing "where is this column's centerline" a second way.
    static func computeRails(for shape: VectorShape) throws -> (railA: [Point2D], railB: [Point2D]) {
        guard let sub = shape.subPaths.first else {
            throw SatinGenerationError.shapeNotSuitable("no outline was provided")
        }
        var polygon = sub.points
        if polygon.count > 1, polygon.first == polygon.last { polygon.removeLast() }
        guard polygon.count >= 4 else {
            throw SatinGenerationError.shapeNotSuitable("the outline needs at least 4 distinct points")
        }

        let (axis, mean) = PolygonGeometry.principalAxis(polygon)
        let (startEdge, endEdge) = endCapEdges(polygon, axis: axis, mean: mean)
        guard startEdge != endEdge else {
            throw SatinGenerationError.shapeNotSuitable("couldn't identify two distinct ends for this outline")
        }

        let n = polygon.count
        let startMid = midpoint(polygon[startEdge], polygon[(startEdge + 1) % n])
        let endMid = midpoint(polygon[endEdge], polygon[(endEdge + 1) % n])

        let railACore = walkForward(polygon, from: (startEdge + 1) % n, to: endEdge)
        let railBCore = Array(walkForward(polygon, from: (endEdge + 1) % n, to: startEdge).reversed())
        return ([startMid] + railACore + [endMid], [startMid] + railBCore + [endMid])
    }

    public static func generate(for shape: VectorShape, parameters: StitchGenerationParameters) throws -> [Point2D] {
        let (railA, railB) = try computeRails(for: shape)

        let density = max(parameters.satinDensityMM, 0.1)
        let approxLength = max(PolygonGeometry.pathLength(railA), PolygonGeometry.pathLength(railB))
        let crossingCount = max(2, Int((approxLength / density).rounded()))

        let resampledA = PolygonGeometry.resampleByCount(railA, count: crossingCount)
        let resampledB = PolygonGeometry.resampleByCount(railB, count: crossingCount)

        let widths = zip(resampledA, resampledB).map { $0.distance(to: $1) }
        let averageWidth = widths.reduce(0, +) / Double(max(1, widths.count))
        let compensation = parameters.pullCompensationMM
            ?? PullCompensationCalculator.estimate(stitchType: .satin, densityMM: density, objectWidthMM: averageWidth)

        var maxWidth = 0.0
        var stitches: [Point2D] = []
        for i in 0...crossingCount {
            let a = resampledA[i], b = resampledB[i]
            // Pull compensation (spec §17): push each rail point outward,
            // away from the crossing's midpoint, so the column sews at the
            // intended width after fabric pulls it narrower. Expanding
            // symmetrically about the midpoint keeps the centerline (and
            // therefore the underlay generated from these same rails)
            // exactly where it was digitized.
            let expandedA = pushOutward(a, from: b, by: compensation / 2)
            let expandedB = pushOutward(b, from: a, by: compensation / 2)
            maxWidth = max(maxWidth, expandedA.distance(to: expandedB))
            stitches.append(expandedA)
            stitches.append(expandedB)
        }

        if maxWidth > parameters.maxSatinWidthMM {
            throw SatinGenerationError.columnTooWide(maxWidthMM: maxWidth, limitMM: parameters.maxSatinWidthMM)
        }

        return stitches
    }

    /// Moves `point` further away from `other` along the line between them, by `distance`.
    private static func pushOutward(_ point: Point2D, from other: Point2D, by distance: Double) -> Point2D {
        guard distance != 0 else { return point }
        let dx = point.x - other.x, dy = point.y - other.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.0001 else { return point }
        return Point2D(point.x + dx / len * distance, point.y + dy / len * distance)
    }

    private static func midpoint(_ a: Point2D, _ b: Point2D) -> Point2D {
        Point2D((a.x + b.x) / 2, (a.y + b.y) / 2)
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

}
