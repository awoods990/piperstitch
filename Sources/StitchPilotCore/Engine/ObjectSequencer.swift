import Foundation

/// Orders a document's objects for sewing, improving stitch-conversion
/// performance (fewer thread color changes, shorter same-color jumps)
/// while never violating the one ordering constraint that's actually
/// unsafe to break: a shape that geometrically contains another must be
/// sewn first (spec §23: "background before foreground... inside before
/// outside"). For a badge's outer ring with a smaller emblem centered on
/// top of it, sewing the emblem first means the ring's stitching that
/// follows would bury or distort it.
///
/// This is a greedy, constraint-respecting scheduler, not a full TSP
/// solve or a general graph-based router (Ink/Stitch's `auto_satin`,
/// studied for this — see `EMBROIDERY_ALGORITHM_REFERENCE.md` — actually
/// restructures satin *columns themselves* into a running-stitch graph and
/// finds an Eulerian-ish path through it; that's real future work, not
/// what this does). Concretely:
///
/// 1. Containment defines a strict partial order (a "must sew before"
///    edge from each containing object to each object it contains) —
///    strict because `isBackground` requires a >5% area margin, so it
///    can't produce a cycle. Containment is a true polygon test (every
///    point of the contained shape's outer boundary must actually fall
///    inside the containing shape's outer boundary), not just a
///    bounding-box comparison: a concave (e.g. L-shaped) object can have a
///    bounding box that encloses something sitting entirely in its notch,
///    outside its real area, which a bounding-box-only check would
///    misclassify as nested.
/// 2. Repeatedly choose the next object from those with no unresolved
///    "must sew before me" edges (a topological-sort "ready set"),
///    preferring (a) the same thread color as whatever was just placed —
///    every color switch costs a trim and a machine stop for a thread
///    change, the most expensive thing in the sequencing budget — then
///    (b) whichever ready candidate is geometrically nearest the last
///    placed object, to shorten the same-color jumps a machine actually
///    executes without operator intervention, then (c) original authoring
///    order as a final, deterministic tie-break.
///
/// Two objects with no containment relationship between them are free to
/// be reordered relative to each other by this process (that's exactly
/// what lets same-color objects that were authored apart end up sewn back
/// to back), but an object is never moved ahead of something it must
/// follow, so this can't scatter an ordering the artwork's nesting
/// actually depends on.
///
/// 3. A bounded 2-opt local-search pass then refines that greedy order:
///    greedy construction is inherently short-sighted (it can't see that
///    picking the *locally* nearest candidate now leaves a worse jump
///    later), the classic failure case being two spatially separate
///    clusters visited in an interleaved zigzag instead of one cluster
///    then the other. 2-opt repeatedly tries reversing a contiguous
///    stretch of the order and keeps the reversal only if it lowers total
///    cost (color changes weighted far above raw travel distance, so it
///    never trades away color grouping for a shorter jump) and only if
///    doing so wouldn't violate a containment edge with both ends inside
///    the reversed stretch. See `twoOptImprove`'s doc comment for why this
///    is efficient enough to run unconditionally (bounded object counts
///    aside): reversing a stretch and flipping each item's own
///    entry/exit choice leaves every *internal* edge's cost unchanged, so
///    only the two boundary edges need re-evaluating per candidate.
///
/// `sequence` (below) uses each object's bounding-box *center* as its
/// proximity proxy — cheap, but not what a machine actually travels
/// to/from. `sequenceGenerated` uses the real first/last points of each
/// object's already-generated stitch path instead, and additionally
/// considers *reversing* a path (sewing it end-first) when that's the
/// closer approach from wherever the previous object left off — a
/// genuinely closer step toward jump-minimizing routing, since it
/// measures the actual points a machine jumps from/to rather than a
/// geometric proxy.
///
/// Two further rules from the Wilcom reference manual (docs/
/// WILCOM_MANUAL_REVIEW.md B7) sit on top of the greedy chooser:
///
/// - **Details last.** Within a colour block, running-stitch outlines
///   and small accents (`isDetail`: under `detailAreaFraction` of the
///   design's area) are sewn after the block's bulk shapes, so the
///   fabric has settled and a fine line lands where it was digitized
///   instead of being pushed by a fill sewn afterwards. Colour grouping
///   still wins: a detail never waits past its own colour block.
/// - **Caps sew bottom-to-top and centre-out.** A cap's front panel is
///   held by the frame at the sweatband and pushes upward and outward
///   as it is sewn, so lettering on a cap is sequenced from the row
///   nearest the sweatband up, and each row from the middle out (one
///   side to its end, back to the middle, the other side) --
///   `capOrder`. Applies when the objects' fabric `isHeadwear`.
public enum ObjectSequencer {
    /// An object smaller than this share of the design's bounding-box
    /// area is a detail and sews after its colour block's bulk shapes.
    public static let detailAreaFraction = 0.02

