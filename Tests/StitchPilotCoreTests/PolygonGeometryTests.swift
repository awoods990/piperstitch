import Testing
@testable import StitchPilotCore

struct PolygonGeometryTests {
    @Test func pointInsideSquareIsInside() {
        let square = [Point2D(0, 0), Point2D(10, 0), Point2D(10, 10), Point2D(0, 10)]
        #expect(PolygonGeometry.pointInPolygon(Point2D(5, 5), polygon: square))
    }

    @Test func pointOutsideSquareIsOutside() {
        let square = [Point2D(0, 0), Point2D(10, 0), Point2D(10, 10), Point2D(0, 10)]
        #expect(!PolygonGeometry.pointInPolygon(Point2D(15, 5), polygon: square))
        #expect(!PolygonGeometry.pointInPolygon(Point2D(5, -5), polygon: square))
    }

    /// An L-shape occupying the bottom strip plus the left strip of a
    /// 100x100 area -- a point in its "notch" (top-right quadrant) is
    /// within the shape's bounding box but genuinely outside its area.
    @Test func pointInConcaveNotchIsOutsideEvenThoughInsideBoundingBox() {
        let lShape = [
            Point2D(0, 0), Point2D(100, 0), Point2D(100, 40), Point2D(40, 40), Point2D(40, 100), Point2D(0, 100),
        ]
        #expect(!PolygonGeometry.pointInPolygon(Point2D(70, 70), polygon: lShape))
        #expect(PolygonGeometry.pointInPolygon(Point2D(20, 20), polygon: lShape)) // in the bottom strip
        #expect(PolygonGeometry.pointInPolygon(Point2D(20, 70), polygon: lShape)) // in the left strip
    }

    @Test func degeneratePolygonIsNeverInside() {
        #expect(!PolygonGeometry.pointInPolygon(Point2D(0, 0), polygon: [Point2D(0, 0), Point2D(1, 1)]))
        #expect(!PolygonGeometry.pointInPolygon(Point2D(0, 0), polygon: []))
    }

    @Test func pointInPolygonsHandlesHolesViaEvenOddRule() {
        let outer = [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)]
        let hole = [Point2D(5, 5), Point2D(15, 5), Point2D(15, 15), Point2D(5, 15)]

        // Inside the outer boundary but also inside the hole -- toggled
        // twice (even), so outside per the even-odd fill rule.
        #expect(!PolygonGeometry.pointInPolygons(Point2D(10, 10), polygons: [outer, hole]))
        // Inside the outer boundary, not inside the hole -- toggled once.
        #expect(PolygonGeometry.pointInPolygons(Point2D(2, 2), polygons: [outer, hole]))
        // Outside everything.
        #expect(!PolygonGeometry.pointInPolygons(Point2D(30, 30), polygons: [outer, hole]))
    }
}
