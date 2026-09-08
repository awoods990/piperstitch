import Foundation
import Vision
import CoreGraphics
import ImageIO

/// A rough weight guess (bold vs regular) for a detected text region, from
/// how much of its own tight bounding box is actually covered by ink --
/// a heuristic, not a real font match. Presented to the caller as a
/// starting suggestion for `LetteringGenerator`'s font picker, never as a
/// confident identification of the source font itself (see
/// `TextDetector`'s own doc comment on why real font-matching is out of
/// scope).
public enum SuggestedFontWeight: Sendable {
    case bold
    case regular
}

public struct DetectedTextRegion: Sendable, Identifiable {
    public var id = UUID()
    public var text: String
    /// Vision's own confidence (0-1) in this transcription.
    public var confidence: Float
    /// In the same pixel-space convention `ImageImporter`'s traced shapes
    /// use before fitting to a physical size: origin top-left, Y-down.
    public var boundingBoxPixels: BoundingBox
    /// Degrees the text's own top edge is rotated from horizontal (0 =
    /// perfectly horizontal, positive = tilted). Vision's own detection is
    /// tuned for straight or gently-rotated lines -- a large rotation, or
    /// text Vision only partially picks up, is a hint (not a proof) that
    /// the source is actually curved (a badge's ring text), which a
    /// single rotation angle can't fully represent. Surfaced to the user
    /// as "this looks tilted/curved, consider enabling curving" rather
    /// than silently guessing a precise arc radius.
    public var rotationDegrees: Double
    public var suggestedWeight: SuggestedFontWeight

    public init(text: String, confidence: Float, boundingBoxPixels: BoundingBox, rotationDegrees: Double, suggestedWeight: SuggestedFontWeight) {
        self.text = text
        self.confidence = confidence
        self.boundingBoxPixels = boundingBoxPixels
        self.rotationDegrees = rotationDegrees
        self.suggestedWeight = suggestedWeight
    }
}

/// Detects text already present in imported raster artwork, so
/// `LetteringGenerator` (real font outlines) can be offered as a
/// replacement for the raster-traced region -- fixing text at the source
/// instead of asking the user to notice it's illegible and retype it from
/// scratch. Built on Vision's `VNRecognizeTextRequest`.
///
/// Two things this deliberately does NOT attempt, because they're
/// substantially harder problems than transcription itself and getting
/// them wrong confidently is worse than not offering them:
/// - **Curved text.** Vision's OCR is tuned for straight (or gently
///   rotated) lines; a badge's tightly curved ring text will detect
///   unreliably or not at all. `rotationDegrees` flags a region that's at
///   least tilted, as a hint toward manually enabling curving in the
///   Lettering tool -- this never tries to infer a precise arc radius or
///   center from the detection itself.
/// - **Font identification.** Real font-matching (which exact typeface
///   the source used) is essentially unsolved in general, even for
///   dedicated commercial font-ID services. `suggestedWeight` only ever
///   offers a bold-vs-regular guess from ink density within the detected
///   region -- a coarse, honest starting point for the font picker, never
///   presented as an actual match.
public enum TextDetector {
    /// Below this confidence, Vision's own transcription is unreliable
    /// enough it's not worth surfacing as a suggestion at all.
    public static let defaultMinConfidence: Float = 0.3

    /// A bold face's strokes cover noticeably more of their own tight
    /// bounding box than a regular weight's. This midpoint (empirically
    /// between typical regular ~15-22% and bold ~28-38% ink coverage for
    /// a line of latin text) is a reasonable split, not a precise
    /// measurement -- see `estimateWeight`.
    private static let boldInkFractionThreshold = 0.28

    public static func detectTextRegions(from data: Data, minConfidence: Float = defaultMinConfidence) throws -> [DetectedTextRegion] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return []
        }
        let width = cgImage.width, height = cgImage.height
        guard width > 1, height > 1 else { return [] }
        let pixels = renderRGBA(cgImage, width: width, height: height)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let observations = request.results else { return [] }

        var regions: [DetectedTextRegion] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= minConfidence else { continue }

            // Vision's corners are normalized (0-1), origin bottom-left --
            // flip Y and scale to pixel space to match this codebase's
            // top-left/Y-down convention throughout.
            func toPixel(_ p: CGPoint) -> Point2D {
                Point2D(Double(p.x) * Double(width), Double(1 - p.y) * Double(height))
            }
            let corners = [observation.topLeft, observation.topRight, observation.bottomLeft, observation.bottomRight].map(toPixel)
            let box = BoundingBox(points: corners)
            guard !box.isEmpty else { continue }

            let topLeftPx = toPixel(observation.topLeft), topRightPx = toPixel(observation.topRight)
            let rotation = atan2(topLeftPx.y - topRightPx.y, topRightPx.x - topLeftPx.x) * 180 / .pi

            let weight = estimateWeight(pixels: pixels, width: width, height: height, box: box)
            regions.append(DetectedTextRegion(text: candidate.string, confidence: candidate.confidence,
                                               boundingBoxPixels: box, rotationDegrees: rotation, suggestedWeight: weight))
        }
        return regions
    }

    /// Splits luminance within the region into two classes at the
    /// region's own mean and treats the smaller class's area fraction as
    /// "ink" -- reasonable for a tight bounding box around just one line
    /// of text, where the letters themselves (whichever tone they are)
    /// cover less area than the background peeking through gaps and
    /// between letterforms.
    private static func estimateWeight(pixels: [UInt8], width: Int, height: Int, box: BoundingBox) -> SuggestedFontWeight {
        let minX = max(0, Int(box.minX)), maxX = min(width - 1, Int(box.maxX.rounded(.up)))
        let minY = max(0, Int(box.minY)), maxY = min(height - 1, Int(box.maxY.rounded(.up)))
        guard maxX > minX, maxY > minY else { return .regular }

        var luminances: [Double] = []
        luminances.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for y in minY...maxY {
            for x in minX...maxX {
                let i = (y * width + x) * 4
                guard i + 2 < pixels.count else { continue }
                luminances.append(Double(pixels[i]) * 0.299 + Double(pixels[i + 1]) * 0.587 + Double(pixels[i + 2]) * 0.114)
            }
        }
        guard !luminances.isEmpty else { return .regular }
        let mean = luminances.reduce(0, +) / Double(luminances.count)
        let darkCount = luminances.filter { $0 < mean }.count
        let inkFraction = Double(min(darkCount, luminances.count - darkCount)) / Double(luminances.count)
        return inkFraction > boldInkFractionThreshold ? .bold : .regular
    }

    /// Minimal RGBA render, independent of `ImageImporter`'s own -- kept
    /// separate rather than sharing its private implementation, since this
    /// is a much smaller, read-only need (sampling pixels for the ink-
    /// density heuristic) and duplicating a dozen lines here carries far
    /// less risk than changing the visibility of already-tested code.
    private static func renderRGBA(_ cgImage: CGImage, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return pixels
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
}
