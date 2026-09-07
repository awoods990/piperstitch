import Foundation
import CoreGraphics
import ImageIO

public enum ImageImportError: Error, LocalizedError {
    case cannotDecode
    case noForegroundFound

    public var errorDescription: String? {
        switch self {
        case .cannotDecode:
            return "Couldn't decode this image. It may be corrupted or an unsupported variant of its format."
        case .noForegroundFound:
            return "Couldn't find any distinct foreground shapes in this image — it may be blank, or entirely one flat color."
        }
    }
}

public struct ImageImportResult {
    /// One shape per detected color region, in pixel coordinates (origin
    /// top-left, Y down — same convention as SVG import).
    public var shapes: [VectorShape]
    /// Parallel to `shapes`: the region's quantized color.
    public var fillColors: [RGBColor?]
    public var pixelWidth: Int
    public var pixelHeight: Int
}

/// Imports raster artwork (PNG/JPEG/TIFF/BMP/WEBP/GIF) by finding
/// foreground regions and vectorizing their boundaries — connected-component
/// labeling + Moore-neighbor contour tracing + polyline simplification —
/// rather than treating every pixel as a stitch (spec §7: "construct clean
/// vector-like regions... do not merely trace every pixel").
///
/// Color handling (spec §8): foreground pixels are reduced to at most
/// `maxColors` colors with `ColorQuantizer` (perceptual/LAB k-means), then
/// segmented *per color* — each color gets its own connected-component pass
/// — so a simple multi-color logo produces one object per color region
/// rather than one big region colored however the first pixel happened to
/// be. Gradient/photograph detection and text-region detection (also spec
/// §7) remain Phase 3+.
public enum ImageImporter {
    /// Pixels closer than this (0-255 per channel, summed) to the detected
    /// background color are treated as background.
    private static let colorDistanceThreshold: Double = 45
    /// Connected components smaller than this many pixels are dropped —
    /// "eliminate insignificant isolated pixels" (spec §7).
    private static let minComponentAreaPixels = 8
    /// Douglas-Peucker epsilon, in source pixels.
    private static let simplifyEpsilonPixels: Double = 1.5

