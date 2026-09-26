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

/// A traced letter is one shape with a junction in it, and the branching
/// plan sews it from a skeleton — on an E that plan crosses itself and
/// leaves voids. Reading the columns off the outline is offered as an
/// alternative and wins where it covers more, which is what the customer
/// sees as "it's still missing some of the fill".
struct TracedLetterCoverageTests {
    /// A slab E, 20 mm tall: stem plus three bars, no curves.
    private func eShape() -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(14, 0), Point2D(14, 3), Point2D(4, 3), Point2D(4, 8.5),
            Point2D(12, 8.5), Point2D(12, 11.5), Point2D(4, 11.5), Point2D(4, 17), Point2D(14, 17),
            Point2D(14, 20), Point2D(0, 20),
        ], closed: true)])
    }

    /// The same E with slab serifs on its three bar ends and its stem.
    /// Each serif is another branch in the skeleton, and branches meeting
    /// near a junction are where the branching plan twists.
    private func serifEShape() -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(16, 0), Point2D(16, 1), Point2D(14, 1), Point2D(14, 3),
            Point2D(5, 3), Point2D(5, 8), Point2D(11, 8), Point2D(11, 7), Point2D(13, 7),
            Point2D(13, 13), Point2D(11, 13), Point2D(11, 12), Point2D(5, 12), Point2D(5, 17),
            Point2D(14, 17), Point2D(14, 19), Point2D(16, 19), Point2D(16, 20), Point2D(0, 20),
            Point2D(0, 19), Point2D(2, 19), Point2D(2, 1), Point2D(0, 1),
        ], closed: true)])
    }

    private func stitchRuns(_ plan: StitchPlan) -> [[Point2D]] {
        var runs: [[Point2D]] = [], current: [Point2D] = []
        for command in plan.commands {
            if case .stitch(let p) = command { current.append(p) }
            else { if current.count > 1 { runs.append(current) }; current = [] }
        }
        if current.count > 1 { runs.append(current) }
        return runs
    }

    /// End to end: whichever plan wins, and whatever the backstop has to
    /// patch afterwards, the letter reaches the fabric covered.
    @Test func aTracedLetterComesOutFilled() throws {
        var p = StitchGenerationParameters()
        p.allowBranchingSatin = true
        let shape = eShape()
        let object = EmbroideryObject(name: "E", shape: shape, stitchType: .satin,
                                      threadColor: .generic(RGBColor(hex: 0x000000)), parameters: p)
        let plan = try DigitizePipeline.flatten(StitchDocument(name: "E", physicalWidthMM: 16, physicalHeightMM: 22, objects: [object]))
        let bare = CoverageBackstop.missingRegions(in: shape, covered: stitchRuns(plan)).reduce(0.0) { total, pocket in
            total + (pocket.subPaths.first.map { abs(PolygonGeometry.signedArea($0.points)) } ?? 0)
        }
        let area = abs(PolygonGeometry.signedArea(shape.subPaths[0].points))
        #expect(bare / area < 0.02, "an E \(String(format: "%.0f", area)) mm² left \(String(format: "%.1f", bare)) mm² of itself bare")
    }

    /// The premise of offering the reading at all: on a letter, the
    /// skeleton's branching plan crosses itself and leaves voids that
    /// reading the outline does not. Without this the letter still ends up
    /// covered -- the backstop patches the voids with fill at its own angle
    /// -- but patched satin is not satin, and this is the difference.
    @Test func readingTheOutlineCoversALetterBetterThanItsSkeletonDoes() throws {
        var p = StitchGenerationParameters()
        p.allowBranchingSatin = true
        let shape = serifEShape()
        let polygons = shape.subPaths.map { $0.points }
        let columns = GlyphColumnExtractor.columns(for: shape)
        #expect(columns.count >= 2, "an E is more than one column")
        let fromOutline = SatinColumnGenerator.sewColumns(columns, parameters: p, polygons: polygons)
        let fromSkeleton = try #require(try? SatinColumnGenerator.generateBranchingRuns(for: shape, parameters: p))
        func bare(_ runs: [[Point2D]]) -> Double {
            CoverageBackstop.missingRegions(in: shape, covered: runs).reduce(0.0) { total, pocket in
                total + (pocket.subPaths.first.map { abs(PolygonGeometry.signedArea($0.points)) } ?? 0)
            }
        }
        let outlineBare = bare(fromOutline), skeletonBare = bare(fromSkeleton)
        #expect(outlineBare < skeletonBare,
                "outline left \(String(format: "%.1f", outlineBare)) mm² bare, skeleton \(String(format: "%.1f", skeletonBare))")
    }

    /// The reading is offered, not imposed: the shape came from pixels and
    /// the skeleton is sometimes right about it. A plain bar has no
    /// junction at all and must not be dragged down this path.
    @Test func aPlainBarIsUntouchedByTheOfferedAlternative() throws {
        var p = StitchGenerationParameters()
        p.allowBranchingSatin = true
        let bar = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(30, 0), Point2D(30, 4), Point2D(0, 4),
        ], closed: true)])
        let object = EmbroideryObject(name: "bar", shape: bar, stitchType: .satin,
                                      threadColor: .generic(RGBColor(hex: 0x000000)), parameters: p)
        let plan = try DigitizePipeline.flatten(StitchDocument(name: "bar", physicalWidthMM: 32, physicalHeightMM: 6, objects: [object]))
        #expect(plan.trimCount <= 1, "a single column is one run; \(plan.trimCount) trims means it was cut into pieces")
        #expect(plan.stitchCount > 40)
    }
}
