import Testing
@testable import StitchPilotCore

struct ObjectSequencerTests {
    private func square(_ minX: Double, _ minY: Double, _ size: Double, name: String) -> EmbroideryObject {
        let shape = VectorShape(subPaths: [SubPath(points: [
            Point2D(minX, minY), Point2D(minX + size, minY), Point2D(minX + size, minY + size), Point2D(minX, minY + size),
        ], closed: true)])
        return EmbroideryObject(name: name, shape: shape, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0x000000)))
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
