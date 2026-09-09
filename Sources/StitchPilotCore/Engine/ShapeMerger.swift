import Foundation

/// Merges several vector shapes into one by rasterizing their union at a
/// fine resolution and re-tracing the connected outline(s) — the same
/// rasterize-then-trace approach `ImageImporter` uses for raster artwork,
/// rather than true polygon boolean union, which this engine doesn't
/// otherwise implement. Good enough for its actual use (joining a handful
/// of adjacent or overlapping shapes a user selected, or painting extra
/// coverage onto one), not a general-purpose CAD operation.
public enum ShapeMerger {
    /// Pixels per millimeter used to rasterize before tracing — fine
    /// enough that the retraced outline doesn't visibly differ from a true
    /// vector union at normal viewing/embroidery scale, coarse enough that
    /// merging stays fast for typical shape sizes.
    private static let pixelsPerMM = 10.0
    /// Hard cap on the rasterization buffer so merging two far-apart,
    /// large shapes can't allocate an enormous mask — resolution is scaled
    /// down to fit instead of merging failing outright.
    private static let maxPixels = 6_000_000
    private static let simplifyEpsilonPixels = 1.2

    /// Merges `shapes` into one `VectorShape`. Returns `nil` if the shapes
    /// have no combined area (e.g. all empty) or nothing traceable
    /// resulted (degenerate input). If the union isn't a single connected
    /// region — the selected shapes don't actually touch or overlap — the
    /// result still contains every piece, as separate subpaths of one
    /// shape, so nothing is silently dropped; it just sews as one object
    /// instead of several.
    public static func merge(_ shapes: [VectorShape]) -> VectorShape? {
        let nonEmpty = shapes.filter { !$0.subPaths.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        return trace(polygonSets: nonEmpty.map { $0.subPaths.map { $0.points } })
    }

    /// Merges `shapes` together with an additional freehand brush stroke —
    /// a sequence of points sampled along a drag, at physical radius
    /// `radiusMM` — the operation behind "paint in more coverage": the
    /// stroke is rendered as a chain of overlapping discs and unioned with
    /// the given shapes exactly like `merge` unions ordinary shapes, so a
    /// stroke overlapping an existing shape extends it seamlessly.
    public static func mergeWithStroke(_ shapes: [VectorShape], strokePoints: [Point2D], radiusMM: Double) -> VectorShape? {
        guard radiusMM > 0, !strokePoints.isEmpty else { return merge(shapes) }
        return merge(shapes + discChain(along: strokePoints, radiusMM: radiusMM))
    }

    /// The delete pen's operation: removes a freehand brush stroke's own
    /// coverage from `shapes` instead of adding it -- rasterizes `shapes`
    /// (unioned, exactly like `mergeWithStroke`), then clears whichever
    /// pixels the same disc-chain stroke covers, and retraces. Returns
    /// `nil` both for degenerate input and for a stroke that erases every
    /// remaining pixel -- either way, the caller has nothing left to keep
    /// as a shape (a fully-erased object should be deleted outright, not
    /// kept as an empty one).
    public static func subtractStroke(_ shapes: [VectorShape], strokePoints: [Point2D], radiusMM: Double) -> VectorShape? {
        let nonEmpty = shapes.filter { !$0.subPaths.isEmpty }
        guard !nonEmpty.isEmpty, radiusMM > 0, !strokePoints.isEmpty else { return nil }
        return traceDifference(basePolygonSets: nonEmpty.map { $0.subPaths.map { $0.points } },
                                erasePolygonSets: discChain(along: strokePoints, radiusMM: radiusMM).map { $0.subPaths.map { $0.points } })
    }

    /// Approximates a brush stroke as a chain of overlapping regular
    /// polygons ("discs") along the path — resampled at a fine enough step
    /// that consecutive discs always overlap, so the chain has no gaps for
    /// the rasterizer to see as separate pieces. Each disc is its own
    /// `VectorShape` (not one shape with many subpaths) specifically so
    /// `trace`'s per-shape even-odd rasterization treats overlapping discs
    /// as a *union* — the way separate shapes combine — rather than
    /// even-odd, which is what a single shape's own subpaths mean (that's
    /// how a shape's holes are represented) and would toggle every
    /// overlap back off, punching the stroke full of holes wherever
    /// consecutive discs overlapped.
    private static func discChain(along points: [Point2D], radiusMM: Double) -> [VectorShape] {
        guard let first = points.first else { return [] }
        var samples: [Point2D] = [first]
        let step = max(radiusMM * 0.5, 0.05)
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let segmentLength = a.distance(to: b)
            guard segmentLength > 0 else { continue }
            var traveled = step
            while traveled < segmentLength {
                let t = traveled / segmentLength
                samples.append(Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
                traveled += step
            }
            samples.append(b)
        }
        return samples.map { center in
            VectorShape(subPaths: [SubPath(points: regularPolygon(center: center, radius: radiusMM, sides: 12), closed: true)])
        }
    }

    private static func regularPolygon(center: Point2D, radius: Double, sides: Int) -> [Point2D] {
        (0..<sides).map { i in
            let angle = 2 * Double.pi * Double(i) / Double(sides)
            return Point2D(center.x + radius * cos(angle), center.y + radius * sin(angle))
        }
    }

    /// `polygonSets` is one entry per original shape, each entry being that
    /// shape's own list of subpath polygons — rasterized (and unioned into
    /// the shared mask) one shape at a time so each shape's *own* subpaths
    /// still combine via even-odd (correctly punching out its own holes),
    /// while two different *shapes* combine via union (so overlapping
    /// shapes merge solid, rather than canceling out where they overlap
    /// the way one single even-odd pass across everyone's edges at once
    /// would).
    private static func trace(polygonSets: [[[Point2D]]]) -> VectorShape? {
        var combinedBounds = BoundingBox.empty
        for polygons in polygonSets {
            for polygon in polygons {
                combinedBounds = combinedBounds.union(BoundingBox(points: polygon))
            }
        }
        guard let sizing = rasterSizing(for: combinedBounds) else { return nil }

        var mask = [Bool](repeating: false, count: sizing.width * sizing.height)
        for polygons in polygonSets {
            rasterize(polygons: polygons, into: &mask, width: sizing.width, height: sizing.height,
                      originX: sizing.originX, originY: sizing.originY, scale: sizing.scale)
        }
        return traceMask(mask, sizing: sizing)
    }

    /// Same rasterize-then-trace shape as `trace`, except the mask starts
    /// from `basePolygonSets`' own union and then has `erasePolygonSets`'
    /// union cleared out of it before retracing -- the delete pen's actual
    /// mechanism. Sized off the *base* shapes' own bounds only (matching
    /// `subtractStroke`'s doc comment: erasing can only remove area, never
    /// add any outside what was already there), so an eraser stroke
    /// reaching outside the shape being erased simply has no effect out
    /// there rather than growing the raster buffer for no reason.
    private static func traceDifference(basePolygonSets: [[[Point2D]]], erasePolygonSets: [[[Point2D]]]) -> VectorShape? {
        var combinedBounds = BoundingBox.empty
        for polygons in basePolygonSets {
            for polygon in polygons {
                combinedBounds = combinedBounds.union(BoundingBox(points: polygon))
            }
        }
        guard let sizing = rasterSizing(for: combinedBounds) else { return nil }

        var mask = [Bool](repeating: false, count: sizing.width * sizing.height)
        for polygons in basePolygonSets {
            rasterize(polygons: polygons, into: &mask, width: sizing.width, height: sizing.height,
                      originX: sizing.originX, originY: sizing.originY, scale: sizing.scale)
        }
        var eraseMask = [Bool](repeating: false, count: sizing.width * sizing.height)
        for polygons in erasePolygonSets {
            rasterize(polygons: polygons, into: &eraseMask, width: sizing.width, height: sizing.height,
                      originX: sizing.originX, originY: sizing.originY, scale: sizing.scale)
        }
        for i in mask.indices where eraseMask[i] { mask[i] = false }
        return traceMask(mask, sizing: sizing)
    }

    private struct RasterSizing {
        var scale: Double
        var originX: Double
        var originY: Double
        var width: Int
        var height: Int
    }

    /// The raster buffer geometry (resolution, origin, clamped size) shared
    /// by every rasterize-then-trace operation here -- pulled out so
    /// `trace` and `traceDifference` compute it identically instead of two
    /// copies drifting apart.
    private static func rasterSizing(for combinedBounds: BoundingBox) -> RasterSizing? {
        guard !combinedBounds.isEmpty else { return nil }
        let marginMM = 1.0
        var scale = pixelsPerMM
        let rawWidth = (combinedBounds.width + marginMM * 2) * scale
        let rawHeight = (combinedBounds.height + marginMM * 2) * scale
        if rawWidth * rawHeight > Double(maxPixels), rawWidth * rawHeight > 0 {
            scale *= (Double(maxPixels) / (rawWidth * rawHeight)).squareRoot()
        }
        let originX = combinedBounds.minX - marginMM
        let originY = combinedBounds.minY - marginMM
        let width = max(1, Int(((combinedBounds.width + marginMM * 2) * scale).rounded(.up)))
        let height = max(1, Int(((combinedBounds.height + marginMM * 2) * scale).rounded(.up)))
        guard width * height <= maxPixels else { return nil }
        return RasterSizing(scale: scale, originX: originX, originY: originY, width: width, height: height)
    }

    private static func traceMask(_ mask: [Bool], sizing: RasterSizing) -> VectorShape? {
        let components = RasterTracing.connectedComponents(mask: mask, width: sizing.width, height: sizing.height, minAreaPixels: 1)
        guard !components.isEmpty else { return nil }

        var subPaths: [SubPath] = []
        for component in components {
            guard let boundary = RasterTracing.traceBoundary(mask: mask, width: sizing.width, height: sizing.height, start: component.topLeftMost) else { continue }
            let simplified = PolylineSimplify.douglasPeucker(boundary, epsilon: simplifyEpsilonPixels)
            guard simplified.count > 2 else { continue }
            let docPoints = simplified.map { Point2D(sizing.originX + $0.x / sizing.scale, sizing.originY + $0.y / sizing.scale) }
            subPaths.append(SubPath(points: docPoints, closed: true))
        }
        guard !subPaths.isEmpty else { return nil }
        return VectorShape(subPaths: subPaths)
    }

    /// Fills `polygons` (even-odd across them, matching how a shape with
    /// holes is represented elsewhere in this engine) into `mask` with a
    /// per-row scanline fill — far faster than testing every pixel against
    /// every polygon edge, which matters multiplied across every pixel of
    /// a merge's raster buffer.
    private static func rasterize(polygons: [[Point2D]], into mask: inout [Bool], width: Int, height: Int,
                                   originX: Double, originY: Double, scale: Double) {
        guard !polygons.isEmpty else { return }
        for py in 0..<height {
            let y = originY + (Double(py) + 0.5) / scale
            var crossings: [Double] = []
            for polygon in polygons {
                guard polygon.count > 2 else { continue }
                var j = polygon.count - 1
                for i in 0..<polygon.count {
                    let pi = polygon[i], pj = polygon[j]
                    if (pi.y > y) != (pj.y > y) {
                        let t = (y - pi.y) / (pj.y - pi.y)
                        crossings.append(pi.x + t * (pj.x - pi.x))
                    }
                    j = i
                }
            }
            guard !crossings.isEmpty else { continue }
            crossings.sort()
            var k = 0
            while k + 1 < crossings.count {
                let xStartPx = max(0, Int(((crossings[k] - originX) * scale).rounded()))
                let xEndPx = min(width, Int(((crossings[k + 1] - originX) * scale).rounded()))
                if xStartPx < xEndPx {
                    for px in xStartPx..<xEndPx { mask[py * width + px] = true }
                }
                k += 2
            }
        }
    }
}
