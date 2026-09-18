import Foundation

/// Mitre corners for satin columns -- docs/WILCOM_MANUAL_REVIEW.md A4.
///
/// `SatinColumnGenerator` matches a column's two rails *proportionally by
/// arc length*: crossing k joins the point k/n of the way along rail A to
/// the point k/n along rail B. That is exactly right for a smooth curve
/// (the outer rail's extra length really is spread evenly round the
/// bend), and exactly wrong for a sharp corner, where all of the outer
/// rail's extra length (about two column widths) belongs to the corner
/// square alone. Spread proportionally, it becomes a lean of up to 45°
/// on every crossing of the column, worst on an "L" or "T" with legs of
/// unequal length -- visibly slanted satin where a digitizer would sew
/// perpendicular crossings up to the corner and a **mitre** at it.
///
/// `findCorners` pairs a sharp vertex on one rail with the matching
/// vertex on the other, and the generator then matches each leg between
/// corners on its own (perpendicular, because each leg's rails are the
/// same length once the corner square is set aside) and fills the corner
/// square with `mitreCrossings`: crossings parallel to each leg, ending
/// on the diagonal from the inside vertex to the outside vertex, getting
/// shorter toward the tip, overlapping the diagonal slightly so the seam
/// never opens. Corners turning less than ~40° or more than ~140° are
/// not mitred and stay proportional (the lean is small for a gentle bend,
/// and a hairpin isn't a column corner).
enum SatinCorners {
    static let minimumTurnDegrees = 40.0
    static let maximumTurnDegrees = 140.0
    /// How far each leg's crossings extend past the mitre diagonal so the
    /// two legs overlap at the seam (Wilcom: "Mitre overlap: 0.5 mm").
    static let overlapMM = 0.5

    struct Corner {
        var outerIsA: Bool
        var pa: Point2D          // outside vertex (on the outer rail)
        var pb: Point2D          // inside vertex (on the inner rail)
        var t1: Point2D          // outer rail direction arriving at pa
        var t2: Point2D          // outer rail direction leaving pa
        var n1: Point2D          // inward normal of leg 1
        var n2: Point2D          // inward normal of leg 2
        var l1: Double           // leg-1 length from the diagonal's foot to the tip
        var l2: Double
        var w1: Double           // column width at each leg
        var w2: Double
        var sOuterIn: Double     // arc length on the outer rail where the corner square begins
        var sOuterOut: Double    // ... and ends
        var sInner: Double       // arc length on the inner rail of the inside vertex
    }

    // MARK: - corner detection

    private struct Candidate {
        var index: Int
        var point: Point2D
        var s: Double
        var dirIn: Point2D
        var dirOut: Point2D
        var turnDegrees: Double
        var turnSign: Double
    }

    private static func cumulative(_ rail: [Point2D]) -> [Double] {
        var out = [0.0]
        for i in 1..<rail.count { out.append(out[i - 1] + rail[i].distance(to: rail[i - 1])) }
        return out
    }

    private static func candidates(on rail: [Point2D], cumulative s: [Double], windowMM: Double) -> [Candidate] {
        guard rail.count >= 3 else { return [] }
        var found: [Candidate] = []
        for v in 1..<(rail.count - 1) {
            var j = v - 1
            while j > 0, s[v] - s[j] < windowMM { j -= 1 }
            var k = v + 1
            while k < rail.count - 1, s[k] - s[v] < windowMM { k += 1 }
            guard let dIn = unit(rail[v] - rail[j]), let dOut = unit(rail[k] - rail[v]) else { continue }
            let turn = acos(max(-1, min(1, dot(dIn, dOut)))) * 180 / .pi
            guard turn >= minimumTurnDegrees, turn <= maximumTurnDegrees else { continue }
            found.append(Candidate(index: v, point: rail[v], s: s[v], dirIn: dIn, dirOut: dOut, turnDegrees: turn, turnSign: cross(dIn, dOut) >= 0 ? 1 : -1))
        }
        // Keep only the sharpest candidate within each window's reach.
        var kept: [Candidate] = []
        for c in found {
            if let last = kept.last, c.s - last.s < windowMM * 2 {
                if c.turnDegrees > last.turnDegrees { kept[kept.count - 1] = c }
            } else {
                kept.append(c)
            }
        }
        return kept
    }

