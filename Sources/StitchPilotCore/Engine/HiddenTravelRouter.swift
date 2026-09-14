import Foundation

/// Routes a same-color travel gap as buried running stitch instead of a
/// jump, when doing so avoids a trim — real digitizing software's "travel
/// under" technique: a path that will be covered by stitching sewn
/// afterward doesn't need to be cut and rejoined, since the buried
/// stitches vanish once that later stitching covers them.
///
/// Checks every object still to come in the sew order — not just the one
/// immediately following the gap — for whether its own eventual stitching
/// covers the straight path, and buries the travel the moment any one of
/// them qualifies. The immediate-next object remains the common, simplest
/// case (checked first, so it wins whenever it applies): since it's sewn
/// right afterward, its own stitching is guaranteed to cover that exact
/// area moments later, no assumption about anything else needed. But nothing
/// about the underlying physical reasoning is actually specific to "the
/// very next thing sewn," or even to matching the travel's own color —
/// once *anything* dense enough gets stitched on top of a spot, whatever
/// was buried underneath it is hidden, regardless of which object that
/// turns out to be or what color it sews in (thread coverage is opaque;
/// it doesn't care what color is underneath it). This is
/// `EMBROIDERY_ALGORITHM_REFERENCE.md`'s own "recommended next
/// improvements" #1, implemented: generalizing beyond the immediate-next-
/// object case to arbitrary later objects, including a different color if
/// it's opaque enough.
///
/// "Opaque enough" is still a real, narrow requirement, not "anything
/// later" — see `nextObjectCanHideATravelPath`'s own doc comment for why
/// tatami fill specifically doesn't qualify even though "inside the
/// polygon" alone might suggest it does.
///
/// Only worth doing when the plain alternative would have cost a trim: a
/// same-color jump under `maxJumpWithoutTrimMM` already gets sewn as an
/// untrimmed thread carry, which ends up buried under later coverage just
/// the same once something covers it — bridging that case would only add
/// stitches for no benefit. This only fires above that threshold, where
/// the plain alternative was a real trim (cut, reposition, tie in again).
public enum HiddenTravelRouter {
    /// How many points to sample *strictly between* the two endpoints when
    /// checking whether a candidate path is covered by a later object's
    /// shape. The endpoints themselves are excluded deliberately: the exit
    /// and entry points are fixed regardless of this decision (a plain
    /// jump travels between the same two points), and the entry point in
    /// particular is essentially always sitting on or right at its own
    /// object's boundary by construction (every stitch generator starts
    /// exactly at the shape's edge) — checking it with even-odd ray-casting
    /// is a numerically ambiguous edge case that has no bearing on the
    /// actual decision anyway. A straight segment can still dip outside a
    /// concave shape's boundary between two interior-ish points, so
    /// multiple interior samples (not just a midpoint) are checked.
    private static let interiorSampleCount = 6

    /// How many objects ahead in the sew order to check as a potential
    /// coverer for one gap, mirroring `ObjectSequencer.maxObjectsForTwoOpt`'s
    /// own reasoning: a real design's covering object, if one exists, is
    /// almost always found within the first handful of objects sewn after
    /// the gap (the same color run continuing, or a large background
    /// object sewn nearby) — bounding the search keeps this an O(n) pass
    /// per gap instead of unbounded, without giving up realistic coverage.
    private static let maxLookaheadObjects = 40

