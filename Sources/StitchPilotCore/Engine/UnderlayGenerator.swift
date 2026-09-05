import Foundation

/// Generates underlay — a lighter base layer of stitching sewn *before* the
/// object's main stitches to stabilize the fabric and anchor the final
/// stitches to (spec §16). "Users should generally not need to configure
/// underlay manually" (spec §16): `generate` picks a sensible default per
/// stitch type unless `parameters.underlayType` overrides it.
public enum UnderlayGenerator {
    public static func generate(for shape: VectorShape, stitchType: StitchType, parameters: StitchGenerationParameters) -> [Point2D] {
        let effective = parameters.underlayType ?? defaultUnderlay(for: stitchType)
        switch effective {
        case .none:
            return []
        case .centerRun:
            return centerRun(shape: shape, parameters: parameters)
        case .edgeRun:
            return edgeRun(shape: shape, parameters: parameters)
        }
    }

    private static func defaultUnderlay(for stitchType: StitchType) -> UnderlayType {
        switch stitchType {
        case .satin: return .centerRun
        case .tatamiFill: return .edgeRun
        case .runningStitch, .tripleRun: return .none // already a single light pass; no fabric buildup to stabilize
        }
    }

    /// A running stitch along a satin column's centerline (the average of
    /// its two rails), inset from the true ends so the underlay doesn't
    /// poke out past the satin's own tapered tips — spec §16: underlay
    /// selection depends on "object geometry, stitch type... width."
    private static func centerRun(shape: VectorShape, parameters: StitchGenerationParameters) -> [Point2D] {
        guard let (railA, railB) = try? SatinColumnGenerator.computeRails(for: shape) else { return [] }

        let approxLength = max(PolygonGeometry.pathLength(railA), PolygonGeometry.pathLength(railB))
        let count = max(4, Int((approxLength / max(parameters.underlayStitchLengthMM, 0.5)).rounded()))
        let resampledA = PolygonGeometry.resampleByCount(railA, count: count)
        let resampledB = PolygonGeometry.resampleByCount(railB, count: count)

        let centerline = zip(resampledA, resampledB).map { Point2D(($0.x + $1.x) / 2, ($0.y + $1.y) / 2) }
        let inset = trimPolylineEnds(centerline, insetMM: parameters.underlayInsetMM)
        guard inset.count > 1 else { return [] }

        return RunningStitchGenerator.generate(for: SubPath(points: inset, closed: false),
                                                stitchLengthMM: parameters.underlayStitchLengthMM, minStitchLengthMM: 0.4)
    }

    /// A running stitch around the shape's boundary, inset inward so it
    /// falls entirely underneath the fill that follows — spec §16 "edge run."
    private static func edgeRun(shape: VectorShape, parameters: StitchGenerationParameters) -> [Point2D] {
        guard let outer = shape.subPaths.first, outer.points.count >= 3 else { return [] }
        let inset = insetPolygon(outer.points, by: parameters.underlayInsetMM)
        guard inset.count >= 3 else { return [] }
        return RunningStitchGenerator.generate(for: SubPath(points: inset, closed: true),
                                                stitchLengthMM: parameters.underlayStitchLengthMM, minStitchLengthMM: 0.4)
    }

    /// Removes the first/last `insetMM` of arc length from an open
    /// polyline, interpolating new endpoints exactly at that distance.
    private static func trimPolylineEnds(_ points: [Point2D], insetMM: Double) -> [Point2D] {
        guard points.count > 1, insetMM > 0 else { return points }
        let total = PolygonGeometry.pathLength(points)
        guard total > insetMM * 2 else { return [] } // too short to inset at all

        func pointAtDistance(_ target: Double) -> (point: Point2D, index: Int) {
            var covered = 0.0
            for i in 1..<points.count {
                let segLen = points[i - 1].distance(to: points[i])
                if covered + segLen >= target || i == points.count - 1 {
                    let t = segLen > 0 ? min(1, max(0, (target - covered) / segLen)) : 0
                    let a = points[i - 1], b = points[i]
                    return (Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t), i)
                }
                covered += segLen
            }
            return (points.last!, points.count - 1)
        }

        let (startPoint, startIndex) = pointAtDistance(insetMM)
        let (endPoint, endIndex) = pointAtDistance(total - insetMM)
        guard startIndex <= endIndex else { return [startPoint, endPoint] }

        var result: [Point2D] = [startPoint]
        result.append(contentsOf: points[startIndex..<endIndex])
        result.append(endPoint)
        return result
    }

    /// Naive per-vertex polygon erosion: moves each vertex inward along the
    /// average of its two adjacent edges' inward normals. This is an
    /// approximation — it doesn't handle self-intersection on sharp
    /// concave corners the way a true straight-skeleton/Minkowski offset
    /// would — adequate for the modest 1mm-scale insets underlay uses, on
    /// the mildly-concave shapes typical of logos and lettering; a robust
    /// general polygon offset is a follow-up.
    private static func insetPolygon(_ polygon: [Point2D], by insetMM: Double) -> [Point2D] {
        guard polygon.count >= 3, insetMM > 0 else { return polygon }
        var pts = polygon
        if pts.first == pts.last { pts.removeLast() }
        let n = pts.count
        guard n >= 3 else { return polygon }

        // Inward normal direction depends on winding: CCW interior is to
        // the left of each directed edge, CW interior is to the right.
        let isCCW = PolygonGeometry.signedArea(pts) > 0

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
            result.append(Point2D(cur.x + avg.x * insetMM, cur.y + avg.y * insetMM))
        }
        return result
    }
}
