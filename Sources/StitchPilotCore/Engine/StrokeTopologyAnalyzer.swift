import Foundation

/// Decomposes a shape's stroke into a topology graph — nodes (endpoints,
/// junctions) and edges (individual stroke segments, each with a local
/// width profile) — as the foundation for satin generation on branching
/// shapes (a letter like "A", "B", "R") that today's
/// `SatinColumnGenerator.computeRails` can't represent as one open column
/// or one ring. See DIGITIZING_ENGINE.md's branching-letter satin entry
/// for the staged rollout plan this is stage 1 of: this file only builds
/// the topology graph. It is not wired into `StitchTypeClassifier` or any
/// stitch generator anywhere yet — nothing downstream of this file exists
/// until a later stage.
///
/// Approach: rather than a vector method (straight skeleton, Voronoi
/// medial axis) — more precise on clean geometry but brittle on the
/// near-degenerate, noisy boundaries real raster-traced artwork actually
/// produces (this engine's own anti-aliasing fragmentation fixes exist
/// because of exactly that noise) — this rasterizes the shape onto a
/// temporary pixel grid and extracts its skeleton there: Zhang-Suen
/// thinning for topology (which pixels sit on the 1px-wide skeleton, and
/// how they connect), and a separate chamfer distance transform for local
/// stroke width (how far each skeleton pixel sits from the nearest
/// boundary/background pixel). Both are standard, well-specified
/// image-morphology algorithms with no ambiguous edge cases, which
/// matters more here than raw geometric precision: a topology analyzer
/// that's merely approximate but never produces a nonsensical graph is a
/// far safer foundation to build satin generation on than one that's
/// precise on paper but occasionally degenerates on real input.
public enum StrokeTopologyAnalyzer {

    // MARK: - Output types

    public struct Node: Hashable {
        public var id: Int
        /// Physical (mm) position — callers never need to know this was
        /// computed on a temporary raster grid at all.
        public var position: Point2D
        public var isJunction: Bool
        /// Local stroke half-width at this node, doubled — i.e. the full
        /// stroke width the skeleton was centered in at this point.
        public var widthMM: Double
    }

    /// One stroke segment between two nodes. A shape whose skeleton is a
    /// pure closed loop with no junction at all (a plain ring, e.g. a
    /// thick "O") produces a single edge with `isClosedLoop == true` and
    /// no nodes (`startNodeID == endNodeID == -1`) — a plain ring already
    /// has a direct, proven satin path
    /// (`SatinColumnGenerator.computeRingRails`); this analyzer only needs
    /// to not crash or produce a nonsensical graph when handed one, not
    /// special-case detecting it itself.
    public struct Edge {
        public var startNodeID: Int
        public var endNodeID: Int
        public var isClosedLoop: Bool
        /// Physical-space centerline samples, ordered start -> end (or,
        /// for a closed loop, in walk order starting and ending at the
        /// same point).
        public var polyline: [Point2D]
        /// Local stroke width (mm) at each `polyline` sample — same count
        /// and order as `polyline`.
        public var widthsMM: [Double]
    }

    public struct Topology {
        public var nodes: [Node]
        public var edges: [Edge]
    }

    public struct Parameters {
        /// Raster grid resolution for skeleton extraction — independent
        /// of any other rasterization elsewhere in the engine (import,
        /// `ShapeMerger`); this one only ever exists for the lifetime of
        /// one `analyze` call, matching `ShapeMerger`'s own default so
        /// the two raster-based subsystems behave comparably at the same
        /// nominal fineness.
        public var pixelsPerMM: Double = 10
        /// A spurious branch shorter than this multiple of the local
        /// stroke width at its junction end is pruned — thinning
        /// algorithms reliably throw off short fake branches at every
        /// real junction and at every bit of boundary noise. Such a spur
        /// reaches from the skeleton's junction point into one corner of
        /// the stroke, so it's well under one stroke width long; a real
        /// letterform branch is longer. Lowered from 1.5: a real Red Sox
        /// "B"'s own hook measured 9.5mm against a 7.1mm-wide junction
        /// (1.33x) and was being pruned as a spur, collapsing the top
        /// junction into one 68mm stem-over-the-top edge whose rails
        /// then had to negotiate hook material the topology no longer
        /// knew about. A hook or serif between 1x and 1.5x its junction's
        /// width is an ordinary real feature; nothing thinning produces
        /// reaches 1x.
        public var pruneBranchLengthFactor: Double = 1.0
        /// A floor under the factor above so a very thin stroke's own
        /// tiny width doesn't let a genuinely-too-short spurious branch
        /// survive.
        public var minPruneLengthMM: Double = 0.15
        /// A spur is pruned only when its far end is thinner than this
        /// fraction of the junction's width -- see `prune`.
        public var spurTipWidthFraction: Double = 0.62
        /// A spur ending at least this wide is a stroke, never noise.
        public var realStrokeTipWidthMM: Double = 2.5
        /// A spur shorter than this multiple of its junction's width whose
        /// tip is thinner than `serifWingTipWidthFraction` of it is a
        /// serif's wing, absorbed into the stroke's end -- see `prune`.
        /// A real hook (the Red Sox "B", 1.33x its junction's width) does
        /// not taper to a quarter of the stem.
        public var serifWingLengthFactor: Double = 1.4
        public var serifWingTipWidthFraction: Double = 0.3
        /// ...and no longer than this fraction of the longest other arm at
        /// the same junction (a serif's wing against its stem).
        public var serifWingOtherArmFraction: Double = 0.4
        /// Two junctions joined by an edge shorter than this multiple of
        /// the wider one's width are one junction -- see `prune`.
        public var junctionMergeDistanceFactor: Double = 1.5

        public init() {}
    }

    /// A raster grid beyond this many pixels is refused rather than
    /// attempted — this runs per-shape at classification/generation time
    /// (unlike `ShapeMerger`'s one-off merge), so it needs a tighter
    /// budget to stay cheap across a whole multi-letter design.
    private static let maxRasterPixels = 2_000_000