    public static func bridgeSameColorGaps(_ items: [(object: EmbroideryObject, runs: [[Point2D]])], thresholdMM: Double) -> [(object: EmbroideryObject, runs: [[Point2D]])] {
        guard items.count > 1 else { return items }
        var result = items

        for i in 1..<result.count {
            let previous = result[i - 1]
            let next = result[i]
            guard previous.object.threadColor.rgb == next.object.threadColor.rgb,
                  let exit = previous.runs.last?.last, let entry = next.runs.first?.first,
                  exit.distance(to: entry) > thresholdMM else { continue }

            let lookaheadEnd = min(result.count, i + maxLookaheadObjects)
            guard firstCoveringObjectIndex(from: exit, to: entry, in: result[i..<lookaheadEnd]) != nil else { continue }

            let stitchLength = max(next.object.parameters.stitchLengthMM, 0.3)
            let bridge = RunningStitchGenerator.generate(
                for: SubPath(points: [exit, entry], closed: false),
                stitchLengthMM: stitchLength,
                minStitchLengthMM: next.object.parameters.minStitchLengthMM
            )
            // Drop both endpoints: `exit` already duplicates the previous
            // object's own last point, and `entry` already duplicates
            // `next.runs.first.first` — keep only the genuinely new
            // in-between stitches. The bridge is attached as a lead-in to
            // `next` (whichever object actually ends up covering it, `next`
            // itself or a later one, the bridge still needs to sit right
            // after `previous`'s own exit chronologically, so it always
            // prepends to `next`'s run regardless of which object's
            // eventual coverage justified it).
            let bridgePoints = Array(bridge.dropFirst().dropLast())
            guard !bridgePoints.isEmpty else { continue }

            result[i].runs[0] = bridgePoints + next.runs[0]
        }
        return result
    }

    /// The index (within `candidates`, a slice of the still-to-come sew
    /// order starting with the immediate next object) of the first
    /// candidate whose own eventual stitching covers `a`->`b`, or `nil` if
    /// none do. Checked in sew order, not by any other ranking — the
    /// immediate-next object is deliberately checked first so it keeps
    /// winning whenever it qualifies (the simplest, most obviously-correct
    /// case), and any qualifying candidate is equally valid regardless of
    /// how far ahead it sews, since static geometry doesn't change between
    /// now and whenever it actually gets stitched.
    private static func firstCoveringObjectIndex(from a: Point2D, to b: Point2D, in candidates: ArraySlice<(object: EmbroideryObject, runs: [[Point2D]])>) -> Int? {
        for index in candidates.indices {
            let candidate = candidates[index].object
            guard nextObjectCanHideATravelPath(candidate), pathIsCoveredByShape(from: a, to: b, shape: candidate.shape) else { continue }
            return index
        }
        return nil
    }

    /// "The path lands geometrically inside the next object's polygon" is
    /// necessary but NOT sufficient for a buried travel stitch to actually
    /// stay hidden -- it also needs the covering object's own stitching to
    /// be dense enough, along that exact path, to visually swallow it.
    /// Satin qualifies: crossings typically run 0.3-0.5mm apart, tight
    /// enough to read as one continuous solid column regardless of which
    /// direction a buried stitch happens to cross it. Tatami fill (and
    /// Cross-Hatch/Basket Weave, both built from the same row generation)
    /// does NOT: "Rows" texture is only rows in the first place because
    /// there's real, intentional negative space between them -- a bridge
    /// stitch cutting diagonally across that texture, rather than running
    /// along one row, lands in the gaps and stays visibly exposed. Found
    /// directly against real lettering (an all-tatami-fill word, "N" and
    /// "H"'s own row spacing wide enough that a same-color bridge between
    /// two non-adjacent letters cut a visible diagonal scratch across
    /// several letters in between) -- see CHANGELOG.md.
    private static func nextObjectCanHideATravelPath(_ object: EmbroideryObject) -> Bool {
        object.stitchType == .satin
    }

    private static func pathIsCoveredByShape(from a: Point2D, to b: Point2D, shape: VectorShape) -> Bool {
        let polygons = shape.subPaths.map { $0.points }
        guard !polygons.isEmpty else { return false }
        for step in 1...interiorSampleCount {
            let t = Double(step) / Double(interiorSampleCount + 1)
            let sample = Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            guard PolygonGeometry.pointInPolygons(sample, polygons: polygons) else { return false }
        }
        return true
    }
}
