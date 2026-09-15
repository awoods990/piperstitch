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
    /// `rasterSizing` below scales down to a *continuous* target of
    /// `maxPixels`, then rounds each dimension up to a whole pixel
    /// independently — two ceilings that can each add just under a pixel,
    /// nudging the discrete `width * height` a few thousand pixels past
    /// the continuous target right at the boundary. Targeting 98% instead
    /// of 100% leaves comfortable slack (~120,000 pixels) for that
    /// rounding, found via a real merge (four largeish logo shapes on a
    /// wide canvas) that failed outright with "Couldn't merge the
    /// selected shapes" despite being nowhere near a genuinely
    /// unreasonable size. See CHANGELOG.md.
    private static let rasterBudgetSafetyFactor = 0.98
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

    /// The union of `shapes` grown outward by `marginMM` on every side,
    /// as one shape -- the footprint a laydown stitch covers
    /// (`LaydownGenerator`). Grown on the raster by a square dilation
    /// (exact along the axes, ~1.4× on a diagonal), which is what a
    /// laydown margin needs and far cheaper than a true disc. With
    /// `fillHoles`, enclosed background (letter counters, the inside of a
    /// ring) becomes part of the footprint too, so the nap is flattened
    /// there as well.
    public static func dilatedUnion(_ shapes: [VectorShape], marginMM: Double, fillHoles: Bool) -> VectorShape? {
        let nonEmpty = shapes.filter { !$0.subPaths.isEmpty }
        guard !nonEmpty.isEmpty, marginMM >= 0 else { return nil }
        var bounds = BoundingBox.empty
        for shape in nonEmpty { bounds = bounds.union(shape.boundingBox) }
        // Room for the margin on every side.
        let grown = BoundingBox(minX: bounds.minX - marginMM, minY: bounds.minY - marginMM, maxX: bounds.maxX + marginMM, maxY: bounds.maxY + marginMM)
        guard let sizing = rasterSizing(for: grown) else { return nil }
        var mask = [Bool](repeating: false, count: sizing.width * sizing.height)
        for shape in nonEmpty {
            rasterize(polygons: shape.subPaths.map { $0.points }, into: &mask, width: sizing.width, height: sizing.height,
                      originX: sizing.originX, originY: sizing.originY, scale: sizing.scale)
        }
        let radius = Int((marginMM * sizing.scale).rounded())
        if radius > 0 { dilate(&mask, width: sizing.width, height: sizing.height, radius: radius) }
        if fillHoles { fillEnclosedBackground(&mask, width: sizing.width, height: sizing.height) }
        return traceMask(mask, sizing: sizing)
    }

    /// `base` with every part that `covers` will sew over removed, except
    /// a band `keepOverlapMM` wide under each cover's edge (registration:
    /// the cover must have something to land on if the fabric shifts) --
    /// Wilcom's "remove overlaps" (docs/WILCOM_MANUAL_REVIEW.md C2).
    /// Pieces smaller than `minFragmentAreaMM2` are dropped so no tiny
    /// object survives. Returns nil when nothing sewable is left.
    ///
    /// Returned as one shape per connected piece (each with its own
    /// holes): a shape cut in two by a cover sews as two objects, not as
    /// one outline-with-a-hole that a satin rail would bridge.
    public static func subtractCoverage(of base: VectorShape, by covers: [VectorShape], keepOverlapMM: Double, minFragmentAreaMM2: Double) -> [VectorShape] {
        guard !base.subPaths.isEmpty else { return [] }
        let coverage = covers.filter { !$0.subPaths.isEmpty }
        guard !coverage.isEmpty else { return [base] }
        var bounds = base.boundingBox
        for cover in coverage { bounds = bounds.union(cover.boundingBox) }
        guard let sizing = rasterSizing(for: bounds) else { return [base] }
        var mask = [Bool](repeating: false, count: sizing.width * sizing.height)
        rasterize(polygons: base.subPaths.map { $0.points }, into: &mask, width: sizing.width, height: sizing.height,
                  originX: sizing.originX, originY: sizing.originY, scale: sizing.scale)
        var erase = [Bool](repeating: false, count: mask.count)
        for cover in coverage {
            rasterize(polygons: cover.subPaths.map { $0.points }, into: &erase, width: sizing.width, height: sizing.height,
                      originX: sizing.originX, originY: sizing.originY, scale: sizing.scale)
        }
        // What survives outright, plus the registration band: covered
        // base within `keepOverlapMM` of the surviving part -- the strip
        // the cover's edge lands on. (Not a uniform band round every
        // cover: where a cover extends past the base there is no seam,
        // and a strip there would just be a sliver sewn twice.)
        var remaining = [Bool](repeating: false, count: mask.count)
        var removedAny = false
        for i in mask.indices where mask[i] {
            if erase[i] { removedAny = true } else { remaining[i] = true }
        }
        guard removedAny else { return [base] }
        // Drop uncovered fragments below the minimum (before the band is
        // added back, so a sliver doesn't survive on its band alone).
        let minPixels = max(1, Int(minFragmentAreaMM2 * sizing.scale * sizing.scale))
        guard RasterTracing.removeSmallComponents(&remaining, width: sizing.width, height: sizing.height, minAreaPixels: minPixels) else { return [] }
        let radius = Int((keepOverlapMM * sizing.scale).rounded())
        var near = remaining
        if radius > 0 { dilate(&near, width: sizing.width, height: sizing.height, radius: radius) }
        for i in mask.indices { mask[i] = remaining[i] || (mask[i] && near[i]) }
        guard let traced = traceMask(mask, sizing: sizing) else { return [] }
        return splitIntoPieces(traced)
    }

    /// One shape per outer boundary, each with the holes that lie inside
    /// it. `traceMask` lists outers first, then every hole; an outer is a
    /// subpath not inside any other subpath.
    static func splitIntoPieces(_ shape: VectorShape) -> [VectorShape] {
        let paths = shape.subPaths.filter { $0.points.count >= 3 }
        guard paths.count > 1 else { return paths.isEmpty ? [] : [VectorShape(subPaths: paths)] }
        func isInside(_ inner: SubPath, _ outer: SubPath) -> Bool {
            let probe = inner.points[0]
            let pointOfInner = Point2D(probe.x + (inner.points[1].x - probe.x) * 0.5, probe.y + (inner.points[1].y - probe.y) * 0.5)
            return PolygonGeometry.pointInPolygon(pointOfInner, polygon: outer.points)
        }
        var outers: [Int] = [], holes: [Int] = []
        for (i, path) in paths.enumerated() {
            let insideAnother = paths.indices.contains { j in j != i && abs(PolygonGeometry.signedArea(paths[j].points)) > abs(PolygonGeometry.signedArea(path.points)) && isInside(path, paths[j]) }
            if insideAnother { holes.append(i) } else { outers.append(i) }
        }
        return outers.map { o in
            // A hole belongs to the smallest outer that contains it.
            let mine = holes.filter { h in
                let containing = outers.filter { isInside(paths[h], paths[$0]) }
                let smallest = containing.min { abs(PolygonGeometry.signedArea(paths[$0].points)) < abs(PolygonGeometry.signedArea(paths[$1].points)) }
                return smallest == o
            }
            return VectorShape(subPaths: [paths[o]] + mine.map { paths[$0] })
        }
    }

    /// Square dilation by `radius` pixels: a horizontal pass then a
    /// vertical pass, each marking every pixel within `radius` of a set
    /// one along that axis, in O(pixels) via a running count.
    private static func dilate(_ mask: inout [Bool], width: Int, height: Int, radius: Int) {
        func pass(length: Int, count: Int, index: (Int, Int) -> Int) {
            var line = [Bool](repeating: false, count: length)
            for l in 0..<count {
                for i in 0..<length { line[i] = mask[index(l, i)] }
                var window = 0
                for i in 0..<(length + radius) {
                    if i < length, line[i] { window += 1 }
                    let leaving = i - 2 * radius - 1
                    if leaving >= 0, line[leaving] { window -= 1 }
                    let target = i - radius
                    if target >= 0, target < length, window > 0 { mask[index(l, target)] = true }
                }
            }
        }
        pass(length: width, count: height) { row, x in row * width + x }
        pass(length: height, count: width) { column, y in y * width + column }
    }

    /// Sets every background pixel that can't reach the raster's border
    /// through background -- the holes inside the foreground.
    private static func fillEnclosedBackground(_ mask: inout [Bool], width: Int, height: Int) {
        var outside = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        func seed(_ i: Int) { if !mask[i], !outside[i] { outside[i] = true; stack.append(i) } }
        for x in 0..<width { seed(x); seed((height - 1) * width + x) }
        for y in 0..<height { seed(y * width); seed(y * width + width - 1) }
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            if x > 0 { seed(i - 1) }
            if x < width - 1 { seed(i + 1) }
            if y > 0 { seed(i - width) }
            if y < height - 1 { seed(i + width) }
        }
        for i in mask.indices where !mask[i] && !outside[i] { mask[i] = true }
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
        let budget = Double(maxPixels) * rasterBudgetSafetyFactor
        if rawWidth * rawHeight > budget, rawWidth * rawHeight > 0 {
            scale *= (budget / (rawWidth * rawHeight)).squareRoot()
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

        func toDocPoints(_ boundary: [Point2D]) -> SubPath? {
            let simplified = PolylineSimplify.douglasPeucker(boundary, epsilon: simplifyEpsilonPixels)
            guard simplified.count > 2 else { return nil }
            let docPoints = simplified.map { Point2D(sizing.originX + $0.x / sizing.scale, sizing.originY + $0.y / sizing.scale) }
            return SubPath(points: docPoints, closed: true)
        }

        var subPaths: [SubPath] = []
        for component in components {
            guard let boundary = RasterTracing.traceBoundary(mask: mask, width: sizing.width, height: sizing.height, start: component.topLeftMost),
                  let subPath = toDocPoints(boundary) else { continue }
            subPaths.append(subPath)
        }
        guard !subPaths.isEmpty else { return nil }

        // Any of those same connected components can still have its own
        // hole -- a letterform counter, most commonly. Rasterizing and
        // re-tracing without also finding these would otherwise silently
        // fill them in (an "O" merged or painted anywhere near becoming a
        // solid blob), even though the outer-boundary tracing above is
        // completely correct on its own terms: it was never asked to look
        // for enclosed background at all. See CHANGELOG.md.
        let holeBoundaries = RasterTracing.findEnclosedRegionBoundaries(foregroundMask: mask, width: sizing.width, height: sizing.height, minAreaPixels: 1)
        for boundary in holeBoundaries {
            guard let subPath = toDocPoints(boundary) else { continue }
            subPaths.append(subPath)
        }
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
