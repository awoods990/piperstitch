import Foundation

/// Satin columns read off a glyph's own outline.
///
/// The rest of the engine reconstructs a stroke: it rasterizes the shape,
/// thins it to a skeleton, and casts rays out from the skeleton to guess
/// where the edges were. For traced artwork there is no alternative — the
/// only thing we have is pixels. For a typed letter there is: the font
/// hands us the exact outline, and reconstructing it from a raster throws
/// that away and then spends a great deal of care repairing the loss. A
/// medial axis also stops half a stroke width short of a flat cap, so
/// every arm finished short of its own outline.
///
/// So for glyphs this reads the columns instead of inferring them. Walk
/// the outline; at each sample cast inward and look for the point facing
/// back. A pair that face each other across the shape is a satin
/// crossing — literally the stitch the needle makes. Runs of consecutive
/// crossings that do not cross each other are one column.
///
/// Two properties follow from the construction rather than from tuning.
/// Every crossing lands exactly on the outline, so nothing spills outside
/// the letter; and a bar's last crossing sits on the bar's own end, so
/// slab terminals come out square.
public enum GlyphColumnExtractor {
    /// Along-the-outline sampling. Finer than the stitch spacing, because
    /// these samples decide where a column starts and stops, not where a
    /// stitch goes: the rails are resampled downstream.
    public static let sampleStepMM = 0.25
    /// How far off parallel the far wall may be and still count as the
    /// other side of a column. Beyond this the ray is skimming an edge
    /// rather than crossing a stroke.
    public static let facingTolerance = 0.72
    /// A run this short is a corner artefact, not a column.
    public static let minimumCrossings = 2

    public static func columns(for shape: VectorShape) -> [SatinColumn] {
        let polygons = shape.subPaths.map { closedPoints($0.points) }.filter { $0.count >= 3 }
        guard !polygons.isEmpty else { return [] }
        let box = shape.boundingBox
        // Generous on purpose: a chord spanning an H's whole crossbar,
        // stems included, is a real column and the only thing that covers
        // the corners where bar meets stem. Anything too wide to sew as
        // satin is split further downstream, where that decision lives.
        let maxWidth = max(box.width, box.height) * 1.25
        var segments: [(Point2D, Point2D)] = []
        for polygon in polygons {
            for i in polygon.indices { segments.append((polygon[i], polygon[(i + 1) % polygon.count])) }
        }

        var runs: [[(a: Point2D, b: Point2D)]] = []
        for polygon in polygons {
            let samples = resampled(polygon, step: sampleStepMM)
            guard samples.count >= 3 else { continue }
            let inward = inwardNormals(samples, counterClockwise: PolygonGeometry.signedArea(polygon) > 0)
            var crossings: [(a: Point2D, b: Point2D)?] = []
            for (point, normal) in zip(samples, inward) {
                crossings.append(crossing(from: point, along: normal, segments: segments, polygons: polygons, maxWidth: maxWidth))
            }
            var run: [(a: Point2D, b: Point2D)] = []
            for index in 0...crossings.count {
                guard index < crossings.count, let crossing = crossings[index] else {
                    if run.count >= minimumCrossings { runs.append(run) }
                    run.removeAll()
                    continue
                }
                // Two crossings that do not cross each other can still be
                // far apart: walking down the end of an E's top arm, the
                // far wall jumps to the next arm, and the quad between
                // those two crossings sweeps straight across the notch
                // between them. The near rail advances one sample at a
                // time by construction; the far rail has to as well, or it
                // is a different wall and a different column.
                let jumped = run.last.map { $0.b.distance(to: crossing.b) > sampleStepMM * 4 } ?? false
                if let previous = run.last, jumped || segmentsIntersect(previous.a, previous.b, crossing.a, crossing.b) {
                    if run.count >= minimumCrossings { runs.append(run) }
                    run.removeAll()
                }
                run.append(crossing)
            }
            if run.count >= minimumCrossings { runs.append(run) }
        }

        // Every column is found twice, once from each side; sewing both
        // would lay the letter down at double density. So a run takes the
        // ground its crossings stand on, and the order decides who gets
        // there first.
        //
        // Long runs of short crossings go first, because that is what a
        // stroke is: a stem is many narrow chords across it. Sorting by
        // length alone let the one wide chord spanning an E's bar and its
        // stem together claim the junction, and the stem then had to sew
        // around it at the wrong angle. A digitizer sews the stem across
        // the stem.
        func slenderness(_ run: [(a: Point2D, b: Point2D)]) -> Double {
            let widths = run.map { $0.a.distance(to: $0.b) }.sorted()
            let median = widths[widths.count / 2]
            return median > 1e-9 ? Double(run.count) / median : 0
        }
        runs.sort { slenderness($0) > slenderness($1) }
        var claimed: [Point2D] = []
        var out: [SatinColumn] = []
        for run in runs {
            let middles = run.map { Point2D(($0.a.x + $0.b.x) / 2, ($0.a.y + $0.b.y) / 2) }
            let reach = sampleStepMM * 1.5
            // A column earns its place by covering ground nobody has
            // covered. Letting one in that merely overlaps its neighbours
            // laid a second set of stitches across an E's bar at its own
            // angle, and the letter came out banded.
            let fresh = middles.filter { m in !claimed.contains { abs($0.x - m.x) < reach && abs($0.y - m.y) < reach } }
            if Double(fresh.count) < Double(middles.count) * 0.5 { continue }
            out.append(SatinColumn(railA: run.map { $0.a }, railB: run.map { $0.b }))
            claimed.append(contentsOf: middles)
        }
        return ordered(out, polygons: polygons)
    }

