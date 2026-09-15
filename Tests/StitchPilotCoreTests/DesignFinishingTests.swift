import Foundation
import Testing
@testable import StitchPilotCore

/// Overlap removal on vector import (C2) and finishing touches (C7) --
/// `DesignFinishing`, docs/WILCOM_MANUAL_REVIEW.md.
struct DesignFinishingTests {
    private func disc(center: Point2D, radius: Double) -> VectorShape {
        VectorShape(subPaths: [SubPath(points: (0..<64).map { i in
            let t = Double(i) / 64 * 2 * .pi
            return Point2D(center.x + radius * cos(t), center.y + radius * sin(t))
        }, closed: true)])
    }
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [Point2D(x, y), Point2D(x + w, y), Point2D(x + w, y + h), Point2D(x, y + h)], closed: true)])
    }

    @Test func laterShapesCutTheirFootprintOutOfEarlierOnesKeepingARegistrationBand() {
        // A badge: big red disc, white disc on it, blue disc on that, a bar on top.
        let red = disc(center: Point2D(50, 50), radius: 45)
        let white = disc(center: Point2D(50, 50), radius: 32)
        let blue = disc(center: Point2D(50, 50), radius: 22)
        let bar = rect(42, 20, 16, 60)
        let result = DesignFinishing.removeOverlaps([red, white, blue, bar], opaque: [true, true, true, true])
        #expect(result.count == 4)
        #expect(result[0].count == 1 && result[1].count == 1, "red and white stay single rings")
        #expect(result[2].count == 2, "blue is cut in two by the bar: \(result[2].count) pieces")
        let cutRed = result[0][0], cutWhite = result[1][0]
        let cutBlue = VectorShape(subPaths: result[2].flatMap { $0.subPaths })
        // The bar (on top) is untouched -- exact geometry.
        #expect(result[3][0].subPaths[0].points == bar.subPaths[0].points)
        // Red became a ring: its centre is no longer inside it, its rim still is.
        let redPolys = cutRed.subPaths.map { $0.points }
        #expect(!PolygonGeometry.pointInPolygons(Point2D(50, 50), polygons: redPolys))
        #expect(PolygonGeometry.pointInPolygons(Point2D(50, 10), polygons: redPolys))
        // ... but keeps the 1.5mm band under the white disc's edge (r 32 → red reaches in to ~30.5).
        #expect(PolygonGeometry.pointInPolygons(Point2D(50, 50 - 31.2), polygons: redPolys), "registration band missing")
        #expect(!PolygonGeometry.pointInPolygons(Point2D(50, 50 - 29.5), polygons: redPolys), "cut too shallow")
        // White lost the blue disc and the bar; blue lost the bar.
        #expect(!PolygonGeometry.pointInPolygons(Point2D(50, 50), polygons: cutWhite.subPaths.map { $0.points }))
        #expect(!PolygonGeometry.pointInPolygons(Point2D(50, 50), polygons: cutBlue.subPaths.map { $0.points }))
        #expect(PolygonGeometry.pointInPolygons(Point2D(50 + 15, 50), polygons: cutBlue.subPaths.map { $0.points }))
        // Stitch count drops: each region sews once.
        var p = StitchGenerationParameters(); p.underlayType = UnderlayType.none
        let before = [red, white, blue, bar].map { TatamiFillGenerator.generate(for: $0, parameters: p).count }.reduce(0, +)
        let after = [cutRed, cutWhite, cutBlue, bar].map { TatamiFillGenerator.generate(for: $0, parameters: p).count }.reduce(0, +)
        #expect(Double(after) < Double(before) * 0.75, "before \(before) after \(after)")
    }

    @Test func fullyCoveredShapesAndTinyLeftoversDisappear() {
        let under = rect(10, 10, 10, 10)
        let over = rect(8, 8, 14, 14)
        let result = DesignFinishing.removeOverlaps([under, over], opaque: [true, true])
        #expect(result[0].isEmpty, "a shape entirely under another sews nowhere")
        // A sliver under 4mm² left over is dropped too (its registration
        // band doesn't count toward keeping it).
        let wide = rect(0, 0, 40, 10)
        let almost = rect(0.3, -1, 40, 12)   // leaves a 0.3 × 10 strip = 3mm²
        let r2 = DesignFinishing.removeOverlaps([wide, almost], opaque: [true, true])
        #expect(r2[0].isEmpty)
        // A real strip survives, with its band.
        let r2b = DesignFinishing.removeOverlaps([wide, rect(3, -1, 40, 12)], opaque: [true, true])
        let strip = try! #require(r2b[0].first).boundingBox
        #expect(strip.maxX > 4.2 && strip.maxX < 4.8, "3mm strip + 1.5mm band: \(strip)")
        // An unfilled outline on top covers nothing.
        let r3 = DesignFinishing.removeOverlaps([under, over], opaque: [true, false])
        #expect(r3[0].first?.subPaths[0].points == under.subPaths[0].points)
    }

    @Test func outlinesAndBorderAreAddedOnce() throws {
        let a = EmbroideryObject(name: "A", shape: rect(0, 0, 20, 20), stitchType: .tatamiFill, threadColor: .generic(RGBColor(hex: 0xFF0000)))
        let b = EmbroideryObject(name: "B", shape: rect(30, 0, 20, 20), stitchType: .satin, threadColor: .generic(RGBColor(hex: 0x0000FF)))
        var doc = StitchDocument(name: "D", physicalWidthMM: 60, physicalHeightMM: 30, objects: [a, b])
        let outlines = DesignFinishing.outlineObjects(for: doc)
        #expect(outlines.count == 2 && outlines.allSatisfy { $0.stitchType == .tripleRun })
        #expect(outlines[0].threadColor.rgb == a.threadColor.rgb && outlines[0].name == "Outline of A")
        doc.objects += outlines
        #expect(DesignFinishing.outlineObjects(for: doc).isEmpty, "no second outline for the same object")
        // Outlines sew after their colour's fill.
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 0)

        let border = try #require(DesignFinishing.borderObject(for: doc, threadColor: .generic(RGBColor(hex: 0x000000))))
        #expect(border.name == "Border")
        let box = border.shape.boundingBox
        #expect(box.minX < -2 && box.maxX > 52 && box.minY < -2 && box.maxY > 22, "ring surrounds the design: \(box)")
        // The ring is hollow: the design's interior isn't in it.
        #expect(!PolygonGeometry.pointInPolygons(Point2D(10, 10), polygons: border.shape.subPaths.map { $0.points }))
        #expect(PolygonGeometry.pointInPolygons(Point2D(-1.2, 10), polygons: border.shape.subPaths.map { $0.points }))
    }
}
