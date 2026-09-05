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
}
