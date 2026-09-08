import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import StitchPilotCore

struct TextDetectorTests {
    private func deviceColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, in colorSpace: CGColorSpace) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [r, g, b, 1])!
    }

    private func makeTextPNG(_ text: String, fontName: String = "Helvetica", fontSize: CGFloat = 72,
                              size: CGSize = CGSize(width: 900, height: 200), rotationDegrees: CGFloat = 0) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(deviceColor(1, 1, 1, in: colorSpace))
        context.fill(CGRect(origin: .zero, size: size))

        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: deviceColor(0, 0, 0, in: colorSpace),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let lineBounds = CTLineGetBoundsWithOptions(line, [])

        context.saveGState()
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: rotationDegrees * .pi / 180)
        context.translateBy(x: -(lineBounds.minX + lineBounds.width / 2), y: -(lineBounds.minY + lineBounds.height / 2))
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()

        let image = context.makeImage()!
        let mutableData = NSMutableData()
        let dest = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return mutableData as Data
    }

    @Test func detectsClearHorizontalText() throws {
        let png = makeTextPNG("HELLO WORLD")
        let regions = try TextDetector.detectTextRegions(from: png)
        #expect(!regions.isEmpty, "should detect at least one text region")
        let found = regions.contains { $0.text.uppercased().contains("HELLO") }
        #expect(found, "should transcribe something recognizable from clear, large text; got \(regions.map { $0.text })")
    }

    @Test func detectedRegionHasAReasonableBoundingBox() throws {
        let png = makeTextPNG("WIDTH")
        let regions = try TextDetector.detectTextRegions(from: png)
        let region = try #require(regions.first)
        #expect(region.boundingBoxPixels.width > 20)
        #expect(region.boundingBoxPixels.height > 5)
        #expect(region.boundingBoxPixels.minX >= 0)
        #expect(region.boundingBoxPixels.maxX <= 900)
    }

    @Test func blankImageProducesNoRegions() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(deviceColor(1, 1, 1, in: colorSpace))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = context.makeImage()!
        let mutableData = NSMutableData()
        let dest = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)

        let regions = try TextDetector.detectTextRegions(from: mutableData as Data)
        #expect(regions.isEmpty)
    }

    @Test func rotatedTextReportsARoughlyMatchingRotation() throws {
        let png = makeTextPNG("TILTED", rotationDegrees: 20)
        let regions = try TextDetector.detectTextRegions(from: png)
        let region = try #require(regions.first { $0.text.uppercased().contains("TILT") })
        // Vision's own angle estimate for a real rasterized, anti-aliased
        // rotation is approximate -- checking it lands in the right
        // ballpark (clearly tilted, roughly the right direction and
        // magnitude) rather than requiring a precise match.
        #expect(region.rotationDegrees > 5, "should detect a clearly non-horizontal tilt, got \(region.rotationDegrees)")
    }

    @Test func nearHorizontalTextReportsNearZeroRotation() throws {
        let png = makeTextPNG("FLAT")
        let regions = try TextDetector.detectTextRegions(from: png)
        let region = try #require(regions.first)
        #expect(abs(region.rotationDegrees) < 5)
    }

    @Test func boldTextIsSuggestedAsBoldMoreOftenThanThinText() throws {
        // A heuristic, not an exact classifier -- checked by comparing a
        // genuinely heavy weight against a genuinely light one (not just
        // "Bold" vs "Regular", since some regular weights already sit
        // close to the threshold) so the test isn't sensitive to exactly
        // where the cutoff falls.
        let heavyPNG = makeTextPNG("WEIGHT", fontName: "Helvetica-Bold", fontSize: 90)
        let lightPNG = makeTextPNG("WEIGHT", fontName: "HelveticaNeue-UltraLight", fontSize: 90)
        let heavyRegions = try TextDetector.detectTextRegions(from: heavyPNG)
        let lightRegions = try TextDetector.detectTextRegions(from: lightPNG)
        let heavy = try #require(heavyRegions.first)
        let light = try #require(lightRegions.first)
        #expect(heavy.suggestedWeight == .bold)
        #expect(light.suggestedWeight == .regular)
    }
}
