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
/// - up to `parameters.maxSatinWidthMM`: satin.
/// - wider: tatami fill.
///
/// This only looks at the shape's *outer* boundary (`subPaths[0]`) even
/// when the shape has holes — holes affect how it should be *filled*, not
/// whether it reads as a stroke or a blob in the first place. Note this
/// only catches a shape whose *average* width is too thin; a shape whose
/// average is fine but that narrows below the minimum in one section
/// (e.g. a tapering stroke) still classifies as `.satin` here and is
/// instead caught per-section by `SatinColumnGenerator.generatePartial`.
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
        if averageWidth <= parameters.maxSatinWidthMM { return .satin }
        return .tatamiFill
    }
}
