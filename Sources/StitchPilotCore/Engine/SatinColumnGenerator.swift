import Foundation

public enum SatinGenerationError: Error, LocalizedError {
    case shapeNotSuitable(String)
    case columnTooWide(maxWidthMM: Double, limitMM: Double)
    case columnTooNarrow(minWidthMM: Double, limitMM: Double)

    public var errorDescription: String? {
        switch self {
        case .shapeNotSuitable(let reason):
            return "This shape isn't a usable satin column: \(reason)"
        case .columnTooWide(let width, let limit):
            return String(format: "This satin column is %.1fmm wide at its widest point, beyond the %.1fmm practical satin limit. Split it into sections or convert it to a fill.", width, limit)
        case .columnTooNarrow(let width, let limit):
            return String(format: "This satin column narrows to %.1fmm, below the %.1fmm practical minimum. Sew it as a running/triple-run line instead.", width, limit)
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
/// An end cap either tapers to a single shared point (a genuinely pointed
/// end -- a star point, a leaf tip) or squares off across the full width
/// at once (a flat end -- a plain rectangle, most letter strokes' actual
/// top/bottom), decided per end from the end-cap edge's own length (see
/// `squareCapMinEdgeLengthMM`) rather than always tapering.
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
        // Neither rail technique below can represent more than one hole:
        // the ring path takes exactly one, and the open-column path only
        // ever looks at the outer boundary. Silently walking that outer
        // boundary alone used to "succeed" here for a two-counter "B" --
        // one column swept straight across both counters as if they
        // weren't there. That output was normally masked because the
        // walk also twisted and was rejected downstream, but on the real
        // Red Sox "B" a one-pixel change to the outline was enough for it
        // to pass the twist check and sew a solid red slab over the
        // counters, pre-empting the branching path that actually handles
        // multi-hole shapes (`DigitizePipeline` only falls through to
        // `generateBranchingRuns` once this path throws).
        guard shape.subPaths.count <= 2 else {
            throw SatinGenerationError.shapeNotSuitable("a single satin column can't represent more than one hole")
        }

        // A shape with exactly one hole (a letterform counter -- O, P, R,
        // A, D, Q...) is a genuine ring, not a "sausage" with two ends --
        // route it to the closed-loop rail computation below instead of
        // the open-column, end-cap-based logic beneath it, which has no
        // way to represent this (its rails always taper to a single
        // shared point at each "end," which doesn't exist on a ring).
        if shape.subPaths.count == 2 {
            var outer = sub.points
            var hole = shape.subPaths[1].points
            if outer.count > 1, outer.first == outer.last { outer.removeLast() }
            if hole.count > 1, hole.first == hole.last { hole.removeLast() }
            return try computeRingRails(outer: outer, hole: hole)
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
        let railACore = walkForward(polygon, from: (startEdge + 1) % n, to: endEdge)
        let railBCore = Array(walkForward(polygon, from: (endEdge + 1) % n, to: startEdge).reversed())

        // `railACore`/`railBCore` already start and end at the end-cap
        // edges' own two corner vertices -- for a genuinely FLAT end (the
        // edge itself is a real, meaningful length, not a near-coincident
        // point), those two corners ARE the squared crossing: railACore's
        // end starts at one corner, railBCore's at the other, giving full
        // column width right at the tip instead of tapering into it. Only
        // a genuinely POINTED end (the edge's two corners are essentially
        // the same point, as a flattened bezier's true tip is) needs the
        // shared midpoint prepended/appended to taper to zero width.
        let startEdgeLengthMM = polygon[startEdge].distance(to: polygon[(startEdge + 1) % n])
        let endEdgeLengthMM = polygon[endEdge].distance(to: polygon[(endEdge + 1) % n])
        let startIsSquare = startEdgeLengthMM >= squareCapMinEdgeLengthMM
        let endIsSquare = endEdgeLengthMM >= squareCapMinEdgeLengthMM

        let startMid = startIsSquare ? nil : midpoint(polygon[startEdge], polygon[(startEdge + 1) % n])
        let endMid = endIsSquare ? nil : midpoint(polygon[endEdge], polygon[(endEdge + 1) % n])

        let railA = [startMid].compactMap { $0 } + railACore + [endMid].compactMap { $0 }
        let railB = [startMid].compactMap { $0 } + railBCore + [endMid].compactMap { $0 }
        return (railA, railB)
    }

    /// Below this end-cap edge length, an end is treated as a genuine
    /// point (tapered) rather than squared -- a flattened bezier's true
    /// tip has its two "corner" vertices essentially coincident (a
    /// fraction of a mm apart at most), while a real flat end (a plain
    /// rectangle's short side, most letter strokes' top/bottom) has an
    /// edge length that's a meaningful fraction of the column's own
    /// width, generally at least a few tenths of a mm even for a fine
    /// stroke.
    private static let squareCapMinEdgeLengthMM = 0.5

    /// How strongly `computeCrossings` packs extra crossings into a tight
    /// curve -- see `PolygonGeometry.curvatureWeightedSegmentLengths`'s doc
    /// comment for the exact formula. At a curve whose radius equals the
    /// column's own crossing spacing (`satinDensityMM`), this roughly
    /// triples the local crossing density; a gentle curve (radius large
    /// relative to crossing spacing) is barely affected. Chosen as a
    /// moderate default -- strong enough to visibly fix a small round
    /// letter's faceted outer edge, not so strong that an ordinary curve
    /// balloons in stitch count for no visible benefit.
    private static let curvatureDensityWeight = 3.0

    /// How many angles `computeRingRails` samples around the full circle --
    /// dense enough to faithfully represent a typical letterform counter's
    /// shape (including corners, e.g. a rectangular counter) before
    /// `computeCrossings`'s own resampling reduces it to the actual
    /// stitch-density crossing count.
    private static let ringRailSampleCount = 120

    /// For a genuine ring -- an outer boundary with exactly one enclosed
    /// hole (a letterform counter: O, P, R, A, D, Q...) -- computes two
    /// CLOSED rails by radially sampling both boundaries from a point
    /// inside the hole: for `ringRailSampleCount` evenly-spaced angles
    /// around the full circle, casts a ray from that center and finds
    /// where it first crosses the hole boundary (rail B) and the outer
    /// boundary (rail A).
    ///
    /// This keeps the two rails in angular correspondence *by
    /// construction* -- unlike the arc-length-based pairing the open-
    /// column case above relies on, it can't produce a "twisted" zigzag
    /// where a crossing's two endpoints aren't roughly radially opposite
    /// each other. It also handles an off-center hole correctly (P, R --
    /// the counter sits in the upper half, not the middle of the whole
    /// glyph) since the ray origin is the HOLE's own center, not the
    /// outer shape's -- a ray from a point that's guaranteed to be inside
    /// the hole reliably sweeps the entire hole boundary and then
    /// continues out to the (possibly much-further-away-on-one-side)
    /// outer boundary, which is exactly the varying stroke width a real
    /// "P" or "R" actually has around its counter.
    ///
    /// Both returned rails are explicitly closed (their first point
    /// repeated at the end) -- the signal every other piece of code that
    /// consumes `computeRails`'s result checks (via `railA.first ==
    /// railA.last`) to know this column has no real "ends" to trim/taper,
    /// unlike an open stroke: `computeCrossings`'s push-compensation
    /// trimming and `UnderlayGenerator.centerRun`'s end-inset both skip
    /// themselves for a closed rail rather than cutting an arbitrary gap
    /// into otherwise-continuous coverage at wherever this function
    /// happened to start sampling.
    private static func computeRingRails(outer: [Point2D], hole: [Point2D]) throws -> (railA: [Point2D], railB: [Point2D]) {
        guard outer.count >= 3, hole.count >= 3 else {
            throw SatinGenerationError.shapeNotSuitable("the ring's outline needs at least 3 distinct points on each boundary")
        }
        let center = vertexAverage(hole)
        guard PolygonGeometry.pointInPolygons(center, polygons: [hole]) else {
            throw SatinGenerationError.shapeNotSuitable("couldn't find a usable center point inside this hole")
        }

        var railA: [Point2D] = []
        var railB: [Point2D] = []
        for i in 0..<ringRailSampleCount {
            let theta = 2 * Double.pi * Double(i) / Double(ringRailSampleCount)
            let direction = Point2D(cos(theta), sin(theta))
            guard let holeHit = rayPolygonIntersection(origin: center, direction: direction, polygon: hole),
                  let outerHit = rayPolygonIntersection(origin: center, direction: direction, polygon: outer) else {
                continue // this angle missed one of the boundaries (a concavity) -- skip it
            }
            railB.append(holeHit)
            railA.append(outerHit)
        }
        // A handful of missed angles (concavities) is fine; if most angles
        // missed, this hole's shape is too irregular for a simple radial
        // sweep from one center to represent reliably.
        guard railA.count >= ringRailSampleCount * 3 / 4 else {
            throw SatinGenerationError.shapeNotSuitable("couldn't trace a consistent ring column around this hole")
        }

        if let firstA = railA.first, let firstB = railB.first {
            railA.append(firstA)
            railB.append(firstB)
        }
        return (railA, railB)
    }

    /// A coarse centroid (plain vertex average, matching the same
    /// approximation `PolygonGeometry.principalAxis` already uses
    /// elsewhere in this engine, not an area-weighted centroid) -- good
    /// enough as a ray-casting origin for the reasonably-convex shapes
    /// letterform counters actually are.
    private static func vertexAverage(_ points: [Point2D]) -> Point2D {
        let n = Double(points.count)
        let sx = points.reduce(0) { $0 + $1.x }
        let sy = points.reduce(0) { $0 + $1.y }
        return Point2D(sx / n, sy / n)
    }

    /// The nearest point (smallest positive `t`) where the ray from
    /// `origin` in `direction` crosses `polygon`'s boundary, or nil if it
    /// doesn't cross at all. Standard ray/segment intersection via each
    /// edge's own parametric form; `direction` need not be normalized.
    private static func rayPolygonIntersection(origin: Point2D, direction: Point2D, polygon: [Point2D]) -> Point2D? {
        var bestT: Double?
        let n = polygon.count
        let perp = Point2D(-direction.y, direction.x)
        for i in 0..<n {
            let a = polygon[i], b = polygon[(i + 1) % n]
            let v1x = origin.x - a.x, v1y = origin.y - a.y
            let v2x = b.x - a.x, v2y = b.y - a.y
            let denom = v2x * perp.x + v2y * perp.y
            guard abs(denom) > 1e-9 else { continue } // parallel to this edge
            let t = (v2x * v1y - v2y * v1x) / denom
            let s = (v1x * perp.x + v1y * perp.y) / denom
            guard t > 1e-6, s >= -1e-6, s <= 1 + 1e-6 else { continue }
            if bestT == nil || t < bestT! { bestT = t }
        }
        guard let t = bestT else { return nil }
        return Point2D(origin.x + t * direction.x, origin.y + t * direction.y)
    }

    /// Like `rayPolygonIntersection`, but against every one of a shape's
    /// boundaries at once (outer plus every hole), returning every
    /// crossing found across all of them ordered nearest-first —
    /// `computeSegmentRails` only ever wants the very nearest (a
    /// branching segment's rail can pass near, or between, more than one
    /// hole at once — a "B"'s stem sits between its two bowls' counters
    /// — and a ray cast only against the outer boundary would sail
    /// straight through an intervening hole to the far side, well past
    /// where the segment's own rail should actually stop), but
    /// `computeSegmentRingRails` below wants the nearest *two*: for a
    /// self-loop edge (a hole's own skeleton loop), the first crossing
    /// from its centroid is the hole's own boundary and the second is
    /// whatever lies beyond it — normally the outer boundary, the same
    /// pair `computeRingRails` gets by querying its one hole and one
    /// outer polygon separately, just generalized to however many
    /// boundaries a branching shape's full set of sub-paths has.
    private static func rayPolygonsIntersections(origin: Point2D, direction: Point2D, polygons: [[Point2D]]) -> [Point2D] {
        var hits: [(t: Double, point: Point2D)] = []
        let perp = Point2D(-direction.y, direction.x)
        for polygon in polygons {
            guard polygon.count >= 3 else { continue }
            let n = polygon.count
            for i in 0..<n {
                let a = polygon[i], b = polygon[(i + 1) % n]
                let v1x = origin.x - a.x, v1y = origin.y - a.y
                let v2x = b.x - a.x, v2y = b.y - a.y
                let denom = v2x * perp.x + v2y * perp.y
                guard abs(denom) > 1e-9 else { continue }
                let t = (v2x * v1y - v2y * v1x) / denom
                let s = (v1x * perp.x + v1y * perp.y) / denom
                guard t > 1e-6, s >= -1e-6, s <= 1 + 1e-6 else { continue }
                hits.append((t, Point2D(origin.x + t * direction.x, origin.y + t * direction.y)))
            }
        }
        return hits.sorted { $0.t < $1.t }.map { $0.point }
    }

    /// The nearest crossing only — see `rayPolygonsIntersections`'s own
    /// doc comment.
    private static func rayPolygonsIntersection(origin: Point2D, direction: Point2D, polygons: [[Point2D]]) -> Point2D? {
        rayPolygonsIntersections(origin: origin, direction: direction, polygons: polygons).first
    }

    /// The nearest point on any of `polygons`' own edges to `point`,
    /// restricted to whichever side of `point` the `perp` direction
    /// (`side: 1` or `-1`) picks out — `computeSegmentRails`' actual
    /// rail-fitting primitive for an open branch segment, in place of a
    /// single fixed-direction ray-cast.
    ///
    /// A ray-cast only ever finds a boundary point that happens to sit
    /// exactly along one fixed direction from the sample; a genuine
    /// medial-axis point near a CORNER, though, can be the true nearest
    /// point to many *different* tangent directions along a curving or
    /// widening segment (the corner's distance stays roughly the same
    /// while the ray direction sweeps right past it) — a fixed-direction
    /// ray only hits that corner from the one sample where the angle
    /// happens to line up, and at every neighboring sample either misses
    /// it (finding a much farther point along its own fixed direction, or
    /// nothing at all) or, if the tangent is rotating, snaps onto and off
    /// the corner in a way that isn't continuous from one sample to the
    /// next. Found directly against a real raster-traced "B" logo (Boston
    /// Red Sox): its stem, curving up into the wide junction where both
    /// bowls meet, produced a rail whose B side stayed pinned to the same
    /// physical corner for many consecutive samples while its A side kept
    /// advancing along the smooth outer boundary — width climbing from
    /// ~4mm to ~10mm over a handful of samples, which is exactly the kind
    /// of asymmetric "fan" `isTwisted` correctly flags, but here it was a
    /// real geometric consequence of the ray-casting technique itself, not
    /// raster noise (which `smoothedPolyline` above already accounts for
    /// separately). Searching for the nearest point directly, rather than
    /// only along one fixed ray, tracks the true medial-axis pairing
    /// continuously as the sample moves — including smoothly approaching
    /// and leaving a corner, rather than only ever finding it from one
    /// exact angle.
    private static func nearestBoundaryPoint(from point: Point2D, perp: Point2D, side: Double, polygons: [[Point2D]]) -> Point2D? {
        var best: Point2D?
        var bestDistSq = Double.infinity
        for polygon in polygons {
            guard polygon.count >= 2 else { continue }
            let n = polygon.count
            for i in 0..<n {
                let a = polygon[i], b = polygon[(i + 1) % n]
                let candidate = nearestPointOnSegment(point, a, b)
                let dx = candidate.x - point.x, dy = candidate.y - point.y
                let dot = dx * perp.x + dy * perp.y
                guard dot * side >= 0 else { continue }
                let distSq = dx * dx + dy * dy
                if distSq < bestDistSq { bestDistSq = distSq; best = candidate }
            }
        }
        return best
    }

    /// The closest point to `p` lying on the segment `a`-`b` (clamped to
    /// the segment, not the infinite line through it).
    private static func nearestPointOnSegment(_ p: Point2D, _ a: Point2D, _ b: Point2D) -> Point2D {
        let abx = b.x - a.x, aby = b.y - a.y
        let lenSq = abx * abx + aby * aby
        guard lenSq > 1e-12 else { return a }
        let t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq
        let clamped = max(0, min(1, t))
        return Point2D(a.x + clamped * abx, a.y + clamped * aby)
    }

    /// Whether `shape` -- a single-boundary (no-hole) outline -- can be
    /// represented as one well-formed satin column with this engine's
    /// current rail-fitting: `computeRails` succeeds and the resulting
    /// crossings don't twist (see `isTwisted`'s own doc comment). Used by
    /// `StitchTypeClassifier.classifyLetteringRun` to check every glyph in
    /// a lettering run up front, not just measure width -- a genuinely
    /// branching letter (H's two stems joined by a crossbar) can't be a
    /// single satin column regardless of width, and rather than that one
    /// letter alone falling back to a different stitch type (visually
    /// inconsistent with its neighbors), the whole run falls back to
    /// tatami fill together. Cheap enough to call once per glyph at
    /// classification time -- it does the same rail/crossing computation
    /// `generatePartial` would, just checked and discarded here rather
    /// than kept.
    public static func canRepresentAsSingleSatinColumn(shape: VectorShape, parameters: StitchGenerationParameters) -> Bool {
        guard shape.subPaths.count == 1 else { return false }
        return (try? computeCrossings(for: shape, parameters: parameters)) != nil
    }

    public static func generate(for shape: VectorShape, parameters: StitchGenerationParameters) throws -> [Point2D] {
        let crossings = try computeCrossings(for: shape, parameters: parameters)

        let maxWidth = crossings.widths.max() ?? 0
        if maxWidth > parameters.maxSatinWidthMM {
            throw SatinGenerationError.columnTooWide(maxWidthMM: maxWidth, limitMM: parameters.maxSatinWidthMM)
        }

        // Only check "too narrow" in the interior (see `interiorRange`):
        // every column tapers to near-zero width at its very tips by
        // design (see this type's own doc comment on tapered end caps),
        // which isn't the same thing as being impractically narrow
        // throughout a real section of the column.
        let interior = interiorRange(count: crossings.widths.count)
        // A mitred corner's crossings taper to the tip by design (see
        // `SatinCorners`), the same way the end caps do.
        if let minWidth = interior.filter({ !crossings.mitre[$0] }).map({ crossings.widths[$0] }).min(), minWidth < parameters.minSatinWidthMM {
            throw SatinGenerationError.columnTooNarrow(minWidthMM: minWidth, limitMM: parameters.minSatinWidthMM)
        }

        var stitches: [Point2D] = []
        for i in 0..<crossings.expandedA.count {
            stitches.append(crossings.expandedA[i])
            stitches.append(crossings.expandedB[i])
        }
        return stitches
    }

    /// The crossing-index range excluded from natural end-cap tapering —
    /// both `generate`'s strict narrow check and `generatePartial`'s
    /// narrow-run detection only look here, since a genuinely POINTED
    /// column's width tapers toward zero at its very tips by construction
    /// (both rails share a single point at that end cap), which would
    /// otherwise make every such column look "too narrow" right where it's
    /// supposed to. A SQUARED end cap (see `squareCapMinEdgeLengthMM`)
    /// doesn't actually taper, so excluding this same margin there is
    /// simply a slightly wider safety margin than strictly needed, not
    /// incorrect -- not worth branching the two cases apart just for that.
    /// Mirrors the margin used by `SatinColumnGeneratorTests` to exclude
    /// the same zone when checking width against an expected value.
    private static func interiorRange(count: Int) -> Range<Int> {
        let margin = min(count / 2, max(2, count / 10))
        return margin..<(count - margin)
    }

    /// True when any two ADJACENT crossings, within the column's interior
    /// (see `interiorRange`, which excludes natural end-cap tapering near
    /// the tips), geometrically cross each other as line segments -- the
    /// direct, literal version of the visible defect this guards against
    /// (a satin column whose zigzag crosses over itself, rendering as a
    /// tangled mess rather than a smooth column). This can happen even
    /// when the crossing *direction* only changes moderately from one to
    /// the next (checking for an outright >90° reversal missed real
    /// cases, e.g. a real "H" glyph, where the two rails don't visibly
    /// reverse but still pinch through each other) -- an actual segment
    /// intersection test catches it regardless of how gradually or
    /// sharply the crossing rotates.
    private static func isTwisted(_ resampledA: [Point2D], _ resampledB: [Point2D]) -> Bool {
        let count = resampledA.count
        guard count > 2 else { return false }
        return isTwisted(resampledA, resampledB, within: interiorRange(count: count))
    }

    /// The same adjacent-crossing intersection test restricted to `range`
    /// -- `branchingPlan` passes the whole segment's own `interiorRange`
    /// intersected with the crossings it will actually sew, so a segment
    /// trimmed at a junction end is never checked MORE strictly than the
    /// untrimmed segment would have been (a margin recomputed from the
    /// shorter kept range shrinks at the far, untrimmed end too, exposing
    /// a tapering tip's own natural end twist that the full-length margin
    /// correctly ignores -- found directly against a real cap-logo "B" at
    /// 100mm, whose hook tip started failing the moment its junction end
    /// was trimmed).
    private static func isTwisted(_ resampledA: [Point2D], _ resampledB: [Point2D], within range: Range<Int>) -> Bool {
        let count = resampledA.count
        guard range.count > 1 else { return false }
        for i in range where i + 1 < count {
            let a0 = resampledA[i], b0 = resampledB[i], a1 = resampledA[i + 1], b1 = resampledB[i + 1]
            guard segmentsIntersect(a0, b0, a1, b1), let p = intersectionPoint(a0, b0, a1, b1) else { continue }
            // Two adjacent crossings that meet right at one of their own
            // endpoints are FANNING, not twisted: at a tight inside bend
            // the inner rail stalls (several consecutive crossings share
            // nearly the same inner point) while the outer rail sweeps
            // on, so consecutive crossings pivot about that inner point
            // and, with a hair of backward drift in it, technically cross
            // there. That's what satin is supposed to do at an inside
            // corner. A genuine twist -- the two rails having swapped
            // sides, or scissoring in opposite directions past each
            // other -- crosses well inside both crossings, away from any
            // endpoint. Found directly against the 96px Red Sox "B" at
            // 100mm, where each source pixel is ~1mm and the bottom
            // bowl's inside corner is a literal sharp vertex.
            let nearEndpoint = [a0, b0, a1, b1].contains { $0.distance(to: p) <= fanPivotToleranceMM }
            if !nearEndpoint { return true }
        }
        return false
    }

    /// How close to one of its own endpoints two adjacent crossings may
    /// intersect and still count as a fan about that endpoint rather than
    /// a twist -- see `isTwisted(_:_:within:)`. A stalled inner rail
    /// drifts by a few hundredths of a mm per crossing; a real twist's
    /// intersection sits millimeters from every endpoint.
    private static let fanPivotToleranceMM = 0.5

    /// Where segments `p1`-`p2` and `p3`-`p4` cross, given that
    /// `segmentsIntersect` already said they do (nil only if the two are
    /// parallel, which that test excludes).
    private static func intersectionPoint(_ p1: Point2D, _ p2: Point2D, _ p3: Point2D, _ p4: Point2D) -> Point2D? {
        let r = p2 - p1, s = p4 - p3
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-12 else { return nil }
        let qp = p3 - p1
        let t = (qp.x * s.y - qp.y * s.x) / denominator
        return p1 + r * t
    }

    /// True when any interior crossing OR zigzag connector's own midpoint
    /// falls outside the shape's actual boundary -- catches a column whose
    /// rails don't correspond to a real column even when they never
    /// directly cross each other (`isTwisted`'s own check): a concave bend
    /// (e.g. an "L", two straight strokes meeting at a right angle) can
    /// rail-walk into a single crossing -- or, just as easily, the zigzag
    /// path's own *connector* between one crossing and the next
    /// (`generate`'s actual stitch order alternates A[i], B[i], A[i+1],
    /// B[i+1]... -- the connector is the B[i]-to-A[i+1] leg) -- that spans
    /// straight across the shape's own empty notch, without ever
    /// intersecting a neighboring segment. A real column's centerline,
    /// which is what every one of these midpoints traces, should never
    /// leave its own outline.
    static func crossingsEscapeTheShape(_ resampledA: [Point2D], _ resampledB: [Point2D], polygon: [Point2D]) -> Bool {
        let count = resampledA.count
        guard count > 2, polygon.count >= 3 else { return false }
        let interior = interiorRange(count: count)
        guard interior.count > 1 else { return false }
        for i in interior {
            if !PolygonGeometry.pointInPolygon(midpoint(resampledA[i], resampledB[i]), polygon: polygon) {
                return true
            }
            if i + 1 < count, interior.contains(i + 1),
               !PolygonGeometry.pointInPolygon(midpoint(resampledB[i], resampledA[i + 1]), polygon: polygon) {
                return true
            }
        }
        return false
    }

    /// Standard strict segment/segment intersection test via orientation
    /// signs (cross products) -- true only for a genuine crossing, not
    /// segments that merely touch at a shared endpoint or run collinear.
    private static func segmentsIntersect(_ p1: Point2D, _ p2: Point2D, _ p3: Point2D, _ p4: Point2D) -> Bool {
        func cross(_ o: Point2D, _ a: Point2D, _ b: Point2D) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        let d1 = cross(p3, p4, p1), d2 = cross(p3, p4, p2)
        let d3 = cross(p1, p2, p3), d4 = cross(p1, p2, p4)
        return ((d1 > 0) != (d2 > 0)) && (d1 != 0) && (d2 != 0)
            && ((d3 > 0) != (d4 > 0)) && (d3 != 0) && (d4 != 0)
    }

    /// Both rails resampled to their final crossing positions: a fine,
    /// curvature-weighted grid at `density / SatinSpacing.oversampling`,
    /// thinned by `SatinSpacing.decimate` to width-dependent spacing.
    /// Returns the rails and `count` such that valid indices are
    /// `0...count`, matching what the former direct resample produced.
    private static func fineThenDecimatedRails(railA: [Point2D], railB: [Point2D], density: Double, parameters: StitchGenerationParameters) -> (railA: [Point2D], railB: [Point2D], count: Int, mitre: [Bool]) {
        let fineDensity = density / SatinSpacing.oversampling
        let (fineA, fineB, fineMitre) = fineRails(railA: railA, railB: railB, fineDensity: fineDensity, parameters: parameters)
        let kept = SatinSpacing.decimate(railA: fineA, railB: fineB, parameters: parameters, flags: fineMitre)
        // Never fewer than three crossings (two for a degenerate stub):
        // `interiorRange` and the twist checks assume a real column.
        if kept.a.count < 3, fineA.count >= 3 {
            let mid = fineA.count / 2
            return ([fineA[0], fineA[mid], fineA[fineA.count - 1]], [fineB[0], fineB[mid], fineB[fineB.count - 1]], 2, [false, false, false])
        }
        return (kept.a, kept.b, kept.a.count - 1, kept.flags)
    }

    /// Both rails on the fine grid, proportionally matched piece by piece
    /// between mitred corners (`SatinCorners`), with each corner square's
    /// own mitre crossings in between. Without corners this is one
    /// proportional match of the whole rails, as it always was.
    private static func fineRails(railA: [Point2D], railB: [Point2D], fineDensity: Double, parameters: StitchGenerationParameters) -> (a: [Point2D], b: [Point2D], mitre: [Bool]) {
        func proportional(_ a: [Point2D], _ b: [Point2D]) -> (a: [Point2D], b: [Point2D]) {
            guard a.count > 1, b.count > 1 else { return (a, b) }
            let weightedLength = max(
                PolygonGeometry.weightedPathLength(a, referenceLengthMM: fineDensity, curvatureWeight: curvatureDensityWeight),
                PolygonGeometry.weightedPathLength(b, referenceLengthMM: fineDensity, curvatureWeight: curvatureDensityWeight)
            )
            let count = max(2, Int((weightedLength / fineDensity).rounded()))
            return (PolygonGeometry.resampleByCountCurvatureWeighted(a, count: count, referenceLengthMM: fineDensity, curvatureWeight: curvatureDensityWeight),
                    PolygonGeometry.resampleByCountCurvatureWeighted(b, count: count, referenceLengthMM: fineDensity, curvatureWeight: curvatureDensityWeight))
        }
        func plain() -> (a: [Point2D], b: [Point2D], mitre: [Bool]) {
            let (a, b) = proportional(railA, railB)
            return (a, b, Array(repeating: false, count: a.count))
        }
        // Ring columns (closed rails) and columns with no sharp corner
        // take the plain proportional path.
        let isClosedRing = railA.count > 1 && railA.first == railA.last
        let corners = (parameters.satinMitreCorners && !isClosedRing) ? SatinCorners.findCorners(railA: railA, railB: railB) : []
        guard !corners.isEmpty else { return plain() }

        var fineA: [Point2D] = [], fineB: [Point2D] = [], mitre: [Bool] = []
        var cursorA = 0.0, cursorB = 0.0
        func append(_ piece: (a: [Point2D], b: [Point2D]), isMitre: Bool) {
            // Drop a duplicated seam point between consecutive pieces.
            var a = piece.a, b = piece.b
            if let la = fineA.last, let lb = fineB.last, let fa = a.first, let fb = b.first, la.distance(to: fa) < 1e-6, lb.distance(to: fb) < 1e-6 {
                a.removeFirst(); b.removeFirst()
            }
            fineA.append(contentsOf: a); fineB.append(contentsOf: b)
            mitre.append(contentsOf: Array(repeating: isMitre, count: a.count))
        }
        for corner in corners {
            let (endA, endB) = corner.outerIsA ? (corner.sOuterIn, corner.sInner) : (corner.sInner, corner.sOuterIn)
            append(proportional(SatinCorners.subPolyline(railA, from: cursorA, to: endA), SatinCorners.subPolyline(railB, from: cursorB, to: endB)), isMitre: false)
            append(SatinCorners.mitreCrossings(corner, spacingMM: fineDensity), isMitre: true)
            (cursorA, cursorB) = corner.outerIsA ? (corner.sOuterOut, corner.sInner) : (corner.sInner, corner.sOuterOut)
        }
        append(proportional(SatinCorners.subPolyline(railA, from: cursorA, to: .infinity), SatinCorners.subPolyline(railB, from: cursorB, to: .infinity)), isMitre: false)
        guard fineA.count == fineB.count, fineA.count >= 3 else { return plain() }
        return (fineA, fineB, mitre)
    }

    /// Resampled, compensated rail crossings shared by `generate` and
    /// `generatePartial` — the two differ only in what they do once they
    /// know each crossing's final (post-compensation) width, not in how
    /// that width is computed.
    private static func computeCrossings(for shape: VectorShape, parameters: StitchGenerationParameters) throws -> (expandedA: [Point2D], expandedB: [Point2D], widths: [Double], mitre: [Bool]) {
        let (railA, railB) = try computeRails(for: shape)
        // `computeRingRails` closes both rails explicitly (first point
        // repeated at the end) precisely so this check can tell "a ring
        // with no real ends" apart from "an open column whose two rail
        // endpoints just happen to coincide" (astronomically unlikely,
        // but `railA.count > 1` guards the degenerate single-point case
        // regardless).
        let isClosedRing = railA.count > 1 && railA.first == railA.last

        let density = parameters.effectiveSatinDensityMM
        // `approxLength` (the real, unweighted path length) still drives
        // push compensation below -- that's a physical-length quantity,
        // not something that should shift with how curvy the column
        // happens to be.
        let approxLength = max(PolygonGeometry.pathLength(railA), PolygonGeometry.pathLength(railB))
        // Crossings are laid down on a FINE grid first (`SatinSpacing.
        // oversampling` per nominal spacing, curvature-weighted so a tight
        // curve gets proportionally more candidates than a straight run)
        // and then thinned to the real stitch spacing by `SatinSpacing.
        // decimate`, which measures distance along the outer rail and
        // chooses each gap from the crossing's own width -- narrow columns
        // sew at a wider spacing, wide columns tighter (docs/
        // WILCOM_MANUAL_REVIEW.md A2/A3). The curvature weighting still
        // matters for *where* candidates sit; the thinning decides how
        // many survive.
        let (resampledA, resampledB, crossingCount, mitre) = fineThenDecimatedRails(railA: railA, railB: railB, density: density, parameters: parameters)

        // The single-global-axis end-cap algorithm above (see this type's
        // own doc comment) is built for a single "sausage" -- a shape that
        // genuinely branches (e.g. "H"'s two separate stems joined by a
        // crossbar, which has no single pair of end-cap edges that
        // correspond to two sensible parallel rails) can make it walk the
        // boundary in an order that doesn't correspond to a real column at
        // all, producing rails whose crossings visibly cross and re-cross
        // each other rather than sweeping smoothly along the shape. Ring
        // columns are exempt -- their rails come from angular ray-casting
        // (`computeRingRails`), which can't twist this way by construction.
        //
        // `isTwisted` alone doesn't catch every broken case, though: a
        // concave BEND rather than a full branch (e.g. an "L" -- one
        // vertical stroke and one horizontal stroke meeting at a right
        // angle) can rail-walk into a single crossing that spans straight
        // across the shape's own empty notch, landing far outside its
        // boundary, without that crossing ever intersecting its
        // neighbors -- `isTwisted`'s adjacent-segment check has nothing to
        // catch there. Checking that every interior crossing's own
        // midpoint actually lands inside the shape catches this
        // complementary failure mode: a real column's centerline should
        // never leave its own outline. Found directly against a real
        // raster-imported logo's own "L" (see `StitchTypeClassifier`'s
        // doc comment on this same case) -- reproduced and confirmed fixed
        // via `--lettering-preview`-style direct rendering before this
        // check was added; see CHANGELOG.md.
        if !isClosedRing, isTwisted(resampledA, resampledB) || crossingsEscapeTheShape(resampledA, resampledB, polygon: shape.subPaths.first?.points ?? []) {
            throw SatinGenerationError.shapeNotSuitable("this outline branches into more than one column and can't be represented as a single satin column")
        }

        var lo = 0, hi = crossingCount
        // Push compensation: fabric pushes apart *along* the stitching
        // direction (as opposed to pull, which narrows a design
        // perpendicular to it — see `PullCompensationCalculator`), so drop
        // crossings from both ends of the column before sewing, so it sews
        // at its intended length after that push. This can't be done by
        // trimming the raw rail *polylines* by arc length: each rail's
        // first/last few millimeters are the perpendicular "jog" from the
        // shared end-cap midpoint out to the boundary corner (see this
        // type's own doc comment on tapered end caps), not travel along the
        // column's actual length — arc-length trimming would eat into that
        // sideways jog almost without moving along the column at all.
        // Instead, measure each crossing by projecting its midpoint onto
        // the column's principal axis, and drop crossings whose projection
        // falls within the compensation distance of the column's true
        // (projected) extremes — immune to the end-cap jog since it
        // measures the real length axis directly.
        //
        // A closed ring has no free ends to push apart this way -- push
        // compensation doesn't have an equivalent effect around a full
        // loop, so this whole step is skipped for one entirely rather than
        // trimming crossings from an arbitrary point around the ring's
        // circumference (wherever `computeRingRails` happened to start its
        // angular sweep), which would cut a real, visible gap into
        // otherwise-continuous coverage for no physically-motivated
        // reason. Pull compensation (below) still applies normally to a
        // ring -- it's perpendicular to the column at each crossing, which
        // is just as meaningful there.
        if !isClosedRing {
            let (axis, mean) = PolygonGeometry.principalAxis(railA + railB)
            func projection(_ p: Point2D) -> Double { (p.x - mean.x) * axis.x + (p.y - mean.y) * axis.y }
            let midpointProjections = (0...crossingCount).map { projection(midpoint(resampledA[$0], resampledB[$0])) }

            let pushCompMM = parameters.pushCompensationMM
                ?? PullCompensationCalculator.estimatePush(stitchType: .satin, densityMM: density, objectLengthMM: approxLength, fabricType: parameters.fabricType)
            if pushCompMM > 0, let minProj = midpointProjections.min(), let maxProj = midpointProjections.max(), maxProj - minProj > pushCompMM {
                let loTarget = minProj + pushCompMM / 2
                let hiTarget = maxProj - pushCompMM / 2
                lo = midpointProjections.firstIndex(where: { $0 >= loTarget }) ?? 0
                hi = midpointProjections.lastIndex(where: { $0 <= hiTarget }) ?? crossingCount
                if lo >= hi { lo = 0; hi = crossingCount } // degenerate guard: keep everything rather than nothing
            }
        }

        let rawWidths = (lo...hi).map { resampledA[$0].distance(to: resampledB[$0]) }
        let averageWidth = rawWidths.reduce(0, +) / Double(max(1, rawWidths.count))
        let pullCompMM = parameters.pullCompensationMM
            ?? PullCompensationCalculator.estimate(stitchType: .satin, densityMM: density, objectWidthMM: averageWidth, fabricType: parameters.fabricType)

        var expandedA: [Point2D] = []
        var expandedB: [Point2D] = []
        for i in lo...hi {
            let a = resampledA[i], b = resampledB[i]
            // Pull compensation (spec §17): push each rail point outward,
            // away from the crossing's midpoint, so the column sews at the
            // intended width after fabric pulls it narrower. Expanding
            // symmetrically about the midpoint keeps the centerline (and
            // therefore the underlay generated from these same rails)
            // exactly where it was digitized.
            expandedA.append(pushOutward(a, from: b, by: pullCompMM / 2))
            expandedB.append(pushOutward(b, from: a, by: pullCompMM / 2))
        }
        let widths = zip(expandedA, expandedB).map { $0.distance(to: $1) }
        return (expandedA, expandedB, widths, Array(mitre[lo...hi]))
    }

    private enum CrossingKind { case satin, fill, narrowRun }

    /// Like `generate`, but never rejects a column for being too wide *or*
    /// too narrow: crossings that exceed `maxSatinWidthMM` are converted to
    /// tatami fill sub-regions, crossings that fall below `minSatinWidthMM`
    /// (checked only in the interior — see `interiorRange`) are converted
    /// to a triple-run line along the centerline instead, and crossings
    /// that fit stay genuine satin — the width-aware partial version of
    /// `generate`'s all-or-nothing checks, closer to Ink/Stitch's
    /// `SatinColumn.split()` idea (see `EMBROIDERY_ALGORITHM_REFERENCE.md`)
    /// than converting the *whole* object over a width violation in one
    /// section. `generate` itself is kept as the strict, pure-satin variant
    /// (used directly by tests that want a hard guarantee, and available to
    /// any future preflight/validation check that wants to know "would
    /// this column fit as clean satin?"); `DigitizePipeline` calls this one,
    /// since a design should never simply fail to produce output over a
    /// width violation in one section of one object.
    ///
    /// A lone over/under-width crossing surrounded by in-range ones is
    /// folded back into satin rather than becoming a one-crossing "fill"
    /// or "narrow-run" sliver — there's no meaningful polygon (or
    /// meaningful line) from a single crossing, and it's well within the
    /// kind of measurement noise a column that's otherwise a good satin
    /// candidate can have. A real fill or narrow-run sub-region only forms
    /// from two or more consecutive out-of-range crossings.
    public static func generatePartial(for shape: VectorShape, parameters: StitchGenerationParameters) throws -> [Point2D] {
        let crossings = try computeCrossings(for: shape, parameters: parameters)
        return stitchesSplittingByWidth(expandedA: crossings.expandedA, expandedB: crossings.expandedB, widths: crossings.widths,
                                        mitre: crossings.mitre, overWide: .localFill, parameters: parameters)
    }

    /// What `stitchesSplittingByWidth` does with a run of crossings wider
    /// than `maxSatinWidthMM`.
    private enum OverWideStrategy {
        /// The quad-strip those crossings span becomes a local tatami fill
        /// sub-region (`fillSegment`) -- `generatePartial`'s long-standing
        /// behavior for a single column.
        case localFill
        /// Those crossings are sewn as two or more parallel satin columns
        /// side by side, each under the cap (`splitSatinSegment`) -- the
        /// standard real-world technique for an over-wide satin stroke,
        /// used for a branching shape's segments: a fill sub-region's rows
        /// run at their own angle, unrelated to the satin direction on
        /// either side of it, and on a real cap-logo "B" at 100mm that
        /// read as jarring blocks of different texture dropped into the
        /// middle of otherwise smooth satin arms (confirmed directly by
        /// rendering it). Split satin keeps the same direction and sheen,
        /// with only a seam down the middle of the stroke.
        case splitSatin
    }

    /// The width-aware body of `generatePartial`, factored out so a
    /// branching shape's individual segments (`generateBranching`) get the
    /// same per-crossing satin/narrow-run split a single column does --
    /// a branch segment whose bowl is genuinely too wide for satin in one
    /// stretch (found directly against a real cap-logo "B" at 100mm, whose
    /// bowls reached ~16mm against the 12mm cap) handles that stretch per
    /// `overWide` and stays satin everywhere else, rather than the whole
    /// letter being rejected from the branching path and falling back to
    /// tatami fill outright.
    private static func stitchesSplittingByWidth(expandedA: [Point2D], expandedB: [Point2D], widths: [Double], mitre: [Bool],
                                                 overWide: OverWideStrategy, parameters: StitchGenerationParameters) -> [Point2D] {
        let interior = interiorRange(count: widths.count)

        var kind: [CrossingKind] = widths.enumerated().map { i, width in
            if width > parameters.maxSatinWidthMM { return .fill }
            // A mitre's crossings taper to the corner's tip on purpose
            // (`SatinCorners`); they are never a "narrow section".
            if interior.contains(i), width < parameters.minSatinWidthMM, !(i < mitre.count && mitre[i]) { return .narrowRun }
            return .satin
        }
        for i in 0..<kind.count where kind[i] != .satin {
            let prevSame = i > 0 && kind[i - 1] == kind[i]
            let nextSame = i < kind.count - 1 && kind[i + 1] == kind[i]
            if !prevSame && !nextSame { kind[i] = .satin }
        }

        var stitches: [Point2D] = []
        var i = 0
        while i < kind.count {
            var j = i
            while j < kind.count, kind[j] == kind[i] { j += 1 }
            switch kind[i] {
            case .fill:
                switch overWide {
                case .localFill:
                    stitches.append(contentsOf: fillSegment(expandedA: expandedA, expandedB: expandedB, range: i...(j - 1), parameters: parameters))
                case .splitSatin:
                    stitches.append(contentsOf: splitSatinSegment(expandedA: expandedA, expandedB: expandedB, widths: widths, range: i...(j - 1), parameters: parameters))
                }
            case .narrowRun:
                stitches.append(contentsOf: narrowRunSegment(expandedA: expandedA, expandedB: expandedB, range: i...(j - 1), parameters: parameters))
            case .satin:
                stitches.append(contentsOf: satinZigzag(expandedA: expandedA, expandedB: expandedB, range: i...(j - 1), parameters: parameters))
            }
            i = j
        }
        return stitches
    }

    /// The plain satin zigzag over crossings `range`, with stitch
    /// shortening on the inside of bends and long-stitch auto split
    /// applied (`SatinSpacing`). `generate` -- the strict, test-facing
    /// variant -- deliberately emits raw crossings instead.
    private static func satinZigzag(expandedA: [Point2D], expandedB: [Point2D], range: ClosedRange<Int>, parameters: StitchGenerationParameters) -> [Point2D] {
        let crossings = SatinSpacing.shorten(expandedA: expandedA, expandedB: expandedB, range: range, parameters: parameters)
        var stitches: [Point2D] = []
        stitches.reserveCapacity(crossings.count * 2)
        for c in crossings {
            stitches.append(c.a)
            stitches.append(c.b)
        }
        return SatinSpacing.autoSplit(stitches, parameters: parameters, seed: range.lowerBound)
    }

    /// Builds the closed quad-strip polygon spanning rail crossings `range`
    /// (both rails, one walked forward and the other back, so it traces the
    /// sub-region's boundary) and fills it with tatami stitches. Pull
    /// compensation is zeroed for this sub-fill call since it was already
    /// baked into `expandedA`/`expandedB` by the caller — applying it again
    /// here would expand the boundary twice.
    private static func fillSegment(expandedA: [Point2D], expandedB: [Point2D], range: ClosedRange<Int>, parameters: StitchGenerationParameters) -> [Point2D] {
        var points: [Point2D] = []
        for i in range { points.append(expandedA[i]) }
        for i in range.reversed() { points.append(expandedB[i]) }
        guard points.count >= 3 else { return [] }

        let polygon = VectorShape(subPaths: [SubPath(points: points, closed: true)])
        var subParameters = parameters
        // Both compensations were already baked into expandedA/expandedB by
        // the caller (pull via the rail-level outward push, push via the
        // rail-length trim); applying either again here, independently, on
        // this sub-region's own local axes would double up on the same two
        // effects rather than adding anything new.
        subParameters.pullCompensationMM = 0
        subParameters.pushCompensationMM = 0
        return TatamiFillGenerator.generate(for: polygon, parameters: subParameters)
    }

    /// Sews rail crossings `range` -- all wider than `maxSatinWidthMM` --
    /// as the fewest parallel satin columns that each fit under it, laid
    /// side by side between the same two rails: for `n` columns, the
    /// intermediate rails are the points `k/n` of the way across each
    /// crossing. Columns alternate direction (the first walks the range
    /// forward, the next walks it back, ...) so each one ends exactly
    /// where the next begins and the whole stretch sews as one continuous
    /// pass with no hop at all. See `OverWideStrategy.splitSatin` for why
    /// this exists alongside `fillSegment`.
    private static func splitSatinSegment(expandedA: [Point2D], expandedB: [Point2D], widths: [Double], range: ClosedRange<Int>, parameters: StitchGenerationParameters) -> [Point2D] {
        let cap = max(parameters.maxSatinWidthMM, 0.1)
        let widest = range.map { widths[$0] }.max() ?? 0
        let columns = max(2, Int((widest / cap).rounded(.up)))

        func rail(_ k: Int, _ i: Int) -> Point2D {
            let t = Double(k) / Double(columns)
            return expandedA[i] + (expandedB[i] - expandedA[i]) * t
        }

        var stitches: [Point2D] = []
        for k in 0..<columns {
            let forward = k % 2 == 0
            let indices = forward ? Array(range) : Array(range.reversed())
            for i in indices {
                stitches.append(rail(k, i))
                stitches.append(rail(k + 1, i))
            }
        }
        return SatinSpacing.autoSplit(stitches, parameters: parameters, seed: range.lowerBound &+ 7919)
    }

    /// Sews rail crossings `range` as a triple-run (bean-stitch) line along
    /// their centerline instead of a satin zigzag — a column section too
    /// narrow to zigzag reliably still needs to read as a bold line, and a
    /// single plain running stitch would look visually thin next to actual
    /// satin elsewhere on the same object. Resamples at `stitchLengthMM`
    /// (not the much finer `satinDensityMM` the crossings themselves are
    /// spaced at) before tripling, the same technique
    /// `DigitizePipeline`'s `.tripleRun` case uses.
    private static func narrowRunSegment(expandedA: [Point2D], expandedB: [Point2D], range: ClosedRange<Int>, parameters: StitchGenerationParameters) -> [Point2D] {
        let centerline = range.map { midpoint(expandedA[$0], expandedB[$0]) }
        guard centerline.count >= 2 else { return centerline }

        let base = RunningStitchGenerator.generate(for: SubPath(points: centerline, closed: false),
                                                     stitchLengthMM: parameters.stitchLengthMM,
                                                     minStitchLengthMM: parameters.minStitchLengthMM)
        guard base.count > 1 else { return base }
        return base + base.reversed() + base
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

    // MARK: - Branching satin (stage 2 — not wired into classification or
    // `DigitizePipeline` yet; see DIGITIZING_ENGINE.md's branching-letter
    // satin entry for the staged rollout plan)

    /// Whether `shape` — an outline (with any number of holes) that
    /// genuinely branches (a letter like "A", "B", "R", "H"; a logo
    /// stroke with a junction) — can be represented as satin by
    /// decomposing it into `StrokeTopologyAnalyzer`'s stroke segments and
    /// rail-fitting each one independently, the way
    /// `canRepresentAsSingleSatinColumn` checks the single-column case. A
    /// hole's own loop becomes a self-loop edge in the topology (see
    /// `StrokeTopologyAnalyzer.Edge`'s own doc comment) and is rail-fit
    /// exactly like any other segment — `computeSegmentRails`/
    /// `computeSegmentCrossings` operate on a polyline generically and
    /// don't care whether it's open or closed, the same way
    /// `computeCrossings` already treats `computeRingRails`'s closed rail
    /// pair no differently from an open column's. Requires the topology
    /// to have at least one real junction: a shape with none either
    /// already has a direct, simpler, better-proven path
    /// (`canRepresentAsSingleSatinColumn`, or the ring path for exactly
    /// one hole) or isn't usable at all, and shouldn't route through this
    /// newer, less-proven decomposition when it doesn't need to.
    public static func canRepresentAsBranchingSatinColumn(shape: VectorShape, parameters: StitchGenerationParameters) -> Bool {
        (try? branchingPlan(for: shape, parameters: parameters)) != nil
    }

    /// Routes to `computeSegmentRingRails` for a self-loop edge (a
    /// hole's own skeleton loop) and `computeSegmentRails` for every
    /// other segment — see `computeSegmentRingRails`'s own doc comment
    /// for why a self-loop specifically needs the radial technique
    /// rather than the tangent-walk one every other segment uses.
    private static func railsForEdge(_ edge: StrokeTopologyAnalyzer.Edge, shapePolygons: [[Point2D]]) throws -> (railA: [Point2D], railB: [Point2D]) {
        if edge.startNodeID == edge.endNodeID {
            guard let rails = computeSegmentRingRails(loopPolyline: edge.polyline, shapePolygons: shapePolygons) else {
                throw SatinGenerationError.shapeNotSuitable("couldn't trace a consistent ring column around this loop segment")
            }
            return rails
        }
        return try computeSegmentRails(polyline: edge.polyline, widthsMM: edge.widthsMM, shapePolygons: shapePolygons)
    }

    /// Generates satin stitches for a branching shape by decomposing it
    /// into `StrokeTopologyAnalyzer`'s stroke segments, rail-fitting and
    /// crossing each one independently (`computeSegmentRails`/
    /// `computeSegmentCrossings` — the same per-crossing technique
    /// `computeCrossings` uses, just following a local segment centerline
    /// instead of one global end-cap-to-end-cap axis), then concatenating
    /// them in stroke-graph walk order (`orderedEdges`) into one flat
    /// stitch list — the same `[Point2D]` contract `generate`/
    /// `generatePartial` already return. `DigitizePipeline` uses
    /// `generateBranchingRuns` instead, which keeps the same pieces split
    /// into separately-sewn runs wherever a hop between them would
    /// otherwise be sewn straight across open fabric.
    ///
    /// Every node where two or more segments meet gets a dedicated radial
    /// fan patch (`junctionPatchFill`) in place of each incident segment's
    /// own crossings within that patch's radius — see that function's
    /// own doc comment for why simply letting consecutive segments'
    /// near-junction crossings follow each other in the flat list (this
    /// function's original form, an acceptable first approximation while
    /// the decomposition mechanism itself was being proven) turned out to
    /// leave a real, visible crease at every junction once checked
    /// against a real letterform at high resolution.
    public static func generateBranching(for shape: VectorShape, parameters: StitchGenerationParameters) throws -> [Point2D] {
        try generateBranchingRuns(for: shape, parameters: parameters).flatMap { $0 }
    }

    /// `generateBranching`'s pieces as one or more disjoint runs, the
    /// same contract `TatamiFillGenerator.generateRuns` uses: consecutive
    /// pieces stay in one run when the hop between them can be sewn as an
    /// ordinary connector, and start a new run (which `DigitizePipeline`
    /// turns into a real trim+jump) when it can't. A hop can't be sewn
    /// when its straight line leaves the shape -- across a letterform's
    /// own counter, say -- whatever its length: a stitched connector there
    /// lies on open fabric with nothing sewn over it later, a visible
    /// stray line (found directly against a real cap-logo "B", whose
    /// counters each showed one straight red line cut clean across them).
    /// A hop that stays on the shape's own material is fine to sew: it
    /// gets covered by whatever sews there next, exactly like the
    /// underlay-to-crossings seam every plain satin column already has.
    public static func generateBranchingRuns(for shape: VectorShape, parameters: StitchGenerationParameters) throws -> [[Point2D]] {
        let plan = try branchingPlan(for: shape, parameters: parameters)

        // Assemble the pieces in walk order: each edge's kept crossings,
        // with its START node's patch just before them and its END node's
        // patch just after (each patch once, at the first edge to reach
        // it) -- so the sequence flows arm -> patch -> next arm with the
        // needle already at the junction, rather than the patch landing
        // far away after an arm that merely *began* there.
        var pieces: [[Point2D]] = []
        var emittedPatchNodes = Set<Int>()
        func emitPatch(at nodeID: Int) {
            guard !emittedPatchNodes.contains(nodeID), let patch = plan.patchByNode[nodeID] else { return }
            pieces.append(patch)
            emittedPatchNodes.insert(nodeID)
        }
        for segment in plan.segments {
            emitPatch(at: segment.edge.startNodeID)
            if !segment.kept.isEmpty {
                pieces.append(stitchesSplittingByWidth(
                    expandedA: Array(segment.expandedA[segment.kept]), expandedB: Array(segment.expandedB[segment.kept]),
                    widths: Array(segment.widths[segment.kept]), mitre: Array(segment.mitre[segment.kept]),
                    overWide: .splitSatin, parameters: parameters))
            }
            emitPatch(at: segment.edge.endNodeID)
        }
        pieces.removeAll { $0.isEmpty }
        guard !pieces.isEmpty else {
            throw SatinGenerationError.shapeNotSuitable("no usable branch segments")
        }

        var runs: [[Point2D]] = [pieces[0]]
        for piece in pieces.dropFirst() {
            if let last = runs[runs.count - 1].last, hopStaysOnShape(from: last, to: piece[0], polygons: plan.polygons) {
                runs[runs.count - 1].append(contentsOf: piece)
            } else {
                runs.append(piece)
            }
        }
        return runs
    }

    /// One branch segment, rail-fit and resampled, with the index range of
    /// its crossings that will actually be sewn (the rest lies inside a
    /// junction patch at one end or the other).
    private struct BranchSegment {
        var edge: StrokeTopologyAnalyzer.Edge
        var expandedA: [Point2D]
        var expandedB: [Point2D]
        var widths: [Double]
        var mitre: [Bool]
        var kept: Range<Int>
    }

    private struct BranchingPlan {
        var polygons: [[Point2D]]
        var segments: [BranchSegment]
        var patchByNode: [Int: [Point2D]]
    }

    /// Everything `generateBranchingRuns` sews, decided in one place so
    /// `canRepresentAsBranchingSatinColumn` answers "would this succeed?"
    /// by literally trying it rather than by a separate approximation --
    /// the two can never disagree about what counts as a usable segment.
    ///
    /// In particular, the twist check (`isTwisted`) runs on each segment's
    /// KEPT crossings only, after junction trimming. It used to run on the
    /// whole segment inside `computeSegmentCrossings`, which rejected a
    /// segment for crossings that were never going to be sewn: right at a
    /// junction the two rails routinely fan about a near-fixed midpoint
    /// (each rail's nearest boundary there belongs partly to a different
    /// arm), and that fan is exactly what the junction patch exists to
    /// replace. Found directly against the 96px Red Sox "B" once its
    /// anti-aliasing slivers were cleaned up: a 1px nudge to its hook put
    /// a fan in the first ~3mm of its stem, and the whole letter fell back
    /// to tatami over stitches the patch would have covered anyway.
    private static func branchingPlan(for shape: VectorShape, parameters: StitchGenerationParameters) throws -> BranchingPlan {
        guard !shape.subPaths.isEmpty else {
            throw SatinGenerationError.shapeNotSuitable("no outline was provided")
        }
        let polygons = shape.subPaths.map { $0.points }
        guard let topology = StrokeTopologyAnalyzer.analyze(shape: shape), !topology.edges.isEmpty else {
            throw SatinGenerationError.shapeNotSuitable("couldn't derive a stroke topology for this shape")
        }
        guard topology.nodes.contains(where: { $0.isJunction }) else {
            throw SatinGenerationError.shapeNotSuitable("this shape has no junction to branch at")
        }

        var segments: [BranchSegment] = []
        for edge in orderedEdges(topology) {
            let (railA, railB) = try railsForEdge(edge, shapePolygons: polygons)
            guard let crossings = computeSegmentCrossings(railA: railA, railB: railB, parameters: parameters),
                  !crossings.expandedA.isEmpty else {
                throw SatinGenerationError.shapeNotSuitable("a branch segment couldn't be rail-fit as satin")
            }
            segments.append(BranchSegment(edge: edge, expandedA: crossings.expandedA, expandedB: crossings.expandedB,
                                          widths: crossings.widths, mitre: crossings.mitre, kept: 0..<crossings.expandedA.count))
        }

        let nodesByID = Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, $0) })
        var incidentEdgeCount: [Int: Int] = [:]
        for segment in segments where segment.edge.startNodeID != segment.edge.endNodeID {
            incidentEdgeCount[segment.edge.startNodeID, default: 0] += 1
            incidentEdgeCount[segment.edge.endNodeID, default: 0] += 1
        }
        let patchedNodeIDs = Set(incidentEdgeCount.filter { $0.value >= minimumJunctionEdgeCount }.map { $0.key })

        // Trim off whichever of each incident edge's own crossings near a
        // patched node fall within that node's trim radius -- those are
        // exactly the crossings whose own direction never accounted for
        // the OTHER edges meeting at the same point (the crease itself),
        // to be covered by the patch instead. A crossing is trimmed by
        // its MIDPOINT's distance, but its two rail ends sit half a stroke
        // width to either side, farther out -- so each node's patch is
        // sized to the farthest rail end of anything trimmed at it, not
        // to the trim radius itself: a patch built at the trim radius
        // alone left visible uncovered wedges beside every rosette on a
        // real 7mm-wide arm (found directly by rendering it).
        var patchRadiusByNode: [Int: Double] = [:]
        for index in segments.indices {
            let segment = segments[index]
            let count = segment.expandedA.count
            var lo = 0, hi = count
            if segment.edge.startNodeID != segment.edge.endNodeID {
                if let node = nodesByID[segment.edge.startNodeID], patchedNodeIDs.contains(segment.edge.startNodeID) {
                    let radius = junctionTrimRadius(for: node)
                    while lo < hi - 1, node.position.distance(to: midpoint(segment.expandedA[lo], segment.expandedB[lo])) <= radius {
                        let reach = max(node.position.distance(to: segment.expandedA[lo]), node.position.distance(to: segment.expandedB[lo]))
                        patchRadiusByNode[node.id] = max(patchRadiusByNode[node.id] ?? radius, reach)
                        lo += 1
                    }
                }
                if let node = nodesByID[segment.edge.endNodeID], patchedNodeIDs.contains(segment.edge.endNodeID) {
                    let radius = junctionTrimRadius(for: node)
                    while hi > lo + 1, node.position.distance(to: midpoint(segment.expandedA[hi - 1], segment.expandedB[hi - 1])) <= radius {
                        let reach = max(node.position.distance(to: segment.expandedA[hi - 1]), node.position.distance(to: segment.expandedB[hi - 1]))
                        patchRadiusByNode[node.id] = max(patchRadiusByNode[node.id] ?? radius, reach)
                        hi -= 1
                    }
                }
            }
            segments[index].kept = lo..<hi

            // A self-loop's ring rails (`railsForEdge` routes exactly these
            // to `computeSegmentRingRails`) can't twist by construction --
            // radial spokes from one center -- so they're exempt, exactly
            // as `computeCrossings` exempts a plain ring. Keyed off the
            // edge itself rather than "first rail point == last rail
            // point": after resampling those two differ in the last
            // floating-point digit, and that exact-equality check silently
            // stopped exempting every ring (caught by the synthetic "P"
            // fixture the moment the check moved here).
            let isRing = segment.edge.startNodeID == segment.edge.endNodeID
            let checked = interiorRange(count: count).clamped(to: lo..<hi)
            if !isRing, isTwisted(segment.expandedA, segment.expandedB, within: checked) {
                throw SatinGenerationError.shapeNotSuitable("a branch segment's rails twist across each other")
            }
        }

        var patchByNode: [Int: [Point2D]] = [:]
        for nodeID in patchedNodeIDs {
            guard let node = nodesByID[nodeID] else { continue }
            let radius = patchRadiusByNode[nodeID] ?? junctionTrimRadius(for: node)
            if let patch = junctionPatchFill(node: node, radius: radius, shapePolygons: polygons, parameters: parameters) {
                patchByNode[nodeID] = patch
            }
        }
        return BranchingPlan(polygons: polygons, segments: segments, patchByNode: patchByNode)
    }

