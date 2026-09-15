import Foundation
import Testing
@testable import StitchPilotCore

/// Width-based auto spacing, inside-of-bend stitch shortening and
/// long-stitch auto split -- see `SatinSpacing` and
/// docs/WILCOM_MANUAL_REVIEW.md A2/A3/A6.
struct SatinSpacingTests {
    private func straightRails(lengthMM: Double, widthMM: Double, samples: Int) -> (a: [Point2D], b: [Point2D]) {
        let a = (0..<samples).map { Point2D(Double($0) / Double(samples - 1) * lengthMM, 0) }
        let b = a.map { Point2D($0.x, widthMM) }
        return (a, b)
    }

    /// A quarter-circle bend: outer rail radius `outer`, inner `outer - width`.
    private func bentRails(outerRadius: Double, widthMM: Double, samples: Int) -> (a: [Point2D], b: [Point2D]) {
        let inner = outerRadius - widthMM
        var a: [Point2D] = [], b: [Point2D] = []
        for i in 0..<samples {
            let t = Double(i) / Double(samples - 1) * .pi / 2
            a.append(Point2D(outerRadius * cos(t), outerRadius * sin(t)))
            b.append(Point2D(inner * cos(t), inner * sin(t)))
        }
        return (a, b)
    }

    private func spacings(_ points: [Point2D]) -> [Double] {
        zip(points, points.dropFirst()).map { $0.distance(to: $1) }
    }

    @Test func spacingFactorWidensNarrowAndTightensWide() {
        #expect(SatinSpacing.spacingFactor(forWidthMM: 5.0) == 1.0)
        #expect(SatinSpacing.spacingFactor(forWidthMM: 1.2) > 1.3)
        #expect(SatinSpacing.spacingFactor(forWidthMM: 10.0) < 0.9)
        // Monotonically non-increasing with width.
        var last = Double.infinity
        for w in stride(from: 0.5, through: 15.0, by: 0.25) {
            let f = SatinSpacing.spacingFactor(forWidthMM: w)
            #expect(f <= last + 1e-12)
            last = f
        }
    }

    @Test func decimateSpacesNarrowColumnsWiderThanWideOnes() {
        var p = StitchGenerationParameters()
        p.satinDensityMM = 0.4
        let fine = 0.4 / SatinSpacing.oversampling
        let narrow = straightRails(lengthMM: 40, widthMM: 1.2, samples: Int(40 / fine) + 1)
        let wide = straightRails(lengthMM: 40, widthMM: 10, samples: Int(40 / fine) + 1)
        let narrowKept = SatinSpacing.decimate(railA: narrow.a, railB: narrow.b, parameters: p)
        let wideKept = SatinSpacing.decimate(railA: wide.a, railB: wide.b, parameters: p)
        let narrowSpacing = 40.0 / Double(narrowKept.a.count - 1)
        let wideSpacing = 40.0 / Double(wideKept.a.count - 1)
        #expect(narrowSpacing > 0.5, "narrow column should space wider than nominal, got \(narrowSpacing)")
        #expect(wideSpacing < 0.38, "wide column should space tighter than nominal, got \(wideSpacing)")
        #expect(narrowKept.a.first == narrow.a.first && narrowKept.a.last == narrow.a.last)
        // Exact, even spacing -- not quantised to the fine grid.
        let steps = spacings(wideKept.a).dropLast()
        #expect(steps.allSatisfy { abs($0 - steps[steps.startIndex]) < 1e-6 }, "uneven: \(steps.prefix(4))")

        p.satinAutoSpacing = false
        let flat = SatinSpacing.decimate(railA: narrow.a, railB: narrow.b, parameters: p)
        #expect(abs(40.0 / Double(flat.a.count - 1) - 0.4) < 0.02, "auto spacing off means the nominal density everywhere")
    }

    @Test func decimateMeasuresAlongTheOuterEdgeOfABend() {
        var p = StitchGenerationParameters()
        p.satinDensityMM = 0.4
        p.satinSpacingOffsetFraction = 0
        p.satinAutoSpacing = false
        let bend = bentRails(outerRadius: 10, widthMM: 4, samples: 800)
        let kept = SatinSpacing.decimate(railA: bend.a, railB: bend.b, parameters: p)
        let outerSteps = spacings(kept.a)
        let interior = outerSteps.dropFirst().dropLast()
        // Outer-edge spacing lands on the nominal density (within the
        // fine grid's placement granularity) even though the inner rail
        // is much shorter.
        #expect(interior.allSatisfy { $0 > 0.3 && $0 < 0.5 }, "outer steps: \(interior.prefix(5))")
    }