    /// The mitre-able corners of a column, in rail order, or [] when the
    /// column has none (the common case, which costs one pass over each
    /// rail's vertices).
    static func findCorners(railA: [Point2D], railB: [Point2D]) -> [Corner] {
        guard railA.count >= 3 || railB.count >= 3, railA.count > 1, railB.count > 1 else { return [] }
        let sampled = 10
        let a = PolygonGeometry.resampleByCount(railA, count: sampled)
        let b = PolygonGeometry.resampleByCount(railB, count: sampled)
        let width = zip(a, b).map { $0.distance(to: $1) }.reduce(0, +) / Double(a.count)
        guard width > 0.3 else { return [] }
        let sA = cumulative(railA), sB = cumulative(railB)
        let window = max(width * 0.5, 0.5)
        let ca = candidates(on: railA, cumulative: sA, windowMM: window)
        let cb = candidates(on: railB, cumulative: sB, windowMM: window)
        guard !ca.isEmpty, !cb.isEmpty else { return [] }

        // Pair each A candidate with the nearest B candidate of the same
        // turn sense within a plausible distance; pairs must advance
        // along both rails.
        var corners: [Corner] = []
        var usedB = Set<Int>()
        var lastOuterOut = -Double.infinity, lastInner = -Double.infinity
        for pa in ca {
            let match = cb.enumerated()
                .filter { !usedB.contains($0.offset) && $0.element.turnSign == pa.turnSign }
                .map { ($0.offset, $0.element, pa.point.distance(to: $0.element.point)) }
                .filter { $0.2 >= width * 0.4 && $0.2 <= width * 2.5 }
                .min { $0.2 < $1.2 }
            guard let (bIndex, pb, _) = match else { continue }
            // Which rail is outside at this corner: the one whose turn is
            // toward its own interior side (the other rail).
            let sideOfBFromA = cross(pa.dirIn, pb.point - pa.point) >= 0 ? 1.0 : -1.0
            let outerIsA = sideOfBFromA == pa.turnSign
            let outer = outerIsA ? pa : pb, inner = outerIsA ? pb : pa
            guard let corner = build(outerIsA: outerIsA, outer: outer, inner: inner, width: width),
                  corner.sOuterIn > lastOuterOut, corner.sInner > lastInner else { continue }
            corners.append(corner)
            usedB.insert(bIndex)
            lastOuterOut = corner.sOuterOut
            lastInner = corner.sInner
        }
        return corners
    }

    /// Corners of a PAIRED rail set (a branch segment's: railA[i] and
    /// railB[i] are the two ends of one skeleton crossing). The outside
    /// vertex is found as a sharp turn on either rail; the inside vertex
    /// is simply the other rail's point at the same index -- the pairing
    /// already says which inner point belongs to which outer one, so
    /// there is no search for a matching inner turn. `findCorners`'
    /// search paired the LIBBi "B"'s top-left outer corner with a stall
    /// at the junction 15 mm away (its true inner corner had been
    /// smoothed into a curve), and the mitre legs ran the whole top bar.
    static func findPairedCorners(railA: [Point2D], railB: [Point2D]) -> [Corner] {
        guard railA.count == railB.count, railA.count >= 3 else { return [] }
        let widths = zip(railA, railB).map { $0.distance(to: $1) }
        let width = widths.reduce(0, +) / Double(widths.count)
        guard width > 0.3 else { return [] }
        let sA = cumulative(railA), sB = cumulative(railB)
        let window = max(width * 0.5, 0.5)
        var found: [(outerIsA: Bool, outer: Candidate, inner: Candidate)] = []
        for (isA, rail, s, other, sOther) in [(true, railA, sA, railB, sB), (false, railB, sB, railA, sA)] {
            for c in candidates(on: rail, cumulative: s, windowMM: window) {
                // Outside vertex: the rail turns away from the other rail.
                let toOther = other[c.index] - c.point
                let sideOfOther = cross(c.dirIn, toOther) >= 0 ? 1.0 : -1.0
                guard sideOfOther == c.turnSign else { continue }
                let innerPoint = other[c.index]
                let inner = Candidate(index: c.index, point: innerPoint, s: sOther[c.index], dirIn: c.dirIn, dirOut: c.dirOut, turnDegrees: c.turnDegrees, turnSign: c.turnSign)
                found.append((isA, c, inner))
            }
        }
        found.sort { $0.outer.index < $1.outer.index }
        var corners: [Corner] = []
        var lastIndex = -1
        for f in found {
            guard f.outer.index > lastIndex, let corner = build(outerIsA: f.outerIsA, outer: f.outer, inner: f.inner, width: widths[f.outer.index]) else { continue }
            corners.append(corner)
            lastIndex = f.outer.index
        }
        return corners
    }

    private static func build(outerIsA: Bool, outer: Candidate, inner: Candidate, width: Double) -> Corner? {
        let pa = outer.point, pb = inner.point
        let t1 = outer.dirIn, t2 = outer.dirOut
        var n1 = Point2D(-t1.y, t1.x); if dot(pb - pa, n1) < 0 { n1 = Point2D(t1.y, -t1.x) }
        var n2 = Point2D(-t2.y, t2.x); if dot(pb - pa, n2) < 0 { n2 = Point2D(t2.y, -t2.x) }
        let w1 = dot(pb - pa, n1), w2 = dot(pb - pa, n2)
        let l1 = dot(pa - pb, t1), l2 = dot(pb - pa, t2)
        guard w1 > 0.2, w2 > 0.2, l1 > 0.2, l2 > 0.2, l1 <= 3 * width, l2 <= 3 * width, w1 <= 3 * width, w2 <= 3 * width else { return nil }
        return Corner(outerIsA: outerIsA, pa: pa, pb: pb, t1: t1, t2: t2, n1: n1, n2: n2, l1: l1, l2: l2, w1: w1, w2: w2,
                      sOuterIn: outer.s - l1, sOuterOut: outer.s + l2, sInner: inner.s)
    }

