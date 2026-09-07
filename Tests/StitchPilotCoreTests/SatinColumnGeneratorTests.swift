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

        // Crossings in the middle of the column should be close to width
        // 4mm (the rectangle's short side). Crossings very near either end
        // are excluded deliberately: both rails share a single endpoint at
        // each detected end-cap edge (see SatinColumnGenerator's doc
        // comment), which tapers width to exactly 0 at the very tip --
        // correct for a pointed end (a star tip), but a known, documented
        // approximation for a flat/square-capped end like this rectangle's.
        let crossingCount = stitches.count / 2
        let margin = max(2, crossingCount / 10)
        for i in stride(from: margin * 2, to: stitches.count - margin * 2, by: 2) {
            let width = stitches[i].distance(to: stitches[i + 1])
            #expect(abs(width - 4.0) <= 0.5)
        }

        let box = BoundingBox(points: stitches)
        #expect(box.minX >= -0.1 && box.maxX <= 30.1)
        #expect(box.minY >= -0.1 && box.maxY <= 4.1)
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
}
