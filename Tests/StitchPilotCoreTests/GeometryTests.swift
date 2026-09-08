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

    @Test func boundingBoxContainsAFullyEnclosedBox() {
        let outer = BoundingBox(minX: 0, minY: 0, maxX: 100, maxY: 100)
        let inner = BoundingBox(minX: 10, minY: 10, maxX: 20, maxY: 20)
        #expect(outer.contains(inner))
        #expect(!inner.contains(outer))
    }

    /// A box that merely overlaps (rubber-band selection uses this
    /// distinction directly: a shape the drag only grazes should not be
    /// selected, only one it fully encloses).
    @Test func boundingBoxDoesNotContainAMerelyOverlappingBox() {
        let a = BoundingBox(minX: 0, minY: 0, maxX: 10, maxY: 10)
        let b = BoundingBox(minX: 5, minY: 5, maxX: 15, maxY: 15)
        #expect(!a.contains(b))
        #expect(!b.contains(a))
    }

    @Test func boundingBoxContainsItselfAndTouchingEdgesCount() {
        let box = BoundingBox(minX: 0, minY: 0, maxX: 10, maxY: 10)
        #expect(box.contains(box))
        // Exactly touching the outer box's own edge still counts as fully
        // enclosed, not excluded for merely brushing the boundary.
        let flushWithEdge = BoundingBox(minX: 0, minY: 0, maxX: 10, maxY: 5)
        #expect(box.contains(flushWithEdge))
    }

    @Test func emptyBoxIsNeverContained() {
        let box = BoundingBox(minX: 0, minY: 0, maxX: 10, maxY: 10)
        #expect(!box.contains(.empty))
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
        // The (6,0) -> (6,4) gap straddles the colorChange -- the thread is
        // cut there, so it's not a real 4mm stitch; the longest *actual*
        // stitch is one of the two 3mm segments before it.
        #expect(abs(plan.maxStitchLength() - 3) <= 0.0001)
    }

    /// A colorChange (and a trim) physically cuts the thread -- the point
    /// right after one must not be measured as a continuation of the
    /// distance from whatever came before it, no matter how far apart they
    /// are. Companion to the fix verified above via `maxStitchLength()`;
    /// this checks `totalStitchLength` doesn't add that phantom gap either.
    @Test func totalStitchLengthExcludesTheGapAcrossAColorChange() {
        var plan = StitchPlan()
        plan.commands = [.jump(Point2D(0, 0)), .stitch(Point2D(3, 0)), .stitch(Point2D(6, 0)), .colorChange, .stitch(Point2D(6, 4)), .stitch(Point2D(6, 8)), .trim, .end]
        // 3 (0->3) + 3 (3->6) + 4 (6,4 -> 6,8) = 10; NOT +4 for the phantom (6,0)->(6,4) gap across colorChange.
        #expect(abs(plan.totalStitchLength - 10) <= 0.0001)
    }
}