    // MARK: - the mitre itself

    /// The corner square's crossings at `spacingMM`, as (a, b) pairs
    /// keeping rail identity: leg 1 from the diagonal's foot to the tip
    /// (long to short), one stitch into the tip, leg 2 from the tip out
    /// (short to long). Each crossing runs from the outer rail toward the
    /// diagonal and `overlapMM` past it, never past the column's width.
    static func mitreCrossings(_ c: Corner, spacingMM: Double) -> (a: [Point2D], b: [Point2D]) {
        var outerPoints: [Point2D] = [], innerPoints: [Point2D] = []
        guard let diagonal = unit(c.pa - c.pb), spacingMM > 0 else { return ([], []) }

        func add(outer o: Point2D, along n: Point2D, fullWidth: Double) {
            // From the outer point inward (along the inward normal) to the
            // diagonal, plus the overlap, capped at the column's width.
            guard let hit = lineIntersection(o, n, c.pb, diagonal) else { return }
            let s = min(o.distance(to: hit) + overlapMM, fullWidth)
            outerPoints.append(o)
            innerPoints.append(Point2D(o.x + n.x * s, o.y + n.y * s))
        }

        let n1Count = max(1, Int((c.l1 / spacingMM).rounded()))
        for k in 0..<n1Count {
            let d = c.l1 - Double(k) * spacingMM
            guard d > spacingMM * 0.25 else { break }
            add(outer: Point2D(c.pa.x - c.t1.x * d, c.pa.y - c.t1.y * d), along: c.n1, fullWidth: c.w1)
        }
        // The tip: a single short stitch into the outside vertex along the diagonal.
        outerPoints.append(c.pa)
        innerPoints.append(Point2D(c.pa.x - diagonal.x * min(overlapMM, 0.3), c.pa.y - diagonal.y * min(overlapMM, 0.3)))
        let n2Count = max(1, Int((c.l2 / spacingMM).rounded()))
        for k in 1...n2Count {
            let d = min(Double(k) * spacingMM, c.l2)
            add(outer: Point2D(c.pa.x + c.t2.x * d, c.pa.y + c.t2.y * d), along: c.n2, fullWidth: c.w2)
        }
        return c.outerIsA ? (outerPoints, innerPoints) : (innerPoints, outerPoints)
    }

    // MARK: - rail pieces

    /// The part of `rail` between arc lengths `from` and `to`, with
    /// interpolated endpoints. Clamped to the rail.
    static func subPolyline(_ rail: [Point2D], from: Double, to: Double) -> [Point2D] {
        guard rail.count > 1 else { return rail }
        let s = cumulative(rail)
        let total = s[s.count - 1]
        let a = max(0, min(total, from)), b = max(0, min(total, to))
        guard b > a + 1e-9 else { return [pointAt(rail, s, a)] }
        var out = [pointAt(rail, s, a)]
        for i in 0..<rail.count where s[i] > a + 1e-9 && s[i] < b - 1e-9 { out.append(rail[i]) }
        out.append(pointAt(rail, s, b))
        return out
    }

    private static func pointAt(_ rail: [Point2D], _ s: [Double], _ target: Double) -> Point2D {
        if target <= 0 { return rail[0] }
        for i in 1..<rail.count where s[i] >= target {
            let segLen = s[i] - s[i - 1]
            let t = segLen > 0 ? (target - s[i - 1]) / segLen : 0
            return Point2D(rail[i - 1].x + (rail[i].x - rail[i - 1].x) * t, rail[i - 1].y + (rail[i].y - rail[i - 1].y) * t)
        }
        return rail[rail.count - 1]
    }

    // MARK: - small vector helpers

    private static func unit(_ v: Point2D) -> Point2D? {
        let len = (v.x * v.x + v.y * v.y).squareRoot()
        guard len > 1e-9 else { return nil }
        return Point2D(v.x / len, v.y / len)
    }

    private static func dot(_ a: Point2D, _ b: Point2D) -> Double { a.x * b.x + a.y * b.y }
    private static func cross(_ a: Point2D, _ b: Point2D) -> Double { a.x * b.y - a.y * b.x }

    /// Intersection of the lines p + s·d and q + u·e.
    private static func lineIntersection(_ p: Point2D, _ d: Point2D, _ q: Point2D, _ e: Point2D) -> Point2D? {
        let denominator = d.x * e.y - d.y * e.x
        guard abs(denominator) > 1e-9 else { return nil }
        let qp = q - p
        let s = (qp.x * e.y - qp.y * e.x) / denominator
        return Point2D(p.x + d.x * s, p.y + d.y * s)
    }
}
