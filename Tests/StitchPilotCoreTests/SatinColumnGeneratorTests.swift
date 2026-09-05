import Testing
@testable import StitchPilotCore

struct SatinColumnGeneratorTests {
    /// Pull compensation defaults to off here so these tests check pure
    /// satin geometry against exact bounds; `pullCompensationWidensColumn`
    /// below tests compensation itself.
    func params(density: Double = 0.4, maxWidth: Double = 12.0) -> StitchGenerationParameters {
        var p = StitchGenerationParameters()
        p.satinDensityMM = density
        p.maxSatinWidthMM = maxWidth
        p.pullCompensationMM = 0
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
}
