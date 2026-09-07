import Testing
@testable import StitchPilotCore

struct ShapeMergerTests {
    private func square(_ x: Double, _ y: Double, _ size: Double) -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [
            Point2D(x, y), Point2D(x + size, y), Point2D(x + size, y + size), Point2D(x, y + size),
        ], closed: true)])
    }

    /// Two overlapping squares should merge into one connected shape
    /// spanning both — the whole point of the tool is joining fragments
    /// that visually belong together.
    @Test func overlappingShapesMergeIntoOneConnectedShape() throws {
        let a = square(0, 0, 10)
        let b = square(5, 5, 10)
        let merged = try #require(ShapeMerger.merge([a, b]))
        #expect(merged.subPaths.count == 1, "overlapping shapes should trace as a single connected outline")
        let box = merged.boundingBox
        #expect(abs(box.minX - 0) < 1)
        #expect(abs(box.minY - 0) < 1)
        #expect(abs(box.maxX - 15) < 1)
        #expect(abs(box.maxY - 15) < 1)
    }

    /// Two far-apart shapes that never touch shouldn't be silently dropped
    /// or merged into a bridging blob -- the result keeps both regions, as
    /// separate subpaths of one object, so nothing is lost even though
    /// they don't form one connected outline.
    @Test func nonTouchingShapesAreKeptAsSeparateSubpathsOfOneShape() throws {
        let a = square(0, 0, 5)
        let b = square(100, 100, 5)
        let merged = try #require(ShapeMerger.merge([a, b]))
        #expect(merged.subPaths.count == 2)
        let totalArea = merged.boundingBox
        #expect(totalArea.width > 90, "the combined bounding box should still span both squares")
    }

    @Test func emptyInputReturnsNil() {
        #expect(ShapeMerger.merge([]) == nil)
        #expect(ShapeMerger.merge([VectorShape(subPaths: [])]) == nil)
    }

    /// A brush stroke overlapping an existing shape should extend it into
    /// one connected region, not just sit alongside it -- this is the
    /// "paint in more coverage" use case.
    @Test func brushStrokeExtendsAnOverlappingShapeIntoOneRegion() throws {
        let base = square(0, 0, 10)
        // Stroke starts inside the square and extends well past its right edge.
        let stroke = [Point2D(5, 5), Point2D(20, 5)]
        let merged = try #require(ShapeMerger.mergeWithStroke([base], strokePoints: stroke, radiusMM: 3))
        #expect(merged.subPaths.count == 1, "a stroke overlapping the shape should join it into one region")
        #expect(merged.boundingBox.maxX > 15, "the merged shape should now extend past the original square's edge")
    }

    /// A brush stroke with no existing shapes to join should still produce
    /// a paintable shape on its own -- painting on empty canvas creates new
    /// coverage, it doesn't require an existing selection.
    @Test func brushStrokeAloneProducesAShape() throws {
        let stroke = [Point2D(0, 0), Point2D(10, 0), Point2D(10, 10)]
        let merged = try #require(ShapeMerger.mergeWithStroke([], strokePoints: stroke, radiusMM: 2))
        #expect(!merged.subPaths.isEmpty)
    }
}