    public static func sequence(_ objects: [EmbroideryObject]) -> [EmbroideryObject] {
        guard objects.count > 1 else { return objects }
        let centers = objects.map { $0.shape.boundingBox.center }
        let order = computeOrder(
            shapes: objects.map { $0.shape },
            colors: objects.map { $0.threadColor.rgb },
            entryPoints: centers,
            exitPoints: centers,
            isDetail: detailFlags(objects),
            capRank: capOrder(objects)
        )
        return order.map { objects[$0.index] }
    }

    /// Which objects are details -- see the type doc comment.
    static func detailFlags(_ objects: [EmbroideryObject]) -> [Bool] {
        var designBox = BoundingBox.empty
        for object in objects { designBox = designBox.union(object.shape.boundingBox) }
        let designArea = designBox.width * designBox.height
        return objects.map { object in
            if object.stitchType == .runningStitch || object.stitchType == .tripleRun { return true }
            guard designArea > 0, let outer = object.shape.subPaths.first?.points, outer.count >= 3 else { return false }
            return abs(PolygonGeometry.signedArea(outer)) < designArea * detailAreaFraction
        }
    }

    /// Per-object sort key for a cap (lower sews first), or nil when the
    /// design isn't on headwear. Rows are found by bounding-box overlap
    /// in y (two objects share a row when their vertical extents overlap
    /// by at least half the shorter one); rows rank from the bottom of
    /// the design (largest y -- design coordinates are y-down) upward,
    /// and within a row the object nearest the design's centre line goes
    /// first, then the rest of that side outward, then the other side
    /// from the centre outward.
    static func capOrder(_ objects: [EmbroideryObject]) -> [Double]? {
        guard objects.count > 1, objects.contains(where: { $0.parameters.fabricType.isHeadwear }) else { return nil }
        let boxes = objects.map { $0.shape.boundingBox }
        var designBox = BoundingBox.empty
        for box in boxes { designBox = designBox.union(box) }
        let centerX = designBox.center.x

        // Rows: cluster by vertical overlap, top-down, then rank bottom-up.
        var rows: [[Int]] = []
        var rowRanges: [(minY: Double, maxY: Double)] = []
        for i in boxes.indices.sorted(by: { boxes[$0].center.y < boxes[$1].center.y }) {
            let box = boxes[i]
            var placed = false
            for r in rows.indices {
                let overlap = min(box.maxY, rowRanges[r].maxY) - max(box.minY, rowRanges[r].minY)
                let shorter = min(box.height, rowRanges[r].maxY - rowRanges[r].minY)
                if overlap >= shorter * 0.5 {
                    rows[r].append(i)
                    rowRanges[r] = (min(rowRanges[r].minY, box.minY), max(rowRanges[r].maxY, box.maxY))
                    placed = true
                    break
                }
            }
            if !placed { rows.append([i]); rowRanges.append((box.minY, box.maxY)) }
        }
        let rowOrder = rows.indices.sorted { rowRanges[$0].maxY > rowRanges[$1].maxY }

        var rank = [Double](repeating: 0, count: objects.count)
        for (rowRank, r) in rowOrder.enumerated() {
            let members = rows[r].sorted { boxes[$0].center.x < boxes[$1].center.x }
            let m = members.indices.min { abs(boxes[members[$0]].center.x - centerX) < abs(boxes[members[$1]].center.x - centerX) }!
            // Centre object, then its right-hand side outward, then the
            // left-hand side outward from the centre.
            var walk: [Int] = [members[m]]
            walk += members[(m + 1)...]
            walk += members[..<m].reversed()
            for (position, index) in walk.enumerated() {
                rank[index] = Double(rowRank) * 1_000_000 + Double(position)
            }
        }
        return rank
    }