    /// How finely `hopStaysOnShape` samples a connector for leaving the
    /// shape -- a counter narrower than this could in principle be
    /// stepped over unnoticed, but nothing embroiderable is that small.
    private static let hopSampleSpacingMM = 0.5

    private static func hopStaysOnShape(from: Point2D, to: Point2D, polygons: [[Point2D]]) -> Bool {
        let length = from.distance(to: to)
        guard length > hopSampleSpacingMM else { return true }
        let steps = Int((length / hopSampleSpacingMM).rounded(.up))
        for step in 1..<steps {
            let t = Double(step) / Double(steps)
            let p = from + (to - from) * t
            if !PolygonGeometry.pointInPolygons(p, polygons: polygons) { return false }
        }
        return true
    }

    /// A junction node needs a patch only once at least two DISTINCT
    /// non-self-loop edges actually meet there (a self-loop's own
    /// first/last crossing isn't at the node at all -- see
    /// `computeSegmentRingRails`'s own doc comment -- so it can't
    /// contribute a meaningful boundary point here); below that, there's
    /// nothing for a patch to bridge.
    private static let minimumJunctionEdgeCount = 2

    /// How many samples `junctionPatchFill`'s radial sweep casts around a
    /// full circle -- dense enough to trace a typical junction's own real
    /// boundary shape (including a concave corner where two arms meet)
    /// before `TatamiFillGenerator`'s own row spacing reduces it to the
    /// actual stitch density, matching `ringRailSampleCount`'s identical
    /// reasoning for the same tradeoff.
    private static let junctionPatchSampleCount = 60

