import Foundation

/// The three satin-quality techniques every professional digitizing
/// package applies on top of a plain zigzag, each documented in the Wilcom
/// reference manual (see docs/WILCOM_MANUAL_REVIEW.md A2, A3, A6) and
/// implemented here as pure post-processing over the rail crossings
/// `SatinColumnGenerator` already computes -- so the single-column path
/// (`computeCrossings`) and the branching-letter path
/// (`computeSegmentCrossings`) get identical behavior from the same code.
///
/// 1. **Auto spacing by width** (`decimate`). Satin density is not a
///    constant: a narrow column at the nominal spacing has needle
///    penetrations so close together that they perforate the fabric and
///    break thread, while a wide column's long stitches need *tighter*
///    spacing to still cover. The crossings are generated on a fine grid
///    and then thinned to a spacing chosen from each crossing's own width
///    (`spacingFactor`), measured along the column's *outside* edge --
///    the edge that has to be covered -- blended `spacingOffsetFraction`
///    of the way toward the inside edge (Wilcom's "fractional spacing").
/// 2. **Stitch shortening** (`shorten`). On the inside of a bend the
///    penetrations bunch up (the inner rail travels far less than the
///    outer for the same number of crossings): thread breaks and a hard
///    lump. Where the inside-edge step falls below a fraction of the
///    nominal spacing, alternate stitches stop short of the inner rail --
///    in a jagged pattern so the shortened penetrations never line up
///    into a visible seam. Coverage on the outside is untouched.
/// 3. **Auto split** (`autoSplit`). A satin stitch longer than a machine
///    sews cleanly (about 7 mm) is broken into shorter stitches -- but at
///    a *randomised* point, never the midpoint, because evenly split
///    stitches put every extra penetration on one line down the middle
///    of the column, which reads as a visible crease. This keeps a wide
///    column looking like satin rather than converting it to tatami.
enum SatinSpacing {
    /// Multiplier on `satinDensityMM` for a crossing of the given width.
    /// Narrow columns space wider (less fabric damage, less bulk), wide
    /// columns tighter (long stitches sag and need more of them to
    /// cover). Piecewise-linear through the anchor points below; the
    /// 5 mm anchor is exactly 1.0 so a mid-width column sews at the
    /// nominal density the user set, and the real Brother-machine
    /// sew-out that tuned that nominal (see `satinDensityMM`'s comment)
    /// stays valid.
    static let anchors: [(widthMM: Double, factor: Double)] = [
        (1.0, 1.45), (1.5, 1.35), (3.0, 1.12), (5.0, 1.0), (8.0, 0.9), (12.0, 0.84),
    ]

