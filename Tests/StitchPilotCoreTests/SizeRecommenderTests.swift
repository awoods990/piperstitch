import Testing
@testable import StitchPilotCore

struct SizeRecommenderTests {
    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [
            Point2D(x, y), Point2D(x + width, y), Point2D(x + width, y + height), Point2D(x, y + height),
        ], closed: true)])
    }

    @Test func simpleBoldShapeStaysAtTheDefaultSize() {
        let shapes = [rect(0, 0, 200, 200)]
        let recommended = SizeRecommender.recommendedWidthMM(for: shapes, currentWidthMM: 100)
        #expect(recommended == 100, "a shape with no fine detail shouldn't scale up beyond the normal default")
    }

    @Test func fineDetailAlongsideABoldShapeScalesUp() {
        // A big bold square plus a thin sliver (a stroke/letter-like
        // feature) in the same artwork -- the sliver's presence should
        // pull the recommended size up well past the default so it has a
        // chance of surviving as a real stitch.
        let shapes = [rect(0, 0, 200, 200), rect(0, 205, 180, 2)]
        let recommended = SizeRecommender.recommendedWidthMM(for: shapes, currentWidthMM: 100)
        #expect(recommended > 100, "a thin real feature should push the recommendation above the default")
    }

    @Test func emptyArtworkFallsBackToTheCurrentWidth() {
        let recommended = SizeRecommender.recommendedWidthMM(for: [], currentWidthMM: 123)
        #expect(recommended == 123)
    }

    /// A single stray noise speck (far thinner than everything else) must
    /// not by itself dictate a huge recommendation -- the low-percentile
    /// approach should still be driven by the artwork's *bulk* of real
    /// content. A naive "always use the single thinnest shape" measure
    /// would drive this to the 400mm ceiling; the percentile-based
    /// approach should stay at the ordinary default instead.
    @Test func aSingleOutlierSpeckDoesNotDominateTheRecommendation() {
        var shapes: [VectorShape] = []
        for i in 0..<20 {
            shapes.append(rect(Double(i) * 20, 0, 20, 20)) // 20 ordinary 20x20 squares in a row
        }
        shapes.append(rect(50, 25, 5, 0.5)) // one stray, far-thinner-than-everything-else speck
        let recommended = SizeRecommender.recommendedWidthMM(for: shapes, currentWidthMM: 100)
        #expect(recommended == 100, "a single outlier speck shouldn't drag the recommendation up on its own")
    }

    @Test func recommendationIsClampedToAReasonableMaximum() {
        // Every shape is proportionally razor-thin relative to the overall
        // artwork -- genuinely detail-dense artwork, not a single outlier --
        // so the raw formula would ask for a huge size; the ceiling should
        // still cap it at something sane rather than recommending anything
        // truly absurd.
        var shapes: [VectorShape] = []
        for i in 0..<20 {
            shapes.append(rect(Double(i) * 50, 0, 45, 0.3))
        }
        let recommended = SizeRecommender.recommendedWidthMM(for: shapes, currentWidthMM: 100)
        #expect(recommended == 400, "extremely fine, artwork-wide detail should clamp to the ceiling, not run away unbounded")
    }

    /// A degenerate shape (zero area or zero-length principal axis) has no
    /// measurable width at all -- falls back to `currentWidthMM` rather
    /// than crashing or producing a nonsense value from a division by zero.
    @Test func degenerateArtworkFallsBackToTheCurrentWidth() {
        let zeroArea = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(20, 0)], closed: true)])
        let recommended = SizeRecommender.recommendedWidthMM(for: [zeroArea], currentWidthMM: 77)
        #expect(recommended == 77)
    }
}