    /// The shortest circumference a closed-loop edge (see
    /// `walkClosedLoops`) is trusted as a real feature rather than
    /// dropped as thinning residue — see that guard's own comment.
    ///
    /// A real hole's skeleton loop runs through the MIDDLE of the ring
    /// of material around it, so its circumference is roughly
    /// π × (hole diameter + stroke width): for this to fall under 6mm the
    /// hole plus its own stroke would have to be under ~2mm across, well
    /// below anything a satin ring could sew (`minSatinWidthMM` alone is
    /// 1.5mm). Raised from 3.0: a real cap-logo "B" produced a 13-pixel
    /// isolated ring of 3.1mm — a pinhole in the rasterized mask where
    /// its own waist boundaries nearly touch, thinned into a tiny loop —
    /// which slipped past the old threshold, reached `SatinColumnGenerator`
    /// as a ring segment whose centroid sat in solid material, and so
    /// rejected the entire otherwise-sound letter from the branching path.
    private static let minimumClosedLoopLengthMM = 6.0

    /// See `buildGraph`: a dead-ended walk shorter than this is skeleton
    /// noise, not a lost arm.
    private static let minimumDanglingEdgePixels = 6

    // MARK: - Entry point

    /// Builds the topology graph for `shape`, or `nil` if the shape is
    /// empty, has no usable outer boundary, or would need an
    /// unreasonably large raster grid to analyze at the requested
    /// resolution.
    public static func analyze(shape: VectorShape, parameters: Parameters = Parameters()) -> Topology? {
        guard let outer = shape.subPaths.first, outer.points.count >= 3 else { return nil }
        let bounds = shape.boundingBox
        guard !bounds.isEmpty, bounds.width > 0, bounds.height > 0, parameters.pixelsPerMM > 0 else { return nil }

        let marginMM = 2.0 / parameters.pixelsPerMM
        let scale = parameters.pixelsPerMM
        let originX = bounds.minX - marginMM
        let originY = bounds.minY - marginMM
        let width = max(1, Int(((bounds.width + marginMM * 2) * scale).rounded(.up)))
        let height = max(1, Int(((bounds.height + marginMM * 2) * scale).rounded(.up)))
        guard width > 2, height > 2, width * height <= maxRasterPixels else { return nil }

        var mask = [Bool](repeating: false, count: width * height)
        rasterize(shape: shape, into: &mask, width: width, height: height, originX: originX, originY: originY, scale: scale)
        guard mask.contains(true) else { return nil }

        let distance = chamferDistanceTransform(mask: mask, width: width, height: height)
        let skeleton = zhangSuenThin(mask: mask, width: width, height: height)
        guard skeleton.contains(true) else { return nil }

        let raw = buildGraph(skeleton: skeleton, distance: distance, width: width, height: height,
                              originX: originX, originY: originY, scale: scale)
        return prune(raw, parameters: parameters)
    }

    // MARK: - Rasterization

    /// Fills `shape`'s subpaths even-odd (outer boundary minus holes,
    /// matching every other fill-semantics use in this engine — see
    /// `PolygonGeometry.pointInPolygons`'s own doc comment) into `mask`
    /// via a per-row scanline fill. A self-contained copy of the same
    /// technique `ShapeMerger`'s private `rasterize` uses, rather than
    /// exposing that one — this file is deliberately self-contained so
    /// stage 1 can be reviewed and tested in isolation from every other
    /// engine subsystem.
    private static func rasterize(shape: VectorShape, into mask: inout [Bool], width: Int, height: Int,
                                   originX: Double, originY: Double, scale: Double) {
        let polygons = shape.subPaths.map { $0.points }
        guard !polygons.isEmpty else { return }
        for py in 0..<height {
            let y = originY + (Double(py) + 0.5) / scale
            var crossings: [Double] = []
            for polygon in polygons {
                guard polygon.count > 2 else { continue }
                var j = polygon.count - 1
                for i in 0..<polygon.count {
                    let pi = polygon[i], pj = polygon[j]
                    if (pi.y > y) != (pj.y > y) {
                        let t = (y - pi.y) / (pj.y - pi.y)
                        crossings.append(pi.x + t * (pj.x - pi.x))
                    }
                    j = i
                }
            }
            guard !crossings.isEmpty else { continue }
            crossings.sort()
            var k = 0
            while k + 1 < crossings.count {
                let xStartPx = max(0, Int(((crossings[k] - originX) * scale).rounded()))
                let xEndPx = min(width, Int(((crossings[k + 1] - originX) * scale).rounded()))
                if xStartPx < xEndPx {
                    for px in xStartPx..<xEndPx { mask[py * width + px] = true }
                }
                k += 2
            }
        }
    }

    // MARK: - Distance transform (local stroke width)

    /// Two-pass chamfer (3-4) distance transform: `result[idx]` is this
    /// pixel's approximate Euclidean distance, in whole pixels, to the
    /// nearest `false` (background/hole) pixel — 0 for background pixels
    /// themselves. The 3-4 weighting (orthogonal step = 3, diagonal step
    /// = 4, normalized by /3 at the end) is the standard cheap
    /// approximation of true Euclidean distance for this purpose: this
    /// only ever feeds a *width estimate* (`2 × distance` at a skeleton
    /// point), where a few percent of chamfer error is invisible next to
    /// the coarser raster resolution itself, and an exact two-pass EDT
    /// (Felzenszwalt-Huttenlocher) would cost meaningfully more code for
    /// no visible benefit here.
    private static func chamferDistanceTransform(mask: [Bool], width: Int, height: Int) -> [Double] {
        let bigValue = Double(width + height) * 4
        var dist = [Double](repeating: bigValue, count: width * height)
        for i in 0..<mask.count where !mask[i] { dist[i] = 0 }

        func at(_ x: Int, _ y: Int) -> Double {
            guard x >= 0, x < width, y >= 0, y < height else { return bigValue }
            return dist[y * width + x]
        }

        for y in 0..<height {
            for x in 0..<width {
                guard mask[y * width + x] else { continue }
                let idx = y * width + x
                dist[idx] = min(dist[idx], at(x - 1, y - 1) + 4, at(x, y - 1) + 3, at(x + 1, y - 1) + 4, at(x - 1, y) + 3)
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) {
                guard mask[y * width + x] else { continue }
                let idx = y * width + x
                dist[idx] = min(dist[idx], at(x + 1, y + 1) + 4, at(x, y + 1) + 3, at(x - 1, y + 1) + 4, at(x + 1, y) + 3)
            }
        }
        return dist.map { $0 / 3 }
    }