    /// How far along each arm from a junction node its crossings are
    /// trimmed (by crossing midpoint), as a multiple of the node's own
    /// local stroke width. A junction NODE's `widthMM` is the diameter of
    /// the largest circle that fits at the point where its arms' material
    /// merges (twice the distance transform there), so half of it is that
    /// circle's radius: a crossing whose midpoint lies inside the circle
    /// is a junction crossing -- its rails belong partly to different arms
    /// and fan about the node rather than running with any one column --
    /// and one outside it has cleared the junction and belongs to its arm.
    /// Two earlier values bracketed this from both sides on real files:
    /// `1.3x`, uncapped, ate most of a short connecting arm's own length
    /// and left huge gaps (the original Red Sox "B"'s waist nodes measure
    /// 7.7-10.6mm wide); `0.4x` capped at 3mm then failed to reach the fan
    /// at all on the same letterform's cap-logo cut at 100mm, whose waist
    /// merges into one 17mm-wide blob with the first crossing's midpoint
    /// already 6mm out -- the whole letter fell back to tatami over that
    /// one untrimmed fan. The PATCH's own radius is derived from what
    /// actually got trimmed (see `branchingPlan`), not from this directly.
    private static let junctionTrimRadiusFactor = 0.5

    private static func junctionTrimRadius(for node: StrokeTopologyAnalyzer.Node) -> Double {
        max(node.widthMM, 1.0) * junctionTrimRadiusFactor
    }

