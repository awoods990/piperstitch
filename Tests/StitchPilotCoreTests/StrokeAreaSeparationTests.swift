import Testing
import Foundation
@testable import StitchPilotCore

/// The stroke-vs-area decomposition that turns one imported colour into
/// fill for its solid parts and satin for its lines -- see
/// `ShapeMerger.splitThickAndThin` and `StitchTypeClassifier.
/// separateStrokesFromAreas`, both added against the professionally
/// digitized reference designs in TestArtwork/Professional Files.
struct StrokeAreaSeparationTests {
    private func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [Point2D] {
        [Point2D(x0, y0), Point2D(x1, y0), Point2D(x1, y1), Point2D(x0, y1)]
    }

    /// A 20 mm square with a 1 mm line 30 mm long hanging off it, sewn as
    /// one shape (the alligator's jacket-plus-keyline in miniature). Since
    /// the line hangs off exactly one area with no holes, it needs the
    /// "very thin and long" route to count as a stroke.
    private func squareWithLine() -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 9.5), Point2D(50, 9.5), Point2D(50, 10.5), Point2D(20, 10.5), Point2D(20, 20), Point2D(0, 20),
        ], closed: true)])
    }

    @Test func aSquareWithALineAttachedSplitsIntoAreaAndStroke() throws {
        let split = try #require(ShapeMerger.splitThickAndThin(squareWithLine(), thinWidthMM: 3.0, overlapMM: 0.4))
        #expect(split.thick.count == 1)
        #expect(split.thin.count == 1)
        let area = try #require(split.thick.first).boundingBox
        let stroke = try #require(split.thin.first).boundingBox
        #expect(area.maxX < 22, "the area is the square, not the line")
        #expect(stroke.minX > 18 && stroke.maxX > 49, "the stroke is the line, reaching the square (with its overlap band)")
        #expect(stroke.height < 2.5, "the stroke is the 1 mm line, not a slice of the square")
    }

    /// Specks and hairlines are not sewn: a 0.3 mm speck and a 0.4 mm-
    /// wide 4 mm sliver (the two at the Oholi bird's head) go, a 1 mm dot
    /// and a 1 mm-wide line stay, and a shape that is only slivers is nil.
    @Test func specksAndHairlinesAreNotSewable() {
        let speck = SubPath(points: rect(0, 0, 0.3, 0.3), closed: true)
        let sliver = SubPath(points: rect(0, 0, 4, 0.4), closed: true)
        let dot = SubPath(points: (0..<16).map { Point2D(0.5 + 0.5 * cos(Double($0) / 16 * .pi * 2), 0.5 + 0.5 * sin(Double($0) / 16 * .pi * 2)) }, closed: true)
        let line = SubPath(points: rect(0, 0, 5, 1), closed: true)
        #expect(!StitchTypeClassifier.isSewableSize(speck))
        #expect(!StitchTypeClassifier.isSewableSize(sliver))
        #expect(StitchTypeClassifier.isSewableSize(dot))
        #expect(StitchTypeClassifier.isSewableSize(line))
        #expect(StitchTypeClassifier.droppingUnsewable(VectorShape(subPaths: [speck, sliver])) == nil)
        #expect(StitchTypeClassifier.droppingUnsewable(VectorShape(subPaths: [line, sliver]))?.subPaths.count == 1)
    }

    /// The pipeline sews nothing for an unsewable object and the readiness
    /// report says so, rather than the detail silently vanishing.
    @Test func unsewableObjectsProduceNoStitchesAndAreReported() throws {
        let square = EmbroideryObject(name: "square", shape: VectorShape(subPaths: [SubPath(points: rect(0, 0, 20, 20), closed: true)]),
                                      stitchType: .tatamiFill, threadColor: .generic(RGBColor(hex: 0x000000)))
        let speck = EmbroideryObject(name: "speck", shape: VectorShape(subPaths: [SubPath(points: rect(30, 30, 30.3, 30.3), closed: true)]),
                                     stitchType: .tripleRun, threadColor: .generic(RGBColor(hex: 0x000000)))
        let doc = StitchDocument(name: "d", physicalWidthMM: 40, physicalHeightMM: 40, objects: [square, speck])
        let plan = try DigitizePipeline.flatten(doc)
        let box = plan.commands.compactMap { command -> Point2D? in if case .stitch(let p) = command { return p } else { return nil } }
        #expect(box.allSatisfy { $0.x <= 21 && $0.y <= 21 }, "the speck must not be sewn")
        let report = QualityAnalyzer.analyze(plan, document: doc)
        #expect(report.issues.contains { $0.message.contains("too small to sew") && $0.message.hasPrefix("1 detail") })
    }

    @Test func aPlainSquareIsAllArea() throws {
        let square = VectorShape(subPaths: [SubPath(points: rect(0, 0, 20, 20), closed: true)])
        let split = try #require(ShapeMerger.splitThickAndThin(square, thinWidthMM: 3.0, overlapMM: 0.4))
        #expect(split.thick.count == 1 && split.thin.isEmpty)
    }

    /// A 2.5-4 mm ring straddling a 3 mm threshold is one stroke of
    /// varying width, not eleven fill patches alternating with satin
    /// (the Red Sox halo).
    @Test func aRingNearTheThresholdIsAllStroke() throws {
        var outer: [Point2D] = [], hole: [Point2D] = []
        for i in 0..<72 {
            let a = Double(i) / 72 * 2 * .pi
            let r = 20.0 + 0.75 * sin(3 * a) // outer radius varies 19.25-20.75
            outer.append(Point2D(30 + r * cos(a), 30 + r * sin(a)))
            hole.append(Point2D(30 + 17 * cos(a), 30 + 17 * sin(a)))
        }
        let ring = VectorShape(subPaths: [SubPath(points: outer, closed: true), SubPath(points: hole.reversed(), closed: true)])
        let split = try #require(ShapeMerger.splitThickAndThin(ring, thinWidthMM: 3.0, overlapMM: 0.4))
        #expect(split.thick.isEmpty && split.thin.count == 1)
    }

    /// A tapering tip is thin near its end but is part of its area: a
    /// triangle's point must not be cut off as a "stroke".
    @Test func aTaperingTipStaysWithItsArea() throws {
        let leaf = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20), Point2D(-25, 10),
        ], closed: true)])
        let split = try #require(ShapeMerger.splitThickAndThin(leaf, thinWidthMM: 3.0, overlapMM: 0.4))
        #expect(split.thin.isEmpty, "the point of the leaf is a tip, not a line")
        #expect(split.thick.count == 1)
    }

    @Test func separatingObjectsMakesFillAreasAndSatinOrBeanStrokesInThatOrder() {
        var parameters = StitchGenerationParameters()
        parameters.pullCompensationMM = 0; parameters.pushCompensationMM = 0
        let object = EmbroideryObject(name: "Mark", shape: squareWithLine(), stitchType: .tatamiFill,
                                      threadColor: .generic(RGBColor(hex: 0x224422)), parameters: parameters)
        let result = StitchTypeClassifier.separateStrokesFromAreas([object])
        #expect(result.count == 2)
        #expect(result[0].name == "Mark (area)" && result[0].stitchType == .tatamiFill)
        #expect(result[1].name == "Mark (outline)")
        #expect(result[1].stitchType == .satin || result[1].stitchType == .tripleRun, "a stroke is never fill")
        #expect(result.allSatisfy { $0.stitchTypeIsManualOverride }, "the sibling-consensus passes must leave these alone")
        #expect(result[1].parameters.allowBranchingSatin)
        // The area's own fill and the stroke's satin both survive the
        // passes that used to re-vote same-colour siblings.
        let harmonized = StitchTypeClassifier.reconcileRunningStitchOutliers(StitchTypeClassifier.harmonizeSameColorFillConsistency(result))
        #expect(harmonized.map { $0.stitchType } == result.map { $0.stitchType })
    }

    /// A one-hole shape is only a satin ring if the radial sweep from the
    /// hole's centre reaches the whole outline -- a long ribbon with a
    /// small loop at one end is not a ring, whatever its hole count.
    @Test func aRibbonWithALoopIsNotARing() {
        // 60 mm x 1.5 mm ribbon with a 6 mm loop at its right end.
        var outer: [Point2D] = [Point2D(0, 0), Point2D(54, 0)]
        for i in 0...24 { let a = -Double.pi / 2 + Double(i) / 24 * 2 * .pi; outer.append(Point2D(57 + 3.75 * cos(a), 3.75 + 3.75 * sin(a))) }
        outer.append(Point2D(54, 1.5)); outer.append(Point2D(0, 1.5))
        var hole: [Point2D] = []
        for i in 0..<24 { let a = Double(i) / 24 * 2 * .pi; hole.append(Point2D(57 + 2.25 * cos(a), 3.75 + 2.25 * sin(a))) }
        let ribbon = VectorShape(subPaths: [SubPath(points: outer, closed: true), SubPath(points: hole, closed: true)])
        #expect(!SatinColumnGenerator.canRepresentAsRingSatinColumn(shape: ribbon))
        var annulusOuter: [Point2D] = [], annulusHole: [Point2D] = []
        for i in 0..<48 { let a = Double(i) / 48 * 2 * .pi; annulusOuter.append(Point2D(10 * cos(a), 10 * sin(a))); annulusHole.append(Point2D(7 * cos(a), 7 * sin(a))) }
        let annulus = VectorShape(subPaths: [SubPath(points: annulusOuter, closed: true), SubPath(points: annulusHole, closed: true)])
        #expect(SatinColumnGenerator.canRepresentAsRingSatinColumn(shape: annulus))
    }
}
