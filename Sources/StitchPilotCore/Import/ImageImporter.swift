import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

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
    /// The colour the importer took for the page or card behind the
    /// artwork, when it found one -- what the preview should draw the
    /// fabric as, so a white design for a navy shirt is not white on
    /// white. Nil for transparent canvases and for images with no
    /// dominant ground.
    public var backgroundColor: RGBColor? = nil
    /// How the image's colours behaved under quantisation -- what tells a
    /// flat logo from a photograph or a soft scan (`CandidateAssessment`).
    public var colorStatistics: ImageColorStatistics = ImageColorStatistics()
}

public struct ImageColorStatistics: Codable, Sendable, Equatable {
    /// Pixels the importer took as artwork (not page or card).
    public var foregroundPixels: Int = 0
    /// Distinct RGB values among them, as a share of the pixels: a flat
    /// logo repeats a few values; a photograph rarely repeats one.
    public var distinctColorFraction: Double = 0
    /// Mean Delta-E from each pixel to the colour it was assigned: near
    /// zero for flat colour, large where the image is gradients.
    public var meanColorDistance: Double = 0
    /// Share of pixels sitting between two colours (anti-aliasing is a
    /// thin fringe; a blurred or low-resolution image is mostly fringe).
    public var ambiguousFraction: Double = 0
    public init() {}
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

    /// See the ramp handling in `importShapes(rgba:)`: a ramp cluster
    /// whose distance to the nearest real colour is under this fraction of
    /// its distance to the background is a shade of that colour, and its
    /// pixels join it rather than being voted on.
    private static let shadeOfRealRatio = 0.35
    /// Connected components smaller than this many pixels are dropped —
    /// "eliminate insignificant isolated pixels" (spec §7).
    private static let minComponentAreaPixels = 8
    /// Douglas-Peucker epsilon, in source pixels.
    private static let simplifyEpsilonPixels: Double = 1.5
    /// A pixel whose nearest cluster is not at least this much closer
    /// (Delta-E) than its second-nearest counts as "ambiguous" for
    /// `smoothAmbiguousBoundaryLabels` -- see that function's own doc
    /// comment. 0.6 means the runner-up must be within 67% of the winner's
    /// distance; a genuinely flat-color region's pixels are essentially
    /// exact matches to their own cluster (ratio near 0), while a true
    /// anti-aliasing blend pixel sits close to equidistant between the two
    /// colors it's between (ratio approaching 1).
    private static let ambiguousLabelRatio = 0.6