    /// Traces the shape's own real boundary around `node` via the same
    /// radial-sweep-from-one-center technique `computeRingRails`/
    /// `computeSegmentRingRails` already use, rather than synthesizing a
    /// polygon from disparate rail samples (tried first: sorting each
    /// incident edge's own near-node rail points by raw angle around the
    /// node produced a self-intersecting polygon whenever an edge's own A
    /// and B rails sat far apart in angle, which is the ordinary case for
    /// a real stroke width -- confirmed directly by rendering it: a
    /// sparse, gap-riddled zigzag instead of a solid fill). A ray cast
    /// from the node's own position, in any direction, always finds a
    /// real, physically-meaningful boundary point -- clamped to
    /// `radius` (sized by the caller to cover every crossing it trimmed
    /// at this node), so a direction that runs straight down one of the
    /// arms (where the nearest boundary is actually far away, along that
    /// arm's own length) gets a point at the radius limit instead of one
    /// arbitrarily far out.
    ///
    /// Stitches the resulting small, roughly star-shaped region as a
    /// radial FAN -- alternating between the node's own center and each
    /// boundary point in turn, all the way around -- rather than handing
    /// it to `TatamiFillGenerator` as a row-based fill (tried first: rows
    /// scanning across a small region with real concave notches between
    /// arms routinely cross the boundary more than twice, splitting one
    /// row into several disconnected pieces -- confirmed directly by
    /// rendering it, a dense, spiky, disconnected scribble rather than a
    /// clean fill, distinctly worse than the crease it was meant to
    /// replace). A fan has no such problem: every single stitch is a
    /// straight line from the center to a point already known to be on
    /// the real boundary, so it can never partially miss the shape the
    /// way a fixed-direction horizontal scanline can. This is also the
    /// standard real-world embroidery technique for a small round/star
    /// patch (a "wheel" or rosette stitch), not a workaround specific to
    /// this engine. The boundary is resampled to `satinDensityMM`-spaced
    /// points first (`junctionPatchSampleCount`'s own finer angular sweep
    /// is for tracing the true boundary SHAPE accurately, including a
    /// concave notch -- using all of it as spokes directly would sew far
    /// more stitches, all piling onto the same center point, than the
    /// small patch's own size calls for).
    private static func junctionPatchFill(node: StrokeTopologyAnalyzer.Node, radius: Double, shapePolygons: [[Point2D]], parameters: StitchGenerationParameters) -> [Point2D]? {
        var boundary: [Point2D] = []
        for i in 0..<junctionPatchSampleCount {
            let theta = 2 * Double.pi * Double(i) / Double(junctionPatchSampleCount)
            let direction = Point2D(cos(theta), sin(theta))
            let hit = rayPolygonsIntersection(origin: node.position, direction: direction, polygons: shapePolygons)
            let distance = hit.map { node.position.distance(to: $0) } ?? radius
            let clamped = min(distance, radius)
            boundary.append(Point2D(node.position.x + direction.x * clamped, node.position.y + direction.y * clamped))
        }
        guard boundary.count >= 3 else { return nil }
        boundary.append(boundary[0])

        let density = parameters.effectiveSatinDensityMM
        let perimeter = PolygonGeometry.pathLength(boundary)
        guard perimeter > 0 else { return nil }
        let spokeCount = max(6, Int((perimeter / density).rounded()))
        let spokes = PolygonGeometry.resampleByCount(boundary, count: spokeCount)

        var stitches: [Point2D] = []
        for spoke in spokes {
            stitches.append(node.position)
            stitches.append(spoke)
        }
        return stitches
    }