    @Test func shorteningPullsAlternateStitchesOffTheInnerRail() {
        var p = StitchGenerationParameters()
        p.satinDensityMM = 0.4
        p.satinAutoSpacing = false
        p.satinSpacingOffsetFraction = 0
        let bend = bentRails(outerRadius: 6, widthMM: 4.5, samples: 800)  // inner radius 1.5: heavy inner bunching
        let kept = SatinSpacing.decimate(railA: bend.a, railB: bend.b, parameters: p)
        let a = kept.a, b = kept.b
        let crossings = SatinSpacing.shorten(expandedA: a, expandedB: b, range: 0...(a.count - 1), parameters: p)
        #expect(crossings.count == a.count)
        // Outer endpoints untouched; some inner endpoints moved off the rail.
        let outerMoved = zip(crossings, a).filter { $0.0.a != $0.1 }.count
        let innerMoved = zip(crossings, b).filter { $0.0.b != $0.1 }.count
        #expect(outerMoved == 0)
        #expect(innerMoved > crossings.count / 4, "expected many shortened inner stitches, got \(innerMoved)")
        // A shortened stitch is shorter than the crossing but keeps most of it.
        for (c, original) in zip(crossings, zip(a, b)) where c.b != original.1 {
            let full = original.0.distance(to: original.1)
            let now = c.a.distance(to: c.b)
            #expect(now > full * 0.55 && now < full * 0.97)
        }
        // Never two identical shortening fractions in a row (jagged pattern).
        p.satinShortenBelowFraction = 0
        let untouched = SatinSpacing.shorten(expandedA: a, expandedB: b, range: 0...(a.count - 1), parameters: p)
        #expect(untouched.allSatisfy { c in a.contains(c.a) && b.contains(c.b) }, "threshold 0 disables shortening")
    }

    @Test func straightColumnIsNeverShortened() {
        var p = StitchGenerationParameters()
        p.satinDensityMM = 0.4
        let rails = straightRails(lengthMM: 20, widthMM: 3, samples: 51)
        let crossings = SatinSpacing.shorten(expandedA: rails.a, expandedB: rails.b, range: 0...50, parameters: p)
        #expect(zip(crossings, zip(rails.a, rails.b)).allSatisfy { $0.0.a == $0.1.0 && $0.0.b == $0.1.1 })
    }

    @Test func autoSplitKeepsEveryStitchUnderTheLimitAtRandomisedPoints() {
        var p = StitchGenerationParameters()
        p.satinAutoSplitMM = 7
        // A 20mm-wide zigzag: every leg is ~20mm.
        var zig: [Point2D] = []
        for i in 0..<30 {
            zig.append(Point2D(Double(i) * 0.4, 0))
            zig.append(Point2D(Double(i) * 0.4 + 0.2, 20))
        }
        let split = SatinSpacing.autoSplit(zig, parameters: p)
        #expect(split.count > zig.count * 2)
        #expect(spacings(split).allSatisfy { $0 <= 7.0 + 1e-9 })
        // Original points all survive, in order.
        var idx = 0
        for point in split where idx < zig.count && point == zig[idx] { idx += 1 }
        #expect(idx == zig.count)
        // The split fractions vary from leg to leg -- not all at 1/3, 2/3.
        var fractions: Set<Int> = []
        for i in 1..<zig.count {
            let a = zig[i - 1], b = zig[i]
            for q in split where q != a && q != b && abs((q.y - a.y) / (b.y - a.y)) < 1 && abs(q.x - (a.x + (b.x - a.x) * (q.y - a.y) / (b.y - a.y))) < 1e-6 {
                fractions.insert(Int(((q.y - a.y) / (b.y - a.y)) * 100))
            }
        }
        #expect(fractions.count > 6, "split points should be spread out, saw only \(fractions.sorted())")
        // Deterministic.
        #expect(SatinSpacing.autoSplit(zig, parameters: p) == split)
        p.satinAutoSplitMM = 0
        #expect(SatinSpacing.autoSplit(zig, parameters: p) == zig)
    }

    @Test func generatePartialSpacesANarrowColumnWiderThanAWideOne() throws {
        var p = StitchGenerationParameters()
        p.satinDensityMM = 0.4
        p.pullCompensationMM = 0
        p.pushCompensationMM = 0
        p.satinAutoSplitMM = 0
        p.maxSatinWidthMM = 12
        func column(width: Double) -> VectorShape {
            VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(60, 0), Point2D(60, width), Point2D(0, width)], closed: true)])
        }
        let narrow = try SatinColumnGenerator.generatePartial(for: column(width: 1.8), parameters: p)
        let wide = try SatinColumnGenerator.generatePartial(for: column(width: 9), parameters: p)
        // Two points per crossing; more crossings on the wide column.
        #expect(Double(wide.count) > Double(narrow.count) * 1.25, "wide \(wide.count) vs narrow \(narrow.count)")
    }
}