    /// Like `sequence`, but for objects whose stitch points have already
    /// been generated: uses each path's real start/end points for the
    /// proximity heuristic instead of a bounding-box center, and reverses
    /// a path (returning its points in the opposite order) when entering
    /// from its end is the closer approach — the machine sews the same
    /// shape either way, so there's no reason not to pick whichever
    /// direction shortens the jump into it.
    ///
    /// Each item's stitching is one or more disjoint `runs` (almost always
    /// exactly one — see `DigitizePipeline.stitchRuns`); reversing an item
    /// reverses both the order of its runs and each run's own points, so
    /// the whole object is approached from its true other end while every
    /// run's own internal content stays intact.
    public static func sequenceGenerated(_ items: [(object: EmbroideryObject, runs: [[Point2D]])]) -> [(object: EmbroideryObject, runs: [[Point2D]])] {
        guard items.count > 1 else { return items }
        let objects = items.map { $0.object }
        let order = computeOrder(
            shapes: items.map { $0.object.shape },
            colors: items.map { $0.object.threadColor.rgb },
            entryPoints: items.map { $0.runs.first!.first! },
            exitPoints: items.map { $0.runs.last!.last! },
            isDetail: detailFlags(objects),
            capRank: capOrder(objects)
        )
        return order.map { entry in
            var item = items[entry.index]
            if entry.reversed { item.runs = item.runs.reversed().map { $0.reversed() } }
            return item
        }
    }

    /// Shared scheduling core: builds the containment DAG from `shapes`
    /// and greedily orders indices `0..<n`, preferring a color match then
    /// minimum distance from whatever was placed before — see the
    /// type-level doc comment. `entryPoints`/`exitPoints` are the two ends
    /// each item could be approached from (identical for `sequence`'s
    /// bounding-box-center proxy, the path's real two ends for
    /// `sequenceGenerated`); `reversed` in the result says whether the
    /// caller should present the item end-first.
    private static func computeOrder(shapes: [VectorShape], colors: [RGBColor], entryPoints: [Point2D], exitPoints: [Point2D],
                                     isDetail: [Bool], capRank: [Double]?) -> [(index: Int, reversed: Bool)] {
        let n = shapes.count

        // predecessors[i]: indices that must be sewn before item i.
        var predecessors: [[Int]] = Array(repeating: [], count: n)
        for i in 0..<n {
            for j in 0..<n where j != i {
                if isBackground(shapes[j], relativeTo: shapes[i]) {
                    predecessors[i].append(j)
                }
            }
        }
        var successors: [[Int]] = Array(repeating: [], count: n)
        var inDegree = predecessors.map { $0.count }
        for i in 0..<n {
            for j in predecessors[i] { successors[j].append(i) }
        }

        var ready = (0..<n).filter { inDegree[$0] == 0 }
        var order: [(index: Int, reversed: Bool)] = []
        order.reserveCapacity(n)
        var lastExitPoint: Point2D?
        var lastColor: RGBColor?

        while !ready.isEmpty {
            let (chosen, reversed) = bestCandidate(in: ready, colors: colors, entryPoints: entryPoints, exitPoints: exitPoints,
                                                   isDetail: isDetail, capRank: capRank, lastExitPoint: lastExitPoint, lastColor: lastColor)
            ready.removeAll { $0 == chosen }
            order.append((chosen, reversed))
            lastExitPoint = reversed ? entryPoints[chosen] : exitPoints[chosen]
            lastColor = colors[chosen]
            for successor in successors[chosen] {
                inDegree[successor] -= 1
                if inDegree[successor] == 0 { ready.append(successor) }
            }
        }

        // Containment is a strict partial order (see isBackground's area
        // margin), so it cannot cycle -- every index is placed exactly
        // once. This is a defensive fallback only, never expected to run.
        guard order.count == n else {
            let placed = Set(order.map { $0.index })
            return order + (0..<n).filter { !placed.contains($0) }.map { ($0, false) }
        }
        // A cap's order is a rule, not a distance optimisation -- 2-opt
        // would trade it back for shorter jumps.
        if capRank != nil { return order }
        return twoOptImprove(order, colors: colors, entryPoints: entryPoints, exitPoints: exitPoints, isDetail: isDetail, predecessors: predecessors)
    }

    /// Every color switch costs a real machine stop for a thread change;
    /// this weight (in the same "mm" units the distance terms use) just
    /// needs to be comfortably larger than any realistic single jump so
    /// 2-opt never trades away color grouping for a shorter jump — it
    /// isn't a measured physical cost.
    private static let colorChangeCostMM = 1000.0
    /// Sewing a bulk shape straight after a detail of the same colour
    /// undoes "details last"; costed below a colour change (grouping
    /// still wins) but far above any jump, so 2-opt never introduces one.
    private static let detailBeforeBulkCostMM = 400.0
    /// Above this many objects, skip 2-opt entirely and return the greedy
    /// order as-is: each pass is O(n^2) and a worthwhile design rarely has
    /// anywhere near this many separately-sequenced objects, so this is a
    /// safety valve against pathological runtime, not a tuned threshold.
    private static let maxObjectsForTwoOpt = 300
    private static let maxTwoOptPasses = 25

