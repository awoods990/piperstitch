import Foundation

/// Automatically decides which stitch technique best represents a shape —
/// spec §11 "The software should decide which embroidery technique best
/// represents each object" — rather than requiring the caller to choose
/// `stitchType` by hand for every imported object.
///
/// The heuristic: estimate the shape's average width as `area / length`
/// along its principal (elongation) axis — the same measurement a person
/// eyeballing a shape uses ("that's a thin stroke" vs. "that's a big
/// blob") — and bucket by width, roughly matching standard digitizing
/// practice (very thin line <~1.5mm: running; narrow shape ~1.5-8mm: satin;
/// medium ~8-12mm: satin or tatami depending on the shape; wide >~12mm:
/// tatami):
/// - narrower than `parameters.minSatinWidthMM` (default 1.5mm): too thin
///   even for satin, sews as a running-stitch outline instead (spec §19
///   "small object management" — a hairline stroke).
/// - has one or more holes: tatami fill, regardless of width -- see below.
/// - up to `satinUniformWidthThresholdMM` (8mm): satin outright.
/// - up to `parameters.maxSatinWidthMM` (default 12mm): satin only if the
///   shape's width is fairly *uniform* along its length (a real column,
///   which still lays down fine as satin even toward the wider end of the
///   practical range); a shape whose width varies a lot from one end to
///   the other — its average landing in this medium band doesn't mean
///   every part of it is medium-width — goes to tatami instead, since a
///   real column is what satin actually sews well, not just "something
///   whose average width happens to fit."
/// - wider than that: tatami fill.
///
/// A shape with holes always routes to tatami fill, never satin: unlike
/// `TatamiFillGenerator` (even-odd across every sub-path), `Satin
/// ColumnGenerator` only ever looks at the outer boundary
/// (`shape.subPaths.first`) and has no way to represent a hole at all — a
/// letterform counter (the enclosed hole inside O, P, R, A, D, B, Q...)
/// would get silently filled in solid, and satin's rail-fitting (which
/// assumes a simple, roughly-elongated column shape) can produce genuine
/// nonsense for a boundary shaped like a ring rather than a column. An
/// earlier version of this classifier didn't check for holes at all — real
/// small-lettering artwork with counter-bearing glyphs classified as satin
/// came out structurally wrong (not just visually rough), found by
/// rendering a real logo's tagline text and finding it illegible in a way
/// no amount of "just make satin denser" would fix (see CHANGELOG.md).
/// Note this only catches a shape whose *average* width is too thin; a
/// shape whose average is fine but that narrows below the minimum in one
/// section (e.g. a tapering stroke) still classifies as `.satin` here and
/// is instead caught per-section by `SatinColumnGenerator.generatePartial`.
public enum StitchTypeClassifier {
    /// Below this width, a shape stays satin regardless of how uniform it
    /// is — commercial digitizing guidance treats ~1.5-8mm as squarely
    /// satin's territory. Above it (up to `maxSatinWidthMM`), satin is
    /// still viable but only for a shape that's actually a uniform column,
    /// not just "average width happens to land under 12mm."
    private static let satinUniformWidthThresholdMM = 8.0
    /// How much a shape's width may vary along its length (as a fraction
    /// of its widest point) and still count as "uniform enough" for satin
    /// in the 8-12mm band — generous enough for a letter stroke's natural
    /// taper at serifs/joins, tight enough to route a genuinely blob-shaped
    /// region (whose average width just happens to fall in this band) to
    /// tatami instead.
    private static let uniformWidthToleranceFraction = 0.35
    private static let widthProfileSamples = 12

    public static func classify(shape: VectorShape, parameters: StitchGenerationParameters) -> StitchType {
        guard let outer = shape.subPaths.first, outer.points.count >= 3 else { return .runningStitch }

        let area = abs(PolygonGeometry.signedArea(outer.points))
        let (axis, mean) = PolygonGeometry.principalAxis(outer.points)
        let (lo, hi) = PolygonGeometry.projectionRange(outer.points, axis: axis, mean: mean)
        let length = hi - lo

        guard length > 0, area > 0 else { return .runningStitch }
        let averageWidth = area / length

        if averageWidth < parameters.minSatinWidthMM { return .runningStitch }
        if shape.subPaths.count > 1 { return .tatamiFill }
        guard averageWidth <= parameters.maxSatinWidthMM else { return .tatamiFill }
        guard averageWidth > satinUniformWidthThresholdMM else { return .satin }

        let widths = widthProfile(outer.points, axis: axis, mean: mean, lo: lo, hi: hi, samples: widthProfileSamples)
        guard let maxWidth = widths.max(), let minWidth = widths.min(), maxWidth > 0 else { return .satin }
        return (maxWidth - minWidth) / maxWidth <= uniformWidthToleranceFraction ? .satin : .tatamiFill
    }

    /// Samples the shape's local width at several points along its
    /// principal axis by casting a perpendicular ray through the outer
    /// boundary — a coarse, classification-only measurement (not the
    /// compensated per-crossing widths `SatinColumnGenerator` computes for
    /// actual rail placement) used only to tell "a fairly uniform column"
    /// from "an irregular shape whose average width doesn't represent it."
    private static func widthProfile(_ points: [Point2D], axis: Point2D, mean: Point2D, lo: Double, hi: Double, samples: Int) -> [Double] {
        let perpendicular = Point2D(-axis.y, axis.x)
        guard hi > lo, samples > 0 else { return [] }

        var widths: [Double] = []
        for i in 0..<samples {
            let t = (Double(i) + 0.5) / Double(samples)
            let alongAxis = lo + (hi - lo) * t

            var crossings: [Double] = []
            var j = points.count - 1
            for k in 0..<points.count {
                let a = points[j], b = points[k]
                let pa = (a.x - mean.x) * axis.x + (a.y - mean.y) * axis.y
                let pb = (b.x - mean.x) * axis.x + (b.y - mean.y) * axis.y
                if (pa > alongAxis) != (pb > alongAxis), pb != pa {
                    let segT = (alongAxis - pa) / (pb - pa)
                    let ix = a.x + (b.x - a.x) * segT
                    let iy = a.y + (b.y - a.y) * segT
                    crossings.append((ix - mean.x) * perpendicular.x + (iy - mean.y) * perpendicular.y)
                }
                j = k
            }
            guard crossings.count >= 2 else { continue }
            crossings.sort()
            widths.append(crossings.last! - crossings.first!)
        }
        return widths
    }
}
