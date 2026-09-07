import Testing
@testable import StitchPilotCore

struct ColorQuantizerTests {
    @Test func fewerColorsThanMaxReturnsThemAllUnchanged() {
        let pixels = Array(repeating: RGBColor(hex: 0xFF0000), count: 100) + Array(repeating: RGBColor(hex: 0x0000FF), count: 50)
        let clusters = ColorQuantizer.quantize(pixels: pixels, maxColors: 8)
        #expect(clusters.count == 2)
        #expect(clusters[0].rgb == RGBColor(hex: 0xFF0000)) // most frequent first
        #expect(clusters[0].pixelCount == 100)
        #expect(clusters[1].pixelCount == 50)
    }

    @Test func reducesManyColorsToRequestedCount() {
        // Three well-separated color groups, each with some in-group noise.
        var pixels: [RGBColor] = []
        for _ in 0..<50 { pixels.append(RGBColor(hex: 0xFF0000)) }
        for _ in 0..<50 { pixels.append(RGBColor(hex: 0xFE0101)) } // near-red
        for _ in 0..<50 { pixels.append(RGBColor(hex: 0x00FF00)) }
        for _ in 0..<50 { pixels.append(RGBColor(hex: 0x01FE01)) } // near-green
        for _ in 0..<50 { pixels.append(RGBColor(hex: 0x0000FF)) }
        for _ in 0..<50 { pixels.append(RGBColor(hex: 0x0101FE)) } // near-blue

        let clusters = ColorQuantizer.quantize(pixels: pixels, maxColors: 3)
        #expect(clusters.count == 3)
        #expect(clusters.reduce(0) { $0 + $1.pixelCount } == 300)
    }

    @Test func isDeterministicAcrossRuns() {
        var pixels: [RGBColor] = []
        for i in 0..<20 {
            pixels.append(RGBColor(hex: UInt32(0x100000 * (i % 6) + 0x336699)))
        }
        let a = ColorQuantizer.quantize(pixels: pixels, maxColors: 4)
        let b = ColorQuantizer.quantize(pixels: pixels, maxColors: 4)
        #expect(a.map { $0.rgb } == b.map { $0.rgb })
        #expect(a.map { $0.pixelCount } == b.map { $0.pixelCount })
    }

    @Test func emptyInputProducesNoClusters() {
        #expect(ColorQuantizer.quantize(pixels: [], maxColors: 8).isEmpty)
    }

    /// A soft anti-aliased edge between two solid colors produces a ramp of
    /// intermediate shades -- e.g. navy fading through gray into white.
    /// Each ramp step is genuinely far from both endpoints in color space,
    /// so an unmerged quantizer happily gives it its own cluster; found via
    /// a real customer logo that came back as a swarm of small gray
    /// slivers ringing every letter. A small cluster sitting almost
    /// exactly on the line between two much larger ones should fold into
    /// whichever it's closer to, not survive as its own "color."
    @Test func antiAliasingRampBetweenTwoDominantColorsIsMergedIn() {
        var pixels: [RGBColor] = []
        pixels += Array(repeating: RGBColor(hex: 0x102340), count: 400)   // navy, dominant
        pixels += Array(repeating: RGBColor(hex: 0xFFFFFF), count: 400)   // white, dominant
        pixels += Array(repeating: RGBColor(hex: 0x8090A0), count: 20)    // a ramp step roughly midway

        let clusters = ColorQuantizer.quantize(pixels: pixels, maxColors: 8)
        #expect(clusters.map { $0.rgb }.contains(RGBColor(hex: 0x8090A0)) == false,
                "the mid-ramp gray should have been merged into navy or white, not kept as its own cluster")
        #expect(clusters.reduce(0) { $0 + $1.pixelCount } == 820, "no pixels should be dropped by merging")
    }

    /// A small cluster with a genuinely distinct hue (not a blend of the
    /// two dominant colors) must survive -- e.g. a small orange accent
    /// alongside a mostly navy-and-white logo. This is what distinguishes
    /// real anti-aliasing noise (which sits *on the line* between two
    /// dominant colors) from an intentional accent color (which doesn't).
    @Test func genuinelyDistinctSmallAccentColorIsNotMerged() {
        var pixels: [RGBColor] = []
        pixels += Array(repeating: RGBColor(hex: 0x102340), count: 400)   // navy, dominant
        pixels += Array(repeating: RGBColor(hex: 0xFFFFFF), count: 400)   // white, dominant
        pixels += Array(repeating: RGBColor(hex: 0xFF8000), count: 20)    // orange accent, off the navy-white line

        let clusters = ColorQuantizer.quantize(pixels: pixels, maxColors: 8)
        #expect(clusters.map { $0.rgb }.contains(RGBColor(hex: 0xFF8000)),
                "a genuinely distinct accent color should survive, not be merged away")
    }

    @Test func deltaEIsZeroForIdenticalColorsAndPositiveForDifferentOnes() {
        let red = RGBColor(hex: 0xFF0000)
        let blue = RGBColor(hex: 0x0000FF)
        #expect(RGBColor.deltaE(red, red) < 0.001)
        #expect(RGBColor.deltaE(red, blue) > 50)
    }
}