    /// Bounded local-search refinement of a valid, containment-respecting
    /// `order`: repeatedly looks for a contiguous stretch `[i...j]` whose
    /// *reversal* (with each item's own `reversed` flag flipped too, so
    /// each item is still approached from a self-consistent end) lowers
    /// total cost, and keeps the best one found each pass, stopping once a
    /// full pass finds no improvement or `maxTwoOptPasses` is reached.
    ///
    /// Reversing a stretch and flipping each item's `reversed` flag leaves
    /// every edge strictly *inside* the stretch unchanged: for two
    /// adjacent items in the old order, the edge was
    /// `distance(exit(a), entry(b))`; after both are flipped and their
    /// relative order reversed, the new adjacent edge is
    /// `distance(exit(b-flipped), entry(a-flipped))` = `distance(entry(b),
    /// exit(a))` — the same two points, order doesn't matter for a
    /// Euclidean distance. Only the two *boundary* edges (into position
    /// `i` from whatever precedes it, and out of position `j` to whatever
    /// follows) actually change, so each candidate reversal can be scored
    /// in O(1) instead of by recomputing the whole tour's cost — this is
    /// the standard reason 2-opt is tractable at all.
    private static func twoOptImprove(_ order: [(index: Int, reversed: Bool)], colors: [RGBColor], entryPoints: [Point2D], exitPoints: [Point2D], isDetail: [Bool], predecessors: [[Int]]) -> [(index: Int, reversed: Bool)] {
        let n = order.count
        guard n > 3, n <= maxObjectsForTwoOpt else { return order }

        var order = order
        var positionOf = [Int](repeating: 0, count: n) // objectIndex -> current position
        for (pos, entry) in order.enumerated() { positionOf[entry.index] = pos }

        func edgeCost(_ a: (index: Int, reversed: Bool), _ b: (index: Int, reversed: Bool)) -> Double {
            guard colors[a.index] == colors[b.index] else { return colorChangeCostMM }
            let exitA = a.reversed ? entryPoints[a.index] : exitPoints[a.index]
            let entryB = b.reversed ? exitPoints[b.index] : entryPoints[b.index]
            let detailPenalty = isDetail[a.index] && !isDetail[b.index] ? detailBeforeBulkCostMM : 0
            return exitA.distance(to: entryB) + detailPenalty
        }

        func flipped(_ item: (index: Int, reversed: Bool)) -> (index: Int, reversed: Bool) {
            (item.index, !item.reversed)
        }

        // No precedence edge may have both endpoints inside [lo, hi]:
        // reversing would then place one side of that edge on the wrong
        // side of the other.
        func segmentRespectsContainment(_ lo: Int, _ hi: Int) -> Bool {
            for pos in lo...hi {
                for pred in predecessors[order[pos].index] {
                    let predPos = positionOf[pred]
                    if predPos >= lo, predPos <= hi { return false }
                }
            }
            return true
        }

        for _ in 0..<maxTwoOptPasses {
            var bestDelta = -0.001 // strictly-improving threshold, avoids float-noise thrashing
            var bestRange: (Int, Int)?

            for i in 0..<(n - 1) {
                for j in (i + 1)..<n {
                    guard segmentRespectsContainment(i, j) else { continue }

                    let oldCostBefore = i > 0 ? edgeCost(order[i - 1], order[i]) : 0
                    let oldCostAfter = j < n - 1 ? edgeCost(order[j], order[j + 1]) : 0
                    let newCostBefore = i > 0 ? edgeCost(order[i - 1], flipped(order[j])) : 0
                    let newCostAfter = j < n - 1 ? edgeCost(flipped(order[i]), order[j + 1]) : 0

                    let delta = (newCostBefore + newCostAfter) - (oldCostBefore + oldCostAfter)
                    if delta < bestDelta {
                        bestDelta = delta
                        bestRange = (i, j)
                    }
                }
            }

            guard let (lo, hi) = bestRange else { break } // converged: no improving reversal left
            order[lo...hi].reverse()
            for k in lo...hi { order[k].reversed.toggle() }
            for pos in lo...hi { positionOf[order[pos].index] = pos }
        }
        return order
    }

