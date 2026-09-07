import Foundation

/// Automatic color-count presets (spec §8). Each maps to a default target
/// color count; `ColorQuantizer` still won't invent colors that aren't
/// there — the target is a ceiling, not a quota, so simple 2-color artwork
/// stays 2 colors under any preset.
public enum ColorQuantizationPreset: String, CaseIterable, Sendable {
    case preserveArtwork
    case normalEmbroidery
    case productionEfficient
    case minimalColors

    public var defaultMaxColors: Int {
        switch self {
        case .preserveArtwork: return 16
        case .normalEmbroidery: return 8
        case .productionEfficient: return 5
        case .minimalColors: return 3
        }
    }
}

public struct ColorCluster: Sendable {
    public var rgb: RGBColor
    public var pixelCount: Int
}

/// Reduces a raster image's colors to a small palette suitable for
/// embroidery (spec §8: "Embroidery cannot reproduce unlimited raster
/// colors efficiently"). Works in two stages for performance: first build a
/// coarse histogram over the actual pixels (so a multi-megapixel image
/// still quantizes in milliseconds), then run k-means *on the histogram's
/// distinct colors, weighted by frequency* in perceptual (CIE L*a*b*) space
/// — clustering directly on millions of raw pixels would be far slower for
/// no benefit, since the histogram already captures every distinct color
/// and how often it occurs.
///
/// Deterministic by construction (spec §54: "core stitch generation must
/// remain deterministic and testable" — quantization feeds directly into
/// object segmentation, so the same rule applies): cluster seeding uses a
/// farthest-point heuristic (first center = most frequent color; each
/// subsequent center = the remaining color farthest, weighted, from all
/// already-chosen centers) instead of the random seeding k-means++
/// typically uses, so the same image always quantizes to the same palette.
public enum ColorQuantizer {
    /// Bits of RGB precision kept per channel when building the histogram
    /// (5 bits = 32 levels/channel = 32,768 buckets) — enough to distinguish
    /// visually different colors without the histogram itself becoming a
    /// performance bottleneck on large images.
    private static let histogramBitsPerChannel = 5

    public static func quantize(pixels: [RGBColor], maxColors: Int) -> [ColorCluster] {
        guard maxColors > 0, !pixels.isEmpty else { return [] }

        let entries = buildHistogram(pixels)
        guard !entries.isEmpty else { return [] }

        let clusters: [ColorCluster]
        if entries.count <= maxColors {
            clusters = entries.map { ColorCluster(rgb: $0.rgb, pixelCount: Int($0.weight)) }
                .sorted { $0.pixelCount > $1.pixelCount }
        } else {
            clusters = kMeans(entries: entries, k: maxColors)
        }
        return mergeAntiAliasingClusters(clusters)
    }

