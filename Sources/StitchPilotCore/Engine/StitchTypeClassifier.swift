import Foundation

/// Automatically decides which stitch technique best represents a shape —
/// spec §11 "The software should decide which embroidery technique best
/// represents each object" — rather than requiring the caller to choose
/// `stitchType` by hand for every imported object.
///
/// The heuristic: estimate the shape's average width as `area / length`
/// along its principal (elongation) axis — the same measurement a person
/// eyeballing a shape uses ("that's a thin stroke" vs. "that's a big
/// blob") — and bucket by width:
/// - narrower than `parameters.minSatinWidthMM`: too thin even for satin,
///   sews as a running-stitch outline instead (spec §19 "small object
///   management" — a hairline stroke).
/// - has one or more holes: tatami fill, regardless of width -- see below.
/// - up to `parameters.maxSatinWidthMM`: satin.
/// - wider: tatami fill.
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
        if averageWidth <= parameters.maxSatinWidthMM { return .satin }
        return .tatamiFill
    }
}