    /// Picks which ready (dependency-satisfied) item to place next, and
    /// whether it should be entered from its "exit" end instead of its
    /// "entry" end.
    private static func bestCandidate(in ready: [Int], colors: [RGBColor], entryPoints: [Point2D], exitPoints: [Point2D],
                                      isDetail: [Bool], capRank: [Double]?, lastExitPoint: Point2D?, lastColor: RGBColor?) -> (index: Int, reversed: Bool) {
        if let capRank {
            // Same colour first, bulk before details, then the cap's own
            // bottom-up / centre-out rank.
            let sameColor = lastColor.map { c in ready.filter { colors[$0] == c } } ?? []
            let colorPool = sameColor.isEmpty ? ready : sameColor
            let bulk = colorPool.filter { !isDetail[$0] }
            let pool = bulk.isEmpty ? colorPool : bulk
            let chosen = pool.min { capRank[$0] != capRank[$1] ? capRank[$0] < capRank[$1] : $0 < $1 }!
            guard let lastExitPoint else { return (chosen, false) }
            return (chosen, exitPoints[chosen].distance(to: lastExitPoint) < entryPoints[chosen].distance(to: lastExitPoint))
        }
        guard let lastExitPoint, let lastColor else {
            // Nothing sewn yet: start from whichever ready candidate reads
            // first -- left-to-right, then top-to-bottom -- rather than
            // raw authoring/index order. For raster-imported artwork that
            // order is really "whichever pixel a top-to-bottom,
            // left-to-right mask scan happened to reach first"
            // (`RasterTracing.connectedComponents`'s own scan direction),
            // which has no reason to line up with a word's actual reading
            // order -- a letter with a slightly different baseline or an
            // ascender/accent can easily get scanned before an earlier
            // letter sitting a little lower. Found against a real
            // machine-sewn design that started mid-word instead of at its
            // first letter. See CHANGELOG.md.
            let bulk = ready.filter { !isDetail[$0] }
            let first = (bulk.isEmpty ? ready : bulk).min { a, b in
                let pa = entryPoints[a], pb = entryPoints[b]
                if pa.x != pb.x { return pa.x < pb.x }
                return pa.y < pb.y
            }!
            return (first, false)
        }

        let sameColor = ready.filter { colors[$0] == lastColor }
        let colorPool = sameColor.isEmpty ? ready : sameColor
        // Details last: only once the colour block's bulk shapes are
        // all placed (or waiting on something they contain).
        let bulk = colorPool.filter { !isDetail[$0] }
        let pool = bulk.isEmpty ? colorPool : bulk

        func approachDistance(_ i: Int) -> (distance: Double, reversed: Bool) {
            let dEntry = entryPoints[i].distance(to: lastExitPoint)
            let dExit = exitPoints[i].distance(to: lastExitPoint)
            return dExit < dEntry ? (dExit, true) : (dEntry, false)
        }

        let chosen = pool.min { a, b in
            let da = approachDistance(a).distance, db = approachDistance(b).distance
            if da != db { return da < db }
            return a < b
        }!
        return (chosen, approachDistance(chosen).reversed)
    }

    /// True if `candidate`'s outer boundary genuinely contains `other`'s
    /// outer boundary and is meaningfully larger — not just larger by float
    /// rounding noise, which would make two near-identical overlapping
    /// shapes swap unpredictably. A bounding-box check alone isn't enough:
    /// an L-shaped (or otherwise concave) candidate can have a bounding box
    /// that encloses another shape sitting in its notch, entirely outside
    /// the candidate's actual area — the bounding-box test is kept only as
    /// a cheap pre-check before the real one.
    private static func isBackground(_ candidate: VectorShape, relativeTo other: VectorShape) -> Bool {
        guard let candidateOuter = candidate.subPaths.first?.points, candidateOuter.count >= 3,
              let otherOuter = other.subPaths.first?.points, !otherOuter.isEmpty else {
            return false
        }

        let candidateBox = candidate.boundingBox, otherBox = other.boundingBox
        guard !candidateBox.isEmpty, !otherBox.isEmpty,
              candidateBox.minX <= otherBox.minX, candidateBox.minY <= otherBox.minY,
              candidateBox.maxX >= otherBox.maxX, candidateBox.maxY >= otherBox.maxY else {
            return false
        }

        guard otherOuter.allSatisfy({ PolygonGeometry.pointInPolygon($0, polygon: candidateOuter) }) else {
            return false
        }

        let outerArea = abs(PolygonGeometry.signedArea(candidateOuter))
        let innerArea = abs(PolygonGeometry.signedArea(otherOuter))
        return outerArea > innerArea * 1.05
    }
}
