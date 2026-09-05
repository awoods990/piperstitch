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
/// `sequence` (below) uses each object's bounding-box *center* as its
/// proximity proxy — cheap, but not what a machine actually travels
/// to/from. `sequenceGenerated` uses the real first/last points of each
/// object's already-generated stitch path instead, and additionally
/// considers *reversing* a path (sewing it end-first) when that's the
/// closer approach from wherever the previous object left off — a
/// genuinely closer step toward jump-minimizing routing, since it
/// measures the actual points a machine jumps from/to rather than a
/// geometric proxy.
public enum ObjectSequencer {
    public static func sequence(_ objects: [EmbroideryObject]) -> [EmbroideryObject] {
        guard objects.count > 1 else { return objects }
        let centers = objects.map { $0.shape.boundingBox.center }
        let order = computeOrder(
            shapes: objects.map { $0.shape },
            colors: objects.map { $0.threadColor.rgb },
            entryPoints: centers,
            exitPoints: centers
        )
        return order.map { objects[$0.index] }
    }

    /// Like `sequence`, but for objects whose stitch points have already
    /// been generated: uses each path's real start/end points for the
    /// proximity heuristic instead of a bounding-box center, and reverses
    /// a path (returning its points in the opposite order) when entering
    /// from its end is the closer approach — the machine sews the same
    /// shape either way, so there's no reason not to pick whichever
    /// direction shortens the jump into it.
    public static func sequenceGenerated(_ items: [(object: EmbroideryObject, points: [Point2D])]) -> [(object: EmbroideryObject, points: [Point2D])] {
        guard items.count > 1 else { return items }
        let order = computeOrder(
            shapes: items.map { $0.object.shape },
            colors: items.map { $0.object.threadColor.rgb },
            entryPoints: items.map { $0.points.first! },
            exitPoints: items.map { $0.points.last! }
        )
        return order.map { entry in
            var item = items[entry.index]
            if entry.reversed { item.points.reverse() }
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
    private static func computeOrder(shapes: [VectorShape], colors: [RGBColor], entryPoints: [Point2D], exitPoints: [Point2D]) -> [(index: Int, reversed: Bool)] {
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
            let (chosen, reversed) = bestCandidate(in: ready, colors: colors, entryPoints: entryPoints, exitPoints: exitPoints, lastExitPoint: lastExitPoint, lastColor: lastColor)
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
        return order
    }

    /// Picks which ready (dependency-satisfied) item to place next, and
    /// whether it should be entered from its "exit" end instead of its
    /// "entry" end.
    private static func bestCandidate(in ready: [Int], colors: [RGBColor], entryPoints: [Point2D], exitPoints: [Point2D], lastExitPoint: Point2D?, lastColor: RGBColor?) -> (index: Int, reversed: Bool) {
        guard let lastExitPoint, let lastColor else {
            // Nothing sewn yet: no color or position to relate to, so keep
            // the earliest-authored candidate for stable, predictable output.
            return (ready.min()!, false)
        }

        let sameColor = ready.filter { colors[$0] == lastColor }
        let pool = sameColor.isEmpty ? ready : sameColor

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
