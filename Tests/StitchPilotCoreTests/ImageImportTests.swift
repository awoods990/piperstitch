import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import StitchPilotCore

struct ImageImportTests {
    /// Renders a synthetic PNG in-memory (a black square on a white
    /// background) so this test needs no external asset — spec §66 wants
    /// programmatically generated test artwork specifically to avoid
    /// copyright concerns.
    private func makePNG(size: Int = 100, drawSquare squareRect: CGRect) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
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
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
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
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
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
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 15, y: 15, width: 20, height: 20))

        let result = try ImageImporter.importShapes(from: encodePNG(context.makeImage()!))
        #expect(result.shapes.count == 1)
        #expect(abs(result.shapes[0].boundingBox.width - 20) <= 2.0)
    }
}
