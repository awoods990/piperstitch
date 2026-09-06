import Testing
@testable import StitchPilotCore

struct ObjectSequencerTests {
    private func square(_ minX: Double, _ minY: Double, _ size: Double, name: String, color: UInt32 = 0x000000) -> EmbroideryObject {
        let shape = VectorShape(subPaths: [SubPath(points: [
            Point2D(minX, minY), Point2D(minX + size, minY), Point2D(minX + size, minY + size), Point2D(minX, minY + size),
        ], closed: true)])
        return EmbroideryObject(name: name, shape: shape, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: color)))
    }

    @Test func movesContainingObjectBeforeTheObjectItContains() {
        // Small foreground square authored first, large background square second -- backwards.
        let inner = square(45, 45, 10, name: "inner") // 45...55
        let outer = square(0, 0, 100, name: "outer")  // 0...100, fully contains inner

        let sequenced = ObjectSequencer.sequence([inner, outer])
        #expect(sequenced.map { $0.name } == ["outer", "inner"])
    }

    @Test func leavesAlreadyCorrectOrderUnchanged() {
        let outer = square(0, 0, 100, name: "outer")
        let inner = square(45, 45, 10, name: "inner")
        let sequenced = ObjectSequencer.sequence([outer, inner])
        #expect(sequenced.map { $0.name } == ["outer", "inner"])
    }

    @Test func doesNotReorderUnrelatedObjects() {
        // Two disjoint squares, neither containing the other -- order must be preserved exactly.
        let a = square(0, 0, 10, name: "a")
        let b = square(50, 50, 5, name: "b") // smaller, but not contained by a -- no relationship
        let sequenced = ObjectSequencer.sequence([a, b])
        #expect(sequenced.map { $0.name } == ["a", "b"])
    }

    @Test func handlesTransitiveNesting() {
        // Innermost authored first, then middle, then outermost -- fully backwards three levels deep.
        let innermost = square(45, 45, 5, name: "innermost")
        let middle = square(30, 30, 40, name: "middle")
        let outermost = square(0, 0, 100, name: "outermost")

        let sequenced = ObjectSequencer.sequence([innermost, middle, outermost])
        #expect(sequenced.map { $0.name } == ["outermost", "middle", "innermost"])
    }

    @Test func nearIdenticalSizesAreNotReordered() {
        // Two overlapping squares of almost the same size (one barely
        // "contains" the other due to a fractional size difference) --
        // shouldn't trigger reordering from float noise alone.
        let a = square(0, 0, 10.001, name: "a")
        let b = square(0, 0, 10.0, name: "b")
        let sequenced = ObjectSequencer.sequence([b, a])
        #expect(sequenced.map { $0.name } == ["b", "a"])
    }

    @Test func groupsSameColorObjectsToMinimizeColorChanges() {
        // Red, blue, red, authored in that order, with no containment
        // relationship between any of them -- free to reorder. Grouping the
        // two reds together drops the design from 2 color changes to 1.
        let red1 = square(0, 0, 5, name: "red1", color: 0xFF0000)
        let blue = square(50, 0, 5, name: "blue", color: 0x0000FF)
        let red2 = square(0, 50, 5, name: "red2", color: 0xFF0000)

        let sequenced = ObjectSequencer.sequence([red1, blue, red2])
        #expect(sequenced.map { $0.name } == ["red1", "red2", "blue"])
    }

    @Test func prefersNearestSameColorCandidateToMinimizeJumpDistance() {
        // Three same-color, mutually non-containing squares; "b" is
        // authored second but is far away, while "c" (authored third) sits
        // right next to "a". A jump-minimizing sequence visits c before b.
        let a = square(0, 0, 10, name: "a")
        let b = square(100, 100, 10, name: "b")
        let c = square(20, 20, 10, name: "c")

        let sequenced = ObjectSequencer.sequence([a, b, c])
        #expect(sequenced.map { $0.name } == ["a", "c", "b"])
    }

    @Test func containmentStillWinsOverColorGrouping() {
        // "outer" (blue) must be sewn before "inner" (black) because it
        // contains it, even though there's an unrelated free-standing black
        // square that color-grouping alone would otherwise pull forward.
        let inner = square(45, 45, 10, name: "inner", color: 0x000000)
        let freeBlack = square(200, 200, 5, name: "freeBlack", color: 0x000000)
        var outer = square(0, 0, 100, name: "outer")
        outer.threadColor = .generic(RGBColor(hex: 0x0000FF))

        let sequenced = ObjectSequencer.sequence([inner, freeBlack, outer])
        let outerPos = sequenced.firstIndex { $0.name == "outer" }!
        let innerPos = sequenced.firstIndex { $0.name == "inner" }!
        #expect(outerPos < innerPos)
    }

    @Test func trueContainmentIgnoresBoundingBoxCoincidence() {
        // An L-shape occupying the bottom strip (y 0-40) plus the left
        // strip (x 0-40) of a 100x100 area -- its bounding box is the full
        // 100x100 square, but the top-right 60x60 quadrant (x 40-100,
        // y 40-100) is actually outside its area (the "notch").
        let lShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(100, 0), Point2D(100, 40), Point2D(40, 40), Point2D(40, 100), Point2D(0, 100),
        ], closed: true)])
        let lObject = EmbroideryObject(name: "lShape", shape: lShape, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0x000000)))
        let notchSquare = square(60, 60, 10, name: "notchSquare") // sits in the L's bounding box, but in its notch

        // Authored with the notch square first. A bounding-box-only check
        // would (wrongly) treat the L as containing it and reorder the L
        // first; true polygon containment finds no relationship, so
        // authoring order is left untouched.
        let sequenced = ObjectSequencer.sequence([notchSquare, lObject])
        #expect(sequenced.map { $0.name } == ["notchSquare", "lShape"])
    }

    @Test func sequenceGeneratedReversesPathForCloserApproach() {
        let color: UInt32 = 0x000000
        let first = square(0, 0, 1, name: "first", color: color) // shape geometry is irrelevant here; only points matter
        let second = square(0, 0, 1, name: "second", color: color)

        // "first" ends at (10,0). "second" runs (0,5) -> (10,5): entering
        // from its far end (0,5) is an 11.18mm reach, but entering from its
        // near end (10,5) is only 5mm -- sewing it end-first is closer.
        let items = [
            (object: first, points: [Point2D(0, 0), Point2D(10, 0)]),
            (object: second, points: [Point2D(0, 5), Point2D(10, 5)]),
        ]
        let sequenced = ObjectSequencer.sequenceGenerated(items)
        #expect(sequenced.map { $0.object.name } == ["first", "second"])
        #expect(sequenced[1].points == [Point2D(10, 5), Point2D(0, 5)])
    }

    @Test func sequenceGeneratedDoesNotReverseWhenAlreadyCloser() {
        let color: UInt32 = 0x000000
        let first = square(0, 0, 1, name: "first", color: color)
        let second = square(0, 0, 1, name: "second", color: color)

        // Same shapes as above, but "second"'s points are pre-flipped so its
        // near end (10,5) is already first -- no reversal should happen.
        let items = [
            (object: first, points: [Point2D(0, 0), Point2D(10, 0)]),
            (object: second, points: [Point2D(10, 5), Point2D(0, 5)]),
        ]
        let sequenced = ObjectSequencer.sequenceGenerated(items)
        #expect(sequenced[1].points == [Point2D(10, 5), Point2D(0, 5)])
    }

    @Test func twoOptFixesGreedyNearestNeighborZigzag() {
        // A classic nearest-neighbor trap: 5 same-color points at x =
        // 0, 1, -2, 4, -8 (authored in that index order, all y=0). Greedy
        // nearest-neighbor (starting at index 0 by authoring-order
        // tie-break, since nothing's placed yet) visits them in that same
        // 0, 1, -2, 4, -8 order for a total travel of 22mm -- but a single
        // segment reversal (swap the -2 and 4 positions in the visiting
        // order) reaches 0, 1, 4, -2, -8 for only 16mm. Hand-verified: this
        // is exactly the single best-improving reversal 2-opt should find.
        func point(_ x: Double, name: String) -> EmbroideryObject {
            square(x - 0.5, -0.5, 1, name: name)
        }
        let objects = [point(0, name: "p0"), point(1, name: "p1"), point(-2, name: "p2"), point(4, name: "p3"), point(-8, name: "p4")]

        let sequenced = ObjectSequencer.sequence(objects)
        let xs = sequenced.map { $0.shape.boundingBox.center.x }
        let totalTravel = zip(xs, xs.dropFirst()).reduce(0.0) { $0 + abs($1.1 - $1.0) }

        #expect(totalTravel <= 16.01, "2-opt should reach the known 16mm order instead of settling for greedy's 22mm zigzag (got \(totalTravel)mm via \(xs))")
    }

    @Test func twoOptNeverViolatesContainmentEvenAmongDistanceTemptations() {
        // "outer" must sew before "inner" (it contains it). Two more
        // same-color, distantly-placed objects give the 2-opt pass real
        // work to do; the containment constraint must survive regardless
        // of what reversals it tries along the way.
        let inner = square(45, 45, 10, name: "inner")
        let a = square(200, 200, 5, name: "a")
        let b = square(202, 202, 5, name: "b")
        let outer = square(0, 0, 100, name: "outer")

        let sequenced = ObjectSequencer.sequence([inner, a, b, outer])
        let outerPos = sequenced.firstIndex { $0.name == "outer" }!
        let innerPos = sequenced.firstIndex { $0.name == "inner" }!
        #expect(outerPos < innerPos)
    }

    @Test func integratesWithDigitizePipelineColorSequenceConsistently() throws {
        let inner = square(45, 45, 10, name: "inner")
        var outer = square(0, 0, 100, name: "outer")
        outer.threadColor = .generic(RGBColor(hex: 0xFF0000))
        let doc = StitchDocument(name: "Nested", physicalWidthMM: 100, physicalHeightMM: 100, objects: [inner, outer])

        let plan = try DigitizePipeline.flatten(doc)
        let colors = try DigitizePipeline.colorSequence(for: doc)
        // Whatever order flatten actually sews in, colorSequence must agree exactly.
        #expect(colors.count == plan.colorChangeCount + 1)
    }
}