    /// For each `polyline` sample (a stroke segment's own centerline, from
    /// `StrokeTopologyAnalyzer`), casts a ray perpendicular to the local
    /// tangent in both directions to find the two nearest boundary points —
    /// the same ray-casting primitive `computeRingRails` uses for its fixed
    /// radial sweep from one center, just re-aimed per sample to follow a
    /// locally-varying direction instead. A sample where the perpendicular
    /// ray misses the boundary on either side (rare — a sharp local kink at
    /// a junction, or a centerline sample sitting exactly on a boundary
    /// vertex) is skipped rather than failing the whole segment; only a
    /// segment that loses more than a quarter of its samples this way is
    /// rejected as too irregular to trust.
    /// A perpendicular ray-cast hit farther than this multiple of
    /// `StrokeTopologyAnalyzer`'s own local width estimate is treated as a
    /// miss, not a real boundary point — see this function's own doc
    /// comment on why a sample near a junction needs this bound at all.
    private static let segmentRailWidthToleranceFactor = 2.0

    /// At or below this local width, a branch segment sample is treated
    /// as a genuinely tapering tip rather than merely a narrow section —
    /// see `computeSegmentRails`'s own doc comment on why that distinct
    /// treatment (collapsing both rails to one point) exists at all.
    /// Deliberately well under `minSatinWidthMM`'s 1.5mm default: this
    /// only needs to catch the near-zero-width samples where independent
    /// ray-casting becomes numerically unstable, not every section that
    /// merely happens to be on the narrow side.
    private static let taperCollapseWidthMM = 0.5

