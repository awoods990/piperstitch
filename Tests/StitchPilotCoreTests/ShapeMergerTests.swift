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

    /// The delete pen's basic case: a stroke along one edge of a shape
    /// should shrink it, not touch the far side.
    @Test func eraseStrokeAlongOneEdgeShrinksTheShape() throws {
        let base = square(0, 0, 10)
        // A stroke hugging the left edge, radius wide enough to bite in a
        // couple mm from x=0.
        let stroke = [Point2D(0, 1), Point2D(0, 9)]
        let reduced = try #require(ShapeMerger.subtractStroke([base], strokePoints: stroke, radiusMM: 2))
        #expect(reduced.boundingBox.minX > 0, "erasing along the left edge should push the remaining shape's left bound inward")
        #expect(reduced.boundingBox.maxX > 8, "the far (right) edge shouldn't be affected by a stroke nowhere near it")
    }

    /// Erasing every pixel of a shape (a stroke that fully covers it,
    /// generously oversized) should report nothing left to keep -- the
    /// caller (`AppState.eraseStroke`) uses this `nil` to delete the
    /// object outright rather than keeping an empty shape around.
    @Test func eraseStrokeCoveringTheWholeShapeReturnsNil() {
        let base = square(0, 0, 10)
        let stroke = [Point2D(5, 5)]
        #expect(ShapeMerger.subtractStroke([base], strokePoints: stroke, radiusMM: 20) == nil)
    }

    /// A stroke that never comes near the shape at all should leave it
    /// completely unchanged.
    @Test func eraseStrokeFarFromTheShapeLeavesItUnchanged() throws {
        let base = square(0, 0, 10)
        let stroke = [Point2D(1000, 1000), Point2D(1010, 1000)]
        let result = try #require(ShapeMerger.subtractStroke([base], strokePoints: stroke, radiusMM: 2))
        #expect(abs(result.boundingBox.width - 10) < 0.5)
        #expect(abs(result.boundingBox.height - 10) < 0.5)
    }

    @Test func eraseStrokeWithEmptyInputReturnsNil() {
        #expect(ShapeMerger.subtractStroke([], strokePoints: [Point2D(0, 0)], radiusMM: 2) == nil)
        #expect(ShapeMerger.subtractStroke([square(0, 0, 10)], strokePoints: [], radiusMM: 2) == nil)
    }

    private func ring(outer outerSize: Double, hole holeInset: Double) -> VectorShape {
        VectorShape(subPaths: [
            SubPath(points: [Point2D(0, 0), Point2D(outerSize, 0), Point2D(outerSize, outerSize), Point2D(0, outerSize)], closed: true),
            SubPath(points: [Point2D(holeInset, holeInset), Point2D(outerSize - holeInset, holeInset),
                              Point2D(outerSize - holeInset, outerSize - holeInset), Point2D(holeInset, outerSize - holeInset)], closed: true),
        ])
    }

    /// A shape with its own hole (a letterform counter -- O, A, B...)
    /// must keep that hole through a plain merge, not just when the hole
    /// happens to be the only input -- rasterizing and re-tracing without
    /// separately finding enclosed background regions silently fills a
    /// hole in, turning e.g. an "O" solid. Found directly while building
    /// the paint-tool's own "merge into the object underneath" prompt,
    /// which made this reachable far more often than the existing
    /// Merge Shapes button did. See CHANGELOG.md.
    @Test func mergeAloneStillPreservesAShapesOwnHole() throws {
        let o = ring(outer: 20, hole: 5)
        let merged = try #require(ShapeMerger.merge([o]))
        #expect(merged.subPaths.count == 2, "the hole must survive being rasterized and re-traced")
    }

    /// A brush stroke that overlaps a holed shape's *outer* boundary
    /// (filling in a gap on its outside edge, not touching the hole
    /// itself) should still keep the hole -- only the outer boundary
    /// fuses with the stroke.
    @Test func brushStrokeOverlappingAHoledShapesOuterEdgeStillPreservesTheHole() throws {
        let o = ring(outer: 20, hole: 5)
        // Starts just inside the outer edge (x=19) and extends past it (x=24).
        let stroke = [Point2D(19, 10), Point2D(24, 10)]
        let merged = try #require(ShapeMerger.mergeWithStroke([o], strokePoints: stroke, radiusMM: 2))
        #expect(merged.subPaths.count == 2, "outer boundary fuses with the stroke (1 subpath), hole stays separate (1 more)")
        #expect(merged.boundingBox.maxX > 20, "the merged shape should now extend past the original outer edge")
    }
}
