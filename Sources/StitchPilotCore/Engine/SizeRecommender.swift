import Foundation

/// Recommends an initial physical finished-size for freshly imported
/// artwork, based on how fine the artwork's own detail actually is —
/// rather than always defaulting to one fixed size regardless of content.
///
/// The problem this solves: a fixed default (say 100mm wide) sews a simple
/// bold logo just fine, but silently ruins anything with fine detail — a
/// badge with a ring of curved text, tiny stars, thin serifs — since
/// embroidery thread (~0.3-0.4mm) puts a hard physical floor on how small a
/// stitch can be and still read as the shape it's meant to be. Found
/// against a real team-crest PNG: sewn at the size a fixed 100mm default
/// produced, its ring text and tagline were completely illegible; the
/// *exact same file* at 3x that size came out clearly legible. This
/// estimator exists so that scale-up happens automatically before the user
/// ever sees a bad first result, not as a fix they have to discover by
/// trial and error.
///
/// The user can always override the recommendation afterward (`Finished
/// Size` in the app) — this only changes what the *first* number is.
public enum SizeRecommender {
    /// The finest feature this estimator tries to keep sewable, in mm —
    /// matches `EmbroideryObject.minSatinWidthMM`'s own default, the same
    /// floor the stitch-type classifier already uses to decide between
    /// running stitch and satin. Sizing so the thinnest real detail lands
    /// right at this floor gives it a fighting chance of surviving as an
    /// actual stitched shape instead of collapsing into an illegible
    /// running-stitch scribble.
    private static let targetMinFeatureMM = 1.5

    /// Never recommends *smaller* than this — a simple, bold design (a
    /// single solid logo, no fine detail) has no need to shrink below a
    /// normal, comfortable default just because its own thinnest feature
    /// happens to be wide.
    private static let minRecommendedWidthMM = 100.0

    /// Never recommends *larger* than this, regardless of how fine the
    /// detail is — a hard ceiling so a handful of stray noise pixels (or
    /// artwork that's simply unsuited to embroidery at any reasonable size)
    /// can't blow the recommendation up into something absurd; beyond this
    /// point the user needs to simplify the artwork, not just scale up.
    private static let maxRecommendedWidthMM = 400.0

    /// Which low percentile of per-shape widths counts as "the thinnest
    /// real detail" — the *minimum* alone is too fragile (a single stray
    /// speck below the noise floor would dominate the whole
    /// recommendation), but the plain average is too forgiving (a handful
    /// of genuinely fine strokes among many bold ones would get averaged
    /// away). A low percentile is a robust middle ground: still driven by
    /// the artwork's actual finest *significant* content, not knocked
    /// around by one outlier.
    private static let thinPercentile = 0.15

    /// `shapes` should be the raw imported shapes in their own native
    /// units (source pixels for a raster import, native units for SVG) --
    /// consistent units are all that matters, since only the *ratio*
    /// between the thinnest feature and the overall extent drives the
    /// result. `currentWidthMM` is what the recommendation falls back to
    /// when the artwork has no measurable detail to react to (e.g. every
    /// shape degenerate) -- pass the app's existing default so behavior is
    /// unchanged for that edge case.
    public static func recommendedWidthMM(for shapes: [VectorShape], currentWidthMM: Double) -> Double {
        var combined = BoundingBox.empty
        for shape in shapes { combined = combined.union(shape.boundingBox) }
        guard combined.width > 0, combined.height > 0 else { return currentWidthMM }

        let widths = shapes.compactMap(averageWidth).filter { $0 > 0 }.sorted()
        guard !widths.isEmpty else { return currentWidthMM }

        let index = min(widths.count - 1, Int(Double(widths.count) * thinPercentile))
        let thinnestSignificant = widths[index]
        guard thinnestSignificant > 0 else { return currentWidthMM }

        let neededWidthMM = targetMinFeatureMM * combined.width / thinnestSignificant
        return min(maxRecommendedWidthMM, max(minRecommendedWidthMM, neededWidthMM))
    }

    /// Same technique `StitchTypeClassifier` already uses to judge a
    /// shape's own stitch width: area divided by its extent along its
    /// principal (elongation) axis -- a solid blob's width comes out close
    /// to its full size, while a thin curved stroke's comes out close to
    /// its actual stroke width regardless of how far it curves, which a
    /// plain bounding-box measurement would get wrong.
    private static func averageWidth(_ shape: VectorShape) -> Double? {
        guard let outer = shape.subPaths.first, outer.points.count >= 3 else { return nil }
        let area = abs(PolygonGeometry.signedArea(outer.points))
        let (axis, mean) = PolygonGeometry.principalAxis(outer.points)
        let (lo, hi) = PolygonGeometry.projectionRange(outer.points, axis: axis, mean: mean)
        let length = hi - lo
        guard length > 0, area > 0 else { return nil }
        return area / length
    }
}
