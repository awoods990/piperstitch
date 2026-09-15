import Foundation
import Testing
@testable import StitchPilotCore

/// The cover fill travels along its own edge instead of trimming, and
/// pinprick holes don't split it -- `TatamiFillGenerator.ConnectorRouting`.
struct FillConnectorRoutingTests {
    private func params() -> StitchGenerationParameters {
        var p = StitchGenerationParameters()
        p.underlayType = UnderlayType.none
        p.pullCompensationMM = 0; p.pushCompensationMM = 0
        p.fillJitterFraction = 0
        return p
    }

    /// Every stitch midpoint of `points` lies inside `polygons` grown by `tolerance`.
    private func staysInside(_ points: [Point2D], polygons: [[Point2D]], toleranceMM: Double) -> Int {
        let grown = polygons.enumerated().map { i, poly in PolygonGeometry.offsetPolygon(poly, by: i == 0 ? -toleranceMM : toleranceMM) }
        var outside = 0
        for (p, q) in zip(points, points.dropFirst()) {
            let mid = Point2D((p.x + q.x) / 2, (p.y + q.y) / 2)
            if !PolygonGeometry.pointInPolygons(mid, polygons: grown) { outside += 1 }
        }
        return outside
    }

    @Test func aConcaveFillSewsAsOneRunWithTravelAlongTheEdge() {
        // A "C": rows at 0° split into two strips through the mouth.
        let c = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 8), Point2D(8, 8), Point2D(8, 22), Point2D(30, 22), Point2D(30, 30), Point2D(0, 30),
        ], closed: true)])
        var p = params()
        p.fillAngleDegrees = 0
        let broken = TatamiFillGenerator.generateRuns(for: c, parameters: p, breakThresholdMM: 5, routing: .none)
        let routed = TatamiFillGenerator.generateRuns(for: c, parameters: p, breakThresholdMM: 5, routing: .edge)
        #expect(broken.count >= 2, "without routing the mouth of the C is a break")
        #expect(routed.count == 1, "with edge routing the C sews as one run, got \(routed.count)")
        // The travel never crosses the mouth.
        let outside = staysInside(routed[0], polygons: c.subPaths.map { $0.points }, toleranceMM: 0.3)
        #expect(outside == 0, "\(outside) stitches leave the C")
        // The connector across the mouth is 14mm straight; routed it is longer.
        #expect(routed[0].count > broken.reduce(0) { $0 + $1.count })
    }

    @Test func pinprickHolesDoNotSplitTheFill() {
        var paths = [SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)], closed: true)]
        // Three 0.6mm pinpricks a raster trace might leave.
        for x in [5.0, 10.0, 15.0] {
            paths.append(SubPath(points: [Point2D(x, 10), Point2D(x + 0.6, 10), Point2D(x + 0.6, 10.6), Point2D(x, 10.6)], closed: true))
        }
        let shape = VectorShape(subPaths: paths)
        var p = params(); p.fillAngleDegrees = 0
        let runs = TatamiFillGenerator.generateRuns(for: shape, parameters: p, breakThresholdMM: 5, routing: .none)
        #expect(runs.count == 1, "pinpricks split the fill into \(runs.count) runs")
        // A real 3mm hole still counts.
        let real = VectorShape(subPaths: [paths[0], SubPath(points: [Point2D(8, 8), Point2D(12, 8), Point2D(12, 12), Point2D(8, 12)], closed: true)])
        let realRuns = TatamiFillGenerator.generateRuns(for: real, parameters: p, breakThresholdMM: 1, routing: .none)
        #expect(realRuns.count >= 2)
    }

    @Test func routeFollowsTheExactBoundaryWhenTheInsetOneSelfIntersects() {
        // A notch 1.2mm wide: a 1mm inset boundary folds over itself there.
        let notched = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 10), Point2D(10.6, 10), Point2D(10.6, 2), Point2D(9.4, 2), Point2D(9.4, 10), Point2D(0, 10),
        ], closed: true)])
        let polys = notched.subPaths.map { $0.points }
        let route = TatamiFillGenerator.routeAlongBoundary(from: Point2D(9, 9), to: Point2D(11, 9), polygons: polys, insetMM: 1.0)
        let r = try! #require(route)
        #expect(PolygonGeometry.pathLength(r) > 14, "goes round the notch, not across it: \(PolygonGeometry.pathLength(r))")
        for (p, q) in zip(r, r.dropFirst()) {
            let mid = Point2D((p.x + q.x) / 2, (p.y + q.y) / 2)
            let grown = [PolygonGeometry.offsetPolygon(polys[0], by: -0.05)]
            #expect(PolygonGeometry.pointInPolygons(mid, polygons: grown), "leg \(p)->\(q) leaves the shape")
        }
    }
}
