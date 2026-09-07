import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import StitchPilotCore

struct ImageImportTests {
    /// `CGColor(red:green:blue:alpha:)` creates a color in the generic
    /// calibrated RGB space, not `CGColorSpaceCreateDeviceRGB()` — filling
    /// with it into a device-RGB context makes CoreGraphics color-match
    /// between the two spaces, silently shifting saturated channels by
    /// dozens of units (e.g. pure red came out as (255, 38, 0) in an
    /// earlier version of this file). Building the color directly in the
    /// context's own color space avoids any conversion, which matters once
    /// tests check pixel colors and not just shape counts.
    private func deviceColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, in colorSpace: CGColorSpace) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [r, g, b, 1])!
    }

    /// Renders a synthetic PNG in-memory (a black square on a white
    /// background) so this test needs no external asset — spec §66 wants
    /// programmatically generated test artwork specifically to avoid
    /// copyright concerns.
    private func makePNG(size: Int = 100, drawSquare squareRect: CGRect) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(deviceColor(1, 1, 1, in: colorSpace))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(deviceColor(0, 0, 0, in: colorSpace))
        // Context origin is bottom-left; flip the rect vertically so callers
        // can specify it in top-left/Y-down terms.
        let flipped = CGRect(x: squareRect.minX, y: CGFloat(size) - squareRect.maxY, width: squareRect.width, height: squareRect.height)
        context.fill(flipped)
        return encodePNG(context.makeImage()!)
    }

    private func encodePNG(_ image: CGImage) -> Data {
        let mutableData = NSMutableData()
        let dest = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return mutableData as Data
    }

    @Test func findsSingleSquare() throws {
        let png = makePNG(size: 100, drawSquare: CGRect(x: 20, y: 20, width: 40, height: 40))
        let result = try ImageImporter.importShapes(from: png)

        #expect(result.shapes.count == 1)
        let box = result.shapes[0].boundingBox
        #expect(abs(box.width - 40) <= 2.0)
        #expect(abs(box.height - 40) <= 2.0)
        #expect(abs(box.minX - 20) <= 2.0)
        #expect(abs(box.minY - 20) <= 2.0)
    }

    @Test func findsTwoSeparateShapes() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 100
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(deviceColor(1, 1, 1, in: colorSpace))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(deviceColor(0, 0, 0, in: colorSpace))
        context.fill(CGRect(x: 5, y: 5, width: 15, height: 15))
        context.fill(CGRect(x: 70, y: 70, width: 15, height: 15))

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!))
        #expect(result.shapes.count == 2)
    }

    @Test func ignoresTinyNoise() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 100
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(deviceColor(1, 1, 1, in: colorSpace))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(deviceColor(0, 0, 0, in: colorSpace))
        context.fill(CGRect(x: 40, y: 40, width: 30, height: 30)) // real shape
        context.fill(CGRect(x: 2, y: 2, width: 1, height: 1))     // 1px noise speck

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!))
        #expect(result.shapes.count == 1, "the single-pixel speck should have been filtered out as insignificant")
    }

    @Test func transparentBackgroundDetected() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 60
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Leave fully transparent, then draw an opaque red square.
        context.setFillColor(deviceColor(1, 0, 0, in: colorSpace))
        context.fill(CGRect(x: 15, y: 15, width: 20, height: 20))

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!))
        #expect(result.shapes.count == 1)
        #expect(abs(result.shapes[0].boundingBox.width - 20) <= 2.0)
    }

    /// A logo exported with a transparent margin around an *opaque* white
    /// card behind the actual artwork -- a real customer file that came
    /// back with ~300 spurious slivers before this was fixed, because
    /// "the canvas has transparency" made every opaque pixel (including
    /// that whole white card) count as foreground. The white card touches
    /// the left/right edges (only the very top/bottom strip is left
    /// transparent), so it should still be recognized and excluded as
    /// background despite the canvas not being *fully* opaque.
    @Test func opaqueBackgroundFillWithinAPartiallyTransparentCanvasIsExcluded() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 100
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Leave a transparent margin at the very top/bottom (so the image
        // as a whole reads as "has transparency"), but let the white card
        // span the full width, touching the left and right edges.
        context.setFillColor(deviceColor(1, 1, 1, in: colorSpace))
        context.fill(CGRect(x: 0, y: 5, width: size, height: size - 10))
        context.setFillColor(deviceColor(0, 0, 0.5, in: colorSpace))
        context.fill(CGRect(x: 30, y: 30, width: 40, height: 40))

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!))
        #expect(result.shapes.count == 1, "the opaque white card should be excluded as background, leaving only the navy square")
    }

    /// A circular badge (a team/club logo, say) whose background disc is
    /// the *main content*, not a background fill -- it just happens to
    /// touch each canvas edge at its tangent point, the same border
    /// contact a genuine background card has. Excluding it purely on
    /// border contact would drop most of the design (a real regression
    /// found against an actual circular logo, which came back missing its
    /// entire background disc, only the inner emblem surviving). What
    /// distinguishes it from `opaqueBackgroundFillWithinAPartiallyTransparentCanvasIsExcluded`
    /// above is *how much* of an edge it covers: a tangent point is a
    /// sliver of the edge, a real background card spans most of one.
    @Test func circularBadgeBackgroundIsNotExcludedDespiteTouchingTheBorder() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 96
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // A navy disc inscribed in the canvas (touches each edge only at
        // its tangent point), with a small red emblem on top.
        context.setFillColor(deviceColor(13.0 / 255, 43.0 / 255, 86.0 / 255, in: colorSpace))
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(deviceColor(0.8, 0.1, 0.1, in: colorSpace))
        context.fill(CGRect(x: 36, y: 36, width: 24, height: 24))

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!))
        let totalArea = result.shapes.reduce(0.0) { $0 + $1.boundingBox.width * $1.boundingBox.height }
        #expect(totalArea > 2000, "the navy disc should still be present, not excluded as background -- got total shape area \(totalArea)")
    }

    /// A circular badge traced from a low-resolution raster inevitably
    /// picks up a jagged pixel staircase; the navy disc's boundary should
    /// come back smooth (every point almost exactly one radius from the
    /// shape's own center), not still visibly wobbling the way a raw
    /// pixel trace does -- a real report against an actual sports-team
    /// logo, whose stitched-out circle looked jagged despite otherwise
    /// importing correctly.
    @Test func circularBadgeBoundaryIsSmoothedNotJagged() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 96
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(deviceColor(13.0 / 255, 43.0 / 255, 86.0 / 255, in: colorSpace))
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(deviceColor(0.8, 0.1, 0.1, in: colorSpace))
        context.fill(CGRect(x: 36, y: 36, width: 24, height: 24))

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!))
        let disc = try #require(result.shapes.max(by: { $0.boundingBox.width < $1.boundingBox.width }))
        let points = disc.subPaths[0].points
        let box = disc.boundingBox
        let center = box.center
        let radii = points.map { $0.distance(to: center) }
        let meanRadius = radii.reduce(0, +) / Double(radii.count)
        let maxDeviation = radii.map { abs($0 - meanRadius) }.max() ?? 0
        #expect(maxDeviation / meanRadius < 0.03,
                "every point on a regularized circle should sit almost exactly one radius from center, got a deviation of \(maxDeviation / meanRadius)")
    }

    /// A shape that merely has a square-ish bounding box (a diamond, say)
    /// must not be mistaken for a circle just because width ≈ height --
    /// its boundary points are *not* all equidistant from the center, so
    /// the circularity check should leave it untouched.
    @Test func squareBoundingBoxShapeIsNotMistakenForACircle() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 96
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(deviceColor(0, 0, 0.6, in: colorSpace))
        // A diamond: same bounding box as a circle would have, but corner
        // points sit ~40% farther from center than edge-midpoints do.
        context.move(to: CGPoint(x: 48, y: 4))
        context.addLine(to: CGPoint(x: 92, y: 48))
        context.addLine(to: CGPoint(x: 48, y: 92))
        context.addLine(to: CGPoint(x: 4, y: 48))
        context.closePath()
        context.fillPath()

        // Compares the largest traced shape, not `shapes.count == 1`: a
        // solid color anti-aliased against a fully transparent background
        // (no second real color for `ColorQuantizer`'s cluster-merging to
        // fold it into) can still produce a thin secondary rim shape --
        // an orthogonal, pre-existing characteristic of raster import this
        // test isn't about.
        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!))
        let diamond = try #require(result.shapes.max(by: { $0.boundingBox.width < $1.boundingBox.width }))
        let points = diamond.subPaths[0].points
        #expect(points.count < 72, "a diamond should keep its own simplified vertex count, not be replaced by a 72-point circle")
    }

    /// A ring (a donut, or any letterform counter -- the enclosed hole
    /// inside O, P, R, A, D, B, Q...) must import as a shape with *two*
    /// subpaths -- an outer boundary and an inner hole -- not a solid
    /// disc. Left unhandled, raster import silently filled every such
    /// hole in solid: exactly the "small lettering reads as the wrong
    /// letter" failure already fixed for SVG import (see CHANGELOG.md),
    /// found here for the raster path, which never had it.
    @Test func ringShapeImportsWithItsHoleAsASecondSubpath() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 100
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(deviceColor(13.0 / 255, 43.0 / 255, 86.0 / 255, in: colorSpace))
        context.fillEllipse(in: CGRect(x: 5, y: 5, width: 90, height: 90))
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: 30, y: 30, width: 40, height: 40))
        context.setBlendMode(.normal)

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!))
        let ring = try #require(result.shapes.max(by: { $0.boundingBox.width < $1.boundingBox.width }))
        #expect(ring.subPaths.count == 2, "a ring should have an outer boundary and one hole subpath, got \(ring.subPaths.count)")

        // The hole's own center must read as *outside* the shape under the
        // even-odd rule every other multi-subpath shape in this engine
        // uses -- otherwise the "hole" is just cosmetically present as a
        // second subpath without actually being hollow.
        let outerBox = BoundingBox(points: ring.subPaths[0].points)
        let center = outerBox.center
        let polygons = ring.subPaths.map { $0.points }
        #expect(!PolygonGeometry.pointInPolygons(center, polygons: polygons),
                "the ring's own center should be outside the shape (inside the hole), not solid fill")
    }

    /// Three separate, distinctly-colored squares on a white background:
    /// the multi-color segmentation path (spec §8) should recover all three
    /// regions with their correct colors, not merge them into one region
    /// colored however the first pixel happened to be.
    @Test func multiColorSegmentation() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 120
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(deviceColor(1, 1, 1, in: colorSpace))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(deviceColor(1, 0, 0, in: colorSpace))
        context.fill(CGRect(x: 5, y: 5, width: 20, height: 20))
        context.setFillColor(deviceColor(0, 1, 0, in: colorSpace))
        context.fill(CGRect(x: 50, y: 50, width: 20, height: 20))
        context.setFillColor(deviceColor(0, 0, 1, in: colorSpace))
        context.fill(CGRect(x: 95, y: 95, width: 20, height: 20))

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!), maxColors: 8)
        #expect(result.shapes.count == 3)
        #expect(result.fillColors.count == 3)

        let colors = Set(result.fillColors.compactMap { $0 })
        #expect(colors.contains { RGBColor.deltaE($0, RGBColor(hex: 0xFF0000)) < 10 })
        #expect(colors.contains { RGBColor.deltaE($0, RGBColor(hex: 0x00FF00)) < 10 })
        #expect(colors.contains { RGBColor.deltaE($0, RGBColor(hex: 0x0000FF)) < 10 })
    }

    /// `CGContext` only supports *premultiplied*-alpha bitmaps as a drawing
    /// destination, so a semi-transparent pixel's raw stored RGB is
    /// `trueColor * alpha`, not its true color -- a gold pixel at 50% alpha
    /// stores as dark brown-ish, not gold. A real bug read that raw,
    /// still-premultiplied RGB directly as if it were the pixel's true
    /// color, so every anti-aliased edge in real artwork (there can be
    /// thousands, one ring around every letter and detail in a text-heavy
    /// logo) got misread as its own spurious dark "color" distinct from
    /// both the true foreground and the background -- each becoming its
    /// own tiny traced object. Found via `DigitizeCLI` against
    /// `SMA Logo.webp`, a school-seal-and-text logo, which produced over a
    /// million stitches before this and the tracer-closure fix below (see
    /// CHANGELOG.md). This constructs a single 50%-alpha gold square and
    /// checks the detected color is still recognizably gold, not the
    /// darkened premultiplied value.
    @Test func semiTransparentPixelsResolveToTrueColorNotPremultipliedDarkening() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 60
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Gold at 50% alpha -- premultiplied storage would be roughly half
        // brightness (dark olive/brown), nothing like true gold.
        let gold = CGColor(colorSpace: colorSpace, components: [212.0 / 255, 175.0 / 255, 55.0 / 255, 0.5])!
        context.setFillColor(gold)
        context.fill(CGRect(x: 15, y: 15, width: 20, height: 20))

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!))
        #expect(result.shapes.count == 1)
        let detected = try #require(result.fillColors.first ?? nil)
        #expect(RGBColor.deltaE(detected, RGBColor(hex: 0xD4AF37)) < 15,
                "detected color \(detected) should be close to true gold, not premultiplied-darkened")
    }
}
