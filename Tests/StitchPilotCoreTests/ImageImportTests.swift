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

    /// A small, blurry source: a dark frame whose 3 px-wide enclosed gaps
    /// hold no clean white pixel at all, only light-grey blend, plus a
    /// JPEG-style pink artifact in one corner. Modelled on a 110 px phone
    /// screenshot of a tribal turtle (TestArtwork/Professional Files) that
    /// came back with every hole in the shell stitched in white thread:
    /// the corner pixel was taken as *the* background colour, which broke
    /// the blend-colour test, and the grey outnumbered the dark colour so
    /// the size guard on that test let it through. The holes must import
    /// as holes (bare fabric), not as a light-grey object.
    @Test func blurryEnclosedGapsAreHolesNotALightGreyObject() throws {
        let size = 60
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(deviceColor(1, 1, 1, in: colorSpace))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // Dark frame, 36x36, with five 5-px slots that are light grey (a
        // blend of the dark and the white) rather than white -- and more
        // grey than dark in total, so the old "a blend cluster is smaller
        // than the real one" guard alone would not catch it.
        context.setFillColor(deviceColor(0.09, 0.25, 0.30, in: colorSpace))
        context.fill(CGRect(x: 10, y: 10, width: 36, height: 36))
        context.setFillColor(deviceColor(0.73, 0.85, 0.88, in: colorSpace))
        for slot in 0..<5 { context.fill(CGRect(x: 13, y: 12 + slot * 7, width: 30, height: 5)) }
        // One pink corner pixel.
        context.setFillColor(deviceColor(1, 0.89, 1, in: colorSpace))
        context.fill(CGRect(x: 0, y: size - 1, width: 1, height: 1))
        let png = encodePNG(context.makeImage()!)

        let result = try ImageImporter.importShapes(from: png, maxColors: 3)
        let lightObjects = result.fillColors.compactMap { $0 }.filter { Int($0.r) + Int($0.g) + Int($0.b) > 450 }
        #expect(lightObjects.isEmpty, "the light-grey slots are blend, not a colour to sew: \(result.fillColors)")
        let frame = try #require(result.shapes.max { abs(PolygonGeometry.signedArea($0.subPaths[0].points)) < abs(PolygonGeometry.signedArea($1.subPaths[0].points)) })
        #expect(frame.subPaths.count == 6, "the frame keeps its five slots as holes (got \(frame.subPaths.count - 1))")
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

    /// A shape (a genuine letterform counter, traced via `.clear` above)
    /// reads at the pixel level *identically* to a differently-colored
    /// shape simply overlaid on top of a solid background (text on a
    /// banner, a logo mark on a solid field) -- both are "an enclosed
    /// region of a different color within a larger shape." But they need
    /// opposite treatment: a real counter must stay an actual gap in the
    /// underlying shape's own stitching; an overlay's covered region
    /// should leave the *underlying* shape solid, since the overlay will
    /// stitch fully opaque over it in its own thread regardless --
    /// professional digitizing practice sews the background solid and
    /// layers text/logos on top, never leaves an actual hole in the
    /// fabric for something meant to simply be covered. Left unhandled,
    /// deleting or replacing the overlay (including using Detected Text
    /// to swap raster-traced lettering for generated Lettering, a real
    /// workflow) reveals a hole where the overlay used to sit -- found
    /// directly against a real banner-with-lettering design (see
    /// CHANGELOG.md).
    @Test func overlaidDifferentlyColoredShapeLeavesTheUnderlyingShapeSolid() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 100
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // The "banner": a big blue rectangle.
        context.setFillColor(deviceColor(0.2, 0.4, 0.9, in: colorSpace))
        context.fill(CGRect(x: 5, y: 5, width: 90, height: 90))
        // The "lettering": a smaller navy rectangle painted on top, not
        // cleared -- a genuinely different color occupying real pixels,
        // exactly like text drawn over a banner.
        context.setFillColor(deviceColor(0.02, 0.05, 0.3, in: colorSpace))
        context.fill(CGRect(x: 30, y: 30, width: 40, height: 40))

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!), maxColors: 8)
        let banner = try #require(result.shapes.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }))
        #expect(banner.subPaths.count == 1, "the banner should be solid underneath the overlay, not have a hole cut where the overlay sits")

        // Sanity: the overlay itself still imported as its own separate,
        // real object -- this isn't passing merely because nothing was
        // traced for it.
        #expect(result.shapes.count == 2)
    }

    /// The counter-vs-overlay distinction above must not remove a genuine
    /// hole just because *some* other shape in the image happens to share
    /// a similar bounding box by coincidence -- only one that's the same
    /// color-distinct region traced from literally the same pixels should
    /// qualify. Two separate, small, unrelated shapes elsewhere in the
    /// image (not overlapping the ring at all) must not cause the ring's
    /// own genuine hole to be stripped.
    @Test func unrelatedShapesElsewhereDoNotAffectAGenuineHole() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 100
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(deviceColor(13.0 / 255, 43.0 / 255, 86.0 / 255, in: colorSpace))
        context.fillEllipse(in: CGRect(x: 5, y: 5, width: 60, height: 60))
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: 20, y: 20, width: 30, height: 30))
        context.setBlendMode(.normal)
        // An unrelated small shape well away from the ring.
        context.setFillColor(deviceColor(0.9, 0.1, 0.1, in: colorSpace))
        context.fill(CGRect(x: 75, y: 75, width: 15, height: 15))

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!), maxColors: 8)
        let ring = try #require(result.shapes.max(by: { $0.boundingBox.width < $1.boundingBox.width }))
        #expect(ring.subPaths.count == 2, "an unrelated shape elsewhere must not strip a genuine hole")
    }

    /// A same-colored region that's small, disconnected from its own
    /// color's main shape (because a differently-colored ring fully
    /// encircles it), but sits well inside that main shape's extent, is
    /// the same background layer showing through -- not a separate design
    /// element. This exercises the actual interaction that matters: once
    /// the ring's OWN background-facing hole gets stripped (making the
    /// ring's underlying shape solid across that whole area, the ordinary
    /// "overlay on solid background" fix), the ring's own *counter* --
    /// where the same background color the ring sits on shows back through
    /// again in the very center -- must both merge into the main
    /// background shape AND still read as solid there, not accidentally
    /// re-punch a hole via a redundant leftover subpath (found directly
    /// against exactly this ring/counter interaction -- see CHANGELOG.md).
    @Test func colorIslandInsideARingsCounterMergesAndStaysSolid() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 200
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Background layer, margined off the canvas edges so it reads as
        // real foreground content rather than the page's own background.
        let navy = deviceColor(0.05, 0.1, 0.4, in: colorSpace)
        context.setFillColor(navy)
        context.fill(CGRect(x: 15, y: 15, width: 170, height: 170))
        // A red ring sitting on the navy background, with its own counter
        // punched back to the same navy -- the counter is fully enclosed
        // by the red ring and disconnected from the main navy region.
        context.setFillColor(deviceColor(0.85, 0.1, 0.1, in: colorSpace))
        context.fillEllipse(in: CGRect(x: 60, y: 60, width: 80, height: 80))
        context.setFillColor(navy)
        context.fillEllipse(in: CGRect(x: 87, y: 87, width: 26, height: 26))

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!), maxColors: 8)
        #expect(result.shapes.count == 2, "the navy island should merge into the main navy shape, not remain a third separate object")

        func area(_ shape: VectorShape) -> Double { shape.boundingBox.width * shape.boundingBox.height }
        let navyShape = try #require(result.shapes.max(by: { area($0) < area($1) }), "the navy background should be the larger of the two shapes")
        let ringShape = try #require(result.shapes.min(by: { area($0) < area($1) }), "the red ring should be the smaller of the two shapes")

        // The counter's own center must read as *inside* the navy shape
        // under the even-odd rule (solid, matching the surrounding
        // background) -- this is the exact regression: a leftover
        // redundant subpath there would flip it back to a hole instead.
        let counterCenter = Point2D(100, 100)
        let navyPolygons = navyShape.subPaths.map { $0.points }
        #expect(PolygonGeometry.pointInPolygons(counterCenter, polygons: navyPolygons),
                "the ring's own counter should read as solid, merged background -- not a hole")

        // The ring itself must still have a real hole at its own counter
        // (it must not have become a solid disc).
        #expect(ringShape.subPaths.count == 2, "the ring must keep its own hole, not become a solid disc")
        let ringPolygons = ringShape.subPaths.map { $0.points }
        #expect(!PolygonGeometry.pointInPolygons(counterCenter, polygons: ringPolygons),
                "the ring's own fill must not cover its counter")
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

    /// The generalization `mergeColorIslandsIntoLargestSameColorShape`
    /// needed once it stopped only ever considering the single globally-
    /// largest same-color shape as a merge target: a color that
    /// legitimately forms *two* separate large background regions (not one
    /// main region plus stray fragments) each gets its own overlay-created
    /// island, and each island must merge into its own *nearby* region --
    /// not fail to merge because it isn't contained in whichever region
    /// happened to be biggest. Confirmed directly against the PiperStitch
    /// bird mark: the cream body and the cream neck are each a real,
    /// separate background region (split apart by the rust head-stripe and
    /// navy beak running between them), and the old single-target version
    /// left one of the two un-merged, contributing its own stray fragment.
    @Test func eachOfTwoSeparateSameColorBackgroundRegionsMergesItsOwnLocalIsland() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 300
        let context = CGContext(data: nil, width: size, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let navy = deviceColor(0.05, 0.1, 0.4, in: colorSpace)
        let red = deviceColor(0.85, 0.1, 0.1, in: colorSpace)

        // Two separate navy regions, far enough apart that neither's
        // bounding box contains the other.
        context.setFillColor(navy)
        context.fill(CGRect(x: 10, y: 10, width: 120, height: 120))
        context.fill(CGRect(x: 170, y: 10, width: 120, height: 120))

        // Each region gets its own red ring with a navy counter showing
        // the *local* background back through -- the same construction as
        // `colorIslandInsideARingsCounterMergesAndStaysSolid`, just twice,
        // once per region.
        for offsetX in [0, 160] {
            context.setFillColor(red)
            context.fillEllipse(in: CGRect(x: 40 + offsetX, y: 40, width: 60, height: 60))
            context.setFillColor(navy)
            context.fillEllipse(in: CGRect(x: 60 + offsetX, y: 60, width: 20, height: 20))
        }

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!), maxColors: 8)
        // 2 navy regions (each with its own local island merged in) + 2 red
        // rings = 4. Without the fix: whichever navy region isn't chosen as
        // the single "largest" target leaves its island stray, giving 5.
        #expect(result.shapes.count == 4,
                "each navy region should absorb its own nearby island; got \(result.shapes.count) shapes")
    }

    /// The actual regression the ambiguity-gated boundary smoothing exists
    /// for: an anti-aliased curved edge against a flat, fully opaque
    /// background (routine for a logo exported or screenshotted on white --
    /// unlike the transparency case above, there's no alpha channel to read
    /// the true blend from). Confirmed against three real customer files
    /// (the PiperStitch bird mark, the Amerus logo, the LIBBi wordmark)
    /// whose curved letter edges came back as a swarm of "Light Gray"/
    /// "Silver" sliver objects fringing every letter -- a filled circle
    /// (CoreGraphics anti-aliases its own curved boundary automatically)
    /// reproduces the identical mechanism without needing a real file: the
    /// disc's own rim must resolve into either the disc or the background,
    /// never survive as its own separate gray shape(s).
    @Test func antiAliasedCurveAgainstFlatBackgroundDoesNotFragmentIntoStraySlivers() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let size = 120
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(deviceColor(1, 1, 1, in: colorSpace))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setShouldAntialias(true)
        context.setFillColor(deviceColor(8.0 / 255, 36.0 / 255, 66.0 / 255, in: colorSpace)) // navy
        context.fillEllipse(in: CGRect(x: 10, y: 10, width: 100, height: 100))

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!), maxColors: 8)

        #expect(result.shapes.count == 1,
                "the disc's own anti-aliased rim must resolve into the disc or the background, not survive as \(result.shapes.count) separate shapes")
        let colors = Set(result.fillColors.compactMap { $0 })
        #expect(colors.count == 1, "must not detect a spurious extra color from the ramp: found \(colors)")
    }
}