    /// Sew the columns in an order a hand would use: whichever is nearest
    /// to where the last one finished, reversed if that end is nearer.
    ///
    /// They come out of the search in the order they claimed their ground,
    /// which is by how stroke-like they are and so spatially arbitrary --
    /// an E's middle bar, then its foot, then its stem. Every jump that
    /// leaves the ink is a thread cut, and sewing them in reading order
    /// turns most of those jumps into a short walk under stitching that is
    /// already there.
    private static func ordered(_ columns: [SatinColumn], polygons: [[Point2D]]) -> [SatinColumn] {
        guard columns.count > 2 else { return columns }
        // What decides a thread cut is not how far the next column is but
        // whether the walk to it stays in the ink -- `joinedRuns` joins a
        // hop that stays on the shape however long it is, and cuts one
        // that leaves it however short. Ordering by distance alone made it
        // worse: the nearest column is often across a counter.
        func walkable(_ from: Point2D, _ to: Point2D) -> Bool {
            let steps = 8
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let point = Point2D(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t)
                if !PolygonGeometry.pointInPolygons(point, polygons: polygons) { return false }
            }
            return true
        }
        func start(_ c: SatinColumn) -> Point2D { c.railA.first ?? Point2D(0, 0) }
        func end(_ c: SatinColumn) -> Point2D { c.railB.last ?? c.railA.last ?? Point2D(0, 0) }
        func reversed(_ c: SatinColumn) -> SatinColumn {
            SatinColumn(railA: c.railA.reversed(), railB: c.railB.reversed(), travelOut: c.travelOut)
        }
        var remaining = columns
        var out: [SatinColumn] = [remaining.removeFirst()]
        while !remaining.isEmpty {
            let here = end(out[out.count - 1])
            var bestIndex = 0, bestFlip = false
            var best = (walk: false, distance: Double.infinity)
            for (index, candidate) in remaining.enumerated() {
                for flip in [false, true] {
                    let target = flip ? end(candidate) : start(candidate)
                    let distance = here.distance(to: target)
                    let walk = walkable(here, target)
                    // A walk beats any jump; between two of a kind, nearer.
                    if (walk && !best.walk) || (walk == best.walk && distance < best.distance) {
                        best = (walk, distance); bestIndex = index; bestFlip = flip
                    }
                }
            }
            let picked = remaining.remove(at: bestIndex)
            out.append(bestFlip ? reversed(picked) : picked)
        }
        return out
    }

    /// How much of `shape` the columns actually cover, 0...1, and how much
    /// they put outside it. Measured rather than argued: the glyph library
    /// is built offline, so each glyph can be digitized both ways and the
    /// better one kept, and no letter can come out worse than before.
    public static func coverage(of columns: [SatinColumn], in shape: VectorShape, resolution: Int = 200) -> (covered: Double, spill: Double) {
        let polygons = shape.subPaths.map { closedPoints($0.points) }.filter { $0.count >= 3 }
        let box = shape.boundingBox
        guard !polygons.isEmpty, box.width > 0, box.height > 0 else { return (0, 0) }
        let pad = max(box.width, box.height) * 0.05
        let originX = box.minX - pad, originY = box.minY - pad
        let scale = Double(resolution) / (max(box.width, box.height) + pad * 2)
        func raster(_ paths: [[Point2D]], evenOdd: Bool) -> [Bool] {
            var grid = [Bool](repeating: false, count: resolution * resolution)
            for row in 0..<resolution {
                let y = originY + (Double(row) + 0.5) / scale
                var spans: [Double] = []
                for path in paths {
                    for i in path.indices {
                        let a = path[i], b = path[(i + 1) % path.count]
                        if (a.y > y) != (b.y > y) { spans.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)) }
                    }
                    if !evenOdd {                     // one path at a time, unioned by the caller
                        spans.sort()
                        var index = 0
                        while index + 1 < spans.count {
                            fill(&grid, row: row, from: spans[index], to: spans[index + 1], originX: originX, scale: scale, resolution: resolution)
                            index += 2
                        }
                        spans.removeAll()
                    }
                }
                guard evenOdd else { continue }
                spans.sort()
                var index = 0
                while index + 1 < spans.count {
                    fill(&grid, row: row, from: spans[index], to: spans[index + 1], originX: originX, scale: scale, resolution: resolution)
                    index += 2
                }
            }
            return grid
        }
        let glyph = raster(polygons, evenOdd: true)
        let quads = columns.map { $0.railA + $0.railB.reversed() }.filter { $0.count >= 3 }
        let sewn = raster(quads, evenOdd: false)
        var inside = 0, hit = 0, spill = 0
        for i in 0..<(resolution * resolution) {
            if glyph[i] { inside += 1; if sewn[i] { hit += 1 } } else if sewn[i] { spill += 1 }
        }
        guard inside > 0 else { return (0, 0) }
        return (Double(hit) / Double(inside), Double(spill) / Double(inside))
    }

    private static func fill(_ grid: inout [Bool], row: Int, from: Double, to: Double, originX: Double, scale: Double, resolution: Int) {
        let start = max(0, Int((from - originX) * scale)), end = min(resolution - 1, Int((to - originX) * scale))
        guard start <= end else { return }
        for column in start...end { grid[row * resolution + column] = true }
    }

    private static func closedPoints(_ points: [Point2D]) -> [Point2D] {
        guard points.count > 1, let first = points.first, let last = points.last, first == last else { return points }
        return Array(points.dropLast())
    }

    private static func resampled(_ polygon: [Point2D], step: Double) -> [Point2D] {
        var out: [Point2D] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let distance = a.distance(to: b)
            guard distance > 1e-9 else { continue }
            let pieces = max(1, Int(distance / step))
            for j in 0..<pieces {
                let t = Double(j) / Double(pieces)
                out.append(Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
            }
        }
        return out
    }

    private static func inwardNormals(_ samples: [Point2D], counterClockwise: Bool) -> [Point2D] {
        let count = samples.count
        return samples.indices.map { i in
            let before = samples[(i - 1 + count) % count], after = samples[(i + 1) % count]
            let tx = after.x - before.x, ty = after.y - before.y
            let length = (tx * tx + ty * ty).squareRoot()
            guard length > 1e-12 else { return Point2D(0, 0) }
            let ux = tx / length, uy = ty / length
            return counterClockwise ? Point2D(-uy, ux) : Point2D(uy, -ux)
        }
    }

    private static func crossing(from point: Point2D, along normal: Point2D, segments: [(Point2D, Point2D)],
                                 polygons: [[Point2D]], maxWidth: Double) -> (a: Point2D, b: Point2D)? {
        guard normal.x != 0 || normal.y != 0 else { return nil }
        let probe = Point2D(point.x + normal.x * 1e-4, point.y + normal.y * 1e-4)
        guard PolygonGeometry.pointInPolygons(probe, polygons: polygons) else { return nil }
        var bestT: Double?
        var bestDirection: Point2D?
        let skip = sampleStepMM * 0.25
        for (p1, p2) in segments {
            let ex = p2.x - p1.x, ey = p2.y - p1.y
            let denominator = normal.x * ey - normal.y * ex
            guard abs(denominator) > 1e-12 else { continue }
            let t = ((p1.x - point.x) * ey - (p1.y - point.y) * ex) / denominator
            let u = ((p1.x - point.x) * normal.y - (p1.y - point.y) * normal.x) / denominator
            guard t > skip, u >= -1e-9, u <= 1 + 1e-9 else { continue }
            if bestT == nil || t < bestT! { bestT = t; bestDirection = Point2D(ex, ey) }
        }
        guard let t = bestT, t <= maxWidth, let direction = bestDirection else { return nil }
        let length = (direction.x * direction.x + direction.y * direction.y).squareRoot()
        guard length > 1e-12 else { return nil }
        // Skimming an edge rather than crossing a stroke.
        let facing = abs(normal.x * (direction.x / length) + normal.y * (direction.y / length))
        guard facing <= facingTolerance else { return nil }
        return (point, Point2D(point.x + normal.x * t, point.y + normal.y * t))
    }

    private static func segmentsIntersect(_ p1: Point2D, _ p2: Point2D, _ p3: Point2D, _ p4: Point2D) -> Bool {
        func side(_ a: Point2D, _ b: Point2D, _ c: Point2D) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = side(p3, p4, p1), d2 = side(p3, p4, p2), d3 = side(p1, p2, p3), d4 = side(p1, p2, p4)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }
}