    public static func importShapes(from data: Data, maxColors: Int = ColorQuantizationPreset.normalEmbroidery.defaultMaxColors) throws -> ImageImportResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageImportError.cannotDecode
        }

        let width = cgImage.width, height = cgImage.height
        guard width > 1, height > 1 else { throw ImageImportError.cannotDecode }

        var pixels = try renderRGBA(cgImage, width: width, height: height)
        unpremultiply(&pixels, width: width, height: height)
        let foregroundMask = try computeForegroundMask(pixels: pixels, width: width, height: height)

        var foregroundColors: [RGBColor] = []
        foregroundColors.reserveCapacity(width * height)
        for i in 0..<(width * height) where foregroundMask[i] {
            foregroundColors.append(RGBColor(r: pixels[i * 4], g: pixels[i * 4 + 1], b: pixels[i * 4 + 2]))
        }
        guard !foregroundColors.isEmpty else { throw ImageImportError.noForegroundFound }

        let clusters = ColorQuantizer.quantize(pixels: foregroundColors, maxColors: maxColors)
        guard !clusters.isEmpty else { throw ImageImportError.noForegroundFound }

        // Memoized nearest-cluster lookup: real artwork repeats exact RGB
        // values constantly (flat-color logos especially), so caching by
        // exact color avoids re-running LAB conversion + Delta-E per pixel.
        var nearestClusterCache: [RGBColor: Int] = [:]
        func nearestCluster(_ color: RGBColor) -> Int {
            if let cached = nearestClusterCache[color] { return cached }
            var bestIndex = 0, bestDist = Double.infinity
            for (i, cluster) in clusters.enumerated() {
                let d = RGBColor.deltaE(color, cluster.rgb)
                if d < bestDist { bestDist = d; bestIndex = i }
            }
            nearestClusterCache[color] = bestIndex
            return bestIndex
        }

        var labels = [Int](repeating: -1, count: width * height)
        for i in 0..<(width * height) where foregroundMask[i] {
            let color = RGBColor(r: pixels[i * 4], g: pixels[i * 4 + 1], b: pixels[i * 4 + 2])
            labels[i] = nearestCluster(color)
        }

        var shapes: [VectorShape] = []
        var fillColors: [RGBColor?] = []
        for (clusterIndex, cluster) in clusters.enumerated() {
            var clusterMask = [Bool](repeating: false, count: width * height)
            for i in 0..<(width * height) { clusterMask[i] = labels[i] == clusterIndex }

            let components = RasterTracing.connectedComponents(mask: clusterMask, width: width, height: height, minAreaPixels: minComponentAreaPixels)
            for component in components {
                guard let boundary = RasterTracing.traceBoundary(mask: clusterMask, width: width, height: height, start: component.topLeftMost) else { continue }
                let simplified = PolylineSimplify.douglasPeucker(boundary, epsilon: simplifyEpsilonPixels)
                guard simplified.count > 2 else { continue }
                shapes.append(VectorShape(subPaths: [SubPath(points: regularizeIfCircular(simplified), closed: true)]))
                fillColors.append(cluster.rgb)
            }
        }
        guard !shapes.isEmpty else { throw ImageImportError.noForegroundFound }
        return ImageImportResult(shapes: shapes, fillColors: fillColors, pixelWidth: width, pixelHeight: height)
    }

    /// If a traced boundary is very close to a circle (common for round
    /// badges, buttons, and sports-team logos), replaces the noisy
    /// pixel-traced polygon with a smooth, mathematically regular polygon
    /// at the same center and radius. A source image's circle inevitably
    /// traces as a jagged pixel staircase at typical raster resolutions --
    /// Douglas-Peucker simplification thins the point count but doesn't
    /// smooth the wobble, so it's still visibly rough once stitched, in a
    /// way a real circular badge never is. Detected by how consistent the
    /// boundary's distance from its own centroid is: a real circle's
    /// points are all almost exactly one radius out; an arbitrary shape's
    /// (a letter, an irregular blob) vary far more, so this only fires for
    /// genuinely round shapes, not by coincidentally having a square
    /// bounding box.
    private static func regularizeIfCircular(_ points: [Point2D]) -> [Point2D] {
        guard points.count >= 8 else { return points }
        let box = BoundingBox(points: points)
        guard box.width > 0, box.height > 0 else { return points }
        guard box.width / box.height > 0.9, box.width / box.height < 1.1 else { return points }

        let center = box.center
        let radii = points.map { $0.distance(to: center) }
        let meanRadius = radii.reduce(0, +) / Double(radii.count)
        guard meanRadius > 0 else { return points }
        let variance = radii.reduce(0) { $0 + ($1 - meanRadius) * ($1 - meanRadius) } / Double(radii.count)
        let relativeStdDev = variance.squareRoot() / meanRadius
        guard relativeStdDev < 0.06 else { return points }

        let sides = 72
        return (0..<sides).map { i in
            let angle = 2 * Double.pi * Double(i) / Double(sides)
            return Point2D(center.x + meanRadius * cos(angle), center.y + meanRadius * sin(angle))
        }
    }

    // MARK: - Pixel access

    private static func renderRGBA(_ cgImage: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: width * 4, space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageImportError.cannotDecode
        }
        // No flip needed: CGContext.draw(image:in:) already places the
        // image's row 0 at buffer row 0 (verified empirically — an earlier
        // version of this code added a manual flip here on the assumption
        // that a fresh CGBitmapContext needs one, which actually inverted
        // every raster import). Buffer row 0 == image row 0 == the top of
        // the image, matching our Y-down convention with no transform.
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    /// `renderRGBA` draws into a *premultiplied*-alpha context (the only
    /// kind `CGContext` supports as a drawing destination), so every
    /// partially-transparent pixel's stored RGB is `trueColor * alpha`, not
    /// its true color — a 50%-alpha gold edge pixel is stored roughly as
    /// dark-brown, not gold. Left uncorrected, every anti-aliased edge in
    /// source artwork (there can be thousands, one ring around every letter
    /// and detail in a text-heavy logo) reads as its own spurious "color"
    /// distinct from both the true foreground and the background, each
    /// becoming its own tiny traced object — the actual cause of a small
    /// logo with fine detail (`SMA Logo.webp`, a school seal with text)
    /// producing well over a million stitches and visibly jagged contours
    /// (found via `DigitizeCLI` against that file — see CHANGELOG.md).
    /// Un-premultiplying here, once, restores the true color so downstream
    /// quantization and contour tracing only ever see colors that actually
    /// appear in the artwork.
    private static func unpremultiply(_ pixels: inout [UInt8], width: Int, height: Int) {
        for i in 0..<(width * height) {
            let a = pixels[i * 4 + 3]
            guard a > 0, a < 255 else { continue } // a==255: already straight; a==0: fully transparent, color is moot
            let scale = 255.0 / Double(a)
            pixels[i * 4] = UInt8(max(0, min(255, (Double(pixels[i * 4]) * scale).rounded())))
            pixels[i * 4 + 1] = UInt8(max(0, min(255, (Double(pixels[i * 4 + 1]) * scale).rounded())))
            pixels[i * 4 + 2] = UInt8(max(0, min(255, (Double(pixels[i * 4 + 2]) * scale).rounded())))
        }
    }

    // MARK: - Background detection (spec §7: transparent / uniform background detection)

    private static func computeForegroundMask(pixels: [UInt8], width: Int, height: Int) throws -> [Bool] {
        func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let i = (y * width + x) * 4
            return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]), Double(pixels[i + 3]))
        }

        let corners = [pixel(0, 0), pixel(width - 1, 0), pixel(0, height - 1), pixel(width - 1, height - 1)]
        let hasTransparency = corners.contains { $0.a < 250 } || (0..<(width * height)).contains { pixels[$0 * 4 + 3] < 10 }

        var mask = [Bool](repeating: false, count: width * height)

        if hasTransparency {
            for i in 0..<(width * height) {
                mask[i] = pixels[i * 4 + 3] > 127
            }
            // A "transparent" canvas can still contain a solid opaque
            // background fill alongside the actually-transparent margin
            // (e.g. a logo exported with a transparent border around an
            // opaque white card) -- left in, that whole fill region, plus
            // every anti-aliased edge pixel between it and the real
            // artwork, reads as "foreground": color quantization then
            // splits those into a swarm of spurious near-background
            // shades, each becoming its own tiny traced object (found via
            // a real customer logo that came back as ~300 stray gray
            // slivers around otherwise-correct navy letters).
            excludeDominantOpaqueBackground(&mask, pixels: pixels, width: width, height: height)
            return mask
        }

        let cornersAgree = corners.allSatisfy { c in
            let ref = corners[0]
            return abs(c.r - ref.r) + abs(c.g - ref.g) + abs(c.b - ref.b) < 30
        }

        if cornersAgree {
            let bg = corners[0]
            for y in 0..<height {
                for x in 0..<width {
                    let p = pixel(x, y)
                    let dist = abs(p.r - bg.r) + abs(p.g - bg.g) + abs(p.b - bg.b)
                    mask[y * width + x] = dist > colorDistanceThreshold
                }
            }
            return mask
        }

        // Fallback: Otsu threshold on luminance; assume the minority class is foreground.
        var histogram = [Int](repeating: 0, count: 256)
        var luminances = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
            let l = UInt8(max(0, min(255, 0.299 * r + 0.587 * g + 0.114 * b)))
            luminances[i] = l
            histogram[Int(l)] += 1
        }
        let threshold = otsuThreshold(histogram: histogram, totalPixels: width * height)
        var darkCount = 0
        for l in luminances where l < threshold { darkCount += 1 }
        let darkIsMinority = darkCount < (width * height) / 2
        for i in 0..<(width * height) {
            mask[i] = darkIsMinority ? (luminances[i] < threshold) : (luminances[i] >= threshold)
        }
        return mask
    }

    /// Finds the single most common exact RGB among currently-foreground
    /// (opaque) pixels; if it covers enough of the image to plausibly be a
    /// fill rather than a stroke, *and* spans a substantial share of at
    /// least one full canvas edge, excludes it -- and near matches, to
    /// also catch its anti-aliased edge against the real artwork -- from
    /// the mask.
    ///
    /// Substantial edge *coverage*, not just border *contact*, matters: a
    /// circular badge's background disc inscribed in a square canvas (a
    /// team logo, say) touches each edge too, at its tangent point, but
    /// only across a small fraction of that edge's length -- it's the
    /// main content, not a background fill, and excluding it would drop
    /// most of the design. A genuine background fill (an opaque card
    /// behind text, its own real-world source of this rule) spans most or
    /// all of at least one edge. Measured directly against both cases: a
    /// circular logo's background disc covered ~15% of any single edge,
    /// while a text logo's actual background card covered 41-46% of the
    /// edge it appeared on -- the 25% threshold below sits comfortably
    /// between the two with margin on both sides.
    ///
    /// A wider, connectivity-bounded flood fill was tried here to also
    /// catch a soft multi-pixel anti-aliasing ramp between background and
    /// artwork, but a wide enough tolerance to matter reliably leaked
    /// through the thin near-background gaps between adjacent letters,
    /// eating into real strokes and fragmenting them worse than before
    /// (measured directly against a real customer logo: object count went
    /// *up*, not down). The flat exact-ish match below is more
    /// conservative -- it won't fully absorb a very soft ramp -- but it's
    /// the version that actually reduced a real multi-hundred-object mess
    /// down to a small handful; `ColorQuantizer`'s cluster-merging picks up
    /// most of what this alone misses.
    private static func excludeDominantOpaqueBackground(_ mask: inout [Bool], pixels: [UInt8], width: Int, height: Int) {
        var counts: [RGBColor: Int] = [:]
        var total = 0
        for i in 0..<(width * height) where mask[i] {
            let color = RGBColor(r: pixels[i * 4], g: pixels[i * 4 + 1], b: pixels[i * 4 + 2])
            counts[color, default: 0] += 1
            total += 1
        }
        guard total > 0, let (bg, bgCount) = counts.max(by: { $0.value < $1.value }) else { return }
        guard Double(bgCount) / Double(total) > 0.15 else { return }

        func matchesBackground(_ i: Int) -> Bool {
            let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
            return abs(r - Double(bg.r)) + abs(g - Double(bg.g)) + abs(b - Double(bg.b)) <= colorDistanceThreshold
        }

        var topCount = 0, bottomCount = 0, leftCount = 0, rightCount = 0
        for x in 0..<width {
            let top = x, bottom = (height - 1) * width + x
            if mask[top] && matchesBackground(top) { topCount += 1 }
            if mask[bottom] && matchesBackground(bottom) { bottomCount += 1 }
        }
        for y in 0..<height {
            let left = y * width, right = y * width + (width - 1)
            if mask[left] && matchesBackground(left) { leftCount += 1 }
            if mask[right] && matchesBackground(right) { rightCount += 1 }
        }
        let edgeCoverageThreshold = 0.25
        let coversSubstantialEdge = Double(topCount) / Double(width) > edgeCoverageThreshold
            || Double(bottomCount) / Double(width) > edgeCoverageThreshold
            || Double(leftCount) / Double(height) > edgeCoverageThreshold
            || Double(rightCount) / Double(height) > edgeCoverageThreshold
        guard coversSubstantialEdge else { return }

        for i in 0..<(width * height) where mask[i] && matchesBackground(i) {
            mask[i] = false
        }
    }

    private static func otsuThreshold(histogram: [Int], totalPixels: Int) -> UInt8 {
        var sum = 0.0
        for t in 0..<256 { sum += Double(t) * Double(histogram[t]) }
        var sumB = 0.0, weightB = 0.0, maxVariance = 0.0, threshold = 0
        for t in 0..<256 {
            weightB += Double(histogram[t])
            if weightB == 0 { continue }
            let weightF = Double(totalPixels) - weightB
            if weightF == 0 { break }
            sumB += Double(t) * Double(histogram[t])
            let meanB = sumB / weightB
            let meanF = (sum - sumB) / weightF
            let variance = weightB * weightF * (meanB - meanF) * (meanB - meanF)
            if variance > maxVariance { maxVariance = variance; threshold = t }
        }
        return UInt8(threshold)
    }
}
