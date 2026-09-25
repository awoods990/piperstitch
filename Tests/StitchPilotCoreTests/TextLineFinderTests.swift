import Testing
import Foundation
@testable import StitchPilotCore

/// `TextLineFinder`: text found by geometry alone -- a row of letter-sized
/// shapes of one colour at one height -- so the pipeline can leave a
/// too-small tagline out whole and the setup can offer to re-type it.
struct TextLineFinderTests {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [Point2D(x, y), Point2D(x + w, y), Point2D(x + w, y + h), Point2D(x, y + h)], closed: true)])
    }

    @Test func aRowOfLetterSizedShapesIsOneLine() {
        // Six "letters" 12 px tall in a row, a big logo mark above, a speck.
        var shapes: [VectorShape] = []
        var colors: [RGBColor?] = []
        for i in 0..<6 { shapes.append(rect(20 + Double(i) * 14, 100, 9, 12)); colors.append(RGBColor(hex: 0x203060)) }
        shapes.append(rect(20, 10, 80, 70)); colors.append(RGBColor(hex: 0x203060))
        shapes.append(rect(150, 120, 2, 2)); colors.append(RGBColor(hex: 0x203060))
        let lines = TextLineFinder.find(shapes: shapes, fillColors: colors, imageHeightPixels: 160)
        #expect(lines.count == 1)
        guard let line = lines.first else { return }
        #expect(line.shapeIndices == [0, 1, 2, 3, 4, 5])
        #expect(abs(line.capHeightPixels - 12) < 0.01)
        #expect(abs(line.rotationDegrees) < 1)
        #expect(!line.curved)
        #expect(line.suggestsBold, "solid rectangles are as bold as letters get")
    }

    @Test func aTiltedRowReportsItsAngleAndDifferentColoursDoNotJoin() {
        var shapes: [VectorShape] = []
        var colors: [RGBColor?] = []
        // A row rising to the right at about 15 degrees (Y down, so y falls).
        for i in 0..<5 {
            let x = 20 + Double(i) * 16, y = 100 - Double(i) * 16 * tan(15 * Double.pi / 180)
            shapes.append(rect(x, y, 10, 12)); colors.append(RGBColor(hex: 0x000000))
        }
        // Three shapes of another colour on the same row: not the same line.
        for i in 0..<3 { shapes.append(rect(120 + Double(i) * 16, 100, 10, 12)); colors.append(RGBColor(hex: 0xC02020)) }
        let lines = TextLineFinder.find(shapes: shapes, fillColors: colors, imageHeightPixels: 160)
        #expect(lines.count == 2, "one black line and one red line, got \(lines.count)")
        if let black = lines.first(where: { $0.color == RGBColor(hex: 0x000000) }) {
            #expect(abs(abs(black.rotationDegrees) - 15) < 3, "rotation \(black.rotationDegrees)")
        }
    }

    @Test func aTitleOverItsTaglineIsTwoLinesNotNone() {
        // "Sigma Chi" over "FOUNDATION": big letters with a small line
        // directly beneath, same colour, close enough to chain. The
        // studio file that showed this lost both lines to one fused
        // group's height spread.
        var shapes: [VectorShape] = []
        var colors: [RGBColor?] = []
        for i in 0..<8 { shapes.append(rect(100 + Double(i) * 60, 100, 44, i % 3 == 1 ? 70 : 100)); colors.append(RGBColor(hex: 0x00355E)) }
        for i in 0..<10 { shapes.append(rect(200 + Double(i) * 24, 215, 18, 30)); colors.append(RGBColor(hex: 0x00355E)) }
        let lines = TextLineFinder.find(shapes: shapes, fillColors: colors, imageHeightPixels: 400)
        #expect(lines.count == 2, "title and tagline, got \(lines.count)")
        let caps = lines.map { $0.capHeightPixels }.sorted()
        #expect(caps.count == 2 && abs(caps[0] - 30) < 0.01 && abs(caps[1] - 100) < 0.01, "caps \(caps)")
        #expect(lines.first(where: { $0.capHeightPixels > 50 })?.mixedCase == true)
        #expect(lines.first(where: { $0.capHeightPixels < 50 })?.mixedCase == false)
    }

    @Test func twoRowsOfOneTaglineAreTwoLines() {
        var shapes: [VectorShape] = []
        var colors: [RGBColor?] = []
        for row in 0..<2 {
            for i in 0..<7 { shapes.append(rect(20 + Double(i) * 14, 100 + Double(row) * 20, 9, 12)); colors.append(RGBColor(hex: 0x000000)) }
        }
        let lines = TextLineFinder.find(shapes: shapes, fillColors: colors, imageHeightPixels: 200)
        #expect(lines.count == 2, "two rows, got \(lines.count)")
        #expect(lines.allSatisfy { !$0.curved && $0.shapeIndices.count == 7 })
    }

    @Test func vectorInputMeasuresAgainstTheDrawingItself() {
        // No pixel frame (an SVG): the drawing's own height sets the size
        // limits, so a tagline is found in its native units.
        var shapes: [VectorShape] = []
        var colors: [RGBColor?] = []
        shapes.append(rect(0, 0, 484, 120)); colors.append(RGBColor(hex: 0x092342))
        for i in 0..<18 { shapes.append(rect(Double(i) * 26, 148, 20, 29)); colors.append(RGBColor(hex: 0x092342)) }
        let lines = TextLineFinder.find(shapes: shapes, fillColors: colors, imageHeightPixels: 0)
        #expect(lines.count == 1)
        #expect(lines.first?.shapeIndices.count == 18)
        #expect(abs((lines.first?.capHeightPixels ?? 0) - 29) < 0.01)
    }

    @Test func staggeredShapesInARowAreNotText() {
        // Six "feathers": alike in size, evenly spaced, bottoms all over
        // the place (a steady slope would just be a tilted line).
        var shapes: [VectorShape] = []
        var colors: [RGBColor?] = []
        for (i, dy) in [0.0, 8.0, 16.0, 0.0, 8.0, 16.0, 0.0].enumerated() { shapes.append(rect(20 + Double(i) * 14, 100 + dy, 9, 12)); colors.append(RGBColor(hex: 0x2080E0)) }
        let lines = TextLineFinder.find(shapes: shapes, fillColors: colors, imageHeightPixels: 200)
        #expect(lines.isEmpty, "staggered row read as text")
    }

    @Test func aShortCurvedRunIsNotDroppedOnTheEnginesOwn() {
        var shapes: [VectorShape] = []
        var colors: [RGBColor?] = []
        for i in 0..<6 {
            let angle = (-50 + Double(i) * 20) * Double.pi / 180
            shapes.append(rect(100 + 70 * sin(angle) - 5, 100 - 70 * cos(angle) - 6, 10, 12)); colors.append(RGBColor(hex: 0x000000))
        }
        let lines = TextLineFinder.find(shapes: shapes, fillColors: colors, imageHeightPixels: 200)
        #expect(lines.count == 1 && lines[0].curved)
        #expect(lines.first?.dropsWhenTooSmall == false)
    }

    @Test func lettersOnAnArcAreCurved() {
        var shapes: [VectorShape] = []
        var colors: [RGBColor?] = []
        for i in 0..<9 {
            let angle = (-60 + Double(i) * 15) * Double.pi / 180
            let cx = 100 + 70 * sin(angle), cy = 100 - 70 * cos(angle)
            shapes.append(rect(cx - 5, cy - 6, 10, 12)); colors.append(RGBColor(hex: 0x000000))
        }
        let lines = TextLineFinder.find(shapes: shapes, fillColors: colors, imageHeightPixels: 200)
        #expect(lines.count == 1)
        #expect(lines.first?.curved == true)
        if let r = lines.first?.arcRadiusPixels { #expect(abs(r - 70) < 8, "radius \(r)") }
    }

    @Test func minimumCapHeightFollowsThreadWeight() {
        #expect(TextLineFinder.minimumCapHeightMM(for: .wt40) == 5)
        #expect(TextLineFinder.minimumCapHeightMM(for: .wt60) == 4)
        #expect(TextLineFinder.minimumCapHeightMM(for: .wt30) == 6)
    }

    @Test func omittedTextLinesSurviveTheDocumentRoundTripAndAreReported() throws {
        var doc = StitchDocument(name: "d", physicalWidthMM: 50, physicalHeightMM: 50, objects: [
            EmbroideryObject(name: "square", shape: rect(5, 5, 20, 20), stitchType: .tatamiFill, threadColor: .generic(RGBColor(hex: 0x000000))),
        ], omittedTextLines: 2)
        let data = try JSONEncoder().encode(doc)
        doc = try JSONDecoder().decode(StitchDocument.self, from: data)
        #expect(doc.omittedTextLines == 2)
        let plan = try DigitizePipeline.flatten(doc)
        let report = QualityAnalyzer.analyze(plan, document: doc)
        #expect(report.issues.contains { $0.message.hasPrefix("2 lines of text") })
    }
}
