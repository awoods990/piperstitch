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