    /// A smoothly anti-aliased edge between two solid colors (a scaled-down
    /// raster logo especially, where the source image never had a hard
    /// pixel boundary to begin with) produces a whole ramp of intermediate
    /// shades between them -- e.g. navy fading through several grays into
    /// white. With enough colors allowed, `kMeans` happily gives each ramp
    /// step its own cluster (they're genuinely far apart in LAB space from
    /// each solid color), and each one then becomes its own tiny traced
    /// object in `ImageImporter` -- found via a real customer logo that
    /// came back as a swarm of small gray slivers ringing every letter,
    /// on top of the two colors actually intended.
    ///
    /// Distinguishes a blend from a genuine third color geometrically: a
    /// small cluster lying almost exactly *on the line segment* between two
    /// much larger clusters (its distances to both sum to nearly their
    /// distance to each other) is a blend of those two and gets folded into
    /// whichever it's closer to; a small cluster of its own distinct hue
    /// (an accent color, say) doesn't sit on that line and is left alone.
    private static func mergeAntiAliasingClusters(_ clusters: [ColorCluster]) -> [ColorCluster] {
        guard clusters.count > 2 else { return clusters }
        let total = clusters.reduce(0) { $0 + $1.pixelCount }
        guard total > 0 else { return clusters }

        let smallFraction = 0.08
        let large = clusters.filter { Double($0.pixelCount) / Double(total) >= smallFraction }
        let small = clusters.filter { Double($0.pixelCount) / Double(total) < smallFraction }
        guard large.count >= 2, !small.isEmpty else { return clusters }

        var mergeTarget: [RGBColor: RGBColor] = [:]
        for cluster in small {
            let lab = cluster.rgb.lab
            var bestTarget: RGBColor?
            var bestRelSlack = Double.infinity
            for i in 0..<large.count {
                for j in (i + 1)..<large.count {
                    let labA = large[i].rgb.lab, labB = large[j].rgb.lab
                    let dAB = sqrt(distanceSquared(labA, labB))
                    guard dAB > 1 else { continue }
                    let dA = sqrt(distanceSquared(lab, labA)), dB = sqrt(distanceSquared(lab, labB))
                    let relSlack = ((dA + dB) - dAB) / dAB
                    if relSlack < bestRelSlack {
                        bestRelSlack = relSlack
                        bestTarget = dA < dB ? large[i].rgb : large[j].rgb
                    }
                }
            }
            // A generous but bounded tolerance -- real blends land almost
            // exactly on the line; this still excludes a color that's only
            // vaguely "between" two others in a loose perceptual sense.
            if let target = bestTarget, bestRelSlack <= 0.15 {
                mergeTarget[cluster.rgb] = target
            }
        }
        guard !mergeTarget.isEmpty else { return clusters }

        var merged: [RGBColor: Int] = [:]
        for cluster in clusters {
            let target = mergeTarget[cluster.rgb] ?? cluster.rgb
            merged[target, default: 0] += cluster.pixelCount
        }
        return merged.map { ColorCluster(rgb: $0.key, pixelCount: $0.value) }.sorted { $0.pixelCount > $1.pixelCount }
    }

    private struct HistogramEntry { var rgb: RGBColor; var lab: LABColor; var weight: Double }

    /// Buckets pixels by a reduced-precision RGB key (for grouping speed),
    /// but returns each bucket's *true average color*, not the bucket's
    /// quantization boundary — using the boundary value directly would
    /// visibly shift colors (e.g. pure white 0xFFFFFF bucketing down to
    /// 0xF8F8F8) even when no actual color reduction was needed because the
    /// image already had few distinct colors. Bucketing only groups pixels
    /// for counting; it never substitutes for the real color.
    ///
    /// Returned in a fixed, content-derived order (sorted by RGB) rather
    /// than dictionary iteration order, which Swift does not guarantee
    /// stable — `kMeans`'s farthest-point seeding and Lloyd's-algorithm tie
    /// breaks both depend on a stable input order for the determinism this
    /// type promises (spec §54), and dictionary order is exactly the kind
    /// of hidden global state that requirement rules out.
    private static func buildHistogram(_ pixels: [RGBColor]) -> [HistogramEntry] {
        let shift = 8 - histogramBitsPerChannel
        var sums: [RGBColor: (r: Int, g: Int, b: Int, count: Int)] = [:]
        for p in pixels {
            let bucketKey = RGBColor(r: (p.r >> shift) << shift, g: (p.g >> shift) << shift, b: (p.b >> shift) << shift)
            var entry = sums[bucketKey] ?? (0, 0, 0, 0)
            entry.r += Int(p.r); entry.g += Int(p.g); entry.b += Int(p.b); entry.count += 1
            sums[bucketKey] = entry
        }
        return sums.map { _, v in
            let rgb = RGBColor(r: UInt8(v.r / v.count), g: UInt8(v.g / v.count), b: UInt8(v.b / v.count))
            return HistogramEntry(rgb: rgb, lab: rgb.lab, weight: Double(v.count))
        }.sorted { ($0.rgb.r, $0.rgb.g, $0.rgb.b) < ($1.rgb.r, $1.rgb.g, $1.rgb.b) }
    }