    // MARK: - Skeletonization (Zhang-Suen thinning)

    /// Standard Zhang-Suen iterative thinning: repeatedly removes
    /// foreground boundary pixels that are safe to delete without
    /// breaking connectivity or erasing a genuine endpoint, alternating
    /// two sub-iteration conditions (each catches boundary pixels the
    /// other's asymmetry misses) until a full pass deletes nothing. Well
    /// documented, deterministic, and — unlike ridge-extraction directly
    /// off the distance transform — has no tunable "how much of a local
    /// maximum counts as a ridge" fuzziness to get wrong.
    private static func zhangSuenThin(mask: [Bool], width: Int, height: Int) -> [Bool] {
        var img = mask

        func at(_ arr: [Bool], _ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return arr[y * width + x]
        }

        var changed = true
        while changed {
            changed = false
            for step in 0..<2 {
                var toRemove: [Int] = []
                for y in 0..<height {
                    for x in 0..<width {
                        guard img[y * width + x] else { continue }
                        // Clockwise from north, matching the standard
                        // Zhang-Suen neighbor numbering (P2...P9).
                        let p2 = at(img, x, y - 1), p3 = at(img, x + 1, y - 1), p4 = at(img, x + 1, y)
                        let p5 = at(img, x + 1, y + 1), p6 = at(img, x, y + 1), p7 = at(img, x - 1, y + 1)
                        let p8 = at(img, x - 1, y), p9 = at(img, x - 1, y - 1)
                        let neighbors = [p2, p3, p4, p5, p6, p7, p8, p9]
                        let blackCount = neighbors.filter { $0 }.count
                        guard blackCount >= 2, blackCount <= 6 else { continue }

                        var transitions = 0
                        for i in 0..<neighbors.count where !neighbors[i] && neighbors[(i + 1) % neighbors.count] {
                            transitions += 1
                        }
                        guard transitions == 1 else { continue }

                        let condition3 = step == 0 ? !(p2 && p4 && p6) : !(p2 && p4 && p8)
                        let condition4 = step == 0 ? !(p4 && p6 && p8) : !(p2 && p6 && p8)
                        guard condition3, condition4 else { continue }

                        toRemove.append(y * width + x)
                    }
                }
                guard !toRemove.isEmpty else { continue }
                for idx in toRemove { img[idx] = false }
                changed = true
            }
        }
        return removeResidual2x2Blocks(img, width: width, height: height)
    }

    /// A well-documented Zhang-Suen limitation: a solid 2x2 block of
    /// foreground pixels can satisfy neither sub-iteration's deletion
    /// conditions for any of its four pixels simultaneously, so the main
    /// loop above converges leaving the block fully intact rather than
    /// thinned to a single point. Left alone, `buildGraph` sees each
    /// surviving corner as its own tiny 3-neighbor "junction," and once
    /// the real skeleton has thinned away around it, the block becomes an
    /// isolated 4-pixel island `walkClosedLoops` reports as a spurious
    /// closed loop -- found directly against this file's own T-junction
    /// and branching-H regression tests, both of which came back with an
    /// extra phantom loop before this cleanup pass existed. The standard
    /// fix: repeatedly clear each such block's bottom-right pixel until
    /// none remain (bounded, since each pass can only shrink the
    /// foreground count).
    private static func removeResidual2x2Blocks(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        var img = mask
        for _ in 0..<4 {
            var toRemove: [Int] = []
            for y in 0..<(height - 1) {
                for x in 0..<(width - 1) {
                    let idx = y * width + x
                    guard img[idx], img[idx + 1], img[idx + width], img[idx + width + 1] else { continue }
                    toRemove.append(idx + width + 1)
                }
            }
            guard !toRemove.isEmpty else { break }
            for idx in toRemove { img[idx] = false }
        }
        return img
    }

    // MARK: - Neighbor analysis

    /// The distinct branch directions leaving skeleton pixel `(x, y)` —
    /// one representative neighbor per maximal run of skeleton pixels in
    /// the cyclically-ordered 8-neighborhood (N, NE, E, SE, S, SW, W,
    /// NW). Using this instead of a raw neighbor count/list is what
    /// keeps a diagonal "staircase" segment of a thinned skeleton from
    /// being misread as a junction: two of a chain's own consecutive
    /// pixels are routinely 8-adjacent to a shared third pixel purely
    /// from grid geometry (an orthogonal step and the diagonal step past
    /// it touch the same corner pixel), not because three separate
    /// branches actually meet there — checking for runs (maximal spans
    /// separated by at least one background pixel) distinguishes "one
    /// branch, geometrically thick at this pixel" from "two or more
    /// genuinely separate branches" the way a raw count can't. Found
    /// directly against this file's own regression tests: a raw count
    /// misclassified ordinary staircase pixels along a circular ring and
    /// a branching "H"'s stems as extra junctions, fragmenting each into
    /// far more nodes/edges (and, once those false junctions broke chain
    /// continuity, spurious extra closed-loop pieces) than either shape
    /// actually has.
    private static func branchRuns(_ x: Int, _ y: Int, skeleton: [Bool], width: Int, height: Int) -> [[(Int, Int)]] {
        let offsets = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]
        let ring: [(Int, Int)?] = offsets.map { dx, dy in
            let nx = x + dx, ny = y + dy
            guard nx >= 0, nx < width, ny >= 0, ny < height, skeleton[ny * width + nx] else { return nil }
            return (nx, ny)
        }
        guard let firstGap = ring.firstIndex(where: { $0 == nil }) else {
            // Fully surrounded (a residual un-thinned interior pixel) --
            // treat the whole ring as a single run.
            return ring[0].map { [[$0]] } ?? []
        }

