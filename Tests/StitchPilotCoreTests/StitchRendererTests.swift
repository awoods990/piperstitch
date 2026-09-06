import Testing
import CoreGraphics
@testable import StitchPilotCore

struct StitchRendererTests {
    /// Reads the RGBA bytes of one pixel from a rendered image, given a
    /// design-space point and the same `widthMM`/`heightMM`/`pixelsPerMM`
    /// the image was rendered with (accounting for the renderer's Y-flip).
    private func pixel(at point: Point2D, in image: CGImage, widthMM: Double, heightMM: Double, pixelsPerMM: Double) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bytesPerRow = image.bytesPerRow
        let px = Int((point.x * pixelsPerMM).rounded())
        let py = Int((heightMM * pixelsPerMM - point.y * pixelsPerMM).rounded())
        guard px >= 0, px < image.width, py >= 0, py < image.height else { return nil }
        let offset = py * bytesPerRow + px * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    /// A trim physically cuts the thread; the run that follows a
    /// colorChange must not be drawn as if it continues straight from
    /// wherever the previous color's thread ended, no matter how far apart
    /// the two runs are. A real bug left `lastPoint` set across
    /// `.colorChange`/`.trim`, drawing exactly that spurious bridging line
    /// in the new run's color — found while testing the realistic preview
    /// feature against `TestArtwork/multi_color_badge.svg` (see
    /// CHANGELOG.md).
    @Test func colorChangeDoesNotDrawABridgingLineAcrossTheGap() throws {
        var plan = StitchPlan()
        plan.commands = [
            .jump(Point2D(1, 1)), .stitch(Point2D(1, 1)), .stitch(Point2D(2, 1)),
            .trim, .colorChange,
            .stitch(Point2D(18, 18)), .stitch(Point2D(19, 18)),
            .end,
        ]
        let colors: [ThreadColor] = [.generic(RGBColor(hex: 0xFF0000), name: "Red"), .generic(RGBColor(hex: 0x0000FF), name: "Blue")]
        let options = StitchRenderer.Options(pixelsPerMM: 10)
        let image = try #require(StitchRenderer.render(plan, widthMM: 20, heightMM: 20, colors: colors, options: options))

        // The midpoint of the straight line between the two runs should be
        // plain background -- not stroked in either thread color -- since
        // no physical thread connects them.
        let mid = try #require(pixel(at: Point2D(10, 10), in: image, widthMM: 20, heightMM: 20, pixelsPerMM: 10))
        #expect(mid.r > 200 && mid.g > 200 && mid.b > 200) // background is a light off-white
    }
}
