import Testing
import Foundation
@testable import StitchPilotCore

/// `SmallTextRescue`: a tagline that misses the sewable floor by a little
/// is grown into range rather than left out, and one that misses by a lot
/// is answered with the size that would carry it.
struct SmallTextRescueTests {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> VectorShape {
        VectorShape(subPaths: [SubPath(points: [Point2D(x, y), Point2D(x + w, y), Point2D(x + w, y + h), Point2D(x, y + h)], closed: true)])
    }

    /// Eight letters `cap` tall in a row, alone in the artwork.
    private func tagline(cap: Double) -> (lines: [TextLine], shapes: [VectorShape]) {
        var shapes: [VectorShape] = []
        var colors: [RGBColor?] = []
        for i in 0..<8 {
            shapes.append(rect(20 + Double(i) * cap, 100, cap * 0.7, cap))
            colors.append(RGBColor(hex: 0x203060))
        }
        return (TextLineFinder.find(shapes: shapes, fillColors: colors, imageHeightPixels: 400), shapes)
    }

    @Test func aLineThatMissesByALittleIsGrownRatherThanLeftOut() {
        let (lines, shapes) = tagline(cap: 36)
        #expect(lines.count == 1)
        // 36 px at 0.1 mm/px is 3.6 mm: under the 4 mm floor by a tenth.
        let plan = SmallTextRescue.plan(lines: lines, shapes: shapes, scaleToMM: 0.1, minimumCapHeightMM: 4.0)
        #expect(plan.grownLines == 1)
        #expect(plan.omittedLines == 0)
        #expect(plan.dropped.isEmpty)
        guard let scale = plan.growth[0] else { return }
        #expect(scale >= 4.0 / 3.6 - 0.001, "grown at least to the floor")
        #expect(scale <= SmallTextRescue.maximumGrowth)
    }

    @Test func aLineThatWouldHaveToDoubleIsLeftOutInstead() {
        let (lines, shapes) = tagline(cap: 18)      // 1.8 mm: it needs 2.2x
        let plan = SmallTextRescue.plan(lines: lines, shapes: shapes, scaleToMM: 0.1, minimumCapHeightMM: 4.0)
        #expect(plan.grownLines == 0, "growing it that far would be a redesign, not a nudge")
        #expect(plan.omittedLines == 1)
        #expect(plan.dropped.count == 8)
    }

    @Test func aLineWithNoRoomToGrowIsLeftOut() {
        var (lines, shapes) = tagline(cap: 36)
        // A logo mark hard against the end of the line, as a flourish or a
        // rule usually is -- tall enough that it is plainly not a ninth
        // letter, close enough that there is nowhere for the letters to go.
        shapes.append(rect(20 + 8 * 36 + 2, 40, 60, 160))
        lines = TextLineFinder.find(shapes: shapes,
                                    fillColors: Array(repeating: RGBColor(hex: 0x203060), count: shapes.count),
                                    imageHeightPixels: 400)
        let plan = SmallTextRescue.plan(lines: lines, shapes: shapes, scaleToMM: 0.1, minimumCapHeightMM: 4.0)
        #expect(plan.grownLines == 0)
    }

    @Test func theSizeThatWouldCarryEveryLineIsReported() {
        let (lines, _) = tagline(cap: 20)           // 2.0 mm against a 4 mm floor
        let width = SmallTextRescue.widthThatSewsAllText(lines: lines, currentWidthMM: 75,
                                                         scaleToMM: 0.1, minimumCapHeightMM: 4.0)
        #expect(width != nil)
        if let width { #expect(abs(width - 150) < 0.5, "twice the size, because the text is half of what it needs") }
    }

    @Test func artworkWhoseTextAlreadySewsIsLeftAlone() {
        let (lines, shapes) = tagline(cap: 60)      // 6 mm: comfortably sewable
        let plan = SmallTextRescue.plan(lines: lines, shapes: shapes, scaleToMM: 0.1, minimumCapHeightMM: 4.0)
        #expect(plan.isEmpty)
        #expect(SmallTextRescue.widthThatSewsAllText(lines: lines, currentWidthMM: 75, scaleToMM: 0.1,
                                                     minimumCapHeightMM: 4.0) == nil)
    }
}
