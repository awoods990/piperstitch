import Foundation

/// Generates underlay — a lighter base layer of stitching sewn *before* the
/// object's main stitches to stabilize the fabric and anchor the final
/// stitches to (spec §16). "Users should generally not need to configure
/// underlay manually" (spec §16): `generate` picks a sensible default per
/// stitch type unless `parameters.underlayType` overrides it.
public enum UnderlayGenerator {
    public static func generate(for shape: VectorShape, stitchType: StitchType, parameters: StitchGenerationParameters) -> [Point2D] {
        let effective = parameters.underlayType ?? defaultUnderlay(for: stitchType, shape: shape, parameters: parameters)
        switch effective {
        case .none:
            return []
        case .centerRun:
            return centerRun(shape: shape, parameters: parameters)
        case .edgeRun:
            return edgeRun(shape: shape, parameters: parameters)
        case .zigzag:
            return zigzag(shape: shape, parameters: parameters)
        }
    }

    /// Satin picks between center-run and zigzag by estimated average
    /// width: a single centerline pass stabilizes a narrow column fine,
    /// but a wider zigzag needs more than one line of anchoring stitches
    /// underneath it — the "German underlay" technique (contour-walk +
    /// zigzag together) documented in EMBROIDERY_ALGORITHM_REFERENCE.md,
    /// sourced from studying Ink/Stitch's satin underlay. Avoids
    /// unnecessary underlay on very small objects either way (spec §16).
    private static func defaultUnderlay(for stitchType: StitchType, shape: VectorShape, parameters: StitchGenerationParameters) -> UnderlayType {
        switch stitchType {
        case .satin:
            guard let (railA, railB) = try? SatinColumnGenerator.computeRails(for: shape) else { return .centerRun }
            let sampleCount = 10
            let a = PolygonGeometry.resampleByCount(railA, count: sampleCount)
            let b = PolygonGeometry.resampleByCount(railB, count: sampleCount)
            let averageWidth = zip(a, b).map { $0.distance(to: $1) }.reduce(0, +) / Double(a.count)
            return averageWidth > parameters.zigzagUnderlayWidthThresholdMM ? .zigzag : .centerRun
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

    /// A wider-spaced zigzag between the satin column's rails, inset toward
    /// the centerline so it stays narrower than the final satin coverage —
    /// see the doc comment on `defaultUnderlay` for why this exists
    /// alongside center-run rather than replacing it.
    private static func zigzag(shape: VectorShape, parameters: StitchGenerationParameters) -> [Point2D] {
        guard let (railA, railB) = try? SatinColumnGenerator.computeRails(for: shape) else { return [] }

        let approxLength = max(PolygonGeometry.pathLength(railA), PolygonGeometry.pathLength(railB))
        let spacing = max(parameters.zigzagUnderlaySpacingMM, 0.3)
        let count = max(3, Int((approxLength / spacing).rounded()))
        let resampledA = PolygonGeometry.resampleByCount(railA, count: count)
        let resampledB = PolygonGeometry.resampleByCount(railB, count: count)

        let inset = max(parameters.underlayInsetMM, 0)
        var points: [Point2D] = []
        for i in 0...count {
            let a = resampledA[i], b = resampledB[i]
            let insetA = moveToward(a, target: b, by: inset)
            let insetB = moveToward(b, target: a, by: inset)
            // Alternate which rail comes first each step, so the path
            // actually zigzags instead of running two parallel lines.
            if i % 2 == 0 {
                points.append(insetA); points.append(insetB)
            } else {
                points.append(insetB); points.append(insetA)
            }
        }
        return points
    }

    /// Moves `point` toward `target` by `distance` (clamped so it never overshoots past `target`).
    private static func moveToward(_ point: Point2D, target: Point2D, by distance: Double) -> Point2D {
        guard distance > 0 else { return point }
        let dx = target.x - point.x, dy = target.y - point.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.0001 else { return point }
        let clamped = min(distance, len / 2) // never cross the midpoint -- that would invert the rails
        return Point2D(point.x + dx / len * clamped, point.y + dy / len * clamped)
    }

    /// A running stitch around the shape's boundary, inset inward so it
    /// falls entirely underneath the fill that follows — spec §16 "edge run."
    private static func edgeRun(shape: VectorShape, parameters: StitchGenerationParameters) -> [Point2D] {
        guard let outer = shape.subPaths.first, outer.points.count >= 3 else { return [] }
        let inset = PolygonGeometry.offsetPolygon(outer.points, by: parameters.underlayInsetMM)
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
}
