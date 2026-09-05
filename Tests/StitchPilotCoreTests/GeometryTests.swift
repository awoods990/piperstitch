import Testing
@testable import StitchPilotCore

struct GeometryTests {
    @Test func boundingBoxUnion() {
        let a = BoundingBox(minX: 0, minY: 0, maxX: 10, maxY: 10)
        let b = BoundingBox(minX: 5, minY: -5, maxX: 20, maxY: 5)
        let u = a.union(b)
        #expect(u.minX == 0); #expect(u.minY == -5)
        #expect(u.maxX == 20); #expect(u.maxY == 10)
    }

    @Test func emptyBoundingBoxUnionIsIdentity() {
        let a = BoundingBox.empty
        let b = BoundingBox(minX: 1, minY: 1, maxX: 2, maxY: 2)
        #expect(a.union(b) == b)
        #expect(b.union(a) == b)
    }

    @Test func boundingBoxCenter() {
        let box = BoundingBox(minX: 0, minY: 10, maxX: 20, maxY: 30)
        #expect(box.center == Point2D(10, 20))
    }

    @Test func subPathLengthOpenVsClosed() {
        let open = SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 10)], closed: false)
        #expect(abs(open.length - 20) <= 0.0001)

        let closed = SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 10)], closed: true)
        #expect(abs(closed.length - (20 + 10 * 2.0.squareRoot())) <= 0.0001)
    }

    @Test func stitchPlanStatistics() {
        var plan = StitchPlan()
        plan.commands = [.jump(Point2D(0, 0)), .stitch(Point2D(3, 0)), .stitch(Point2D(6, 0)), .colorChange, .stitch(Point2D(6, 4)), .trim, .end]
        #expect(plan.stitchCount == 3)
        #expect(plan.colorChangeCount == 1)
        #expect(plan.trimCount == 1)
        #expect(abs(plan.maxStitchLength() - 4) <= 0.0001)
    }
}