        var runs: [[(Int, Int)]] = []
        var current: [(Int, Int)] = []
        for step in 0..<ring.count {
            let idx = (firstGap + 1 + step) % ring.count
            if let p = ring[idx] {
                current.append(p)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// One representative pixel per branch run — used only where the
    /// specific pixel chosen within a run doesn't matter, i.e. counting
    /// how many runs (branches) touch a pixel. Walking a chain needs the
    /// smarter, node-aware choice `stepDirections` makes instead — see
    /// its own doc comment for why picking an arbitrary run member here
    /// would be actively wrong for that purpose.
    private static func branchDirections(_ x: Int, _ y: Int, skeleton: [Bool], width: Int, height: Int) -> [(Int, Int)] {
        branchRuns(x, y, skeleton: skeleton, width: width, height: height).compactMap { $0.first }
    }

    /// Like `branchDirections`, but when a run contains a pixel that's
    /// already part of a classified node, steps to *that* pixel rather
    /// than the run's arbitrary first member. Used only to enumerate the
    /// distinct *outgoing* branches from a node's own cluster (one walk
    /// per real branch) — see `nextStep` below for the separate, more
    /// careful logic actually used to walk *along* a branch once
    /// started, which this function's coarser "first of run" choice
    /// isn't precise enough for.
    private static func stepDirections(_ x: Int, _ y: Int, skeleton: [Bool], width: Int, height: Int,
                                        nodeIndexOfPixel: [Int: Int]) -> [(Int, Int)] {
        branchRuns(x, y, skeleton: skeleton, width: width, height: height).map { run in
            run.first(where: { nodeIndexOfPixel[$0.1 * width + $0.0] != nil }) ?? run[0]
        }
    }

    /// The single next pixel to step to while walking a chain from
    /// `current`, having just arrived from `previous` (`nil` only for a
    /// closed-loop walk's very first step, which has no incoming
    /// direction yet). Two considerations, in priority order:
    ///
    /// 1. **A candidate that's already part of a classified node always
    ///    wins**, regardless of geometry. A pixel approaching a junction
    ///    along an otherwise straight run (say, the last pixel of a stem
    ///    right before a T meets its crossbar) can be simultaneously
    ///    8-adjacent to the real junction pixel *and* to a pixel one hop
    ///    further into one of the junction's own other branches, purely
    ///    from grid diagonal adjacency — picking the wrong one silently
    ///    merges two edges into one and leaves the junction pixel
    ///    completely unvisited. Found directly against this file's own
    ///    T-junction and branching-H regression tests.
    /// 2. **Otherwise, the candidate that continues straightest** from
    ///    the incoming direction (largest dot product of unit step
    ///    vectors), not an arbitrary tie-break. A thinned skeleton's
    ///    curved sections routinely offer more than one valid raw
    ///    neighbor once `previous` is excluded (an orthogonal step and
    ///    its neighboring diagonal both continuing the same physical
    ///    curve) — picking whichever happens to come first in a fixed
    ///    scan order, rather than whichever actually continues the
    ///    curve, can walk the trace back toward pixels already passed
    ///    and close a loop many pixels early. Found directly against
    ///    this file's own circular-ring regression test, which came back
    ///    as nine fragments (two large arcs plus seven near-zero-length
    ///    slivers) instead of one continuous loop before this existed.
    private static func nextStep(current: (Int, Int), previous: (Int, Int)?, skeleton: [Bool],
                                  nodeIndexOfPixel: [Int: Int], avoiding: Set<Int> = [], width: Int, height: Int) -> (Int, Int)? {
        var candidates: [(Int, Int)] = []
        for dy in -1...1 {
            for dx in -1...1 where !(dx == 0 && dy == 0) {
                let nx = current.0 + dx, ny = current.1 + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height, skeleton[ny * width + nx] else { continue }
                let candidate = (nx, ny)
                if let previous, candidate == previous { continue }
                guard !avoiding.contains(ny * width + nx) else { continue }
                candidates.append(candidate)
            }
        }
        guard !candidates.isEmpty else { return nil }
        if let nodeCandidate = candidates.first(where: { nodeIndexOfPixel[$0.1 * width + $0.0] != nil }) {
            return nodeCandidate
        }
        guard candidates.count > 1, let previous else { return candidates[0] }

        let inDX = Double(current.0 - previous.0), inDY = Double(current.1 - previous.1)
        let inLen = (inDX * inDX + inDY * inDY).squareRoot()
        guard inLen > 0 else { return candidates[0] }
        var best = candidates[0]
        var bestScore = -Double.infinity
        for candidate in candidates {
            let outDX = Double(candidate.0 - current.0), outDY = Double(candidate.1 - current.1)
            let outLen = (outDX * outDX + outDY * outDY).squareRoot()
            guard outLen > 0 else { continue }
            let score = (inDX * outDX + inDY * outDY) / (inLen * outLen)
            if score > bestScore { bestScore = score; best = candidate }
        }
        return best
    }

    /// Every skeleton pixel within `radius` (raw 8-adjacency, not
    /// `branchDirections`) — used only to cluster physically-adjacent
    /// node pixels into one logical node, where the real question is
    /// "are these pixels part of the same small plateau," not "how many
    /// branches emanate from this one pixel."
    private static func rawNeighbors(_ x: Int, _ y: Int, skeleton: [Bool], width: Int, height: Int) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        for dy in -1...1 {
            for dx in -1...1 where !(dx == 0 && dy == 0) {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height, skeleton[ny * width + nx] else { continue }
                result.append((nx, ny))
            }
        }
        return result
    }

    // MARK: - Graph construction

    /// Turns the thinned skeleton mask into a node/edge graph: classifies
    /// every skeleton pixel by its branch-direction count (see
    /// `branchDirections` — 1 = endpoint, 2 = mid-chain, ≥3 = junction),
    /// clusters adjacent endpoint/junction pixels into single logical
    /// nodes (thinning routinely leaves a real junction as a small 2-4
    /// pixel plateau, not one exact pixel), then walks the remaining
    /// chain pixels between node clusters to build each edge's
    /// centerline and width profile. Any chain pixels left unvisited
    /// once every node-anchored walk is done belong to a pure closed
    /// loop with no junction at all (a plain ring) — walked separately
    /// below.
    private static func buildGraph(skeleton: [Bool], distance: [Double], width: Int, height: Int,
                                    originX: Double, originY: Double, scale: Double) -> Topology {
        func physicalPoint(_ x: Int, _ y: Int) -> Point2D {
            Point2D(originX + (Double(x) + 0.5) / scale, originY + (Double(y) + 0.5) / scale)
        }

        func widthMM(_ x: Int, _ y: Int) -> Double {
            2 * distance[y * width + x] / scale
        }

        var nodeIndexOfPixel: [Int: Int] = [:]
        var junctionOrEndpointPixels: [Int] = []
        for y in 0..<height {
            for x in 0..<width where skeleton[y * width + x] {
                let degree = branchDirections(x, y, skeleton: skeleton, width: width, height: height).count
                if degree == 1 || degree >= 3 { junctionOrEndpointPixels.append(y * width + x) }
            }
        }
        guard !junctionOrEndpointPixels.isEmpty else {
            // No endpoint or junction anywhere -- the whole skeleton is
            // one or more pure closed loops. Walk each independently.
            return Topology(nodes: [], edges: walkClosedLoops(skeleton: skeleton, width: width, height: height,
                                                                physicalPoint: physicalPoint, widthMM: widthMM))
        }

        // Cluster adjacent node pixels (raw 8-adjacency) into logical nodes.
        let nodePixelSet = Set(junctionOrEndpointPixels)
        var visitedNodePixels = Set<Int>()
        var nodes: [Node] = []
        for start in junctionOrEndpointPixels where !visitedNodePixels.contains(start) {
            var queue = [start]
            visitedNodePixels.insert(start)
            var cluster: [Int] = []
            var head = 0
            while head < queue.count {
                let idx = queue[head]; head += 1
                cluster.append(idx)
                let x = idx % width, y = idx / width
                for (nx, ny) in rawNeighbors(x, y, skeleton: skeleton, width: width, height: height) {
                    let nIdx = ny * width + nx
                    guard nodePixelSet.contains(nIdx), !visitedNodePixels.contains(nIdx) else { continue }
                    visitedNodePixels.insert(nIdx)
                    queue.append(nIdx)
                }
            }
            let nodeID = nodes.count
            for idx in cluster { nodeIndexOfPixel[idx] = nodeID }
            let cx = cluster.reduce(0.0) { $0 + Double($1 % width) } / Double(cluster.count)
            let cy = cluster.reduce(0.0) { $0 + Double($1 / width) } / Double(cluster.count)
            let avgWidth = cluster.reduce(0.0) { $0 + widthMM($1 % width, $1 / width) } / Double(cluster.count)
            let anchorDegree = branchDirections(cluster[0] % width, cluster[0] / width, skeleton: skeleton, width: width, height: height).count
            nodes.append(Node(id: nodeID,
                               position: Point2D(originX + (cx + 0.5) / scale, originY + (cy + 0.5) / scale),
                               isJunction: cluster.count > 1 || anchorDegree >= 3,
                               widthMM: avgWidth))
        }

        // Walk every branch direction leaving a node cluster outward
        // until it reaches another node cluster (or loops back to the
        // same one), building one edge per walk.
        var visitedChainPixels = Set<Int>()
        var edges: [Edge] = []
        // Node clusters are fixed from here on; a walk that dead-ends
        // somewhere the degree test didn't call an endpoint gets one made
        // for it (below), appended after the real ones.
        var extraNodes: [Node] = []
        for node in nodes {
            // Sorted: a Swift dictionary's iteration order differs between
            // instances (its storage seeds its hasher by address), so the
            // order in which a cluster's pixels start walks -- and with it
            // which pixel a walk claims first, and so the edges found --
            // silently varied from one call to the next on the same shape.
            let clusterPixels = nodeIndexOfPixel.filter { $0.value == node.id }.map { $0.key }.sorted()
            for pixelIdx in clusterPixels {
                let x = pixelIdx % width, y = pixelIdx / width
                for (nx, ny) in stepDirections(x, y, skeleton: skeleton, width: width, height: height, nodeIndexOfPixel: nodeIndexOfPixel) {
                    let nIdx = ny * width + nx
                    guard nodeIndexOfPixel[nIdx] == nil, !visitedChainPixels.contains(nIdx) else { continue }
                    guard let edge = walkEdge(from: (nx, ny), cameFrom: (x, y), skeleton: skeleton, width: width, height: height,
                                              nodeIndexOfPixel: nodeIndexOfPixel, visitedChainPixels: &visitedChainPixels) else { continue }
                    if let endNodeID = edge.endNodeID, let endNode = nodes.first(where: { $0.id == endNodeID }) {
                        let polyline = [physicalPoint(x, y)] + edge.pixels.map { physicalPoint($0.0, $0.1) } + [endNode.position]
                        let widths = [widthMM(x, y)] + edge.pixels.map { widthMM($0.0, $0.1) } + [endNode.widthMM]
                        edges.append(Edge(startNodeID: node.id, endNodeID: endNodeID,
                                           isClosedLoop: false, polyline: polyline, widthsMM: widths))
                    } else if let last = edge.pixels.last, edge.pixels.count >= minimumDanglingEdgePixels {
                        // A dead-end walk (no node reached) was assumed
                        // impossible on a properly thinned skeleton and
                        // dropped. It does happen -- the step rule can run
                        // out of moves on a two-pixel staircase, or into a
                        // pixel another walk already claimed -- and dropping
                        // it silently lost a real 40 mm arm of a thin ribbon
                        // (the Oholi mark's, from the letter to the loop), so
                        // the satin came out half-length. Keep the arm,
                        // terminated at a synthetic endpoint.
                        let endID = nodes.count + extraNodes.count
                        extraNodes.append(Node(id: endID, position: physicalPoint(last.0, last.1), isJunction: false, widthMM: widthMM(last.0, last.1)))
                        let polyline = [physicalPoint(x, y)] + edge.pixels.map { physicalPoint($0.0, $0.1) }
                        let widths = [widthMM(x, y)] + edge.pixels.map { widthMM($0.0, $0.1) }
                        edges.append(Edge(startNodeID: node.id, endNodeID: endID, isClosedLoop: false, polyline: polyline, widthsMM: widths))
                    }
                }
            }
        }
        nodes += extraNodes

        edges += walkClosedLoops(skeleton: skeleton, width: width, height: height,
                                  excluding: visitedChainPixels.union(nodeIndexOfPixel.keys),
                                  physicalPoint: physicalPoint, widthMM: widthMM)
        return Topology(nodes: nodes, edges: edges)
    }

    /// Walks one chain of degree-2 skeleton pixels starting at
    /// `from` (having just arrived from `cameFrom`, so it isn't
    /// revisited) until reaching a pixel that belongs to a node cluster.
    /// Returns `nil` for a chain that dead-ends without reaching a node
    /// (shouldn't happen on a well-formed thinned skeleton, but a
    /// malformed or pathological input shouldn't loop forever either —
    /// bounded by the pixel grid's own size).
    private static func walkEdge(from start: (Int, Int), cameFrom: (Int, Int), skeleton: [Bool], width: Int, height: Int,
                                  nodeIndexOfPixel: [Int: Int],
                                  visitedChainPixels: inout Set<Int>) -> (pixels: [(Int, Int)], endNodeID: Int?)? {
        var pixels: [(Int, Int)] = []
        var current = start
        var previous = cameFrom
        let maxSteps = width * height

        for _ in 0..<maxSteps {
            let idx = current.1 * width + current.0
            if let nodeID = nodeIndexOfPixel[idx] {
                return (pixels, nodeID)
            }
            guard !visitedChainPixels.contains(idx) else { return (pixels, nil) }
            visitedChainPixels.insert(idx)
            pixels.append(current)

            guard let step = nextStep(current: current, previous: previous, skeleton: skeleton,
                                       nodeIndexOfPixel: nodeIndexOfPixel, width: width, height: height) else { return (pixels, nil) }
            previous = current
            current = step
        }
        return (pixels, nil)
    }

    /// Walks every chain pixel not reachable from any node — i.e. a pure
    /// closed-loop skeleton with no junction or endpoint at all (a plain
    /// ring). `excluding` lets the node-anchored pass above mark which
    /// chain pixels it already consumed, so this only picks up genuinely
    /// separate loops.
    private static func walkClosedLoops(skeleton: [Bool], width: Int, height: Int, excluding visited: Set<Int> = [],
                                         physicalPoint: (Int, Int) -> Point2D, widthMM: (Int, Int) -> Double) -> [Edge] {
        var visited = visited
        var edges: [Edge] = []
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                guard skeleton[idx], !visited.contains(idx) else { continue }

                var pixels: [(Int, Int)] = [(x, y)]
                visited.insert(idx)
                var current = (x, y)
                var previous: (Int, Int)?
                let maxSteps = width * height
                for _ in 0..<maxSteps {
                    // Off-limits for the *next* step: everything this
                    // walk has already stepped onto (without this,
                    // `nextStep`'s straightness tie-break can wander back
                    // through already-traced territory instead of
                    // continuing forward, turning one true loop into a
                    // long, wandering near-infinite walk -- found
                    // directly against this file's own circular-ring
                    // regression test), *and* every pixel any earlier,
                    // separate walk already claimed (a node's own pixel,
                    // or another edge's chain, both still read as plain
                    // `skeleton[idx] == true` here with nothing else
                    // distinguishing them -- without this, a walk that
                    // starts on an unclaimed stray pixel can step onto
                    // and retrace an already-complete edge, found
                    // directly against this file's own straight-column
                    // regression test: its one real edge came back
                    // paired with an exact-length phantom duplicate).
                    // The start pixel `idx` is the one exception, kept
                    // reachable so the walk can actually close the loop.
                    let avoiding = visited.subtracting([idx])
                    guard let step = nextStep(current: current, previous: previous, skeleton: skeleton,
                                               nodeIndexOfPixel: [:], avoiding: avoiding, width: width, height: height) else { break }
                    if step == (x, y) { break }
                    previous = current
                    current = step
                    visited.insert(current.1 * width + current.0)
                    pixels.append(current)
                }
                guard pixels.count >= 3 else { continue }
                let polyline = pixels.map { physicalPoint($0.0, $0.1) } + [physicalPoint(x, y)]
                // A closed loop this short (a handful of pixels,
                // circumference under a millimeter) can't represent any
                // real embroiderable hole or ring at any sane digitizing
                // scale -- it's thinning residue, the same class of
                // artifact `removeResidual2x2Blocks` exists for, just a
                // slightly larger leftover blob that cleanup didn't
                // happen to catch. Found directly against this file's
                // own circular-ring regression test, which came back
                // with its one real ~45mm loop plus several 1-2mm
                // fragments floating disconnected from it.
                guard pathLength(polyline) >= minimumClosedLoopLengthMM else { continue }
                let widths = pixels.map { widthMM($0.0, $0.1) } + [widthMM(x, y)]
                edges.append(Edge(startNodeID: -1, endNodeID: -1, isClosedLoop: true, polyline: polyline, widthsMM: widths))
            }
        }
        return edges
    }

    // MARK: - Pruning

    /// Removes spurious short spurs — an edge from a junction node to a
    /// genuine endpoint (degree-1) node, shorter than
    /// `pruneBranchLengthFactor × the local width at its junction end`
    /// (floored by `minPruneLengthMM`) — and collapses any junction node
    /// left with only two remaining edges into a single straight-through
    /// edge, so pruning a fake branch doesn't leave a fake junction
    /// behind. Only ever removes a spur ending at a real endpoint, never
    /// a short edge directly between two junctions — that's real
    /// topology (two junctions genuinely close together, e.g. a tightly
    /// kerned crossbar), not thinning noise, and collapsing it would
    /// change the letterform's actual structure rather than just
    /// cleaning up the skeleton's representation of it.
    private static func prune(_ topology: Topology, parameters: Parameters) -> Topology {
        guard !topology.nodes.isEmpty else { return topology }
        let debug = ProcessInfo.processInfo.environment["DEBUG_TOPOLOGY"] != nil
        func dump(_ label: String, _ nodes: [Int: Node], _ edges: [Edge]) {
            guard debug else { return }
            print("  topology \(label): nodes " + nodes.values.sorted { $0.id < $1.id }.map { "\($0.id)\($0.isJunction ? "J" : "e")w\(String(format: "%.1f", $0.widthMM))" }.joined(separator: " ")
                  + " | edges " + edges.map { "\($0.startNodeID)-\($0.endNodeID):\(String(format: "%.1f", pathLength($0.polyline)))\($0.isClosedLoop ? "L" : "")" }.joined(separator: " "))
        }
        dump("raw", Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, $0) }), topology.edges)

        var nodesByID = Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, $0) })
        var edges = topology.edges

        var didPrune = true
        while didPrune {
            didPrune = false
            var degreeCount: [Int: Int] = [:]
            for edge in edges where !edge.isClosedLoop {
                degreeCount[edge.startNodeID, default: 0] += 1
                degreeCount[edge.endNodeID, default: 0] += 1
            }

            if let spurIndex = edges.indices.first(where: { candidate in
                let edge = edges[candidate]
                guard !edge.isClosedLoop, edge.startNodeID != edge.endNodeID else { return false }
                guard let a = nodesByID[edge.startNodeID], let b = nodesByID[edge.endNodeID] else { return false }
                let (junction, endpoint) = a.isJunction ? (a, b) : (b, a)
                guard junction.isJunction, !endpoint.isJunction else { return false }
                guard (degreeCount[endpoint.id] ?? 0) == 1 else { return false }
                let length = pathLength(edge.polyline)
                let threshold = max(parameters.minPruneLengthMM, parameters.pruneBranchLengthFactor * junction.widthMM)
                // Thinning's spurious branches run from the junction to a
                // corner of the boundary and taper to nothing there. A
                // short arm that is still a stroke's width at its end is
                // real geometry: a 5 mm "A"'s apex, 2 mm above a 2.6 mm
                // junction and 1.6 mm wide at the top, was pruned as noise
                // and the letter sewn as a bare V.
                // (A stub left on a demoted junction is under the always-prune
                // fraction; treating any edge on one as noise cascaded through
                // a slab-serif H -- each pruned serif demoted a node, the stem
                // half ending there went next -- until only the crossbar was
                // left.)
                // A spur that stays wide at its end is real geometry -- an
                // A's apex (1.6 mm at the tip on a 2.6 mm junction), a slab
                // serif (3.2 mm on 8) -- and pruning it takes a stroke's
                // worth of cover with it: a slab-serif E lost both its arms
                // to a stem-width 8 mm junction and sewed as a bar.
                // Thinning's bumps at a T's corners are half a stroke wide
                // and a quarter long; a slab serif is 0.4 of the stem at
                // its end and half a stem long. The tip width separates
                // them at every length: a spur that keeps more than
                // `spurTipWidthFraction` of the junction's width at its end
                // is real geometry and stays.
                // Thinning's spurious branches end in a corner, at nothing;
                // a spur whose end is still a sewable stroke wide (a slab
                // serif's 3 mm on an 8 mm stem, an E's short middle arm)
                // is real, however short against its junction.
                if endpoint.widthMM >= parameters.realStrokeTipWidthMM { return false }
                let tapersToNothing = endpoint.widthMM <= parameters.spurTipWidthFraction * junction.widthMM
                // A spur that never leaves the junction's own footprint
                // (shorter than half its width) is a stub whatever its end
                // width -- the skeleton's arm into a corner of a rectangle
                // -- unless it is one of a matched pair: two such arms off
                // one junction, alike in length and width, are a slab
                // serif's two halves (an E's arm end, an L's foot), and
                // pruning them leaves the arm a bare stem.
                if length < junction.widthMM * 0.5 {
                    let siblings = edges.indices.filter { $0 != candidate && !edges[$0].isClosedLoop && (edges[$0].startNodeID == junction.id || edges[$0].endNodeID == junction.id) }
                    let twin = siblings.contains { k in
                        let other = edges[k]
                        let otherEndID = other.startNodeID == junction.id ? other.endNodeID : other.startNodeID
                        guard let otherEnd = nodesByID[otherEndID], !otherEnd.isJunction else { return false }
                        let l = pathLength(other.polyline)
                        return abs(l - length) <= max(length, l) * 0.35 && abs(otherEnd.widthMM - endpoint.widthMM) <= max(endpoint.widthMM, otherEnd.widthMM) * 0.35
                    }
                    if !twin { return true }
                }
                guard tapersToNothing else { return false }
                if length < threshold { return true }
                // A serif's wing: a spur not much longer than the stroke
                // is wide that tapers to (nearly) nothing at its tip. As a
                // branch it earns a junction and a radial patch at every
                // foot; as part of the stem's own end the rails simply
                // flare into it, which is how a serif is sewn.
                guard length < parameters.serifWingLengthFactor * junction.widthMM,
                      endpoint.widthMM <= parameters.serifWingTipWidthFraction * junction.widthMM else { return false }
                // ...and short next to the junction's other arms: a small
                // "A"'s tapering leg is not a wing on its own crossbar.
                let longestOther = edges.indices.filter { $0 != candidate && (edges[$0].startNodeID == junction.id || edges[$0].endNodeID == junction.id) }
                    .map { pathLength(edges[$0].polyline) }.max() ?? 0
                return length <= longestOther * parameters.serifWingOtherArmFraction
            }) {
                let removed = edges.remove(at: spurIndex)
                let endpointID = nodesByID[removed.startNodeID]?.isJunction == false ? removed.startNodeID : removed.endNodeID
                nodesByID.removeValue(forKey: endpointID)
                didPrune = true
                dump("spur pruned", nodesByID, edges)
                continue
            }

            // Collapse any junction node now left with exactly two
            // edges -- pruning its third spur demoted it to a plain
            // mid-chain point, not a real junction anymore.
            var collapsedThisRound = false
            for (nodeID, count) in degreeCount.sorted(by: { $0.key < $1.key }) where count == 2 {
                guard nodesByID[nodeID]?.isJunction == true else { continue }
                let incidentIndices = edges.indices.filter { !edges[$0].isClosedLoop && (edges[$0].startNodeID == nodeID || edges[$0].endNodeID == nodeID) }
                guard incidentIndices.count == 2 else { continue }
                let first = edges[incidentIndices[0]], second = edges[incidentIndices[1]]
                guard first.startNodeID != first.endNodeID, second.startNodeID != second.endNodeID else { continue }

                let firstOther = first.startNodeID == nodeID ? first.endNodeID : first.startNodeID
                let secondOther = second.startNodeID == nodeID ? second.endNodeID : second.startNodeID
                var mergedPolyline = first.startNodeID == nodeID ? first.polyline.reversed() : first.polyline
                let secondForward = second.startNodeID == nodeID ? second.polyline : Array(second.polyline.reversed())
                mergedPolyline = Array(mergedPolyline) + secondForward.dropFirst()
                let mergedWidths = (first.startNodeID == nodeID ? Array(first.widthsMM.reversed()) : first.widthsMM)
                    + (second.startNodeID == nodeID ? second.widthsMM : Array(second.widthsMM.reversed())).dropFirst()

                for i in incidentIndices.sorted(by: >) { edges.remove(at: i) }
                edges.append(Edge(startNodeID: firstOther, endNodeID: secondOther, isClosedLoop: false,
                                   polyline: Array(mergedPolyline), widthsMM: Array(mergedWidths)))
                nodesByID.removeValue(forKey: nodeID)
                didPrune = true
                collapsedThisRound = true
                break
            }
            if collapsedThisRound { continue }

            // A node that started as a real junction (degree >= 3) but
            // had enough of its OWN branches pruned as spurious spurs
            // above to end up with only one surviving edge is no longer
            // a real junction -- it's just that one edge's own endpoint
            // now. Left mislabeled `isJunction: true`, a single long
            // (if width-varying) connector reads as "genuinely
            // branching" to `SatinColumnGenerator.
            // canRepresentAsBranchingSatinColumn` when it structurally
            // no longer is. Found directly against a real large logo
            // shape (a bold "A" 's own leg): two legitimate-looking
            // short spurs near a wide junction both fell under the
            // pruning threshold (which scales with the junction's own,
            // here unusually large, local width), leaving a junction
            // node with only one remaining edge still flagged as one.
            // Unlike the degree-2 case above, no edges merge here --
            // the node stays exactly where it is, just correctly
            // reclassified.
            for (nodeID, count) in degreeCount.sorted(by: { $0.key < $1.key }) where count == 1 {
                guard let node = nodesByID[nodeID], node.isJunction else { continue }
                var demoted = node
                demoted.isJunction = false
                nodesByID[nodeID] = demoted
                didPrune = true
            }
            if didPrune { continue }

            // Two junctions closer together than the stroke is wide are
            // one junction that thinning split in two: an "a"'s bowl
            // meets its stem at two points 2 mm apart on a 1.6 mm stem,
            // and sewn as two junctions each got its own patch, the
            // 2 mm of stem between them was trimmed from both sides, and
            // the join was a knot. Contract the short edge between them:
            // the bowl becomes one loop on one junction (a "P"'s own,
            // proven path) and the stem runs straight through.
            var merged = false
            for (edgeIndex, edge) in edges.enumerated() where !edge.isClosedLoop && edge.startNodeID != edge.endNodeID {
                guard let a = nodesByID[edge.startNodeID], let b = nodesByID[edge.endNodeID], a.isJunction, b.isJunction else { continue }
                let width = max(a.widthMM, b.widthMM)
                guard pathLength(edge.polyline) < width * parameters.junctionMergeDistanceFactor else { continue }
                // ...and only where the two are joined more than once (the
                // stem's stub AND the bowl round to the other join): one
                // junction that thinning split. A lone short edge between
                // two junctions is a real stroke -- a slab-serif H's
                // crossbar is shorter than its stems are wide, and merging
                // its ends made the H an I.
                let connections = edges.filter { !$0.isClosedLoop && Set([$0.startNodeID, $0.endNodeID]) == Set([a.id, b.id]) }.count
                guard connections >= 2 else { continue }
                let keep = a.id, drop = b.id
                let position = Point2D((a.position.x + b.position.x) / 2, (a.position.y + b.position.y) / 2)
                nodesByID[keep] = Node(id: keep, position: position, isJunction: true, widthMM: width)
                nodesByID.removeValue(forKey: drop)
                edges.remove(at: edgeIndex)
                for i in edges.indices {
                    if edges[i].startNodeID == drop { edges[i].startNodeID = keep }
                    if edges[i].endNodeID == drop { edges[i].endNodeID = keep }
                }
                // A second edge between the two becomes a short loop on
                // the merged node and is left alone: on the Oholi bird
                // that loop is what covers the body (its radial sweep
                // reaches the far edges), and removing it lost half the
                // stitches.
                merged = true
                dump("merged \(drop) into \(keep)", nodesByID, edges)
                break
            }
            if merged { didPrune = true }
        }

        dump("final", nodesByID, edges)
        return Topology(nodes: nodesByID.values.sorted { $0.id < $1.id }, edges: edges)
    }

    private static func pathLength(_ points: [Point2D]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count { total += points[i - 1].distance(to: points[i]) }
        return total
    }
}
