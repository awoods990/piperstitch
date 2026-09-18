import Foundation

/// One satin column, as a digitizer draws it: two rails, sewn as
/// crossings between them from start to end. The generator normally
/// derives rails from a shape at sew time; a column can also be stored
/// -- a font's glyphs, digitized once at a size where the generator is
/// reliable and reviewed -- and scaled to any size, so a letter sews the
/// same way every time (`GlyphColumnLibrary`).
///
/// Coordinates are in whatever frame the owner uses: millimetres on an
/// `EmbroideryObject`, cap-height units (1000 per cap height, baseline at
/// y = 0, y down) in the glyph library.
public struct SatinColumn: Codable, Sendable, Equatable {
    public var railA: [Point2D]
    public var railB: [Point2D]
    /// Sew the column's midline from its end back to its start first, as
    /// a travel run, then the crossings start to end -- the way the
    /// branching generator sews a dead-end arm so the run finishes back
    /// at the junction it left from.
    public var travelOut: Bool

    public init(railA: [Point2D], railB: [Point2D], travelOut: Bool = false) {
        self.railA = railA
        self.railB = railB
        self.travelOut = travelOut
    }

    private enum CodingKeys: String, CodingKey { case railA = "a", railB = "b", travelOut = "t" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        railA = try c.decode([Point2D].self, forKey: .railA)
        railB = try c.decode([Point2D].self, forKey: .railB)
        travelOut = try c.decodeIfPresent(Bool.self, forKey: .travelOut) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(railA, forKey: .railA)
        try c.encode(railB, forKey: .railB)
        if travelOut { try c.encode(true, forKey: .travelOut) }
    }

    /// The column mapped point by point.
    public func mapped(_ transform: (Point2D) -> Point2D) -> SatinColumn {
        SatinColumn(railA: railA.map(transform), railB: railB.map(transform), travelOut: travelOut)
    }

    /// The chords' midpoints, start to end -- by index when the rails are
    /// paired (the library's columns), else by arc-length fraction.
    public var midline: [Point2D] {
        if railA.count == railB.count, railA.count >= 2 {
            return zip(railA, railB).map { Point2D(($0.x + $1.x) / 2, ($0.y + $1.y) / 2) }
        }
        let n = max(railA.count, railB.count)
        guard n >= 2, railA.count >= 2, railB.count >= 2 else { return [] }
        return (0..<n).map { i in
            let t = Double(i) / Double(n - 1)
            let a = SatinColumn.point(along: railA, fraction: t), b = SatinColumn.point(along: railB, fraction: t)
            return Point2D((a.x + b.x) / 2, (a.y + b.y) / 2)
        }
    }

    /// The paired chords thinned: a chord is dropped when both its ends
    /// lie within `epsilon` of the line between the kept neighbours
    /// (Douglas-Peucker over the pairs), so the pairing survives.
    public func thinned(epsilon: Double) -> SatinColumn {
        guard railA.count == railB.count, railA.count > 2 else { return self }
        var keep = [Bool](repeating: false, count: railA.count)
        keep[0] = true; keep[railA.count - 1] = true
        func deviation(_ i: Int, _ lo: Int, _ hi: Int) -> Double {
            func d(_ p: Point2D, _ a: Point2D, _ b: Point2D) -> Double {
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                guard len2 > 1e-12 else { return p.distance(to: a) }
                let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
                return p.distance(to: Point2D(a.x + dx * t, a.y + dy * t))
            }
            return max(d(railA[i], railA[lo], railA[hi]), d(railB[i], railB[lo], railB[hi]))
        }
        var stack = [(0, railA.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi - lo > 1 else { continue }
            var worst = lo + 1, worstDeviation = -1.0
            for i in (lo + 1)..<hi {
                let dev = deviation(i, lo, hi)
                if dev > worstDeviation { worstDeviation = dev; worst = i }
            }
            if worstDeviation > epsilon {
                keep[worst] = true
                stack.append((lo, worst)); stack.append((worst, hi))
            }
        }
        var a: [Point2D] = [], b: [Point2D] = []
        for i in railA.indices where keep[i] { a.append(railA[i]); b.append(railB[i]) }
        return SatinColumn(railA: a, railB: b, travelOut: travelOut)
    }

    static func point(along polyline: [Point2D], fraction: Double) -> Point2D {
        guard polyline.count > 1 else { return polyline.first ?? Point2D(0, 0) }
        let total = PolygonGeometry.pathLength(polyline)
        guard total > 0 else { return polyline[0] }
        var target = max(0, min(1, fraction)) * total
        for i in 1..<polyline.count {
            let d = polyline[i - 1].distance(to: polyline[i])
            if target <= d {
                let t = d > 0 ? target / d : 0
                return Point2D(polyline[i - 1].x + (polyline[i].x - polyline[i - 1].x) * t, polyline[i - 1].y + (polyline[i].y - polyline[i - 1].y) * t)
            }
            target -= d
        }
        return polyline[polyline.count - 1]
    }
}
