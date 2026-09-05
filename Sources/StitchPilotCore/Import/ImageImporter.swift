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
    /// One shape per detected foreground region, in pixel coordinates
    /// (origin top-left, Y down — same convention as SVG import).
    public var shapes: [VectorShape]
    public var pixelWidth: Int
    public var pixelHeight: Int
}

/// Imports raster artwork (PNG/JPEG/TIFF/BMP/WEBP/GIF) by finding
/// foreground regions and vectorizing their boundaries — connected-component
/// labeling + Moore-neighbor contour tracing + polyline simplification —
/// rather than treating every pixel as a stitch (spec §7: "construct clean
/// vector-like regions... do not merely trace every pixel").
///
/// This is a first, intentionally simple Phase 1 pass: single-region
/// silhouette extraction against an automatically detected background.
/// Multi-color segmentation, gradient/photograph detection, and text
/// detection (spec §7/§8) are Phase 2.
public enum ImageImporter {
    /// Pixels closer than this (0-255 per channel, summed) to the detected
    /// background color are treated as background.
    private static let colorDistanceThreshold: Double = 45
    /// Connected components smaller than this many pixels are dropped —
    /// "eliminate insignificant isolated pixels" (spec §7).
    private static let minComponentAreaPixels = 8
    /// Douglas-Peucker epsilon, in source pixels.
    private static let simplifyEpsilonPixels: Double = 1.5

    public static func importShapes(from data: Data) throws -> ImageImportResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageImportError.cannotDecode
        }

        let width = cgImage.width, height = cgImage.height
        guard width > 1, height > 1 else { throw ImageImportError.cannotDecode }

        let pixels = try renderRGBA(cgImage, width: width, height: height)
        let mask = try computeForegroundMask(pixels: pixels, width: width, height: height)

        let components = connectedComponents(mask: mask, width: width, height: height)
        guard !components.isEmpty else { throw ImageImportError.noForegroundFound }

        var shapes: [VectorShape] = []
        for component in components {
            guard let boundary = traceBoundary(mask: mask, width: width, height: height, start: component.topLeftMost) else { continue }
            let simplified = PolylineSimplify.douglasPeucker(boundary, epsilon: simplifyEpsilonPixels)
            guard simplified.count > 2 else { continue }
            shapes.append(VectorShape(subPaths: [SubPath(points: simplified, closed: true)]))
        }
        guard !shapes.isEmpty else { throw ImageImportError.noForegroundFound }
        return ImageImportResult(shapes: shapes, pixelWidth: width, pixelHeight: height)
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

    // MARK: - Connected components (8-connectivity, BFS)

    private struct Component { var topLeftMost: (x: Int, y: Int); var area: Int }

    private static func connectedComponents(mask: [Bool], width: Int, height: Int) -> [Component] {
        var visited = [Bool](repeating: false, count: width * height)
        var components: [Component] = []
        let neighborOffsets = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                guard mask[idx], !visited[idx] else { continue }

                var queue = [(x, y)]
                visited[idx] = true
                var area = 0
                var topLeftMost = (x: x, y: y)

                var head = 0
                while head < queue.count {
                    let (cx, cy) = queue[head]; head += 1
                    area += 1
                    if cy < topLeftMost.y || (cy == topLeftMost.y && cx < topLeftMost.x) {
                        topLeftMost = (cx, cy)
                    }
                    for (dx, dy) in neighborOffsets {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let nIdx = ny * width + nx
                        if mask[nIdx], !visited[nIdx] {
                            visited[nIdx] = true
                            queue.append((nx, ny))
                        }
                    }
                }

                if area >= minComponentAreaPixels {
                    components.append(Component(topLeftMost: topLeftMost, area: area))
                }
            }
        }
        return components
    }

    // MARK: - Moore-neighbor boundary tracing

    /// Compass directions in cyclic order (each adjacent to the next); the
    /// specific starting point / rotation sense doesn't matter as long as
    /// it's a consistent cyclic order — see DIGITIZING_ENGINE.md.
    private static let compass: [(Int, Int)] = [(-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1)]

    private static func traceBoundary(mask: [Bool], width: Int, height: Int, start: (x: Int, y: Int)) -> [Point2D]? {
        func isForeground(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return mask[y * width + x]
        }

        let first = start
        // `first` is the topmost-then-leftmost pixel of its component, so
        // its West neighbor is guaranteed background.
        var backtrack = (x: first.x - 1, y: first.y)
        var current = first
        var boundary: [Point2D] = [Point2D(Double(current.x), Double(current.y))]

        // Single isolated pixel (no foreground neighbors at all) — too small
        // to form a boundary; the caller's minComponentAreaPixels filter
        // already excludes most of these upstream.
        if compass.allSatisfy({ !isForeground(current.x + $0.0, current.y + $0.1) }) {
            return nil
        }

        let maxSteps = width * height * 2 + 64
        var steps = 0
        repeat {
            guard let bIdx = compass.firstIndex(where: { $0.0 == backtrack.x - current.x && $0.1 == backtrack.y - current.y }) else { break }
            var found: (Int, Int)?
            var idx = (bIdx + 1) % 8
            for _ in 0..<8 {
                let nx = current.x + compass[idx].0, ny = current.y + compass[idx].1
                if isForeground(nx, ny) { found = (nx, ny); break }
                idx = (idx + 1) % 8
            }
            guard let next = found else { break }
            backtrack = current
            current = next
            boundary.append(Point2D(Double(current.x), Double(current.y)))
            steps += 1
        } while !(current == first && backtrack == (x: first.x - 1, y: first.y)) && steps < maxSteps

        return boundary.count > 2 ? boundary : nil
    }
}

private func == (a: (x: Int, y: Int), b: (x: Int, y: Int)) -> Bool { a.x == b.x && a.y == b.y }
