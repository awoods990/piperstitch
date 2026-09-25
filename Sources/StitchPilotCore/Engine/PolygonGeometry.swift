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

    /// Even-odd ray-casting point-in-polygon test: casts a ray from `point`
    /// in the +x direction and counts edge crossings: odd = inside. Treats
    /// `polygon` as implicitly closed (tests the edge from the last point
    /// back to the first), matching every other polygon helper here.
    public static func pointInPolygon(_ point: Point2D, polygon: [Point2D]) -> Bool {
        pointInPolygons(point, polygons: [polygon])
    }

    /// Even-odd ray-casting test across *multiple* closed polygons at
    /// once, combining every polygon's edges into one shared crossing
    /// count — the same technique `TatamiFillGenerator.scanlineCrossings`
    /// uses for a full scanline, just for a single point/single test.
    /// Passing a shape's hole sub-paths alongside its outer boundary gets
    /// hole semantics for free: a point inside the outer loop but also
    /// inside a hole loop toggles twice (even = outside), matching the
    /// even-odd fill rule used everywhere else in this codebase.
    /// How finely a straight connector is checked against a shape. A
    /// counter, a letter's bowl, the gap between an E's arms: the narrow
    /// places a connector must not cross are a couple of millimetres wide,
    /// so the check has to look more often than that.
    public static let insideSampleSpacingMM = 0.4

    /// Whether the straight line from `a` to `b` stays inside `polygons`
    /// the whole way (even-odd, so a hole counts as outside). The
    /// endpoints are excluded deliberately: both sit on the outline by
    /// construction and say nothing about the path between them.
    ///
    /// Sampled by distance, not by a fixed count. Three separate copies of
    /// this test each took five samples whatever the length, so a 20 mm
    /// connector was checked every 3.3 mm and stepped straight over a
    /// 2 mm counter -- which is how a stitch came to run across the gap
    /// between an E's arms. One implementation now, so it can only be
    /// wrong in one place.
    public static func segmentStaysInside(from a: Point2D, to b: Point2D, polygons: [[Point2D]],
                                          spacingMM: Double = insideSampleSpacingMM) -> Bool {
        let length = a.distance(to: b)
        guard length > spacingMM else { return true }
        let steps = max(6, Int((length / max(0.05, spacingMM)).rounded(.up)))
        for step in 1..<steps {
            let t = Double(step) / Double(steps)
            let point = Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            if !pointInPolygons(point, polygons: polygons) { return false }
        }
        return true
    }

    public static func pointInPolygons(_ point: Point2D, polygons: [[Point2D]]) -> Bool {
        var inside = false
        for polygon in polygons {
            guard polygon.count >= 3 else { continue }
            var j = polygon.count - 1
            for i in 0..<polygon.count {
                let pi = polygon[i], pj = polygon[j]
                if (pi.y > point.y) != (pj.y > point.y) {
                    let crossingX = (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x
                    if point.x < crossingX { inside.toggle() }
                }
                j = i
            }
        }
        return inside
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
        guard count > 0 else { return points }
        // A genuinely degenerate rail (a satin column tip collapsed to a
        // single point, or no rail at all) used to just return `points`
        // unchanged here -- breaking this function's own documented
        // contract of always returning `count + 1` points. A caller
        // pairing this rail point-for-point against a normal, fully
        // resampled sibling rail (`SatinColumnGenerator.computeCrossings`)
        // then indexed both with the same index range, crashing outright
        // on the length mismatch. Repeating the single point (matching
        // the identical fallback already used below for a normal-length
        // but zero-length path) keeps the contract instead. See
        // CHANGELOG.md.
        guard points.count > 1 else {
            return points.first.map { Array(repeating: $0, count: count + 1) } ?? points
        }
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

    /// Per-segment lengths of `points`, each scaled up by a curvature
    /// weight based on the turning angle at that segment's trailing
    /// vertex -- shared by `weightedPathLength` and
    /// `resampleByCountCurvatureWeighted`. `curvature ≈ turn / segLength`
    /// (radians per mm) is the standard discretized-curve approximation of
    /// true geometric curvature, and stays roughly independent of how
    /// finely the polyline happens to be flattened (both `turn` and
    /// `segLength` shrink together as flattening gets finer, keeping their
    /// ratio stable). `referenceLengthMM` turns that into a dimensionless
    /// "how tight is this curve relative to how far apart samples
    /// normally are" factor -- in practice, a satin column's own crossing
    /// spacing.
    private static func curvatureWeightedSegmentLengths(_ points: [Point2D], referenceLengthMM: Double, curvatureWeight: Double) -> [Double] {
        guard points.count > 1 else { return [] }
        var lengths: [Double] = []
        for i in 0..<(points.count - 1) {
            let segLength = points[i].distance(to: points[i + 1])
            var weight = 1.0
            if segLength > 1e-6, i + 2 < points.count, referenceLengthMM > 0 {
                let d1x = points[i + 1].x - points[i].x, d1y = points[i + 1].y - points[i].y
                let d2x = points[i + 2].x - points[i + 1].x, d2y = points[i + 2].y - points[i + 1].y
                let len1 = (d1x * d1x + d1y * d1y).squareRoot(), len2 = (d2x * d2x + d2y * d2y).squareRoot()
                if len1 > 1e-9, len2 > 1e-9 {
                    let cosAngle = max(-1, min(1, (d1x * d2x + d1y * d2y) / (len1 * len2)))
                    let turn = acos(cosAngle)
                    let curvature = turn / segLength
                    weight = 1 + curvatureWeight * curvature * referenceLengthMM
                }
            }
            lengths.append(segLength * weight)
        }
        return lengths
    }

    /// The curvature-weighted total length `resampleByCountCurvatureWeighted`
    /// would resample over -- used to size the crossing *count* itself (not
    /// just redistribute a fixed count) so a design with a tight curve gets
    /// genuinely denser coverage there instead of stealing density from its
    /// straight sections to pay for it.
    public static func weightedPathLength(_ points: [Point2D], referenceLengthMM: Double, curvatureWeight: Double) -> Double {
        curvatureWeightedSegmentLengths(points, referenceLengthMM: referenceLengthMM, curvatureWeight: curvatureWeight).reduce(0, +)
    }

    /// Like `resampleByCount`, but weights denser sampling toward regions
    /// of higher local curvature (a sharper turning angle between
    /// consecutive segments) rather than pure even arc length -- a satin
    /// column's crossings need to pack tighter on a tight curve (e.g. a
    /// small "O"'s round stroke) to avoid a faceted, gap-toothed look on
    /// the outside of the curve; pure arc-length spacing treats a tight
    /// curve exactly like a straight run. Falls back to `resampleByCount`
    /// for a too-short polyline (curvature needs at least 3 points to
    /// measure a turning angle at all).
    public static func resampleByCountCurvatureWeighted(_ points: [Point2D], count: Int, referenceLengthMM: Double, curvatureWeight: Double) -> [Point2D] {
        guard points.count > 2, count > 0 else { return resampleByCount(points, count: count) }
        let weightedLengths = curvatureWeightedSegmentLengths(points, referenceLengthMM: referenceLengthMM, curvatureWeight: curvatureWeight)
        let weightedTotal = weightedLengths.reduce(0, +)
        guard weightedTotal > 0 else { return Array(repeating: points[0], count: count + 1) }

        var result: [Point2D] = []
        var segIndex = 0
        var weightedCoveredBeforeSeg = 0.0
        for step in 0...count {
            let targetWeighted = weightedTotal * Double(step) / Double(count)
            while weightedCoveredBeforeSeg + weightedLengths[segIndex] < targetWeighted, segIndex < weightedLengths.count - 1 {
                weightedCoveredBeforeSeg += weightedLengths[segIndex]
                segIndex += 1
            }
            let segWeighted = weightedLengths[segIndex]
            let t = segWeighted > 0 ? min(1, max(0, (targetWeighted - weightedCoveredBeforeSeg) / segWeighted)) : 0
            let a = points[segIndex], b = points[segIndex + 1]
            result.append(Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
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

    /// `polygons` (outer first, then holes) without holes smaller than
    /// `minAreaMM2`. A raster trace leaves pinprick holes of a fraction of
    /// a square millimetre that no stitching can render (thread is
    /// ~0.4 mm wide); to a fill they only split rows and break connectors.
    public static func droppingTinyHoles(_ polygons: [[Point2D]], minAreaMM2: Double) -> [[Point2D]] {
        guard polygons.count > 1 else { return polygons }
        return [polygons[0]] + polygons.dropFirst().filter { abs(signedArea($0)) >= minAreaMM2 }
    }

    /// Clips `polygon` against an axis-aligned rectangle via Sutherland-
    /// Hodgman -- clips sequentially against each of the rectangle's four
    /// half-planes, correct for any simple subject polygon (concave
    /// included) against this convex clip window. Used by
    /// `TatamiFillGenerator`'s basket-weave fill (`FillPattern` doesn't
    /// carry this -- it's automatic, triggered purely by a large enough
    /// shape) to split a large region into cells with an alternating fill
    /// angle. Returns an empty array when the polygon doesn't intersect
    /// the rectangle at all.
    ///
    /// Known limitation shared with any basic Sutherland-Hodgman clip: a
    /// CONCAVE subject polygon that dips out of the rectangle and back in
    /// within one clipped pass can come back as one polygon with a
    /// zero-width "bridge" edge connecting what's geometrically two
    /// separate pieces, rather than two genuinely disjoint output
    /// polygons. Harmless for this call site specifically -- the result
    /// only ever feeds `TatamiFillGenerator`'s even-odd *scanline*
    /// crossing count, where a zero-width bridge contributes a
    /// self-cancelling enter/exit pair at the same position and doesn't
    /// change which side of any real scanline position reads as inside.
    public static func clipPolygonToRect(_ polygon: [Point2D], minX: Double, minY: Double, maxX: Double, maxY: Double) -> [Point2D] {
        guard polygon.count >= 3 else { return [] }

        func clipEdge(_ points: [Point2D], inside: (Point2D) -> Bool, intersect: (Point2D, Point2D) -> Point2D) -> [Point2D] {
            guard !points.isEmpty else { return [] }
            var result: [Point2D] = []
            var prev = points[points.count - 1]
            var prevInside = inside(prev)
            for cur in points {
                let curInside = inside(cur)
                if curInside {
                    if !prevInside { result.append(intersect(prev, cur)) }
                    result.append(cur)
                } else if prevInside {
                    result.append(intersect(prev, cur))
                }
                prev = cur
                prevInside = curInside
            }
            return result
        }

        // An intersect function is only ever invoked on an edge that
        // actually crosses its corresponding boundary (`inside` differs
        // between the edge's two endpoints), so the denominator below is
        // guaranteed nonzero -- two points on the same side of a vertical
        // (or horizontal) test line can't have equal x (or y) AND differ
        // on which side of it they're on.
        func intersectX(_ a: Point2D, _ b: Point2D, x: Double) -> Point2D {
            let t = (x - a.x) / (b.x - a.x)
            return Point2D(x, a.y + (b.y - a.y) * t)
        }
        func intersectY(_ a: Point2D, _ b: Point2D, y: Double) -> Point2D {
            let t = (y - a.y) / (b.y - a.y)
            return Point2D(a.x + (b.x - a.x) * t, y)
        }

        var output = polygon
        output = clipEdge(output, inside: { $0.x >= minX }, intersect: { intersectX($0, $1, x: minX) })
        output = clipEdge(output, inside: { $0.x <= maxX }, intersect: { intersectX($0, $1, x: maxX) })
        output = clipEdge(output, inside: { $0.y >= minY }, intersect: { intersectY($0, $1, y: minY) })
        output = clipEdge(output, inside: { $0.y <= maxY }, intersect: { intersectY($0, $1, y: maxY) })
        return output
    }
}
