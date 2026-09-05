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
///    can't produce a cycle.
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
public enum ObjectSequencer {
    public static func sequence(_ objects: [EmbroideryObject]) -> [EmbroideryObject] {
        let n = objects.count
        guard n > 1 else { return objects }

        // predecessors[i]: indices that must be sewn before object i.
        var predecessors: [[Int]] = Array(repeating: [], count: n)
        for i in 0..<n {
            for j in 0..<n where j != i {
                if isBackground(objects[j], relativeTo: objects[i]) {
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
        var order: [Int] = []
        order.reserveCapacity(n)
        var lastPlaced: Int?

        while !ready.isEmpty {
            let chosen = bestCandidate(in: ready, objects: objects, lastPlaced: lastPlaced)
            ready.removeAll { $0 == chosen }
            order.append(chosen)
            lastPlaced = chosen
            for successor in successors[chosen] {
                inDegree[successor] -= 1
                if inDegree[successor] == 0 { ready.append(successor) }
            }
        }

        // Containment is a strict partial order (see isBackground's area
        // margin), so it cannot cycle -- every index is placed exactly
        // once. This is a defensive fallback only, never expected to run.
        guard order.count == n else {
            let placed = Set(order)
            return order.map { objects[$0] } + (0..<n).filter { !placed.contains($0) }.map { objects[$0] }
        }
        return order.map { objects[$0] }
    }

    /// Picks which ready (dependency-satisfied) object to place next.
    private static func bestCandidate(in ready: [Int], objects: [EmbroideryObject], lastPlaced: Int?) -> Int {
        guard let lastPlaced else {
            // Nothing sewn yet: no color or position to relate to, so keep
            // the earliest-authored candidate for stable, predictable output.
            return ready.min()!
        }
        let previous = objects[lastPlaced]
        let previousCenter = previous.shape.boundingBox.center

        let sameColor = ready.filter { objects[$0].threadColor.rgb == previous.threadColor.rgb }
        let pool = sameColor.isEmpty ? ready : sameColor

        return pool.min { a, b in
            let da = objects[a].shape.boundingBox.center.distance(to: previousCenter)
            let db = objects[b].shape.boundingBox.center.distance(to: previousCenter)
            if da != db { return da < db }
            return a < b
        }!
    }

    /// True if `candidate`'s bounding box fully contains `other`'s and is
    /// meaningfully larger — not just larger by float rounding noise, which
    /// would make two near-identical overlapping shapes swap unpredictably.
    private static func isBackground(_ candidate: EmbroideryObject, relativeTo other: EmbroideryObject) -> Bool {
        let outer = candidate.shape.boundingBox
        let inner = other.shape.boundingBox
        guard !outer.isEmpty, !inner.isEmpty else { return false }
        guard outer.minX <= inner.minX, outer.minY <= inner.minY, outer.maxX >= inner.maxX, outer.maxY >= inner.maxY else {
            return false
        }
        let outerArea = outer.width * outer.height
        let innerArea = inner.width * inner.height
        return outerArea > innerArea * 1.05
    }
}
