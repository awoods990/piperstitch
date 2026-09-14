import Foundation

/// Post-processing stitch cleanup applied after generation, regardless of
/// which generator produced the points — spec §30: "After stitch
/// generation, analyze needle penetrations. Detect and correct: stitches
/// that are too short, excessively long stitches..." This is deliberately a
/// separate pass rather than logic duplicated inside every generator, so a
/// future generator (motif fill, cross stitch, ...) gets the same cleanup
/// for free.
public enum StitchFilter {
    public static func apply(_ points: [Point2D], minLengthMM: Double, maxLengthMM: Double) -> [Point2D] {
        splitLongStitches(mergeTinyStitches(points, minLengthMM: minLengthMM), maxLengthMM: maxLengthMM)
    }

    /// Removes near-duplicate consecutive points that would otherwise
    /// produce a sub-minimum stitch (thread breaks, no visible detail
    /// added), while still landing exactly on the true final point rather
    /// than a near-duplicate of it — snapping the last kept point onto the
    /// real endpoint instead of appending a second, tiny-distance point
    /// beside it.
    ///
    /// The guard below used to require more than 2 points, which silently
    /// skipped this check entirely for the smallest possible run -- exactly
    /// two points -- even when those two points were pathologically close
    /// together (a near-zero-width satin crossing at a tiny fragment's
    /// tapered tip, say). A genuinely tiny object (well within reach once
    /// fragmentation is common, as it is on any detail-heavy or curved
    /// import) can easily generate such a run, and it sailed straight past
    /// this filter into the exported file -- confirmed directly against
    /// the PiperStitch bird mark, whose readiness report flagged
    /// under-0.15mm stitches that `QualityAnalyzer`'s own doc comment
    /// already correctly describes as "a real defect, not a style choice":
    /// this filter is supposed to make that impossible. Two points closer
    /// than `minLengthMM` now collapse to the single true endpoint, the
    /// same outcome a longer run's own trailing run of too-close points
    /// already collapses to.
    static func mergeTinyStitches(_ points: [Point2D], minLengthMM: Double) -> [Point2D] {
        guard points.count > 1, minLengthMM > 0 else { return points }
        var out: [Point2D] = [points[0]]
        for p in points.dropFirst() {
            if let last = out.last, last.distance(to: p) < minLengthMM {
                continue
            }
            out.append(p)
        }
        if let realLast = points.last, out.last != realLast {
            if let last = out.last, last.distance(to: realLast) < minLengthMM {
                out[out.count - 1] = realLast
            } else {
                out.append(realLast)
            }
        }
        return out
    }

    /// Splits any consecutive pair farther apart than `maxLengthMM` into
    /// evenly-spaced intermediate stitches, so no single stitch exceeds the
    /// practical maximum regardless of what a generator produced. (This is
    /// a quality concern distinct from a machine format's hard per-record
    /// coordinate-range limit, e.g. DST's ±12.1mm — format adapters handle
    /// that separately at export time; this exists so an overly long
    /// stitch never reaches that stage looking like a plausible design
    /// choice instead of a defect.)
    static func splitLongStitches(_ points: [Point2D], maxLengthMM: Double) -> [Point2D] {
        guard points.count > 1, maxLengthMM > 0 else { return points }
        var result: [Point2D] = [points[0]]
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let dist = a.distance(to: b)
            if dist > maxLengthMM {
                let segments = Int((dist / maxLengthMM).rounded(.up))
                for s in 1..<segments {
                    let t = Double(s) / Double(segments)
                    result.append(Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
                }
            }
            result.append(b)
        }
        return result
    }
}