    /// Arc-length window (mm) `smoothedPolyline` averages each interior
    /// sample over before rail-fitting — see that function's own doc
    /// comment for why this exists at all. Chosen well under a typical
    /// letter stroke's own width (so a real, meaningful curve along the
    /// stroke's length isn't flattened away), but well above one raster
    /// pixel step at `StrokeTopologyAnalyzer`'s default 10px/mm (0.1mm),
    /// so it actually averages several consecutive steps rather than
    /// nearly none.
    private static let segmentSmoothingWindowMM = 0.6

    /// Arc-length window (mm) used to smooth the RAILS themselves (the
    /// boundary hit points `computeSegmentRails` finds via
    /// `nearestBoundaryPoint`), applied just before returning — wider
    /// than `segmentSmoothingWindowMM` (used for the centerline
    /// beforehand) because a real corner a rail faithfully follows can
    /// stay the true nearest point over a longer stretch than the raw
    /// per-pixel jitter the centerline window targets; over-smoothing a
    /// real corner here just rounds it slightly (routine in satin
    /// digitizing) rather than misrepresenting where the centerline
    /// itself runs, which the smaller centerline window is deliberately
    /// conservative about. Found empirically against the real Red Sox
    /// "B": 1.5mm and 2.0mm still left one isolated pinch (a real corner
    /// the rail tracked for longer than either window), 2.5mm was the
    /// first value that resolved it fully, 3.0mm resolved it with a
    /// clearer margin and is the value kept here.
    private static let railSmoothingWindowMM = 3.0

