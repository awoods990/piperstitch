import Testing
import Foundation
@testable import StitchPilotCore

/// `CoverageBackstop`: the engine asking, for once, whether what it
/// generated actually covers the shape it was given.
struct CoverageBackstopTests {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [Point2D(x, y), Point2D(x + w, y), Point2D(x + w, y + h), Point2D(x, y + h)], closed: true)])
    }

    /// Rows across `box`, 0.4 mm apart, stopping `short` millimetres from
    /// its right-hand edge — a column that finished early.
    private func rows(over box: BoundingBox, stoppingShortBy short: Double) -> [[Point2D]] {
        var runs: [[Point2D]] = []
        var y = box.minY + 0.2
        while y < box.maxY {
            runs.append([Point2D(box.minX + 0.2, y), Point2D(box.maxX - short, y)])
            y += 0.4
        }
        return runs
    }

    @Test func stitchingThatStopsShortLeavesAPocketTheBackstopFinds() {
        let shape = rect(0, 0, 20, 10)
        let missing = CoverageBackstop.missingRegions(in: shape, covered: rows(over: shape.boundingBox, stoppingShortBy: 4))
        #expect(!missing.isEmpty, "four millimetres of bare fabric is not nothing")
        guard let pocket = missing.first else { return }
        let box = pocket.boundingBox
        #expect(box.minX > 14, "and it is the strip at the right-hand end")
        #expect(box.height > 8)
    }

    @Test func stitchingThatCoversItsShapeLeavesNothingToDo() {
        let shape = rect(0, 0, 20, 10)
        #expect(CoverageBackstop.missingRegions(in: shape, covered: rows(over: shape.boundingBox, stoppingShortBy: 0.2)).isEmpty)
    }

    @Test func aGapTooSmallToSeeIsLeftAlone() {
        let shape = rect(0, 0, 20, 10)
        // Half a millimetre short: under a thread's width once the stitches
        // spread, and sewing it would only add density at the edge.
        #expect(CoverageBackstop.missingRegions(in: shape, covered: rows(over: shape.boundingBox, stoppingShortBy: 0.5)).isEmpty)
    }

    @Test func aHoleInTheShapeIsNotMistakenForAGap() {
        // A ring: the middle is not meant to be sewn, and a backstop that
        // filled it would close every letter's counter.
        let outer = SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)], closed: true)
        let hole = SubPath(points: [Point2D(6, 6), Point2D(14, 6), Point2D(14, 14), Point2D(6, 14)], closed: true)
        let ring = VectorShape(subPaths: [outer, hole])
        var runs: [[Point2D]] = []
        var y = 0.2
        while y < 20 {
            if y < 6 || y > 14 {
                runs.append([Point2D(0.2, y), Point2D(19.8, y)])
            } else {
                runs.append([Point2D(0.2, y), Point2D(5.8, y)])
                runs.append([Point2D(14.2, y), Point2D(19.8, y)])
            }
            y += 0.4
        }
        let missing = CoverageBackstop.missingRegions(in: ring, covered: runs)
        for pocket in missing {
            let box = pocket.boundingBox
            let insideHole = box.minX >= 5.5 && box.maxX <= 14.5 && box.minY >= 5.5 && box.maxY <= 14.5
            #expect(!insideHole, "the counter is not a gap")
        }
    }
}
