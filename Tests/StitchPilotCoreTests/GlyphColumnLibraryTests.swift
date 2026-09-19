import Testing
import Foundation
@testable import StitchPilotCore

/// The keyboard-font library: glyphs digitized once as satin columns and
/// sewn at any size from the stored chords.
struct GlyphColumnLibraryTests {
    @Test func everyWebFontHasALibraryWithTheBasicSet() {
        let ids = ["roboto", "roboto-medium", "open-sans", "open-sans-semibold", "montserrat", "oswald", "playfair", "merriweather", "alfa-slab", "anton", "bebas-neue", "lobster", "pacifico", "dancing-script"]
        for id in ids {
            guard let font = GlyphColumnLibrary.font(id) else { Issue.record("no library for \(id)"); continue }
            let missing = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".filter { font.glyphs[String($0)] == nil }
            #expect(missing.isEmpty, "\(id) is missing \(missing)")
        }
    }

    @Test func aGlyphSewsAtFourMillimetresFromItsStoredColumns() throws {
        let font = try #require(GlyphColumnLibrary.font("roboto"))
        let columns = try #require(GlyphColumnLibrary.columns(font: font, character: "A", capHeightMM: 4, origin: Point2D(10, 20)))
        #expect(columns.count >= 2, "an A is strokes and a crossbar, not one column")
        var parameters = StitchGenerationParameters()
        parameters.allowBranchingSatin = true
        let runs = SatinColumnGenerator.sewColumns(columns, parameters: parameters, polygons: [])
        let points = runs.flatMap { $0 }
        #expect(points.count > 40)
        // Placed at the origin, scaled to a 4 mm capital: inside a box a
        // little larger than the letter, above the baseline.
        for p in points {
            #expect(p.x > 9 && p.x < 15, "x \(p.x)")
            #expect(p.y > 15.5 && p.y < 20.5, "y \(p.y)")
        }
        // Placed columns are in millimetres: a 4 mm bold A's strokes are
        // well over half a millimetre wide.
        let widths = zip(columns[0].railA, columns[0].railB).map { $0.distance(to: $1) }
        #expect((widths.max() ?? 0) > 0.4)
    }

    @Test func columnsRoundTripThroughTheDocument() throws {
        let column = SatinColumn(railA: [Point2D(0, 0), Point2D(10, 0)], railB: [Point2D(0, 2), Point2D(10, 2)], travelOut: true)
        let object = EmbroideryObject(name: "L", shape: VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(10, 0), Point2D(10, 2), Point2D(0, 2)], closed: true)]),
                                      stitchType: .satin, threadColor: .generic(RGBColor(hex: 0x000000)), satinColumns: [column])
        let data = try JSONEncoder().encode(object)
        let back = try JSONDecoder().decode(EmbroideryObject.self, from: data)
        #expect(back.satinColumns == [column])
        // And the pipeline sews them rather than deriving rails.
        let doc = StitchDocument(name: "t", physicalWidthMM: 20, physicalHeightMM: 10, objects: [back])
        let plan = try DigitizePipeline.flatten(doc)
        #expect(plan.stitchCount > 20)
    }
}
