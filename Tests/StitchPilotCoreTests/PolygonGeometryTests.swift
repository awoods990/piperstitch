import Testing
import Foundation
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

    // MARK: - resampleByCountCurvatureWeighted

    /// A straight run, then a tight quarter-circle arc, then another
    /// straight run -- approximates the shape of a satin rail along a
    /// round letter's curved stroke. Curvature-weighted resampling should
    /// pack more of a fixed sample count into the curved region (measured
    /// by real, unweighted arc length) than plain even-arc-length
    /// resampling does.
    @Test func resampleByCountCurvatureWeightedPacksDenserOnATightCurve() {
        var points: [Point2D] = []
        for i in 0...10 { points.append(Point2D(Double(i), 0)) } // straight: x 0->10
        let radius = 5.0, centerX = 10.0, centerY = 5.0
        for i in 1...18 { // quarter-circle arc, radius 5mm
            let angle = -Double.pi / 2 + Double(i) / 18 * (Double.pi / 2)
            points.append(Point2D(centerX + radius * cos(angle), centerY + radius * sin(angle)))
        }
        for i in 1...10 { points.append(Point2D(15, 5 + Double(i))) } // straight: y 5->15

        let straightRunEndLength = PolygonGeometry.pathLength(Array(points[0...10]))
        let curveEndLength = PolygonGeometry.pathLength(Array(points[0...28]))

        func countInCurveRegion(_ resampled: [Point2D]) -> Int {
            var cumulative = 0.0
            var count = 0
            for i in 1..<resampled.count {
                cumulative += resampled[i - 1].distance(to: resampled[i])
                if cumulative >= straightRunEndLength, cumulative <= curveEndLength { count += 1 }
            }
            return count
        }

        let weighted = PolygonGeometry.resampleByCountCurvatureWeighted(points, count: 30, referenceLengthMM: 1.0, curvatureWeight: 3.0)
        let plain = PolygonGeometry.resampleByCount(points, count: 30)

        #expect(countInCurveRegion(weighted) > countInCurveRegion(plain),
                "curvature-weighted resampling should land more of its fixed sample count inside the curved region than plain arc-length spacing")
    }

    /// A perfectly straight line has no curvature anywhere -- weighted and
    /// plain resampling should produce (near-)identical results, not
    /// diverge for no reason.
    @Test func resampleByCountCurvatureWeightedMatchesPlainOnAStraightLine() {
        let points = (0...20).map { Point2D(Double($0), 0) }
        let weighted = PolygonGeometry.resampleByCountCurvatureWeighted(points, count: 10, referenceLengthMM: 1.0, curvatureWeight: 3.0)
        let plain = PolygonGeometry.resampleByCount(points, count: 10)
        for (w, p) in zip(weighted, plain) {
            #expect(w.distance(to: p) < 0.001)
        }
    }
}
