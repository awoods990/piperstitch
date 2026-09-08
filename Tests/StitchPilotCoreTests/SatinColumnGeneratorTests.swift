import Testing
@testable import StitchPilotCore

struct SatinColumnGeneratorTests {
    /// `DigitizePipeline`-level fallback, not `SatinColumnGenerator` itself:
    /// `StitchTypeClassifier` picks `.satin` purely from a shape's average
    /// width, which doesn't guarantee the outline is well-formed enough for
    /// satin's own rail-fitting (an outline with fewer than 4 distinct
    /// points, here) -- a real case once a design gets resized larger and a
    /// degenerate sliver's *average* width crosses the satin threshold even
    /// though its actual geometry never could support a satin column.
    /// Before this fallback existed, that single object's
    /// `SatinGenerationError.shapeNotSuitable` propagated all the way up
    /// and aborted the *entire* document's digitize -- found against a real
    /// multi-object design, not synthetically. See CHANGELOG.md.
    @Test func pipelineFallsBackToRunningStitchWhenASatinShapeIsGeometricallyDegenerate() throws {
        let degenerate = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(5, 0), Point2D(2.5, 1),
        ], closed: true)])
        let object = EmbroideryObject(name: "Degenerate", shape: degenerate, stitchType: .satin,
                                       threadColor: .generic(RGBColor(hex: 0x000000)))
        let doc = StitchDocument(name: "DegenerateSatin", physicalWidthMM: 10, physicalHeightMM: 10, objects: [object])

        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 0, "should fall back to a real (running-stitch) result, not silently produce nothing")
    }

    /// A synthetic "H" -- two parallel vertical stems joined by a
    /// crossbar -- the shape whose real font glyph exposed this exact
    /// failure via visual testing against Helvetica-Bold (see
    /// CHANGELOG.md). A shape that genuinely branches has no single pair
    /// of end-cap edges that correspond to two sensible parallel rails
    /// (H's "top" and "bottom" are each split into two disconnected
    /// edges, one per stem), so the single-global-axis rail algorithm
    /// walks the boundary in an order that crosses itself repeatedly
    /// instead of tracing a real column. Must be detected and rejected
    /// (`shapeNotSuitable`) rather than silently returning self-crossing
    /// rails that render as visible garbage.
    @Test func branchingHShapeIsRejectedRatherThanProducingTwistedRails() throws {
        let hShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(3, 0), Point2D(3, 8.5), Point2D(12, 8.5), Point2D(12, 0),
            Point2D(15, 0), Point2D(15, 20), Point2D(12, 20), Point2D(12, 11.5), Point2D(3, 11.5),
            Point2D(3, 20), Point2D(0, 20),
        ], closed: true)])

        #expect(throws: SatinGenerationError.self) {
            _ = try SatinColumnGenerator.generatePartial(for: hShape, parameters: params())
        }

        // The pipeline must still produce real output for this object --
        // falling back to a running-stitch outline (the same fallback any
        // other geometrically-unsuitable satin shape already gets), not
        // aborting the whole document's digitize.
        let object = EmbroideryObject(name: "H", shape: hShape, stitchType: .satin,
                                       threadColor: .generic(RGBColor(hex: 0x000000)), parameters: params())
        let doc = StitchDocument(name: "BranchingH", physicalWidthMM: 15, physicalHeightMM: 20, objects: [object])
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 0)
    }

    /// Pull and push compensation default to off here so these tests check
    /// pure satin geometry against exact bounds; `pullCompensationWidensColumn`
    /// and `pushCompensationShortensColumn` below test compensation itself.
    func params(density: Double = 0.4, maxWidth: Double = 12.0) -> StitchGenerationParameters {
        var p = StitchGenerationParameters()
        p.satinDensityMM = density
        p.maxSatinWidthMM = maxWidth
        p.pullCompensationMM = 0
        p.pushCompensationMM = 0
        return p
    }

    @Test func pullCompensationWidensColumn() throws {
        let rect = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4),
        ], closed: true)])
        var compensated = params()
        compensated.pullCompensationMM = 0.4

        let plain = try SatinColumnGenerator.generate(for: rect, parameters: params())
        let widened = try SatinColumnGenerator.generate(for: rect, parameters: compensated)

        // Compare a middle crossing (away from the tapered ends) on each.
        let mid = plain.count / 2 - (plain.count / 2) % 2
        let plainWidth = plain[mid].distance(to: plain[mid + 1])
        let widenedWidth = widened[mid].distance(to: widened[mid + 1])
        #expect(widenedWidth - plainWidth > 0.3)
    }

    @Test func pushCompensationShortensColumn() throws {
        let rect = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4),
        ], closed: true)])
        var compensated = params()
        compensated.pushCompensationMM = 0.5

        let plain = try SatinColumnGenerator.generate(for: rect, parameters: params())
        let shortened = try SatinColumnGenerator.generate(for: rect, parameters: compensated)

        let plainBox = BoundingBox(points: plain)
        let shortenedBox = BoundingBox(points: shortened)
        // Push compensation trims both ends along the column's length (x),
        // without touching its width (y).
        #expect(shortenedBox.minX > plainBox.minX + 0.15)
        #expect(shortenedBox.maxX < plainBox.maxX - 0.15)
        #expect(abs(shortenedBox.height - plainBox.height) < 0.05)
    }

    /// A 30mm x 4mm rectangle is the simplest possible satin column: two
    /// long parallel rails 4mm apart, ends at the short sides.
    @Test func straightRectangleColumn() throws {
        let rect = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4),
        ], closed: true)])
        let stitches = try SatinColumnGenerator.generate(for: rect, parameters: params())

        #expect(stitches.count > 100, "30mm / 0.4mm density should produce ~75 crossings = 150 stitches")
        #expect(stitches.count % 2 == 0, "satin alternates rail A / rail B, so the count must be even")

        // A plain rectangle's short sides are genuinely FLAT end caps, not
        // points -- every crossing should read close to the rectangle's
        // own 4mm width, including right at the very first/last crossing
        // (a squared end caps at full width immediately, unlike a
        // genuinely pointed end which tapers to 0 -- see
        // `squareCapMinEdgeLengthMM`'s doc comment).
        for i in stride(from: 0, to: stitches.count, by: 2) {
            let width = stitches[i].distance(to: stitches[i + 1])
            #expect(abs(width - 4.0) <= 0.5, "crossing \(i / 2) width \(width) should stay close to 4mm across the whole column, including its squared ends")
        }

        let box = BoundingBox(points: stitches)
        #expect(box.minX >= -0.1 && box.maxX <= 30.1)
        #expect(box.minY >= -0.1 && box.maxY <= 4.1)
    }

    /// A shape with ONE genuinely pointed end and one genuinely flat end --
    /// a thin triangle-like sliver, point at x=0 (its two "corner" points
    /// nearly coincident, the way a flattened bezier's true tip would be)
    /// and a flat 3mm base at x=20. Confirms `squareCapMinEdgeLengthMM`
    /// correctly tells the two ends apart *independently*, not just always
    /// squaring (or always tapering) every column.
    @Test func onePointedEndAndOneFlatEndAreHandledIndependently() throws {
        let points: [Point2D] = [Point2D(0, 0), Point2D(0, 0.05), Point2D(20, 3), Point2D(20, 0)]
        let sliver = VectorShape(subPaths: [SubPath(points: points, closed: true)])

        let stitches = try SatinColumnGenerator.generatePartial(for: sliver, parameters: params(density: 0.5))
        #expect(stitches.count > 4)
        let firstWidth = stitches[0].distance(to: stitches[1])
        let lastWidth = stitches[stitches.count - 2].distance(to: stitches[stitches.count - 1])
        #expect(firstWidth < 0.3, "the pointed tip (x=0) should still taper to near-zero width, not square off")
        #expect(abs(lastWidth - 3.0) <= 0.3, "the flat base (x=20) should square off at ~3mm width, not taper to a point")
    }

    @Test func columnTooWideThrows() throws {
        // A 30mm x 20mm rectangle is far too wide for satin (default limit 12mm).
        let wideRect = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 20), Point2D(0, 20),
        ], closed: true)])

        #expect(throws: SatinGenerationError.self) {
            _ = try SatinColumnGenerator.generate(for: wideRect, parameters: params())
        }
    }

    @Test func degenerateShapeThrows() throws {
        let line = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(1, 0)], closed: false)])
        #expect(throws: SatinGenerationError.self) {
            _ = try SatinColumnGenerator.generate(for: line, parameters: params())
        }
    }

    @Test func partialMatchesPureSatinWhenColumnFitsEntirely() throws {
        // No crossing exceeds the width limit anywhere along this column,
        // so generatePartial's output should be identical to generate's --
        // the partial/mixed code paths simply never trigger.
        let rect = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4),
        ], closed: true)])
        let pure = try SatinColumnGenerator.generate(for: rect, parameters: params())
        let partial = try SatinColumnGenerator.generatePartial(for: rect, parameters: params())
        #expect(partial == pure)
    }

    @Test func generatePartialNeverThrowsWhenUniformlyTooWide() throws {
        // Same shape as columnTooWideThrows -- generate() rejects it, but
        // generatePartial() must still produce a usable (all-fill) result.
        let wideRect = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 20), Point2D(0, 20),
        ], closed: true)])
        let stitches = try SatinColumnGenerator.generatePartial(for: wideRect, parameters: params())
        #expect(!stitches.isEmpty)
    }

    @Test func generatePartialKeepsNarrowSectionAsSatinAndConvertsWideSection() throws {
        // A trapezoid tapering from 2mm wide at one end to 20mm wide at the
        // other, with a 12mm satin limit -- a genuinely mixed column that
        // pure generate() can't produce output for at all, but a real
        // digitizer would still satin-stitch the narrow end.
        let trapezoid = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(60, 0), Point2D(60, 20), Point2D(0, 2),
        ], closed: true)])

        #expect(throws: SatinGenerationError.self) {
            _ = try SatinColumnGenerator.generate(for: trapezoid, parameters: params())
        }

        let stitches = try SatinColumnGenerator.generatePartial(for: trapezoid, parameters: params())
        #expect(!stitches.isEmpty)

        let box = BoundingBox(points: stitches)
        // The mixed output should still span roughly the full column length,
        // not stop short at the point satin gives up.
        #expect(box.maxX > 50)

        // The very first crossing (the narrow end, sewn first) should still
        // be a tight satin pair, not spread out fill-style.
        #expect(stitches[0].distance(to: stitches[1]) < 8, "the narrow end should still sew as a tight satin crossing")
    }

    @Test func tooNarrowInteriorThrowsFromStrictGenerate() throws {
        // A 30mm x 0.5mm column -- below the default 1.5mm practical satin
        // minimum throughout its interior (the jog at each end is smaller
        // than the resampling spacing here, so even crossings just past the
        // margin already measure the full-body 0.5mm width).
        let hairlineColumn = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 0.5), Point2D(0, 0.5),
        ], closed: true)])
        #expect(throws: SatinGenerationError.self) {
            _ = try SatinColumnGenerator.generate(for: hairlineColumn, parameters: params())
        }
    }

    @Test func generatePartialConvertsTooNarrowSectionToTripleRunLine() throws {
        let hairlineColumn = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 0.5), Point2D(0, 0.5),
        ], closed: true)])
        let stitches = try SatinColumnGenerator.generatePartial(for: hairlineColumn, parameters: params())
        #expect(!stitches.isEmpty)

        // Pure satin at the default 0.4mm density over ~30mm would need
        // roughly 150 points; converting the narrow interior to a much
        // coarser triple-run line (stitchLengthMM, not satinDensityMM)
        // should produce far fewer.
        #expect(stitches.count < 100)

        let box = BoundingBox(points: stitches)
        #expect(box.maxX > 25) // still spans nearly the full column length
    }

    @Test func integratesWithDigitizePipeline() throws {
        let rect = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 3), Point2D(0, 3),
        ], closed: true)])
        let object = EmbroideryObject(name: "Satin", shape: rect, stitchType: .satin,
                                       threadColor: .generic(RGBColor(hex: 0x0000FF)), parameters: params())
        let doc = StitchDocument(name: "SatinTest", physicalWidthMM: 20, physicalHeightMM: 3, objects: [object])
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 40)
    }

    /// A shape too wide for satin must not abort the whole design --
    /// DigitizePipeline falls back to tatami fill for that object rather
    /// than propagating SatinGenerationError.columnTooWide (spec: "convert
    /// excessively wide satin regions to another stitch type" — see
    /// EMBROIDERY_ALGORITHM_REFERENCE.md).
    @Test func pipelineFallsBackToFillWhenSatinTooWide() throws {
        let wideRect = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 20), Point2D(0, 20),
        ], closed: true)])
        let object = EmbroideryObject(name: "TooWide", shape: wideRect, stitchType: .satin,
                                       threadColor: .generic(RGBColor(hex: 0x00FF00)), parameters: params())
        let doc = StitchDocument(name: "FallbackTest", physicalWidthMM: 30, physicalHeightMM: 20, objects: [object])

        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 0, "should produce fill stitches instead of throwing")

        // A genuinely satin-appropriate object in the same document must
        // still sew as satin -- the fallback is per-object, not global.
        let narrowObject = EmbroideryObject(name: "Fine", shape: VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 3), Point2D(0, 3),
        ], closed: true)]), stitchType: .satin, threadColor: .generic(RGBColor(hex: 0x0000FF)), parameters: params())
        let mixedDoc = StitchDocument(name: "Mixed", physicalWidthMM: 30, physicalHeightMM: 20, objects: [object, narrowObject])
        let mixedPlan = try DigitizePipeline.flatten(mixedDoc)
        #expect(mixedPlan.stitchCount > plan.stitchCount, "the narrow object's real satin stitches must still be added on top of the fallback's")
    }

    // MARK: - Ring columns (a letterform counter -- O, P, R, A, D, Q...)

    /// A "square donut" -- 20x20mm outer boundary with a centered 10x10mm
    /// hole, a uniform 5mm-wide ring all the way around. `computeRails`'s
    /// ring case should produce two same-length, explicitly-closed rails
    /// (the signal downstream code uses to skip end-trimming/push comp
    /// meant for an open column's tapered tips, which a ring doesn't have).
    @Test func ringRailsAreClosedAndEqualLength() throws {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)], closed: true)
        let hole = SubPath(points: [Point2D(5, 5), Point2D(15, 5), Point2D(15, 15), Point2D(5, 15)], closed: true)
        let ring = VectorShape(subPaths: [outer, hole])

        let (railA, railB) = try SatinColumnGenerator.computeRails(for: ring)
        #expect(railA.count == railB.count)
        #expect(railA.count > 8)
        #expect(railA.first == railA.last, "outer rail should be explicitly closed")
        #expect(railB.first == railB.last, "hole rail should be explicitly closed")
    }

    /// The actual bug this ring support fixes: before it, any shape with a
    /// hole was routed away from satin entirely (`StitchTypeClassifier`),
    /// because the only satin path there was would have ignored the hole
    /// subpath and solid-filled it. Confirms the real, generated stitches
    /// stay on the ring's stroke -- nowhere near the hole's own center --
    /// rather than covering the hole solid.
    @Test func ringColumnStaysOnTheStrokeNotSolidFillingTheHole() throws {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)], closed: true)
        let hole = SubPath(points: [Point2D(5, 5), Point2D(15, 5), Point2D(15, 15), Point2D(5, 15)], closed: true)
        let ring = VectorShape(subPaths: [outer, hole])

        let stitches = try SatinColumnGenerator.generatePartial(for: ring, parameters: params())
        #expect(stitches.count > 20)

        for point in stitches {
            let chebyshevFromCenter = max(abs(point.x - 10), abs(point.y - 10))
            #expect(chebyshevFromCenter > 3, "stitch \(point) landed too close to the hole's center -- looks solid-filled, not a ring")
            #expect(chebyshevFromCenter < 11, "stitch \(point) landed outside the ring's outer boundary")
        }
    }

    /// A ring column integrated through the full pipeline (including
    /// underlay, which also calls `computeRails`) must produce a real,
    /// non-empty plan without throwing -- exercises `UnderlayGenerator`'s
    /// ring-aware center-run path (`isClosedRing`) alongside satin itself.
    @Test func ringColumnIntegratesWithDigitizePipeline() throws {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)], closed: true)
        let hole = SubPath(points: [Point2D(5, 5), Point2D(15, 5), Point2D(15, 15), Point2D(5, 15)], closed: true)
        let ring = VectorShape(subPaths: [outer, hole])
        let object = EmbroideryObject(name: "O", shape: ring, stitchType: .satin,
                                       threadColor: .generic(RGBColor(hex: 0x000000)), parameters: params())
        let doc = StitchDocument(name: "RingTest", physicalWidthMM: 20, physicalHeightMM: 20, objects: [object])

        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 20)
    }

    /// A hole positioned only in the upper portion of a taller outer
    /// shape (like a real "P" or "R"'s counter, which sits nowhere near
    /// the middle of the whole glyph) -- the outer shape's OWN centroid
    /// (~(5, 15), the shape's vertical middle) falls outside this hole
    /// (y: 20-26), which would break a ray-cast centered there. Confirms
    /// `computeRingRails` casting from the HOLE's own center instead
    /// still produces a usable ring.
    @Test func offCenterHoleLikeARealLetterPStillProducesAUsableRing() throws {
        let outer = SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 30), Point2D(0, 30)], closed: true)
        let hole = SubPath(points: [Point2D(2, 20), Point2D(8, 20), Point2D(8, 26), Point2D(2, 26)], closed: true)
        #expect(!PolygonGeometry.pointInPolygons(Point2D(5, 15), polygons: [hole.points]),
                "test setup sanity check: the outer shape's own centroid should fall outside this off-center hole")

        let ring = VectorShape(subPaths: [outer, hole])
        let (railA, railB) = try SatinColumnGenerator.computeRails(for: ring)
        #expect(railA.count == railB.count)
        #expect(railA.count > 8)
    }

    // MARK: - Mitered end caps

    /// Confirms this engine's satin end-cap handling doesn't force a
    /// perpendicular cut: when the shape's OWN end-cap edge is already at
    /// an angle (e.g. a 45° miter, so two adjacent satin border segments
    /// can meet cleanly at a corner the way a picture frame's corners
    /// do), `computeRails`'s squared-end-cap logic (see
    /// `onePointedEndAndOneFlatEndAreHandledIndependently`, which
    /// exercises the same code path for a perpendicular flat end) uses
    /// that edge's own two endpoints directly -- so the rails follow the
    /// angled cut rather than squaring it off to 90°. This engine doesn't
    /// have an interactive tool to automatically miter two separate
    /// objects against each other yet, but a shape authored (by hand, or
    /// imported) with an already-mitered end sews mitered correctly.
    @Test func satinRailsFollowAnAlreadyMiteredEndCapRatherThanSquaringItToNinetyDegrees() throws {
        // A 4mm-wide strip along x, right end cut at a true 45° miter --
        // rising from (20,0) to (24,4) instead of a flat vertical edge.
        let miteredStrip = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(24, 4), Point2D(0, 4),
        ], closed: true)])

        let (railA, railB) = try SatinColumnGenerator.computeRails(for: miteredStrip)
        // The two rails must end at the miter edge's own two distinct
        // corners -- (20,0) and (24,4) -- not a shared, perpendicular
        // cut point in between.
        let allEnds: Set<Point2D> = [railA.first!, railA.last!, railB.first!, railB.last!]
        #expect(allEnds.contains(Point2D(20, 0)))
        #expect(allEnds.contains(Point2D(24, 4)))
    }
}
