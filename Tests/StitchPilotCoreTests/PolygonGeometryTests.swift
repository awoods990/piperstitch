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

    /// A degenerate one-point "rail" (a satin column tip collapsed to a
    /// single point) used to break this function's own documented
    /// contract -- returning the lone input point unchanged instead of
    /// `count + 1` points -- which crashed `SatinColumnGenerator.
    /// isTwisted`/`crossingsEscapeTheShape` outright when they indexed it
    /// point-for-point against a normal sibling rail resampled to the full
    /// count. Found against a real logo (`LIBBi New Logo.png`) that
    /// crashed the whole digitizing pipeline. See CHANGELOG.md.
    @Test func resampleByCountHonorsItsContractForADegenerateSinglePointInput() {
        let single = [Point2D(5, 5)]
        let result = PolygonGeometry.resampleByCount(single, count: 20)
        #expect(result.count == 21, "must still return count + 1 points, not the lone input point unchanged")
        #expect(result.allSatisfy { $0.distance(to: Point2D(5, 5)) < 0.0001 })
    }

    @Test func resampleByCountOnEmptyInputStaysEmpty() {
        let result = PolygonGeometry.resampleByCount([], count: 20)
        #expect(result.isEmpty, "nothing to repeat -- should not fabricate points from no input")
    }

    // MARK: - clipPolygonToRect

    @Test func clipRectFullyInsideWindowIsUnchangedInArea() {
        let square = [Point2D(2, 2), Point2D(8, 2), Point2D(8, 8), Point2D(2, 8)]
        let clipped = PolygonGeometry.clipPolygonToRect(square, minX: 0, minY: 0, maxX: 10, maxY: 10)
        #expect(abs(PolygonGeometry.signedArea(clipped)) == 36) // fully inside the window -- unchanged, 6x6
    }

    @Test func clipRectPartiallyOutsideWindowIsTrimmedToTheOverlap() {
        let square = [Point2D(5, 5), Point2D(15, 5), Point2D(15, 15), Point2D(5, 15)]
        let clipped = PolygonGeometry.clipPolygonToRect(square, minX: 0, minY: 0, maxX: 10, maxY: 10)
        let box = BoundingBox(points: clipped)
        // The true overlap of [5,15]x[5,15] with the [0,10]x[0,10] window is x:[5,10], y:[5,10].
        #expect(abs(box.minX - 5) < 0.001 && abs(box.minY - 5) < 0.001)
        #expect(abs(box.maxX - 10) < 0.001 && abs(box.maxY - 10) < 0.001)
    }

    @Test func clipRectEntirelyOutsideWindowProducesNothing() {
        let square = [Point2D(20, 20), Point2D(30, 20), Point2D(30, 30), Point2D(20, 30)]
        let clipped = PolygonGeometry.clipPolygonToRect(square, minX: 0, minY: 0, maxX: 10, maxY: 10)
        #expect(clipped.count < 3, "no meaningful overlap should produce an empty (or degenerate) result")
    }

    /// A concave "L" shape, clipped by a window that only covers its
    /// bottom-left leg -- confirms the clip correctly excludes the part
    /// of the shape outside the window without needing the subject
    /// polygon to be convex.
    @Test func clipConcaveLShapeToOneLeg() {
        let lShape = [
            Point2D(0, 0), Point2D(10, 0), Point2D(10, 4), Point2D(4, 4), Point2D(4, 10), Point2D(0, 10),
        ]
        let clipped = PolygonGeometry.clipPolygonToRect(lShape, minX: 0, minY: 0, maxX: 4, maxY: 4)
        let box = BoundingBox(points: clipped)
        #expect(!clipped.isEmpty)
        #expect(box.maxX <= 4.001 && box.maxY <= 4.001)
        #expect(abs(PolygonGeometry.signedArea(clipped)) > 14) // most of the 4x4 corner cell
    }
}