    /// Averages each interior sample of a branch segment's raw skeleton
    /// centerline with its neighbors within `segmentSmoothingWindowMM` of
    /// it (by arc length), leaving the first and last samples — a node's
    /// own position, which downstream code relies on to join adjacent
    /// segments — untouched.
    ///
    /// `StrokeTopologyAnalyzer`'s centerline is a literal one-pixel-at-a-
    /// time walk of a thinned raster skeleton: even on ordinary,
    /// already-anti-aliased artwork, that walk routinely staircases a few
    /// tenths of a degree back and forth from one pixel to the next along
    /// an otherwise straight or gently curving stroke. `computeSegmentRails`
    /// derives its perpendicular ray direction at each sample from that
    /// sample's two immediate neighbors, so this pixel-level jitter feeds
    /// directly into the ray direction at every single sample — normally
    /// invisible in the resulting rails on a wide stroke (the noise is a
    /// small fraction of the width), but on a genuinely thin section (a
    /// tapering tip, a fine stroke) the same absolute jitter is a much
    /// larger fraction of the local width, and can swing the rail's
    /// direction enough from one sample to the next to make adjacent
    /// crossings cross each other — exactly what `isTwisted` exists to
    /// catch, but here because the raw walk is noisy relative to the
    /// (small) width there, not because the underlying geometry actually
    /// branches or twists. Found directly against a real raster-traced
    /// "B" logo (Boston Red Sox), whose thin tapering tip still failed
    /// `isTwisted` even after `taperCollapseWidthMM` handled the
    /// near-zero-width samples specifically — the jitter wasn't confined
    /// to the very tip, just less consequential (relative to width)
    /// everywhere else along the same segment.
    private static func smoothedPolyline(_ points: [Point2D], windowMM: Double = segmentSmoothingWindowMM) -> [Point2D] {
        guard points.count > 2 else { return points }
        let n = points.count
        var cumulative = [Double](repeating: 0, count: n)
        for i in 1..<n { cumulative[i] = cumulative[i - 1] + points[i - 1].distance(to: points[i]) }

        var result = points
        for i in 1..<(n - 1) {
            let lo = cumulative[i] - windowMM / 2
            let hi = cumulative[i] + windowMM / 2
            var sumX = 0.0, sumY = 0.0, count = 0.0
            var j = i
            while j >= 0, cumulative[j] >= lo {
                sumX += points[j].x; sumY += points[j].y; count += 1
                j -= 1
            }
            j = i + 1
            while j < n, cumulative[j] <= hi {
                sumX += points[j].x; sumY += points[j].y; count += 1
                j += 1
            }
            guard count > 0 else { continue }
            result[i] = Point2D(sumX / count, sumY / count)
        }
        return result
    }

    /// See the type-level doc comment for the general ray-casting
    /// approach. One case needs an extra safeguard beyond that: a sample
    /// near a junction end sits where the WHOLE shape's own boundary has
    /// "opened up" into a connecting branch (e.g. the left stem of an "H,"
    /// right where it meets the crossbar) — casting perpendicular to the
    /// stem's own local tangent there can sail straight past where the
    /// stem's boundary *would* be in isolation and hit the crossbar's own,
    /// much farther boundary instead, since that point is genuinely
    /// interior to the combined shape, not on its edge at all. Found
    /// directly against this file's own branching-H regression test: every
    /// segment's rails came back structurally fine away from its junction
    /// end, but the samples closest to a junction produced a sudden width
    /// spike that `isTwisted` correctly caught as a malformed column.
    /// `widthsMM` (from the same topology edge, computed locally via the
    /// skeleton's own distance transform — not a whole-boundary ray-cast,
    /// so it doesn't have this failure mode) gives an independent local
    /// width estimate at each sample; a ray-cast hit farther than
    /// `segmentRailWidthToleranceFactor` times that estimate is rejected
    /// as having escaped into an unrelated connected branch rather than
    /// trusted as this segment's own boundary.
    private static func computeSegmentRails(polyline rawPolyline: [Point2D], widthsMM: [Double], shapePolygons: [[Point2D]]) throws -> (railA: [Point2D], railB: [Point2D]) {
        guard rawPolyline.count >= 2, rawPolyline.count == widthsMM.count else {
            throw SatinGenerationError.shapeNotSuitable("a branch segment needs at least two centerline points")
        }
        let polyline = smoothedPolyline(rawPolyline)
        var railA: [Point2D] = []
        var railB: [Point2D] = []
        for i in 0..<polyline.count {
            let tangent: Point2D
            if i == 0 {
                tangent = polyline[1] - polyline[0]
            } else if i == polyline.count - 1 {
                tangent = polyline[i] - polyline[i - 1]
            } else {
                tangent = polyline[i + 1] - polyline[i - 1]
            }
            let tangentLength = tangent.length
            guard tangentLength > 1e-9 else { continue }
            let perp = Point2D(-tangent.y / tangentLength, tangent.x / tangentLength)
            let hitA: Point2D
            let hitB: Point2D
            if widthsMM[i] <= taperCollapseWidthMM {
                // A genuinely tapering tip (a serif, a pointed stroke
                // end) rather than merely a narrow section: collapse
                // both rails to the segment's own centerline point here
                // instead of trusting two independently ray-cast hits.
                // Mirrors the single-column path's own established
                // convention for a pointed end cap (`computeRails`
                // shares a single midpoint between both rails there,
                // rather than tapering two separate boundary hits down
                // to near-coincidence) — the same idea, just decided
                // per-sample from each sample's own known local width
                // instead of one whole-column pointed/squared
                // end-cap choice. Where the true geometry wants both
                // sides to coincide anyway, independently ray-cast hits
                // are exactly where small boundary noise becomes most
                // numerically unstable: found directly against a real
                // raster-traced "B" logo, whose own thin tapering tip
                // (0.2mm narrowing over ~5mm of length) produced a
                // twisted zigzag there even though the rails elsewhere
                // along the same segment were perfectly sound.
                hitA = polyline[i]
                hitB = polyline[i]
            } else {
            // Every one of the shape's boundaries (outer plus every
            // hole), not just the outer one -- a segment near a hole
            // (a "B"'s stem sitting between its two bowls' counters)
            // needs its perpendicular ray to stop at the *nearest*
            // boundary in either direction, which just as easily is a
            // hole's own edge as the outer one. See
            // `rayPolygonsIntersection`'s own doc comment.
            let maxDistance = max(widthsMM[i], 0.3) * segmentRailWidthToleranceFactor
            let rawA = nearestBoundaryPoint(from: polyline[i], perp: perp, side: 1, polygons: shapePolygons)
            let rawB = nearestBoundaryPoint(from: polyline[i], perp: perp, side: -1, polygons: shapePolygons)
            let validA = rawA.flatMap { polyline[i].distance(to: $0) <= maxDistance ? $0 : nil }
            let validB = rawB.flatMap { polyline[i].distance(to: $0) <= maxDistance ? $0 : nil }

            switch (validA, validB) {
            case let (a?, b?):
                hitA = a
                hitB = b
            case let (a?, nil):
                // One side's ray escaped past a plausible hit (typically
                // where this sample sits close to where a hole's own
                // loop passes nearest the point it connects to the rest
                // of the shape -- the same "boundary has opened up into
                // a connected branch" issue the width-tolerance check
                // above exists to catch, just encountered from a loop's
                // own polyline instead of an open segment's). Rather
                // than discarding the sample outright, reconstruct the
                // missing side by reflecting the valid one across this
                // polyline point at the topology's own local half-width
                // -- this point *is* the medial axis by construction, so
                // it should sit equidistant from both true boundaries
                // regardless of which single side the ray-cast actually
                // found. Found directly against a real branching-plus-
                // hole letterform shape (a "P"), where a hole's own loop
                // lost roughly a third of its samples this way near its
                // stem junction before this reconstruction existed.
                hitA = a
                hitB = mirroredAcross(polyline[i], from: a, distance: widthsMM[i] / 2)
            case let (nil, b?):
                hitB = b
                hitA = mirroredAcross(polyline[i], from: b, distance: widthsMM[i] / 2)
            case (nil, nil):
                continue
            }
            }
            railA.append(hitA)
            railB.append(hitB)
        }
        guard railA.count >= max(2, polyline.count * 3 / 4) else {
            throw SatinGenerationError.shapeNotSuitable("couldn't trace a consistent rail pair along this branch segment")
        }
        // Smoothing the CENTERLINE (above) stabilizes the ray/nearest-point
        // direction at each sample, but the resulting rails are still hits
        // against the shape's own boundary -- a real raster-traced logo's
        // boundary is itself a faceted polygon, not a smooth curve, so a
        // rail can still faithfully follow a genuine sharp corner there
        // (`nearestBoundaryPoint` finding the exact same vertex for a run
        // of consecutive samples, then transitioning to a neighboring edge)
        // in a way no amount of centerline smoothing addresses, since the
        // corner is real boundary geometry, not noise in the walk that
        // produced the query points. That faceted transition is still
        // sharp enough, relative to a nearby steadily-moving opposite rail,
        // to make two adjacent crossings pinch through each other --
        // found directly against the same real "B" logo's stem, one
        // isolated instance surviving after `nearestBoundaryPoint` and
        // curvature-weighted resampling above fixed the far more
        // widespread failures. Smoothing the rails themselves the same
        // way flattens exactly this without touching the (already sound)
        // centerline or width profile.
        return (smoothedPolyline(railA, windowMM: railSmoothingWindowMM), smoothedPolyline(railB, windowMM: railSmoothingWindowMM))
    }