    #if canImport(ImageIO)
    public static func importShapes(from data: Data, maxColors: Int = ColorQuantizationPreset.normalEmbroidery.defaultMaxColors) throws -> ImageImportResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageImportError.cannotDecode
        }

        let width = cgImage.width, height = cgImage.height
        guard width > 1, height > 1 else { throw ImageImportError.cannotDecode }

        var pixels = try renderRGBA(cgImage, width: width, height: height)
        unpremultiply(&pixels, width: width, height: height)
        return try importShapes(rgba: pixels, width: width, height: height, maxColors: maxColors)
    }
    #endif

    /// The platform-neutral half of `importShapes(from:)`: everything after
    /// decoding. `rgba` is straight (not premultiplied) 8-bit RGBA, row-major,
    /// row 0 at the top. On Apple platforms `importShapes(from:)` decodes an
    /// encoded file with ImageIO and lands here; the Linux server (see
    /// server/) has no image decoder and instead receives pixels the browser
    /// already decoded and downscaled, so this is its only way in. Either
    /// way, every result downstream of this line is computed identically.
    public static func importShapes(rgba pixels: [UInt8], width: Int, height: Int, maxColors: Int = ColorQuantizationPreset.normalEmbroidery.defaultMaxColors) throws -> ImageImportResult {
        guard width > 1, height > 1, pixels.count == width * height * 4 else { throw ImageImportError.cannotDecode }
        let (foregroundMask, backgroundColor) = try computeForegroundMask(pixels: pixels, width: width, height: height)

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
        // Tracks the *second*-nearest distance alongside the winner --
        // `smoothAmbiguousBoundaryLabels` below needs it to tell "this pixel
        // confidently belongs to its cluster" from "this pixel is roughly
        // equidistant between two clusters," which a single nearest-index
        // lookup can't distinguish.
        var nearestClusterCache: [RGBColor: (index: Int, bestDist: Double, secondDist: Double)] = [:]
        func nearestClusters(_ color: RGBColor) -> (index: Int, bestDist: Double, secondDist: Double) {
            if let cached = nearestClusterCache[color] { return cached }
            var bestIndex = 0, bestDist = Double.infinity, secondDist = Double.infinity
            for (i, cluster) in clusters.enumerated() {
                let d = RGBColor.deltaE(color, cluster.rgb)
                if d < bestDist {
                    secondDist = bestDist
                    bestDist = d
                    bestIndex = i
                } else if d < secondDist {
                    secondDist = d
                }
            }
            let result = (bestIndex, bestDist, secondDist)
            nearestClusterCache[color] = result
            return result
        }

        var labels = [Int](repeating: -1, count: width * height)
        var isAmbiguous = [Bool](repeating: false, count: width * height)
        var statistics = ImageColorStatistics()
        var distanceSum = 0.0, ambiguousCount = 0
        for i in 0..<(width * height) where foregroundMask[i] {
            let color = RGBColor(r: pixels[i * 4], g: pixels[i * 4 + 1], b: pixels[i * 4 + 2])
            let (index, bestDist, secondDist) = nearestClusters(color)
            labels[i] = index
            distanceSum += bestDist
            // The same ambiguity test, but also considering the background
            // reference color (when one exists) as a candidate "second
            // nearest" -- a pixel on the anti-aliasing ramp between a
            // design color and the page background is exactly as ambiguous
            // as one between two design colors, and needs the same
            // treatment (see `smoothAmbiguousBoundaryLabels`'s doc comment).
            // Confirmed against two real logos on flat backgrounds (Amerus,
            // LIBBi) whose ramp pixels formed their own spurious "Light
            // Gray"/"Silver" clusters, fringing every letter.
            let distToBackground = backgroundColor.map { RGBColor.deltaE(color, $0) } ?? .infinity
            let effectiveSecondDist = min(secondDist, distToBackground)
            isAmbiguous[i] = effectiveSecondDist.isFinite && effectiveSecondDist > 0 && bestDist / effectiveSecondDist > ambiguousLabelRatio
            if isAmbiguous[i] { ambiguousCount += 1 }
        }
        statistics.foregroundPixels = foregroundColors.count
        statistics.distinctColorFraction = Double(nearestClusterCache.count) / Double(max(1, foregroundColors.count))
        statistics.meanColorDistance = distanceSum / Double(max(1, foregroundColors.count))
        statistics.ambiguousFraction = Double(ambiguousCount) / Double(max(1, foregroundColors.count))
        // A pixel confidently matching its own cluster is still ambiguous
        // if that whole *cluster* is itself a suspected background ramp
        // (`backgroundRampClusterIndices`) -- k-means can center a cluster
        // exactly on a ramp's own colors when there are enough ramp pixels
        // to seed one, which makes every member pixel a tight, "confident"
        // match to it despite the cluster itself being spurious. Confirmed
        // necessary against real files: without this, the ratio test alone
        // missed ramp pixels precisely because they fit their own tailored
        // cluster too well. Ramp detection runs after the first labelling
        // pass because one of its tests is spatial (see the function).
        let backgroundRampIndices = backgroundRampClusterIndices(clusters, backgroundColor: backgroundColor,
                                                                 labels: labels, foregroundMask: foregroundMask, width: width, height: height)
        if ProcessInfo.processInfo.environment["DEBUG_IMPORT"] != nil {
            print("  import: background \(backgroundColor.map { "(\($0.r),\($0.g),\($0.b))" } ?? "none"), \(clusters.count) clusters")
            for (i, c) in clusters.enumerated() {
                print("    cluster \(i): (\(c.rgb.r),\(c.rgb.g),\(c.rgb.b)) \(c.pixelCount) px\(backgroundRampIndices.contains(i) ? " -- background ramp" : "")")
            }
        }
        if !backgroundRampIndices.isEmpty {
            // A ramp pixel that is decisively nearer the background than any
            // real design colour IS background, whatever its neighbours
            // say. The neighbour vote below is right for a fringe one or
            // two pixels wide, but a small negative space that consists
            // entirely of blend pixels (the turtle case above: 2-4 px holes
            // in a 110-px image) has only design-coloured confident
            // neighbours, so the vote alone fills every hole solid. Colour
            // decides those; the vote still handles the genuinely
            // in-between pixels along the edges.
            let realClusters = clusters.indices.filter { !backgroundRampIndices.contains($0) }
            // A ramp cluster that is itself a shade of a real colour -- much
            // nearer that colour than the background -- IS that colour:
            // its pixels join the nearest real cluster outright. Left
            // "ambiguous" and decided by their neighbours, the dark
            // blue-grey letters of a blurry tagline (whose only neighbours
            // are the white page) dissolved into the background, and the
            // ATS sample lost both its lines of text at import.
            var shadeOf: [Int: Int] = [:]
            if let backgroundColor {
                for c in backgroundRampIndices {
                    guard let nearest = realClusters.min(by: { RGBColor.deltaE(clusters[c].rgb, clusters[$0].rgb) < RGBColor.deltaE(clusters[c].rgb, clusters[$1].rgb) }) else { continue }
                    let toReal = RGBColor.deltaE(clusters[c].rgb, clusters[nearest].rgb)
                    let toBackground = RGBColor.deltaE(clusters[c].rgb, backgroundColor)
                    if toReal < shadeOfRealRatio * toBackground { shadeOf[c] = nearest }
                }
            }
            for i in 0..<(width * height) where labels[i] >= 0 && backgroundRampIndices.contains(labels[i]) {
                if let real = shadeOf[labels[i]] {
                    labels[i] = real
                    continue
                }
                isAmbiguous[i] = true
                guard let backgroundColor, !realClusters.isEmpty else { continue }
                let color = RGBColor(r: pixels[i * 4], g: pixels[i * 4 + 1], b: pixels[i * 4 + 2])
                let toBackground = RGBColor.deltaE(color, backgroundColor)
                let toNearestReal = realClusters.map { RGBColor.deltaE(color, clusters[$0].rgb) }.min() ?? .infinity
                if toBackground < decisiveBackgroundRatio * toNearestReal {
                    labels[i] = backgroundLabelSentinel
                    isAmbiguous[i] = false
                }
            }
        }
        labels = smoothAmbiguousBoundaryLabels(labels, isAmbiguous: isAmbiguous, foregroundMask: foregroundMask, width: width, height: height,
                                               tieBreak: { pixelIndex, candidates in
            // See the tie-handling comment inside `smoothAmbiguousBoundaryLabels`.
            let color = RGBColor(r: pixels[pixelIndex * 4], g: pixels[pixelIndex * 4 + 1], b: pixels[pixelIndex * 4 + 2])
            func distance(to label: Int) -> Double {
                if label == backgroundLabelSentinel {
                    return backgroundColor.map { RGBColor.deltaE(color, $0) } ?? .infinity
                }
                return RGBColor.deltaE(color, clusters[label].rgb)
            }
            return candidates.min { distance(to: $0) < distance(to: $1) }
        })

        var shapes: [VectorShape] = []
        var fillColors: [RGBColor?] = []
        for (clusterIndex, cluster) in clusters.enumerated() {
            var clusterMask = [Bool](repeating: false, count: width * height)
            for i in 0..<(width * height) { clusterMask[i] = labels[i] == clusterIndex }

            // Outer boundaries first, recording each shape's own pixel-space
            // boundary alongside it so holes (below) can be matched back to
            // the specific outer shape that encloses them.
            var outerBoundaries: [(shapeIndex: Int, points: [Point2D])] = []
            let components = RasterTracing.connectedComponents(mask: clusterMask, width: width, height: height, minAreaPixels: minComponentAreaPixels)
            for component in components {
                guard let boundary = RasterTracing.traceBoundary(mask: clusterMask, width: width, height: height, start: component.topLeftMost) else { continue }
                let simplified = PolylineSimplify.douglasPeucker(boundary, epsilon: simplifyEpsilonPixels)
                guard simplified.count > 2 else { continue }
                outerBoundaries.append((shapes.count, simplified))
                shapes.append(VectorShape(subPaths: [SubPath(points: regularizeIfCircular(simplified), closed: true)]))
                fillColors.append(cluster.rgb)
            }

            // Holes: a letterform counter (the enclosed hole inside O, P, R,
            // A, D, B, Q...) or any enclosed ring shape reads, at the pixel
            // level, as a same-colored *foreground* ring around a
            // differently-colored *enclosed* background region -- found and
            // traced the same way an outer shape is, then attached as an
            // additional subpath (even-odd, matching every other multi-
            // subpath shape in this engine) to whichever outer boundary
            // actually contains it. Left unhandled, raster import silently
            // filled every such hole in solid, exactly the "small lettering
            // reads as the wrong letter" failure mode already fixed for SVG
            // import (see CHANGELOG.md) -- this is that same fix for the
            // raster path, which never had it.
            for holePoints in findHoleBoundaries(clusterMask: clusterMask, width: width, height: height) {
                guard let holePoint = holePoints.first else { continue }
                for (shapeIndex, outerPoints) in outerBoundaries where PolygonGeometry.pointInPolygon(holePoint, polygon: outerPoints) {
                    shapes[shapeIndex].subPaths.append(SubPath(points: regularizeIfCircular(holePoints), closed: true))
                    break
                }
            }
        }
        // Order matters: merging a small same-color island into its main
        // shape first grows that shape's own bounding box well past the
        // island's own tiny one -- so when hole-removal runs next, a
        // *different*-colored shape's genuine hole (a letter's own
        // counter) no longer spuriously "nearly matches" the now-much-
        // larger merged shape's box, and stays correctly preserved as a
        // real hole. Reversing this order would risk stripping exactly
        // the hole this pass exists to protect.
        if ProcessInfo.processInfo.environment["DEBUG_IMPORT"] != nil {
            for (i, shape) in shapes.enumerated() {
                let box = shape.boundingBox
                print("    traced \(i): \(fillColors[i].map { "(\($0.r),\($0.g),\($0.b))" } ?? "?") \(shape.subPaths.count) subPaths, \(Int(box.width.rounded()))x\(Int(box.height.rounded())) px")
            }
        }
        mergeColorIslandsIntoLargestSameColorShape(&shapes, fillColors: &fillColors)
        removeHolesCoveredByAnotherShape(&shapes, fillColors: fillColors)
        if ProcessInfo.processInfo.environment["DEBUG_IMPORT"] != nil {
            for (i, shape) in shapes.enumerated() {
                let box = shape.boundingBox
                print("    merged \(i): \(fillColors[i].map { "(\($0.r),\($0.g),\($0.b))" } ?? "?") \(shape.subPaths.count) subPaths, \(Int(box.width.rounded()))x\(Int(box.height.rounded())) px")
            }
        }

        guard !shapes.isEmpty else { throw ImageImportError.noForegroundFound }
        var result = ImageImportResult(shapes: shapes, fillColors: fillColors, pixelWidth: width, pixelHeight: height, backgroundColor: backgroundColor)
        result.colorStatistics = statistics
        return result
    }

    /// Companion to `ColorQuantizer.mergeAntiAliasingClusters`, which folds
    /// a blend cluster into whichever of *two foreground* clusters it sits
    /// between -- but has no notion of the background color as a valid
    /// endpoint, since background pixels are already excluded before
    /// `ColorQuantizer` ever sees the pixel list. A cluster that's really
    /// the anti-aliasing ramp between a design color and a flat background
    /// (routine for a logo exported or screenshotted on white) survives
    /// untouched as its own real-looking cluster otherwise -- confirmed
    /// against two real logos (Amerus, LIBBi) whose ramp pixels formed
    /// their own "Light Gray"/"Silver" clusters, fringing every letter.
    /// Uses the identical "sits almost exactly on the line between two
    /// reference colors" geometric test `mergeAntiAliasingClusters` already
    /// uses for two foreground clusters, just with the background color as
    /// one of the two references and the candidate required to be smaller
    /// than the other (real) cluster it's being tested against.
    ///
    /// Deliberately doesn't merge or drop these clusters outright the way
    /// `mergeAntiAliasingClusters` does -- a ramp cluster's member pixels
    /// span a real range from near-background to near-the-true-color, so a
    /// single per-cluster verdict can't be right for all of them at once.
    /// Flagging the cluster here just marks its pixels as inherently
    /// untrustworthy so `importShapes` treats every one of them as
    /// ambiguous regardless of how tightly they fit this cluster's own
    /// centroid (see the ambiguity computation there), leaving the actual
    /// per-pixel decision -- background or a specific neighboring color --
    /// to `smoothAmbiguousBoundaryLabels`'s neighbor vote.
    ///
    /// Also flags a cluster sitting on the line between two *foreground*
    /// clusters that are each larger than it. `mergeAntiAliasingClusters`
    /// only folds such a blend when BOTH endpoints are "large" (>= 8% of
    /// all pixels), so a blend between a dominant color and a minor one
    /// slips through it -- found directly against the 96px Red Sox "B"
    /// (transparent background, so no background reference at all):
    /// the 1px column where its navy disc meets each white counter is
    /// exactly the navy/white midpoint, the white was under 8%, and the
    /// column survived as its own tight, "confident" gray-blue cluster
    /// that the per-pixel ambiguity test never questioned -- traced as
    /// zero-width gray running-stitch lines, mistaken at first for
    /// baseball-seam detail. Same per-pixel neighbor-vote treatment as
    /// the background case, for the same reason.
    ///
    /// The "smaller than the real cluster" guard is what stops a genuine
    /// mid-tone design colour from being mistaken for a blend, but it
    /// assumes a ramp is a thin fringe. A small or blurry source breaks
    /// that: in a 110-px phone screenshot of a tribal turtle (one of the
    /// professionally digitized reference designs), the 2-4 px negative
    /// spaces inside the dark shell were *entirely* blend pixels -- no
    /// clean background pixel survived inside them -- and those greys
    /// outnumbered the dark colour itself, so the guard let a huge
    /// "Silver" cluster through and every hole in the shell was stitched
    /// solid in white thread. So a cluster on the background/foreground
    /// line is also flagged, whatever its size, when it is *spatially* a
    /// fringe: nearly every one of its pixels sits within 2 px of a pixel
    /// of some other label (or of the background), and its colour is
    /// nearer the background than the foreground end. A real light-grey
    /// design element passes because its interior pixels are more than
    /// 2 px from anything else; a legitimate thin light-grey line on a
    /// tiny image would not, which is the trade-off accepted here.
    private static func backgroundRampClusterIndices(_ clusters: [ColorCluster], backgroundColor: RGBColor?,
                                                     labels: [Int], foregroundMask: [Bool], width: Int, height: Int) -> Set<Int> {
        guard clusters.count > 1 else { return [] }
        var suspects = Set<Int>()
        func liesBetween(_ lab: LABColor, _ endA: LABColor, _ endB: LABColor) -> Bool {
            let dAB = sqrt(labDistanceSquared(endA, endB))
            guard dAB > 1 else { return false }
            let dA = sqrt(labDistanceSquared(lab, endA)), dB = sqrt(labDistanceSquared(lab, endB))
            return ((dA + dB) - dAB) / dAB <= 0.15
        }
        func nearerToBackgroundThan(_ lab: LABColor, _ foregroundLab: LABColor, backgroundLab: LABColor) -> Bool {
            labDistanceSquared(lab, backgroundLab) < labDistanceSquared(lab, foregroundLab)
        }
        // Fractions of cluster `c`'s pixels within a Chebyshev distance of
        // 2 of (a) any pixel carrying a different label, background
        // included, and (b) a pixel of cluster `endpoint` specifically.
        func fringeFractions(_ c: Int, endpoint: Int) -> (any: Double, endpoint: Double) {
            var total = 0, fringe = 0, nearEndpoint = 0
            for y in 0..<height {
                for x in 0..<width where labels[y * width + x] == c {
                    total += 1
                    var touchesOther = false, touchesEndpoint = false
                    for dy in -2...2 {
                        let ny = y + dy
                        guard ny >= 0, ny < height else { touchesOther = true; continue }
                        for dx in -2...2 {
                            let nx = x + dx
                            guard nx >= 0, nx < width else { touchesOther = true; continue }
                            let j = ny * width + nx
                            if !foregroundMask[j] || labels[j] != c { touchesOther = true }
                            if foregroundMask[j], labels[j] == endpoint { touchesEndpoint = true }
                        }
                    }
                    if touchesOther { fringe += 1 }
                    if touchesEndpoint { nearEndpoint += 1 }
                }
            }
            guard total > 0 else { return (0, 0) }
            return (Double(fringe) / Double(total), Double(nearEndpoint) / Double(total))
        }
        for (c, candidate) in clusters.enumerated() {
            let lab = candidate.rgb.lab
            let larger = clusters.enumerated().filter { $0.offset != c && candidate.pixelCount < $0.element.pixelCount }
            if let backgroundColor, larger.contains(where: { liesBetween(lab, backgroundColor.lab, $0.element.rgb.lab) }) {
                suspects.insert(c)
                continue
            }
            if let backgroundColor {
                // A blend is also spatially *between* its two colours: most
                // of its pixels sit right next to the design colour it fades
                // from. Without that test a genuine thin pale line (a light
                // blue ribbon beside navy lettering on white -- the Oholi
                // mark) is indistinguishable from a fringe by colour and
                // thinness alone, and was dissolved into the background.
                let endpoints = clusters.enumerated().filter {
                    $0.offset != c && liesBetween(lab, backgroundColor.lab, $0.element.rgb.lab) && nearerToBackgroundThan(lab, $0.element.rgb.lab, backgroundLab: backgroundColor.lab)
                }
                let isSpatialFringe = endpoints.contains { endpoint in
                    let fractions = fringeFractions(c, endpoint: endpoint.offset)
                    return fractions.any >= spatialRampFringeFraction && fractions.endpoint >= spatialRampEndpointFraction
                }
                if isSpatialFringe {
                    suspects.insert(c)
                    continue
                }
            }
            for i in larger.indices {
                for j in larger.indices where j > i {
                    if liesBetween(lab, larger[i].element.rgb.lab, larger[j].element.rgb.lab) {
                        suspects.insert(c)
                        break
                    }
                }
                if suspects.contains(c) { break }
            }
        }
        return suspects
    }

    /// See `backgroundRampClusterIndices`: the share of a cluster's pixels
    /// that must be within 2 px of another label for it to count as a
    /// fringe on spatial grounds alone.
    private static let spatialRampFringeFraction = 0.75

    /// ...and the share that must sit within 2 px of the design colour the
    /// cluster supposedly blends from.
    private static let spatialRampEndpointFraction = 0.5

    /// A ramp-cluster pixel whose Delta-E to the background is under this
    /// fraction of its Delta-E to the nearest real design colour resolves
    /// straight to background (see the ramp handling in `importShapes`).
    private static let decisiveBackgroundRatio = 0.6

    private static func labDistanceSquared(_ a: LABColor, _ b: LABColor) -> Double {
        let dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b
        return dl * dl + da * da + db * db
    }

    /// `excludeDominantOpaqueBackground` and `ColorQuantizer.
    /// mergeAntiAliasingClusters` already solve anti-aliasing where a color
    /// meets the *background* -- but nothing handled the identical problem
    /// one level in, where two *foreground* colors meet directly with no
    /// background pixel between them (a rust stroke against its own cream
    /// fill, navy against red). Each blend pixel along that boundary gets
    /// assigned to whichever of the two true clusters it happens to be
    /// nearest, pixel by pixel -- and because the blend varies smoothly,
    /// that nearest-cluster choice can flip from one pixel to the next
    /// along the curve (8-bit rounding noise decides ties near the true
    /// midpoint), turning one smooth boundary into a jagged interleaving of
    /// the two labels. Every place the "wrong" label's pixels lose contact
    /// with their own color's main body traces as its own tiny separate
    /// object -- confirmed independently against three real customer
    /// files: the PiperStitch bird mark (scratch-like noise across the
    /// wing and chest), the Amerus logo (a swarm of "Light Gray"/"Dark
    /// Red" slivers ringing the tagline), and the LIBBi wordmark (a
    /// "Silver" fringe outlining every big letter). The same mechanism also
    /// catches the foreground/*background* version of this problem when a
    /// pixel's own cluster is flagged by `backgroundRampClusterIndices`
    /// above (see the ambiguity computation in `importShapes`).
    ///
    /// Fixed the same way a despeckle filter works, but gated on
    /// *ambiguity* rather than applied blindly: only a pixel whose nearest
    /// and second-nearest cluster are close to equidistant (`isAmbiguous`,
    /// computed from the same Delta-E lookup that decided its label) is
    /// eligible to be reassigned, and only toward a label held by a clear
    /// majority of its *confident* (non-ambiguous) neighbors. This is the
    /// fix a first attempt at this got wrong: a blanket "reassign toward
    /// whatever the neighborhood majority is" pass can't tell a genuine
    /// thin ring or outline (solid, confidently one color, just narrow)
    /// from an anti-aliasing ramp (also thin, but colorimetrically
    /// ambiguous) -- it erased real ring topology along with the noise
    /// (`ImageImportTests.colorIslandInsideARingsCounterMergesAndStaysSolid`
    /// caught this in review). Gating on ambiguity fixes that: a solid
    /// ring's pixels are confident matches to their own cluster (their
    /// nearest cluster is far closer than any runner-up) regardless of how
    /// thin the ring is, so they're never touched; only pixels that are
    /// *themselves* colorimetrically uncertain are ever reconsidered.
    ///
    /// Reads every neighbor from the original (pre-smoothing) label
    /// snapshot, never from pixels this same pass has already rewritten,
    /// so the result can't depend on iteration order (spec §54
    /// determinism) -- a single non-iterated pass, like the codebase's
    /// other despeckle-style cleanups.
    ///
    /// Sentinel used only within this pass's neighbor tally to mean "this
    /// neighbor is confidently background," alongside real (>= 0) cluster
    /// indices for confidently-foreground neighbors. A pixel reassigned to
    /// this sentinel gets `labels[i] = -1` in the result -- the same value
    /// every genuinely non-foreground pixel already carries, so the
    /// per-cluster masking loop right after this pass excludes it for free
    /// without needing to also touch `foregroundMask` itself.
    private static let backgroundLabelSentinel = -1

    /// A single pass only resolves ambiguous pixels touching an *already*
    /// confident neighbor within one hop -- adequate for a 1px ramp, but a
    /// real anti-aliasing ramp is routinely 2-3px wide (confirmed directly
    /// against the LIBBi file: a one-pass version left a genuine residue of
    /// "Silver" objects, the ramp pixels sitting in the ramp's own middle,
    /// more than one hop from either confident side). Resolved pixels count
    /// as confident for the *next* round (`resolved`, tracked separately
    /// from the original `isAmbiguous`, which never changes), so a wide
    /// ramp resolves from both edges inward over a few rounds -- still
    /// fully deterministic: each round reads a fixed snapshot and only
    /// writes to a fresh copy, so results never depend on scan order within
    /// a round, and the round count itself is a fixed bound, not
    /// "until convergence" with a data-dependent iteration count.
    private static let maxAmbiguousSmoothingRounds = 4

    private static func smoothAmbiguousBoundaryLabels(_ labels: [Int], isAmbiguous: [Bool], foregroundMask: [Bool], width: Int, height: Int,
                                                      tieBreak: (_ pixelIndex: Int, _ candidates: [Int]) -> Int?) -> [Int] {
        var current = labels
        var resolved = isAmbiguous.map { !$0 }

        for _ in 0..<maxAmbiguousSmoothingRounds {
            var next = current
            var nextResolved = resolved
            var anyChange = false

            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    guard foregroundMask[i], isAmbiguous[i], !resolved[i] else { continue }

                    var confidentNeighborCounts: [Int: Int] = [:]
                    for dy in -1...1 {
                        for dx in -1...1 {
                            guard dx != 0 || dy != 0 else { continue }
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                            let ni = ny * width + nx
                            // A background neighbor is trivially confident
                            // (it was never part of the ambiguous-foreground
                            // computation at all) -- counts toward "this
                            // ramp pixel is closer to background than to
                            // any real design color" exactly like a
                            // confident foreground neighbor counts toward a
                            // specific cluster. A neighbor *resolved* in an
                            // earlier round counts as confident here too,
                            // which is what lets resolution propagate
                            // inward through a multi-pixel ramp.
                            if !foregroundMask[ni] {
                                confidentNeighborCounts[backgroundLabelSentinel, default: 0] += 1
                            } else if resolved[ni] {
                                confidentNeighborCounts[current[ni], default: 0] += 1
                            }
                        }
                    }

                    // A *plurality* winner, not an absolute majority of all
                    // 8 neighbors: a ramp pixel on an ordinary straight
                    // edge naturally has its 8 neighbors split close to
                    // evenly between the two confident sides (background on
                    // one side, the design color on the other) -- requiring
                    // an outright majority (>=5 of 8) almost never fires for
                    // exactly this, the single most common case, and only
                    // resolved pixels near a corner where one side happened
                    // to dominate (confirmed directly: an earlier >=5
                    // version left LIBBi's entire straight-edge ring
                    // unresolved while still clearing tiny corner/speck
                    // clusters). A strict plurality (`bestCount >
                    // secondBestCount`) with a small evidence floor
                    // resolves the ordinary case while still leaving a
                    // genuine three-way junction (three confident sides,
                    // no single dominant neighbor) unresolved.
                    //
                    // An exact TWO-way tie is different, and common: a
                    // 1px ramp column along a perfectly straight vertical
                    // or horizontal edge has exactly 3 confident neighbors
                    // on each side and its own 2 (ambiguous) ramp neighbors
                    // above and below -- a dead 3-3 tie at every pixel down
                    // the whole column, so nothing ever resolves except the
                    // few pixels within `maxAmbiguousSmoothingRounds` hops
                    // of a curved end. The column then survives as its own
                    // tall, 1px-wide traced object. Found directly against
                    // a real cap-logo "B", whose counters' straight left
                    // edges each came back as a zero-width gray
                    // running-stitch line (and the same file's older
                    // 96px cut had shown the identical lines, mistaken for
                    // baseball-seam detail). A pixel in a 2-way tie is a
                    // genuine 50/50 blend of the two sides, so either side
                    // is visually right; what matters is that it joins one
                    // of them rather than becoming its own object -- the
                    // caller breaks the tie toward whichever side's own
                    // color the pixel is actually closer to.
                    let sortedCounts = confidentNeighborCounts.values.sorted(by: >)
                    guard let bestLabel = confidentNeighborCounts.max(by: { $0.value < $1.value })?.key else { continue }
                    let bestCount = sortedCounts[0]
                    let secondBestCount = sortedCounts.count > 1 ? sortedCounts[1] : 0
                    guard bestCount >= 2 else { continue }
                    let resolvedLabel: Int
                    if bestCount > secondBestCount {
                        resolvedLabel = bestLabel
                    } else {
                        let tied = confidentNeighborCounts.filter { $0.value == bestCount }.map { $0.key }
                        guard tied.count == 2, let chosen = tieBreak(i, tied) else { continue }
                        resolvedLabel = chosen
                    }
                    next[i] = resolvedLabel
                    nextResolved[i] = true
                    anyChange = true
                }
            }

            current = next
            resolved = nextResolved
            guard anyChange else { break }
        }
        return current
    }

    /// A hole traced above reads, at the pixel level, identically whether
    /// it's a genuine letterform counter (nothing else there -- the inside
    /// of an "O") or a differently-colored shape overlaid on top of a
    /// solid background (text sitting on a banner, a logo mark on a
    /// solid field). Those two cases need opposite treatment: a real
    /// counter must stay an actual gap in the stitching; an overlay should
    /// leave the *underlying* shape solid, exactly like professional
    /// digitizing practice -- sew the background solid, then sew the
    /// overlay on top of it in its own thread, never leave an actual hole
    /// in the fabric for text that's meant to simply be covered. Left
    /// unhandled, the underlying shape's hole is a real gap that only
    /// looks correct as long as the overlay covers it exactly -- edit,
    /// resize, or delete the overlay (including replacing raster-traced
    /// text with generated Lettering, a real workflow this engine now
    /// supports) and the hole is left showing through as bare fabric,
    /// found directly against a real banner-with-lettering design (see
    /// CHANGELOG.md).
    ///
    /// Distinguished the same way the two cases are geometrically
    /// different: a genuine counter has no other traced shape anywhere
    /// near its own extent; an overlay's hole is, by construction, almost
    /// exactly covered by the differently-colored shape traced from those
    /// same source pixels. `boxesNearlyMatch` catches that without needing
    /// exact polygon equality (simplification/regularization can shift a
    /// few points between the hole and the overlay's own outer boundary).
    ///
    /// Only a shape that is *mostly solid* gets this treatment. A thin
    /// outline network -- the dark keyline of a cartoon, where one colour
    /// draws every edge and encloses every other region -- also reads as
    /// "a shape whose holes are covered by other shapes", and stripping
    /// its holes turns a 1 mm line drawing into a solid silhouette sewn
    /// under the entire design: twice the stitches everywhere, a stiff
    /// double layer, the outline's own character lost, and the base fill's
    /// rows showing through every seam between the colours on top. Found
    /// against a professionally digitized golfing alligator, where the
    /// pro kept that keyline as a satin outline sewn last. The two cases
    /// differ in how much of their outer area the shape itself covers:
    /// a banner with text on it is well over half solid; a line drawing's
    /// strokes are a small fraction of what they enclose
    /// (`minimumSolidFractionForHoleRemoval`).
    private static func removeHolesCoveredByAnotherShape(_ shapes: inout [VectorShape], fillColors: [RGBColor?]) {
        for i in shapes.indices {
            guard shapes[i].subPaths.count > 1 else { continue }
            let outer = shapes[i].subPaths[0]
            let outerArea = abs(PolygonGeometry.signedArea(outer.points))
            let holeArea = shapes[i].subPaths.dropFirst().reduce(0.0) { $0 + abs(PolygonGeometry.signedArea($1.points)) }
            guard outerArea > 0, (outerArea - holeArea) / outerArea >= minimumSolidFractionForHoleRemoval else { continue }

            var strippedHoleBoxes: [BoundingBox] = []
            var keptSubPaths: [SubPath] = []
            for subPath in shapes[i].subPaths.dropFirst() {
                let box = subPath.boundingBox
                let isCoveredByAnotherShape = shapes.indices.contains { j in
                    guard j != i, fillColors[j] != fillColors[i] else { return false }
                    return boxesNearlyMatch(box, shapes[j].boundingBox)
                }
                if isCoveredByAnotherShape {
                    strippedHoleBoxes.append(box)
                } else {
                    keptSubPaths.append(subPath)
                }
            }
            // A kept subpath can only be one of this shape's own genuine
            // holes, or a same-color island `mergeColorIslandsIntoLargestSameColorShape`
            // merged in earlier -- an island is never itself a hole. If a
            // hole just above got stripped (this shape is now solid
            // across that whole area, via its own outer boundary), any
            // island that falls entirely inside that same now-solid area
            // is redundant: leaving it in would add a second boundary
            // crossing there, flipping already-solid fill back into an
            // unwanted hole under the even-odd rule. Removing it is safe
            // either way -- the area was already going to render solid.
            keptSubPaths.removeAll { subPath in
                let box = subPath.boundingBox
                return strippedHoleBoxes.contains { $0.contains(box) }
            }
            shapes[i].subPaths = [outer] + keptSubPaths
        }
    }

    /// See `removeHolesCoveredByAnotherShape`: a shape whose own area is
    /// under this share of its outer boundary's area is a line drawing, not
    /// a solid field, and keeps its holes.
    private static let minimumSolidFractionForHoleRemoval = 0.35

    /// True when each box covers most of their mutual overlap -- "these
    /// are essentially the same region," not just "these two shapes
    /// happen to overlap somewhat." Both directions matter: checking only
    /// one would let a hole that's merely a small corner of a much larger,
    /// unrelated shape count as "covered."
    private static func boxesNearlyMatch(_ a: BoundingBox, _ b: BoundingBox) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let ix = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let iy = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let intersection = ix * iy
        let aArea = a.width * a.height, bArea = b.width * b.height
        guard aArea > 0, bArea > 0 else { return false }
        return intersection / aArea > 0.7 && intersection / bArea > 0.7
    }

    /// A same-colored region that's small and disconnected from its own
    /// color's largest traced shape, but sits well inside that shape's
    /// overall extent, is the *same background layer* -- not a separate
    /// design element -- it only reads as disconnected because something
    /// a different color (a letter's own counter, a logo mark) sits
    /// directly on top of and around it in the source image, splitting
    /// the connected-component pass into pieces. Found directly against a
    /// real circular badge: a letter's own two counters, each still the
    /// badge's background color showing through underneath, imported as
    /// two extra tiny separate objects instead of being part of the one
    /// background layer -- visible as a stitching-direction seam where
    /// the small piece meets the rest (each object gets its own
    /// independently-chosen fill angle), and as clutter in the object
    /// list. Merging them into one shape gives the fill generator one
    /// continuous region to work from, producing consistent stitching
    /// instead of a visibly separate patch (see CHANGELOG.md).
    ///
    /// Conservative on purpose: only merges a fragment genuinely smaller
    /// than (not just any overlap with) its parent, and only when its
    /// entire extent sits inside that parent's own bounding box -- two
    /// separate, comparably-sized shapes that happen to share a color (a
    /// legitimate multi-part design) are left untouched.
    ///
    /// Merges into each fragment's own *nearest* qualifying same-color
    /// shape (the smallest one that still contains it), not into whichever
    /// same-color shape happens to be globally largest -- an earlier
    /// version only ever considered the single biggest shape per color,
    /// which misses a color that legitimately forms two or more separate
    /// background "islands" in different parts of the image (found
    /// directly against the PiperStitch bird mark: the cream body and the
    /// cream neck are each their own large, real region, broken apart by
    /// the rust head-stripe and navy beak running between them -- neither
    /// one's bounding box contains the other, so the old single-largest-
    /// target version merged neither, leaving both to contribute their own
    /// stray same-color fragments). A fragment whose own qualifying parent
    /// is itself later found to be someone else's fragment (an overlay
    /// sitting on an overlay) gets its own redirect resolved transitively,
    /// so a fragment always ends up merged into its color's true top-level
    /// shape regardless of how many layers deep that goes.
    private static func mergeColorIslandsIntoLargestSameColorShape(_ shapes: inout [VectorShape], fillColors: inout [RGBColor?]) {
        var indicesByColor: [RGBColor: [Int]] = [:]
        for (i, color) in fillColors.enumerated() {
            guard let color else { continue }
            indicesByColor[color, default: []].append(i)
        }

        func boxArea(_ box: BoundingBox) -> Double { box.width * box.height }

        var redirectTo: [Int: Int] = [:]
        for indices in indicesByColor.values where indices.count > 1 {
            let boxes = Dictionary(uniqueKeysWithValues: indices.map { ($0, shapes[$0].boundingBox) })
            let areas = boxes.mapValues(boxArea)
            // Smallest first: a fragment always looks for its parent among
            // the *original* shapes, so processing order doesn't change
            // what qualifies -- it only affects nothing here except making
            // the loop's own intent (smallest things are the fragments)
            // explicit.
            for i in indices.sorted(by: { (areas[$0] ?? 0, $0) < (areas[$1] ?? 0, $1) }) {
                guard let box = boxes[i], let area = areas[i] else { continue }
                var bestParent: Int?
                var bestParentArea = Double.infinity
                for j in indices where j != i {
                    guard let parentBox = boxes[j], let parentArea = areas[j],
                          area < parentArea * 0.5, parentBox.contains(box) else { continue }
                    if parentArea < bestParentArea { bestParentArea = parentArea; bestParent = j }
                }
                if let bestParent { redirectTo[i] = bestParent }
            }
        }
        guard !redirectTo.isEmpty else { return }

        func root(of i: Int) -> Int {
            var current = i
            var seen = Set<Int>()
            while let next = redirectTo[current], seen.insert(current).inserted {
                current = next
            }
            return current
        }

        var indicesToRemove = Set<Int>()
        // Sorted, not raw dictionary iteration order -- Dictionary's own
        // order isn't guaranteed, and the exact order fragments' subpaths
        // get appended to a shared target would otherwise be nondeterministic
        // (spec §54: stitch generation must stay deterministic given the
        // same input).
        for fragment in redirectTo.keys.sorted() {
            let target = root(of: fragment)
            guard target != fragment else { continue }
            shapes[target].subPaths.append(contentsOf: shapes[fragment].subPaths)
            indicesToRemove.insert(fragment)
        }
        guard !indicesToRemove.isEmpty else { return }

        var newShapes: [VectorShape] = []
        var newColors: [RGBColor?] = []
        for i in shapes.indices where !indicesToRemove.contains(i) {
            newShapes.append(shapes[i])
            newColors.append(fillColors[i])
        }
        shapes = newShapes
        fillColors = newColors
    }

    /// Finds background-colored regions fully enclosed within
    /// `clusterMask`'s foreground and traces each one's boundary --
    /// `RasterTracing.findEnclosedRegionBoundaries` (shared with
    /// `ShapeMerger`, which needs the identical hole-finding logic to
    /// avoid silently losing a shape's own holes when re-tracing) does
    /// the actual work; this just applies this importer's own
    /// simplification afterward.
    private static func findHoleBoundaries(clusterMask: [Bool], width: Int, height: Int) -> [[Point2D]] {
        let rawBoundaries = RasterTracing.findEnclosedRegionBoundaries(foregroundMask: clusterMask, width: width, height: height, minAreaPixels: minComponentAreaPixels)
        return rawBoundaries.compactMap { boundary in
            let simplified = PolylineSimplify.douglasPeucker(boundary, epsilon: simplifyEpsilonPixels)
            return simplified.count > 2 ? simplified : nil
        }
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

    #if canImport(CoreGraphics)
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
    #endif

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

    /// The mask, plus the single reference background color when one
    /// genuinely exists (a uniform-corner flat background) -- `nil` for the
    /// transparency and Otsu-fallback paths, where "the background" isn't
    /// one representative RGB value. `importShapes` uses this to extend
    /// `smoothAmbiguousBoundaryLabels`'s ambiguity test to the foreground/
    /// background boundary too, not just boundaries between two foreground
    /// colors -- see that function's own doc comment.
    /// See `computeForegroundMask`: this share of the border pixels must
    /// match the border's median colour for it to be the background.
    /// Three grey sides and one white edge is ~75%; a canvas split
    /// between two colours is ~50% and falls through to Otsu.
    private static let borderMajorityFraction = 0.6

    /// See `computeForegroundMask`: with no border majority, the image's
    /// dominant colour is the background when it covers this share of
    /// the picture and this share of the border.
    private static let dominantColorImageFraction = 0.3
    private static let dominantColorBorderFraction = 0.2

    private static func computeForegroundMask(pixels: [UInt8], width: Int, height: Int) throws -> (mask: [Bool], backgroundColor: RGBColor?) {
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
            return (mask, nil)
        }

        // The background colour is the per-channel median of every
        // border pixel, not the single top-left pixel: JPEG ringing put
        // a (255, 227, 255) pink at one corner of a white-background
        // phone screenshot, and with that as the reference the real
        // white was 28 units "away" -- close enough to still count as
        // background, but far enough to break the anti-aliasing ramp
        // test, which measures every blend colour against this value.
        //
        // The border decides by MAJORITY, not by all four corners
        // agreeing: a logo on a grey card with one corner cut away (the
        // crop of a studio's side-by-side, a screenshot with a
        // watermark, a photo with a finger in it) has three grey corners
        // and one white, and the all-corners rule sent it to the Otsu
        // fallback below, which split the image into light and dark and
        // kept the minority -- the white and yellow of an eagle, losing
        // both its blues to the "background" class along with the grey.
        var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
        for x in 0..<width { for y in [0, height - 1] { let p = pixel(x, y); rs.append(p.r); gs.append(p.g); bs.append(p.b) } }
        for y in 0..<height { for x in [0, width - 1] { let p = pixel(x, y); rs.append(p.r); gs.append(p.g); bs.append(p.b) } }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        func borderShare(of reference: (r: Double, g: Double, b: Double)) -> Double {
            var agreeing = 0
            for i in rs.indices where abs(rs[i] - reference.r) + abs(gs[i] - reference.g) + abs(bs[i] - reference.b) <= colorDistanceThreshold { agreeing += 1 }
            return rs.isEmpty ? 0 : Double(agreeing) / Double(rs.count)
        }
        var bg = (r: median(rs), g: median(gs), b: median(bs), a: 255.0)
        var borderAgrees = borderShare(of: (bg.r, bg.g, bg.b)) >= borderMajorityFraction
        if !borderAgrees {
            // No majority around the median: a banner cut off at the sides,
            // with a dark bar along its top and bottom edges and pale sky
            // between, has a border median that matches nothing. The
            // image's DOMINANT colour decides instead, when it covers a
            // real share of the picture and reaches the border -- the pale
            // ground of that banner, the grey card behind a mascot -- and
            // only a picture with no dominant colour (a painting, a
            // photograph) falls through to Otsu, which treated the
            // banner's whole pale sky, sun and rays as background and kept
            // only the green.
            var sample: [RGBColor] = []
            sample.reserveCapacity(width * height / 4 + 1)
            for i in stride(from: 0, to: width * height, by: 4) {
                sample.append(RGBColor(r: pixels[i * 4], g: pixels[i * 4 + 1], b: pixels[i * 4 + 2]))
            }
            if let dominant = ColorQuantizer.quantize(pixels: sample, maxColors: 6).max(by: { $0.pixelCount < $1.pixelCount }),
               Double(dominant.pixelCount) / Double(max(1, sample.count)) >= dominantColorImageFraction {
                let candidate = (r: Double(dominant.rgb.r), g: Double(dominant.rgb.g), b: Double(dominant.rgb.b))
                if borderShare(of: candidate) >= dominantColorBorderFraction {
                    bg = (candidate.r, candidate.g, candidate.b, 255.0)
                    borderAgrees = true
                }
            }
        }

        if borderAgrees {
            for y in 0..<height {
                for x in 0..<width {
                    let p = pixel(x, y)
                    let dist = abs(p.r - bg.r) + abs(p.g - bg.g) + abs(p.b - bg.b)
                    mask[y * width + x] = dist > colorDistanceThreshold
                }
            }
            let backgroundColor = RGBColor(r: UInt8(max(0, min(255, bg.r))), g: UInt8(max(0, min(255, bg.g))), b: UInt8(max(0, min(255, bg.b))))
            return (mask, backgroundColor)
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
        return (mask, nil)
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
