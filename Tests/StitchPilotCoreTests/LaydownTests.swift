import Foundation
import Testing
@testable import StitchPilotCore

/// Laydown stitch for napped fabrics -- `LaydownGenerator`, docs/
/// WILCOM_MANUAL_REVIEW.md C1.
struct LaydownTests {
    private func ring(center: Point2D, outer: Double, inner: Double) -> VectorShape {
        func circle(_ r: Double) -> SubPath {
            SubPath(points: (0..<48).map { i in
                let t = Double(i) / 48 * 2 * .pi
                return Point2D(center.x + r * cos(t), center.y + r * sin(t))
            }, closed: true)
        }
        return VectorShape(subPaths: [circle(outer), circle(inner)])
    }

    private func document(laydown: LaydownSettings?) -> StitchDocument {
        var p = StitchGenerationParameters()
        p.fabricType = .terry
        let a = EmbroideryObject(name: "ring", shape: ring(center: Point2D(20, 20), outer: 12, inner: 5), stitchType: .tatamiFill,
                                 threadColor: .generic(RGBColor(hex: 0x2244AA), name: "Blue"), parameters: p)
        let b = EmbroideryObject(name: "dot", shape: ring(center: Point2D(48, 20), outer: 6, inner: 0.5), stitchType: .tatamiFill,
                                 threadColor: .generic(RGBColor(hex: 0x2244AA), name: "Blue"), parameters: p)
        return StitchDocument(name: "L", physicalWidthMM: 60, physicalHeightMM: 40, objects: [a, b], laydown: laydown)
    }

    @Test func footprintGrowsByTheMarginAndCoversHoles() throws {
        let settings = LaydownSettings(threadColor: .generic(RGBColor(hex: 0xFFFFFF), name: "White"), marginMM: 2)
        let doc = document(laydown: settings)
        let footprint = try #require(LaydownGenerator.footprint(for: doc, settings: settings))
        let box = footprint.boundingBox
        #expect(abs(box.minX - 6) < 0.6 && abs(box.maxX - 56) < 0.6, "grown by ~2mm each side: \(box)")
        // The ring's counter is covered (no hole subpath inside the ring).
        let polygons = footprint.subPaths.map { $0.points }
        #expect(PolygonGeometry.pointInPolygons(Point2D(20, 20), polygons: polygons), "hole should be covered")
        // Two separate shapes 10mm apart stay separate islands.
        #expect(!PolygonGeometry.pointInPolygons(Point2D(37, 20), polygons: polygons))
        // Without hole covering the counter stays open.
        var open = settings; open.coverHoles = false
        let openPolys = try #require(LaydownGenerator.footprint(for: doc, settings: open)).subPaths.map { $0.points }
        #expect(!PolygonGeometry.pointInPolygons(Point2D(20, 20), polygons: openPolys))
    }

    @Test func laydownSewsFirstInItsOwnColourAndIsOpen() throws {
        let white = ThreadColor.generic(RGBColor(hex: 0xFFFFFF), name: "White")
        let with = try DigitizePipeline.flattenWithColors(document(laydown: LaydownSettings(threadColor: white)))
        let without = try DigitizePipeline.flattenWithColors(document(laydown: nil))
        #expect(with.colors.first?.rgb == white.rgb)
        #expect(with.colors.count == without.colors.count + 1)
        #expect(with.plan.colorChangeCount == without.plan.colorChangeCount + 1)
        // Open: two layers at 3mm spacing over ~600mm² add far fewer
        // stitches than the cover fill itself.
        let added = with.plan.stitchCount - without.plan.stitchCount
        #expect(added > 50 && added < without.plan.stitchCount, "added \(added) of \(without.plan.stitchCount)")
        // Every laydown stitch lies within the footprint (margin + a hair).
        let settings = LaydownSettings(threadColor: white)
        // Row ends sit exactly on the boundary; test against a footprint
        // grown by another 0.3mm so those count as inside.
        var grown = settings; grown.marginMM += 0.3
        let footprint = try #require(LaydownGenerator.footprint(for: document(laydown: settings), settings: grown)).subPaths.map { $0.points }
        var firstBlock: [Point2D] = []
        for c in with.plan.commands {
            if case .colorChange = c { break }
            if case .stitch(let p) = c { firstBlock.append(p) }
        }
        let outside = firstBlock.filter { !PolygonGeometry.pointInPolygons($0, polygons: footprint) }
        #expect(Double(outside.count) < Double(firstBlock.count) * 0.02, "\(outside.count) of \(firstBlock.count) outside")
        // One layer is about half of two.
        let one = try DigitizePipeline.flatten(document(laydown: LaydownSettings(threadColor: white, twoLayers: false)))
        let oneAdded = one.stitchCount - without.plan.stitchCount
        #expect(Double(oneAdded) > Double(added) * 0.35 && Double(oneAdded) < Double(added) * 0.65, "one layer \(oneAdded) vs two \(added)")
    }

    @Test func laydownRoundTripsAndOldFilesDecodeWithout() throws {
        let doc = document(laydown: LaydownSettings(threadColor: .generic(RGBColor(hex: 0xEEEEEE), name: "Ecru"), marginMM: 3))
        let back = try JSONDecoder().decode(StitchDocument.self, from: JSONEncoder().encode(doc))
        #expect(back.laydown == doc.laydown)
        let old = try JSONDecoder().decode(StitchDocument.self, from: JSONEncoder().encode(document(laydown: nil)))
        #expect(old.laydown == nil)
        #expect(LaydownSettings.isRecommended(for: .terry) && !LaydownSettings.isRecommended(for: .knit))
    }

    @Test func readinessWarnsOnTerryWithoutALaydown() throws {
        let bare = document(laydown: nil)
        let report = QualityAnalyzer.analyze(try DigitizePipeline.flatten(bare), document: bare)
        #expect(report.issues.contains { $0.message.hasPrefix("No laydown stitch") && $0.severity == .warning })
        let with = document(laydown: LaydownSettings(threadColor: .generic(RGBColor(hex: 0xFFFFFF))))
        let report2 = QualityAnalyzer.analyze(try DigitizePipeline.flatten(with), document: with)
        #expect(!report2.issues.contains { $0.message.hasPrefix("No laydown stitch") })
    }
}
