import Foundation

/// Corrects one specific, safe class of sequencing problem: a smaller
/// object that another, larger object's bounding box fully contains, but
/// which is currently scheduled to sew *before* that larger object (spec
/// §23: "background before foreground... inside before outside"). For the
/// common concentric/overlapping case — a badge's outer ring, a shape with
/// text or a smaller emblem centered on top of it — sewing the small
/// foreground detail first means the larger background stitching that
/// follows can bury or distort it; sewing background-to-foreground avoids
/// that.
///
/// This is deliberately conservative, not a general "sort everything by
/// size" pass: two objects that don't geometrically contain one another are
/// never reordered relative to each other, so it can't scatter same-color
/// objects that `DigitizePipeline`'s color-run consolidation depends on
/// being adjacent, and it can't disturb an ordering the artwork encodes for
/// reasons this heuristic doesn't understand. A full graph-based sequencing
/// pass (informed by studying Ink/Stitch's `auto_satin` jump-minimizing
/// routing — see `EMBROIDERY_ALGORITHM_REFERENCE.md`) is the natural next
/// step beyond this; this handles the single clearest, lowest-risk case
/// first.
public enum ObjectSequencer {
    public static func sequence(_ objects: [EmbroideryObject]) -> [EmbroideryObject] {
        guard objects.count > 1 else { return objects }
        var result = objects
        let maxIterations = objects.count * objects.count + 1 // generous safety cap; containment has no cycles
        var iterations = 0
        var madeChange = true

        while madeChange, iterations < maxIterations {
            madeChange = false
            iterations += 1

            search: for j in 0..<result.count {
                for i in 0..<j {
                    if isBackground(result[j], relativeTo: result[i]) {
                        // result[j] should sew before result[i] but currently doesn't -- move it there.
                        let background = result.remove(at: j)
                        result.insert(background, at: i)
                        madeChange = true
                        break search
                    }
                }
            }
        }
        return result
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
