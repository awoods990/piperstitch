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

    @Test func deltaEIsZeroForIdenticalColorsAndPositiveForDifferentOnes() {
        let red = RGBColor(hex: 0xFF0000)
        let blue = RGBColor(hex: 0x0000FF)
        #expect(RGBColor.deltaE(red, red) < 0.001)
        #expect(RGBColor.deltaE(red, blue) > 50)
    }
}
