import Foundation
import Testing
@testable import StitchPilotCore

/// Mitre corners on satin columns -- `SatinCorners`, docs/WILCOM_MANUAL_REVIEW.md A4.
struct SatinCornersTests {
    /// An "L": a horizontal bar (0...40 × 0...6) and a vertical bar
    /// (34...40 × 0...30). Inside vertex (34, 6), outside vertex (40, 0).
    private let lShape = VectorShape(subPaths: [SubPath(points: [
        Point2D(0, 0), Point2D(40, 0), Point2D(40, 30), Point2D(34, 30), Point2D(34, 6), Point2D(0, 6),
    ], closed: true)])
    private let innerVertex = Point2D(34, 6)
    private let outerVertex = Point2D(40, 0)

    private func params(mitre: Bool) -> StitchGenerationParameters {
        var p = StitchGenerationParameters()
        p.satinDensityMM = 0.4
        p.pullCompensationMM = 0
        p.pushCompensationMM = 0
        p.satinAutoSplitMM = 0
        p.satinShortenBelowFraction = 0
        p.satinMitreCorners = mitre
        return p
    }

    private func penetrationsNear(_ point: Point2D, in stitches: [Point2D], radiusMM: Double) -> Int {
        stitches.filter { $0.distance(to: point) <= radiusMM }.count
    }

    /// Mean sideways lean (|Δx|) of the crossings whose both ends sit on
    /// the horizontal bar well away from the corner.
    private func horizontalBarLean(_ stitches: [Point2D]) -> Double {
        var leans: [Double] = []
        // The zigzag is a0 b0 a1 b1 ...: even-indexed pairs are the crossings.
        for i in stride(from: 0, to: stitches.count - 1, by: 2) {
            let p = stitches[i], q = stitches[i + 1]
            guard p.x > 5, p.x < 28, q.x > 5, q.x < 28, abs(p.y - q.y) > 5 else { continue }
            leans.append(abs(p.x - q.x))
        }
        return leans.isEmpty ? .nan : leans.reduce(0, +) / Double(leans.count)
    }

    @Test func mitreRemovesTheLeanFromTheLegs() throws {
        let leaning = try SatinColumnGenerator.generatePartial(for: lShape, parameters: params(mitre: false))
        let mitred = try SatinColumnGenerator.generatePartial(for: lShape, parameters: params(mitre: true))
        #expect(!leaning.isEmpty && !mitred.isEmpty)
        // Proportional matching spreads the outer rail's extra corner
        // length over the whole column: every crossing slants.
        #expect(horizontalBarLean(leaning) > 1.0, "the plain algorithm should lean on an L, got \(horizontalBarLean(leaning))mm")
        // With the corner square set aside, each leg's crossings are
        // perpendicular to its own bar.
        #expect(horizontalBarLean(mitred) < 0.05, "mitred legs should be perpendicular, got \(horizontalBarLean(mitred))mm")
        // The mitre's tip tapers below `minSatinWidthMM` on purpose and
        // must stay satin -- never a centerline running stitch.
        let tipStitches = mitred.filter { $0.distance(to: outerVertex) < 1.5 }
        #expect(tipStitches.contains { $0.x > 39.9 }, "tip crossings still land on the outer rail")
    }

    @Test func mitreStaysInsideTheShapeAndReachesTheTip() throws {
        let mitred = try SatinColumnGenerator.generatePartial(for: lShape, parameters: params(mitre: true))
        let polygon = lShape.subPaths[0].points
        var outside = 0
        for (p, q) in zip(mitred, mitred.dropFirst()) {
            for step in 1...3 {
                let t = Double(step) / 4
                let sample = Point2D(p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t)
                // Allow a hair of tolerance for points exactly on the boundary.
                let inset = Point2D(sample.x - (sample.x - 37) * 0.002, sample.y - (sample.y - 15) * 0.002)
                if !PolygonGeometry.pointInPolygon(inset, polygon: polygon) { outside += 1 }
            }
        }
        #expect(outside == 0, "\(outside) stitch samples left the L")
        #expect(penetrationsNear(outerVertex, in: mitred, radiusMM: 1.0) >= 1, "the mitre's tip stitch reaches the outside vertex")
    }

    @Test func mitreLegsRunParallelToTheirOwnBar() throws {
        let mitred = try SatinColumnGenerator.generatePartial(for: lShape, parameters: params(mitre: true))
        // Stitches whose midpoint sits in the corner square (34...40 × 0...6)
        // should be near-vertical (horizontal bar's crossings) or
        // near-horizontal (vertical bar's), never diagonal fan spokes.
        var diagonal = 0, total = 0
        for (p, q) in zip(mitred, mitred.dropFirst()) {
            let mid = Point2D((p.x + q.x) / 2, (p.y + q.y) / 2)
            guard mid.x > 34.5, mid.x < 39.5, mid.y > 0.5, mid.y < 5.5, p.distance(to: q) > 1.0 else { continue }
            total += 1
            let angle = abs(atan2(q.y - p.y, q.x - p.x)) * 180 / .pi
            let offAxis = min(angle, abs(angle - 90), abs(angle - 180))
            if offAxis > 20 { diagonal += 1 }
        }
        #expect(total > 6)
        #expect(diagonal * 4 <= total, "mostly axis-aligned crossings in the corner square, got \(diagonal)/\(total) diagonal")
    }

    @Test func gentleBendsAreLeftAlone() throws {
        // A 20° kink is well under the mitre threshold: identical output.
        var pts: [Point2D] = []
        pts.append(Point2D(0, 0)); pts.append(Point2D(30, 0)); pts.append(Point2D(58, 10)); pts.append(Point2D(56, 15.7)); pts.append(Point2D(30, 6)); pts.append(Point2D(0, 6))
        let bend = VectorShape(subPaths: [SubPath(points: pts, closed: true)])
        let a = try SatinColumnGenerator.generatePartial(for: bend, parameters: params(mitre: false))
        let b = try SatinColumnGenerator.generatePartial(for: bend, parameters: params(mitre: true))
        #expect(a == b)
    }

    @Test func straightColumnIsUntouched() throws {
        let rect = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(40, 0), Point2D(40, 5), Point2D(0, 5)], closed: true)])
        let a = try SatinColumnGenerator.generatePartial(for: rect, parameters: params(mitre: false))
        let b = try SatinColumnGenerator.generatePartial(for: rect, parameters: params(mitre: true))
        #expect(a == b)
    }
}