    private static func kMeans(entries: [HistogramEntry], k: Int) -> [ColorCluster] {

        var centers: [LABColor] = []
        let mostFrequent = entries.max(by: { $0.weight < $1.weight })!.lab
        centers.append(mostFrequent)

        while centers.count < k {
            var farthestEntry: (lab: LABColor, dist: Double)?
            for entry in entries {
                let nearestDist = centers.map { distanceSquared($0, entry.lab) }.min()!
                let weighted = nearestDist * entry.weight
                if farthestEntry == nil || weighted > farthestEntry!.dist {
                    farthestEntry = (entry.lab, weighted)
                }
            }
            guard let next = farthestEntry else { break }
            centers.append(next.lab)
        }

        // Lloyd's algorithm: assign-then-recompute, until stable or capped.
        for _ in 0..<15 {
            var sums = [(l: Double, a: Double, b: Double, weight: Double, rgbWeighted: (r: Double, g: Double, b: Double))](
                repeating: (0, 0, 0, 0, (0, 0, 0)), count: centers.count)

            for entry in entries {
                var bestIndex = 0
                var bestDist = Double.infinity
                for (i, c) in centers.enumerated() {
                    let d = distanceSquared(c, entry.lab)
                    if d < bestDist { bestDist = d; bestIndex = i }
                }
                sums[bestIndex].l += entry.lab.l * entry.weight
                sums[bestIndex].a += entry.lab.a * entry.weight
                sums[bestIndex].b += entry.lab.b * entry.weight
                sums[bestIndex].weight += entry.weight
                sums[bestIndex].rgbWeighted.r += Double(entry.rgb.r) * entry.weight
                sums[bestIndex].rgbWeighted.g += Double(entry.rgb.g) * entry.weight
                sums[bestIndex].rgbWeighted.b += Double(entry.rgb.b) * entry.weight
            }

            var changed = false
            for i in 0..<centers.count where sums[i].weight > 0 {
                let newCenter = LABColor(l: sums[i].l / sums[i].weight, a: sums[i].a / sums[i].weight, b: sums[i].b / sums[i].weight)
                if distanceSquared(newCenter, centers[i]) > 0.01 { changed = true }
                centers[i] = newCenter
            }
            if !changed { break }
        }

        // Final assignment pass to build clusters with real RGB averages (not a re-derived LAB->RGB, which can go out of gamut).
        var clusters = [(weight: Double, r: Double, g: Double, b: Double)](repeating: (0, 0, 0, 0), count: centers.count)
        for entry in entries {
            var bestIndex = 0
            var bestDist = Double.infinity
            for (i, c) in centers.enumerated() {
                let d = distanceSquared(c, entry.lab)
                if d < bestDist { bestDist = d; bestIndex = i }
            }
            clusters[bestIndex].weight += entry.weight
            clusters[bestIndex].r += Double(entry.rgb.r) * entry.weight
            clusters[bestIndex].g += Double(entry.rgb.g) * entry.weight
            clusters[bestIndex].b += Double(entry.rgb.b) * entry.weight
        }

        return clusters.compactMap { c in
            guard c.weight > 0 else { return nil }
            let rgb = RGBColor(r: UInt8(clamping: Int((c.r / c.weight).rounded())),
                                g: UInt8(clamping: Int((c.g / c.weight).rounded())),
                                b: UInt8(clamping: Int((c.b / c.weight).rounded())))
            return ColorCluster(rgb: rgb, pixelCount: Int(c.weight))
        }.sorted { $0.pixelCount > $1.pixelCount }
    }

    private static func distanceSquared(_ a: LABColor, _ b: LABColor) -> Double {
        let dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b
        return dl * dl + da * da + db * db
    }
}
