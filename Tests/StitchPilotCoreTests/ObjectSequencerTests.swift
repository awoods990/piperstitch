import Testing
@testable import StitchPilotCore

struct ObjectSequencerTests {
    private func square(_ minX: Double, _ minY: Double, _ size: Double, name: String, color: UInt32 = 0x000000) -> EmbroideryObject {
        let shape = VectorShape(subPaths: [SubPath(points: [
            Point2D(minX, minY), Point2D(minX + size, minY), Point2D(minX + size, minY + size), Point2D(minX, minY + size),
        ], closed: true)])
        return EmbroideryObject(name: name, shape: shape, stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: color)))
    }

    /// A letter inside its own thin halo: the two are traced from
    /// adjacent pixels, so the letter's outline touches the halo's outline
    /// where the halo is thinnest, and one shared vertex can land a
    /// rounding error OUTSIDE the halo after a size fit. That still has
    /// to read as "halo contains letter" -- otherwise nothing forces the
    /// halo to sew first, and it buries the letter. Found directly against
    /// a real "B" logo that came out solid white at 101.6mm and fine at
    /// 100mm. The inner square here pokes 0.01mm past the outer's edge.
    @Test func aContainedObjectTouchingTheContainerEdgeStillSewsAfterIt() {
        let halo = square(0, 0, 100, name: "halo", color: 0xFFFFFF)
        let letter = EmbroideryObject(name: "letter", shape: VectorShape(subPaths: [SubPath(points: [
            Point2D(-0.01, 20), Point2D(60, 20), Point2D(60, 80), Point2D(-0.01, 80),
        ], closed: true)]), stitchType: .runningStitch, threadColor: .generic(RGBColor(hex: 0xC02020)))

        let sequenced = ObjectSequencer.sequence([letter, halo])
        #expect(sequenced.map { $0.name } == ["halo", "letter"])
    }

    /// A satin border round a fill: the border's outer boundary encloses
    /// the fill, but there is no border material under it -- the fill
    /// sits in the border's hole. The border must sew AFTER the fill, so
    /// its satin lands on the fill's edge rather than the fill sewing over
    /// the border's inner edge. Found on a sewn-out cap-logo "B" whose red
    /// fill was the last thing stitched, its edge travel riding on top of
    /// the border. Two borders (an inner navy ring, an outer white one)
    /// sew inside-out after the fill.
    @Test func aRingAroundAFillSewsAfterTheFillNotBefore() {
        func ring(_ inset: Double, name: String, color: UInt32) -> EmbroideryObject {
            let o = inset, i = inset + 4
            let outer = SubPath(points: [Point2D(o, o), Point2D(100 - o, o), Point2D(100 - o, 100 - o), Point2D(o, 100 - o)], closed: true)
            let hole = SubPath(points: [Point2D(i, i), Point2D(100 - i, i), Point2D(100 - i, 100 - i), Point2D(i, 100 - i)], closed: true)
            return EmbroideryObject(name: name, shape: VectorShape(subPaths: [outer, hole]), stitchType: .satin, threadColor: .generic(RGBColor(hex: color)))
        }
        let fill = square(8, 8, 84, name: "fill", color: 0xC02020)          // 8...92, inside the inner ring's hole
        let inner = ring(4, name: "inner", color: 0x102040)                   // 4...96 with hole 8...92
        let outer = ring(0, name: "outer", color: 0xFFFFFF)                   // 0...100 with hole 4...96

        let sequenced = ObjectSequencer.sequence([outer, inner, fill])
        #expect(sequenced.map { $0.name } == ["fill", "inner", "outer"])
        // A solid background that genuinely covers the fill still sews first.
        let background = square(0, 0, 100, name: "background", color: 0xEEEEEE)
        #expect(ObjectSequencer.sequence([fill, background]).map { $0.name } == ["background", "fill"])
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
        // first; true polygon containment finds no relationship, so the
        // order comes entirely from the ordinary (non-containment)
        // tie-break -- reading order (left-to-right, then top-to-bottom)
        // of each object's own bounding-box center, which for this pair
        // happens to put the L-shape (center (50,50)) ahead of the notch
        // square (center (65,65)) regardless of which was authored first.
        let sequenced = ObjectSequencer.sequence([notchSquare, lObject])
        #expect(sequenced.map { $0.name } == ["lShape", "notchSquare"])
    }

    /// The actual real-world bug this whole first-pick heuristic exists to
    /// fix: raster-imported lettering authors its objects in whatever
    /// order `RasterTracing.connectedComponents`'s own top-to-bottom,
    /// left-to-right pixel scan happened to discover them in -- which,
    /// for a row of letters with slightly different baselines/ascenders
    /// (an accented character, a dotted "i", ...), doesn't reliably match
    /// the word's actual left-to-right reading order. Found against a
    /// real machine-sewn design that started mid-word instead of at its
    /// first letter -- authoring order put a *middle* letter first
    /// despite it sitting well to the right of the true first letter.
    /// See CHANGELOG.md.
    @Test func firstObjectPlacedIsTheLeftmostOneNotWhicheverWasAuthoredFirst() {
        // Same color, no containment relationship -- authored out of
        // reading order, middle letter first.
        let middle = square(40, 0, 10, name: "middle")
        let first = square(0, 2, 10, name: "first") // slightly different baseline, same as a real accented/dotted letter would have
        let last = square(80, 0, 10, name: "last")

        let sequenced = ObjectSequencer.sequence([middle, first, last])
        #expect(sequenced.map { $0.name } == ["first", "middle", "last"], "sewing should start at the leftmost letter regardless of authoring order")
    }

    @Test func sequenceGeneratedReversesPathForCloserApproach() {
        let color: UInt32 = 0x000000
        let first = square(0, 0, 1, name: "first", color: color) // shape geometry is irrelevant here; only points matter
        let second = square(0, 0, 1, name: "second", color: color)

        // "first" ends at (10,0). "second" runs (0,5) -> (10,5): entering
        // from its far end (0,5) is an 11.18mm reach, but entering from its
        // near end (10,5) is only 5mm -- sewing it end-first is closer.
        let items = [
            (object: first, runs: [[Point2D(0, 0), Point2D(10, 0)]]),
            (object: second, runs: [[Point2D(0, 5), Point2D(10, 5)]]),
        ]
        let sequenced = ObjectSequencer.sequenceGenerated(items)
        #expect(sequenced.map { $0.object.name } == ["first", "second"])
        #expect(sequenced[1].runs == [[Point2D(10, 5), Point2D(0, 5)]])
    }

    @Test func sequenceGeneratedDoesNotReverseWhenAlreadyCloser() {
        let color: UInt32 = 0x000000
        let first = square(0, 0, 1, name: "first", color: color)
        let second = square(0, 0, 1, name: "second", color: color)

        // Same shapes as above, but "second"'s points are pre-flipped so its
        // near end (10,5) is already first -- no reversal should happen.
        let items = [
            (object: first, runs: [[Point2D(0, 0), Point2D(10, 0)]]),
            (object: second, runs: [[Point2D(10, 5), Point2D(0, 5)]]),
        ]
        let sequenced = ObjectSequencer.sequenceGenerated(items)
        #expect(sequenced[1].runs == [[Point2D(10, 5), Point2D(0, 5)]])
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

    // MARK: - details last, cap ordering (docs/WILCOM_MANUAL_REVIEW.md B7)

    private func box(_ minX: Double, _ minY: Double, w: Double, h: Double, name: String, type: StitchType, color: UInt32, fabric: FabricType = .standard) -> EmbroideryObject {
        let shape = VectorShape(subPaths: [SubPath(points: [
            Point2D(minX, minY), Point2D(minX + w, minY), Point2D(minX + w, minY + h), Point2D(minX, minY + h),
        ], closed: true)])
        var p = StitchGenerationParameters()
        p.fabricType = fabric
        return EmbroideryObject(name: name, shape: shape, stitchType: type, threadColor: .generic(RGBColor(hex: color)), parameters: p)
    }

    @Test func detailsSewAfterTheBulkOfTheirOwnColour() {
        // A red outline authored first and sitting nearest the start,
        // two red fills, then a blue fill. The outline must sew after
        // both red fills but still before blue.
        let outline = box(0, 0, w: 3, h: 3, name: "outline", type: .runningStitch, color: 0xFF0000)
        let fillA = box(10, 0, w: 30, h: 30, name: "fillA", type: .tatamiFill, color: 0xFF0000)
        let fillB = box(50, 0, w: 30, h: 30, name: "fillB", type: .tatamiFill, color: 0xFF0000)
        let blue = box(90, 0, w: 30, h: 30, name: "blue", type: .tatamiFill, color: 0x0000FF)
        let names = ObjectSequencer.sequence([outline, fillA, fillB, blue]).map { $0.name }
        // (The two fills may swap -- 2-opt is free to shorten the jump to blue.)
        #expect(Set(names.prefix(2)) == ["fillA", "fillB"] && names[2] == "outline" && names[3] == "blue", "\(names)")
        // A tiny same-colour accent (well under 2% of the design) is a detail too.
        let accent = box(5, 5, w: 2, h: 2, name: "accent", type: .tatamiFill, color: 0xFF0000)
        let names2 = ObjectSequencer.sequence([accent, fillA, fillB]).map { $0.name }
        #expect(names2.last == "accent", "\(names2)")
    }

    @Test func capsSewBottomRowFirstAndCentreOut() {
        // Two rows of five "letters" on a structured cap, design centre x = 50.
        func row(_ y: Double, prefix: String) -> [EmbroideryObject] {
            (0..<5).map { i in box(Double(i) * 20 + 2, y, w: 16, h: 12, name: "\(prefix)\(i)", type: .satin, color: 0x000000, fabric: .structuredCap) }
        }
        let top = row(0, prefix: "T"), bottom = row(30, prefix: "B")
        let names = ObjectSequencer.sequence(top + bottom).map { $0.name }
        // Bottom row first (larger y is lower on the design), centre letter
        // (index 2) first, then out to the right, then left from the centre.
        #expect(names == ["B2", "B3", "B4", "B1", "B0", "T2", "T3", "T4", "T1", "T0"], "\(names)")
        // Not a cap: the plain nearest-neighbour order reads left to right.
        let flat = ObjectSequencer.sequence(row(0, prefix: "F").map { var o = $0; o.parameters.fabricType = .knit; return o }).map { $0.name }
        #expect(flat == ["F0", "F1", "F2", "F3", "F4"], "\(flat)")
    }

    @Test func capOrderingStillGroupsColoursAndRespectsContainment() {
        let background = box(0, 0, w: 100, h: 60, name: "bg", type: .tatamiFill, color: 0x0000FF, fabric: .unstructuredCap)
        let letterA = box(10, 20, w: 20, h: 20, name: "A", type: .satin, color: 0xFFFFFF, fabric: .unstructuredCap)
        let letterB = box(40, 20, w: 20, h: 20, name: "B", type: .satin, color: 0xFFFFFF, fabric: .unstructuredCap)
        let letterC = box(70, 20, w: 20, h: 20, name: "C", type: .satin, color: 0xFFFFFF, fabric: .unstructuredCap)
        let names = ObjectSequencer.sequence([letterC, letterA, background, letterB]).map { $0.name }
        #expect(names.first == "bg")
        #expect(names.dropFirst() == ["B", "C", "A"], "\(names)")
    }
}