    static func spacingFactor(forWidthMM width: Double) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 1 }
        if width <= first.widthMM { return first.factor }
        if width >= last.widthMM { return last.factor }
        for i in 1..<anchors.count where width <= anchors[i].widthMM {
            let (w0, f0) = anchors[i - 1], (w1, f1) = anchors[i]
            let t = (width - w0) / (w1 - w0)
            return f0 + (f1 - f0) * t
        }
        return last.factor
    }

    static func targetSpacing(forWidthMM width: Double, parameters: StitchGenerationParameters) -> Double {
        let nominal = max(parameters.satinDensityMM, 0.1)
        return parameters.satinAutoSpacing ? nominal * spacingFactor(forWidthMM: width) : nominal
    }

    /// How many fine crossings per nominal spacing the generators lay
    /// down before `decimate` thins them -- the resolution the final
    /// spacing can be placed at. 4 keeps placement error under ~12% of
    /// the spacing while staying cheap.
    static let oversampling = 4.0

    /// Thins fine crossings (`railA[i]`/`railB[i]`, already resampled at
    /// `satinDensityMM / oversampling` along curvature-weighted rails) to
    /// the crossings that become real stitches: the first, the last, and
    /// one every time the distance walked since the last kept crossing --
    /// measured on the *outer* rail of each step, blended toward the
    /// inner rail by `parameters.satinSpacingOffsetFraction` -- reaches
    /// the width-dependent target. The kept crossing is interpolated to
    /// the exact point along the fine step where the target is reached
    /// (same fraction on both rails), so the resulting spacing is the
    /// target itself, not the nearest multiple of the fine grid. Works
    /// purely on distances, so it's indifferent to how the grid was made.
    static func decimate(railA: [Point2D], railB: [Point2D], parameters: StitchGenerationParameters,
                         flags: [Bool]? = nil) -> (a: [Point2D], b: [Point2D], flags: [Bool]) {
        let count = min(railA.count, railB.count)
        // Each kept crossing carries the flag of the fine crossing it was
        // placed before (mitre crossings, `SatinCorners`), so the flag
        // survives thinning without the caller re-deriving it.
        func flag(_ i: Int) -> Bool { flags.map { i < $0.count && $0[i] } ?? false }
        guard count > 2 else { return (Array(railA.prefix(count)), Array(railB.prefix(count)), (0..<count).map(flag)) }
        let fraction = min(max(parameters.satinSpacingOffsetFraction, 0), 1)
        var keptA = [railA[0]], keptB = [railB[0]], keptFlags = [flag(0)]
        var walked = 0.0
        for i in 1..<count {
            let stepA = railA[i].distance(to: railA[i - 1])
            let stepB = railB[i].distance(to: railB[i - 1])
            let outer = max(stepA, stepB), inner = min(stepA, stepB)
            let step = outer * (1 - fraction) + inner * fraction
            guard step > 0 else { continue }
            let width = railA[i].distance(to: railB[i])
            let target = targetSpacing(forWidthMM: width, parameters: parameters)
            if walked + step >= target - 1e-9 {
                // Place the crossing exactly where the target is reached
                // within this step, then carry the remainder forward.
                let f = min(1, max(0, (target - walked) / step))
                keptA.append(railA[i - 1] + (railA[i] - railA[i - 1]) * f)
                keptB.append(railB[i - 1] + (railB[i] - railB[i - 1]) * f)
                keptFlags.append(flag(i))
                walked = step * (1 - f)
                // A step longer than a whole target (coarse fine grid on a
                // long straight) may need more than one crossing.
                while walked >= target - 1e-9 {
                    let f2 = min(1, (1 - walked / step) + target / step)
                    keptA.append(railA[i - 1] + (railA[i] - railA[i - 1]) * f2)
                    keptB.append(railB[i - 1] + (railB[i] - railB[i - 1]) * f2)
                    keptFlags.append(flag(i))
                    walked -= target
                    if f2 >= 1 { break }
                }
            } else {
                walked += step
            }
        }
        // Always end exactly on the rails' last crossing; if the last kept
        // one is closer than half a target to it, replace it rather than
        // leaving two crossings nearly on top of each other.
        let endA = railA[count - 1], endB = railB[count - 1]
        let width = endA.distance(to: endB)
        let tail = max(endA.distance(to: keptA[keptA.count - 1]), endB.distance(to: keptB[keptB.count - 1]))
        if keptA.count > 1, tail < targetSpacing(forWidthMM: width, parameters: parameters) / 2 {
            keptA[keptA.count - 1] = endA
            keptB[keptB.count - 1] = endB
            keptFlags[keptFlags.count - 1] = flag(count - 1)
        } else if tail > 1e-9 {
            keptA.append(endA)
            keptB.append(endB)
            keptFlags.append(flag(count - 1))
        }
        return (keptA, keptB, keptFlags)
    }

    /// Wilcom's own shortening tables ("Row 1..5" of consecutive short
    /// stitches, each as a fraction of full length), used as the length
    /// pattern for a group of `k` consecutive shortened stitches. Jagged
    /// on purpose: equal shortening would line the short penetrations up
    /// into a second, inner seam.
    static let shorteningPatterns: [[Double]] = [
        [0.80],
        [0.85, 0.70],
        [0.70, 0.90, 0.70],
        [0.70, 0.90, 0.80, 0.70],
        [0.70, 0.85, 0.65, 0.85, 0.70],
    ]

    /// Applies stitch shortening to consecutive crossings `range` of the
    /// (already decimated and compensated) rails, returning the crossing
    /// endpoints to sew. A crossing whose inside-edge step (the smaller of
    /// its two rails' distances from the previous crossing) is under
    /// `parameters.satinShortenBelowFraction` of that crossing's target
    /// spacing is "tight"; within each run of tight crossings the
    /// penetration on the inner rail is pulled back toward the outer rail
    /// for `k` of every `k + 1` crossings, where `k` (1...5) is however
    /// many need shortening for the *remaining* inner penetrations to sit
    /// at roughly the target spacing. A tiny deterministic jitter is added
    /// to each shortened length so a long, regular curve doesn't develop
    /// its own faint pattern.
    static func shorten(expandedA: [Point2D], expandedB: [Point2D], range: ClosedRange<Int>, parameters: StitchGenerationParameters) -> [(a: Point2D, b: Point2D)] {
        var out: [(a: Point2D, b: Point2D)] = range.map { (expandedA[$0], expandedB[$0]) }
        let threshold = parameters.satinShortenBelowFraction
        guard threshold > 0, out.count > 2 else { return out }

        // Classify each crossing after the first: tight or not, and which
        // rail is the inner one for it.
        struct Tight { let index: Int; let innerIsA: Bool; let ratio: Double }
        var tight: [Tight?] = Array(repeating: nil, count: out.count)
        for j in 1..<out.count {
            let stepA = out[j].a.distance(to: out[j - 1].a)
            let stepB = out[j].b.distance(to: out[j - 1].b)
            let width = out[j].a.distance(to: out[j].b)
            let target = targetSpacing(forWidthMM: width, parameters: parameters)
            let inner = min(stepA, stepB)
            guard target > 0, inner < threshold * target else { continue }
            tight[j] = Tight(index: j, innerIsA: stepA < stepB, ratio: inner / target)
        }

        var j = 1
        while j < out.count {
            guard let first = tight[j] else { j += 1; continue }
            // The maximal run of tight crossings on the same inner rail.
            var end = j
            var worst = first.ratio
            while end + 1 < out.count, let t = tight[end + 1], t.innerIsA == first.innerIsA {
                end += 1
                worst = min(worst, t.ratio)
            }
            // Shorten k of every k+1 so the un-shortened inner penetrations
            // land about one target apart: k = ceil(1/ratio) - 1, capped.
            let k = min(5, max(1, Int((1 / max(worst, 0.05)).rounded(.up)) - 1))
            let pattern = shorteningPatterns[k - 1]
            var position = 0  // 0..<k shortened, k = the full-length one
            for idx in j...end {
                if position < k {
                    let base = pattern[position]
                    let jitter = (hash01(idx, 17) - 0.5) * 0.08
                    let f = min(0.95, max(0.5, base + jitter))
                    let outer = first.innerIsA ? out[idx].b : out[idx].a
                    let inner = first.innerIsA ? out[idx].a : out[idx].b
                    let shortened = Point2D(outer.x + (inner.x - outer.x) * f, outer.y + (inner.y - outer.y) * f)
                    if first.innerIsA { out[idx].a = shortened } else { out[idx].b = shortened }
                }
                position = (position + 1) % (k + 1)
            }
            j = end + 1
        }
        return out
    }

    /// Splits any stitch in `points` longer than `parameters.satinAutoSplitMM`
    /// into pieces no longer than that, placing each extra penetration at a
    /// randomised (but deterministic) fraction along the stitch rather than
    /// evenly, so the split points across neighbouring stitches never form
    /// a line. Applied to a satin zigzag's full point sequence, which
    /// covers both the crossings and the diagonal connector legs between
    /// them (equally long on a wide column).
    static func autoSplit(_ points: [Point2D], parameters: StitchGenerationParameters, seed: Int = 0) -> [Point2D] {
        let maxLen = parameters.satinAutoSplitMM
        guard maxLen > 0, points.count > 1 else { return points }
        var out: [Point2D] = [points[0]]
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let d = a.distance(to: b)
            if d > maxLen {
                // Nominal pieces of 0.7 × maxLen, each split point jittered
                // by up to ±0.2 of a slot: the longest possible piece is
                // 1.4 × 0.7 = 0.98 × maxLen, the shortest 0.42 × maxLen.
                let n = max(2, Int((d / (maxLen * 0.7)).rounded(.up)))
                for k in 1..<n {
                    let jitter = (hash01(seed &+ i, k) - 0.5) * 0.4
                    let t = (Double(k) + jitter) / Double(n)
                    out.append(Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
                }
            }
            out.append(b)
        }
        return out
    }

    /// A cheap deterministic hash in [0, 1) -- the engine must produce the
    /// same stitches for the same design every time (a regenerate after an
    /// unrelated edit must not reshuffle a column), so no system RNG.
    static func hash01(_ i: Int, _ j: Int) -> Double {
        var z = UInt64(truncatingIfNeeded: i) &* 0x9E3779B97F4A7C15 ^ UInt64(truncatingIfNeeded: j) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }
}