    /// Reflects `point` across `center`, replacing the measured distance
    /// with `distance` -- see `computeSegmentRails`'s own doc comment on
    /// why this specific reconstruction (rather than just discarding an
    /// implausible ray-cast hit) is the right fallback for a rail sample
    /// whose one side is known-good.
    private static func mirroredAcross(_ center: Point2D, from point: Point2D, distance: Double) -> Point2D {
        let dx = center.x - point.x, dy = center.y - point.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-9 else { return center }
        return Point2D(center.x + dx / len * distance, center.y + dy / len * distance)
    }

    /// Rail-fits a self-loop edge (a hole's own skeleton loop — see
    /// `StrokeTopologyAnalyzer.Edge`'s own doc comment) via the same
    /// radial-sweep-from-one-center technique `computeRingRails` already
    /// uses for a shape whose *only* structure is one hole, rather than
    /// `computeSegmentRails`'s local-tangent walk. This distinction
    /// matters, not just style: `computeRingRails`'s own doc comment
    /// already explains why a ring needs angular correspondence from a
    /// fixed center rather than arc-length-local pairing — walking a
    /// closed loop's own polyline and casting locally-perpendicular rays
    /// is exactly the "arc-length-based pairing" that comment warns
    /// twists a ring's rails, and found directly against a real
    /// branching-plus-hole letterform shape (a "P"): every attempt to
    /// rail-fit a bowl's hole loop via `computeSegmentRails` came back
    /// twisted regardless of how far the hole sat from the stem
    /// junction, even once per-sample rail reconstruction (see
    /// `mirroredAcross`) gave it full centerline coverage — the technique
    /// itself, not incomplete coverage, was the problem.
    ///
    /// Unlike `computeRingRails` (which always has exactly one hole
    /// polygon and one outer polygon to query separately), a self-loop
    /// here can be one of several holes in a larger branching shape, so
    /// there's no single "the outer boundary" to hand it directly —
    /// instead, `rayPolygonsIntersections` returns every crossing along
    /// each radial ray ordered nearest-first, and the nearest two are
    /// used: the first is this loop's own hole boundary, the second is
    /// whatever lies just beyond it (normally the shape's outer
    /// boundary, unless two holes sit unusually close together).
    private static func computeSegmentRingRails(loopPolyline: [Point2D], shapePolygons: [[Point2D]]) -> (railA: [Point2D], railB: [Point2D])? {
        let center = vertexAverage(loopPolyline)
        // `pointInPolygons` even-odd across every one of the shape's own
        // boundaries reads "inside a hole" as *outside* the filled
        // shape (the same convention used everywhere else in this
        // engine) — so the centroid landing "inside" here means it
        // landed in solid material, not in the hole this loop actually
        // wraps, and this loop's shape is too irregular for a simple
        // radial sweep from one point to trust. The same "couldn't find
        // a usable center point" guard `computeRingRails` enforces via
        // its own explicit check.
        guard !PolygonGeometry.pointInPolygons(center, polygons: shapePolygons) else { return nil }

        var railA: [Point2D] = []
        var railB: [Point2D] = []
        for i in 0..<ringRailSampleCount {
            let theta = 2 * Double.pi * Double(i) / Double(ringRailSampleCount)
            let direction = Point2D(cos(theta), sin(theta))
            let hits = rayPolygonsIntersections(origin: center, direction: direction, polygons: shapePolygons)
            guard hits.count >= 2 else { continue }
            railB.append(hits[0])
            railA.append(hits[1])
        }
        guard railA.count >= ringRailSampleCount * 3 / 4 else { return nil }

        if let firstA = railA.first, let firstB = railB.first {
            railA.append(firstA)
            railB.append(firstB)
        }
        return (railA, railB)
    }

    /// Like `computeCrossings`, but for one branch segment rather than a
    /// whole single-column shape: resamples the segment's rails at
    /// `satinDensityMM`, rejects a twisted result (`isTwisted`, the same
    /// check `computeCrossings` uses), and applies pull compensation.
    /// Deliberately simpler than `computeCrossings` in two ways, both
    /// because a segment's own ends are junctions or real endpoints
    /// already handled elsewhere in the branching pipeline, not a whole
    /// object's own free ends: no push-compensation trim (there's nothing
    /// to push apart *into* — the segment is one piece of a larger
    /// connected shape, not a standalone column with two free ends), and
    /// no `crossingsEscapeTheShape` check (meaningful for a single global
    /// axis that can rail-walk a concave bend straight across empty space;
    /// a segment's rails come from the local perpendicular at each
    /// centerline sample, which can't do that).
    private static func computeSegmentCrossings(railA: [Point2D], railB: [Point2D], parameters: StitchGenerationParameters) -> (expandedA: [Point2D], expandedB: [Point2D], widths: [Double], mitre: [Bool])? {
        let density = parameters.effectiveSatinDensityMM
        let length = max(PolygonGeometry.pathLength(railA), PolygonGeometry.pathLength(railB))
        guard length > 0 else { return nil }
        // Curvature-weighted, matching `computeCrossings`' own reasoning
        // for the single-column path (see its doc comment): a segment
        // that curves sharply — e.g. where a "B"'s stem sweeps up into
        // the wide junction where both bowls meet — needs denser
        // crossings than a straight run at the same `satinDensityMM`, or
        // consecutive crossings rotate enough, sample to sample, to
        // physically cross each other even though the underlying rails
        // are perfectly sound (exactly the `isTwisted` failure found
        // directly against a real raster-traced "B" logo's own stem,
        // after the corner-fan issue `nearestBoundaryPoint` fixes was
        // ruled out as the cause there).
        // Same fine-grid-then-decimate placement as `computeCrossings` --
        // see the comment there.
        let (resampledA, resampledB, crossingCount, mitre) = fineThenDecimatedRails(railA: railA, railB: railB, density: density, parameters: parameters)
        // No twist check here: `branchingPlan` applies `isTwisted` to each
        // segment's KEPT crossings after junction trimming (see its own
        // doc comment for why checking the untrimmed segment rejected
        // real letterforms over crossings the patch replaces anyway). A
        // closed (ring) rail pair -- `railA.first == railA.last`, how
        // `computeSegmentRingRails` closes a self-loop's rails -- is exempt
        // there for the same reason `computeCrossings` exempts a plain
        // ring: a radial sweep from one fixed center can't twist by
        // construction, and the check's interior-margin exclusion assumes
        // real, tapered open ends. Applying it anyway was a real bug —
        // found directly against a real branching-plus-hole letterform
        // shape (a "P"), whose hole loop failed even once its rails came
        // back fully covered and geometrically sound.

        let rawWidths = (0...crossingCount).map { resampledA[$0].distance(to: resampledB[$0]) }
        let averageWidth = rawWidths.reduce(0, +) / Double(max(1, rawWidths.count))
        let pullCompMM = parameters.pullCompensationMM
            ?? PullCompensationCalculator.estimate(stitchType: .satin, densityMM: density, objectWidthMM: averageWidth, fabricType: parameters.fabricType)

        var expandedA: [Point2D] = []
        var expandedB: [Point2D] = []
        for i in 0...crossingCount {
            let a = resampledA[i], b = resampledB[i]
            expandedA.append(pushOutward(a, from: b, by: pullCompMM / 2))
            expandedB.append(pushOutward(b, from: a, by: pullCompMM / 2))
        }
        let widths = zip(expandedA, expandedB).map { $0.distance(to: $1) }
        // Width is deliberately NOT a rejection reason here, matching
        // `computeCrossings` for the single-column path: `generateBranching`
        // runs every segment's crossings through the same per-crossing
        // satin/fill/narrow-run split `generatePartial` uses
        // (`stitchesSplittingByWidth`), so a stretch too wide for satin
        // sews as a local fill sub-region rather than either emitting an
        // impractically wide zigzag or rejecting the whole letter. A strict
        // `maxSatinWidthMM` cap used to live here instead; found directly
        // against a real cap-logo "B" at 100mm whose bowls reached ~16mm,
        // which it rejected outright, sending the entire letter to tatami.
        return (expandedA, expandedB, widths, mitre)
    }

    /// Orders a stroke topology's edges into one continuous walk via a
    /// simple greedy "follow the node you just arrived at" rule, flipping
    /// each edge's own direction as needed so it continues from wherever
    /// the previous one left off — the same idea `ObjectSequencer` applies
    /// across whole objects, just one level down, across one shape's own
    /// segments. Deliberately simple (no 2-opt improvement pass): proving
    /// the segment-decomposition mechanism itself is this stage's goal,
    /// not stitch-path optimality, which real-file measurement in a later
    /// stage can motivate improving if the naive order leaves visible
    /// excess travel. A segment with no remaining neighbor touching the
    /// current node (a disjoint piece, or having exhausted the current
    /// branch) just starts the next leg from wherever it naturally sits.
    private static func orderedEdges(_ topology: StrokeTopologyAnalyzer.Topology) -> [StrokeTopologyAnalyzer.Edge] {
        var remaining = topology.edges
        guard !remaining.isEmpty else { return [] }

        var ordered: [StrokeTopologyAnalyzer.Edge] = [remaining.removeFirst()]
        var currentNode = ordered[0].endNodeID
        while !remaining.isEmpty {
            var foundIndex: Int?
            for i in remaining.indices {
                let touchesCurrentNode = remaining[i].startNodeID == currentNode || remaining[i].endNodeID == currentNode
                if touchesCurrentNode {
                    foundIndex = i
                    break
                }
            }

            let next: StrokeTopologyAnalyzer.Edge
            if let index = foundIndex {
                var candidate = remaining.remove(at: index)
                if candidate.startNodeID != currentNode {
                    candidate = reversed(candidate)
                }
                next = candidate
            } else {
                // Nothing left touches the current node (the walk exhausted
                // this branch of a graph with cycles) -- rather than an
                // arbitrary next edge taken as-is, start the next leg from
                // whichever remaining edge END is physically nearest to
                // where the needle currently is, flipping that edge if its
                // far end is the nearer one. This can't make the hop
                // connected, but it makes it as short as the graph allows;
                // `generateBranchingRuns` then decides whether even that
                // hop can be sewn or must become a trim+jump.
                let here = ordered.last?.polyline.last ?? remaining[0].polyline[0]
                var bestIndex = 0, bestFlip = false, bestDistance = Double.infinity
                for i in remaining.indices {
                    let startDistance = here.distance(to: remaining[i].polyline[0])
                    let endDistance = here.distance(to: remaining[i].polyline[remaining[i].polyline.count - 1])
                    if startDistance < bestDistance { bestDistance = startDistance; bestIndex = i; bestFlip = false }
                    if endDistance < bestDistance { bestDistance = endDistance; bestIndex = i; bestFlip = true }
                }
                let candidate = remaining.remove(at: bestIndex)
                next = bestFlip ? reversed(candidate) : candidate
            }
            ordered.append(next)
            currentNode = next.endNodeID
        }
        return ordered
    }

    private static func reversed(_ edge: StrokeTopologyAnalyzer.Edge) -> StrokeTopologyAnalyzer.Edge {
        StrokeTopologyAnalyzer.Edge(startNodeID: edge.endNodeID, endNodeID: edge.startNodeID,
                                    isClosedLoop: edge.isClosedLoop,
                                    polyline: Array(edge.polyline.reversed()),
                                    widthsMM: Array(edge.widthsMM.reversed()))
    }
}
