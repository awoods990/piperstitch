import Testing
@testable import StitchPilotCore

struct PolylineSimplifyTests {
    @Test func collinearPointsAreRemoved() {
        let points = (0...20).map { Point2D(Double($0), 0) } // a perfectly straight line, 21 points
        let simplified = PolylineSimplify.douglasPeucker(points, epsilon: 0.1)
        #expect(simplified.count == 2, "a straight line should simplify to just its two endpoints")
        #expect(simplified.first == Point2D(0, 0))
        #expect(simplified.last == Point2D(20, 0))
    }

    @Test func significantCornerIsKept() {
        var points = (0...10).map { Point2D(Double($0), 0) }
        points += (1...10).map { Point2D(10, Double($0)) }
        let simplified = PolylineSimplify.douglasPeucker(points, epsilon: 0.1)
        #expect(simplified.count == 3, "an L-shape should keep exactly its two endpoints plus the corner")
        #expect(simplified.contains(Point2D(10, 0)))
    }

    @Test func doesNotAlterShortPolylines() {
        let points = [Point2D(0, 0), Point2D(1, 1)]
        #expect(PolylineSimplify.douglasPeucker(points, epsilon: 0.1) == points)
    }

    /// Exact Douglas-Peucker is worst-case O(n²); a raster-traced pixel
    /// boundary's near-collinear staircase steps are exactly the kind of
    /// input that triggers it (a real 126,017-point boundary from a single
    /// tiny image fragment took minutes here alone — see CHANGELOG.md).
    /// A zigzag staircase of many points is a reasonable stand-in for that
    /// shape; this just needs to *finish* (the test would hang indefinitely
    /// on the old unbounded recursive implementation) and still produce a
    /// sane, small simplification.
    @Test func largeStaircaseInputFinishesQuicklyAndSimplifiesWell() {
        var points: [Point2D] = []
        for i in 0..<40000 {
            points.append(Point2D(Double(i / 2), Double(i % 2)))
        }
        let simplified = PolylineSimplify.douglasPeucker(points, epsilon: 0.5)
        // The real guarantee this test is protecting is that the call
        // *returns promptly at all* (it would hang indefinitely on the old
        // unbounded recursive implementation) and that its output stays
        // bounded by the pre-decimation cap regardless of input size.
        #expect(simplified.count < 3000, "output should never exceed the pre-decimation cap")
        #expect(simplified.count < points.count, "should still be a real reduction from the raw input")
        #expect(simplified.first == points.first)
        #expect(simplified.last == points.last)
    }
}
