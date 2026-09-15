import Foundation
import Testing
@testable import StitchPilotCore

/// Chord-gap run resampling (B5), tatami row jitter (B6), thread-weight
/// spacing offsets (C3) and short buried travel (B3) -- docs/
/// WILCOM_MANUAL_REVIEW.md.
struct StitchQualityRulesTests {
    @Test func runningStitchLandsOnSharpCornersAndKeepsStraightsLong() {
        let square = SubPath(points: [Point2D(0, 0), Point2D(20, 0), Point2D(20, 20), Point2D(0, 20)], closed: true)
        let points = RunningStitchGenerator.generate(for: square, stitchLengthMM: 3, minStitchLengthMM: 0.4)
        // Every corner is a penetration.
        for corner in square.points { #expect(points.contains(corner), "missing corner \(corner)") }
        // No stitch cuts a corner: every stitch is axis-aligned.
        for (p, q) in zip(points, points.dropFirst()) { #expect(abs(p.x - q.x) < 1e-9 || abs(p.y - q.y) < 1e-9) }
        // Straight runs still use the full length.
        let lengths = zip(points, points.dropFirst()).map { $0.distance(to: $1) }
        #expect(lengths.filter { abs($0 - 3) < 1e-6 }.count >= 20)
        // Chord gap off: the old behaviour cuts corners.
        let cutting = RunningStitchGenerator.generate(for: square, stitchLengthMM: 3, minStitchLengthMM: 0.4, chordGapMM: 0)
        #expect(!cutting.contains(Point2D(20, 0)))
    }

    @Test func runningStitchShortensOnATightCurve() {
        var arc: [Point2D] = []
        for i in 0...60 { let t = Double(i) / 60 * .pi; arc.append(Point2D(3 * cos(t), 3 * sin(t))) }  // radius 3mm semicircle
        let tight = RunningStitchGenerator.generate(for: SubPath(points: arc, closed: false), stitchLengthMM: 3, minStitchLengthMM: 0.4)
        let loose = RunningStitchGenerator.generate(for: SubPath(points: arc, closed: false), stitchLengthMM: 3, minStitchLengthMM: 0.4, chordGapMM: 0)
        #expect(tight.count > loose.count, "tight \(tight.count) vs loose \(loose.count)")
        // Shortened, but never below the 1mm floor.
        for (p, q) in zip(tight, tight.dropFirst()) { #expect(p.distance(to: q) >= RunningStitchGenerator.shortenedStitchFloorMM - 1e-6) }
        // The stitches now sit much closer to the curve at their midpoints.
        func worstSag(_ pts: [Point2D]) -> Double {
            zip(pts, pts.dropFirst()).map { p, q in abs(Point2D((p.x + q.x) / 2, (p.y + q.y) / 2).distance(to: .zero) - 3) }.max() ?? 0
        }
        #expect(worstSag(tight) < worstSag(loose) / 2, "tight \(worstSag(tight)) vs loose \(worstSag(loose))")
    }

    @Test func tatamiJitterMovesInteriorPenetrationsButNotRowEnds() {
        let square = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(40, 0), Point2D(40, 20), Point2D(0, 20)], closed: true)])
        var p = StitchGenerationParameters()
        p.fillAngleDegrees = 0; p.pullCompensationMM = 0; p.pushCompensationMM = 0; p.underlayType = UnderlayType.none
        p.fillJitterFraction = 0
        let regular = TatamiFillGenerator.generate(for: square, parameters: p)
        p.fillJitterFraction = 0.15
        let jittered = TatamiFillGenerator.generate(for: square, parameters: p)
        #expect(regular.count == jittered.count)
        let moved = zip(regular, jittered).filter { $0.0 != $0.1 }.count
        #expect(moved > regular.count / 3, "most interior penetrations should move, moved \(moved) of \(regular.count)")
        // Row ends (x at 0 or 40) never move.
        for (a, b) in zip(regular, jittered) where a.x < 0.01 || a.x > 39.99 { #expect(a == b) }
        // Shift stays within the jitter band and never reorders a row.
        for (a, b) in zip(regular, jittered) { #expect(abs(a.x - b.x) <= 0.15 * p.stitchLengthMM + 1e-9) }
        // Deterministic.
        #expect(TatamiFillGenerator.generate(for: square, parameters: p) == jittered)
    }

    @Test func threadWeightOffsetsSpacing() throws {
        var p = StitchGenerationParameters()
        p.satinDensityMM = 0.4; p.fillSpacingMM = 0.4
        p.threadWeight = .wt60
        #expect(abs(p.effectiveSatinDensityMM - 0.37) < 1e-9 && abs(p.effectiveFillSpacingMM - 0.37) < 1e-9)
        p.threadWeight = .wt30
        #expect(abs(p.effectiveSatinDensityMM - 0.43) < 1e-9)
        // A finer thread sews more stitches in the same fill.
        let square = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(30, 0), Point2D(30, 30), Point2D(0, 30)], closed: true)])
        p.threadWeight = .wt40
        let standard = TatamiFillGenerator.generate(for: square, parameters: p).count
        p.threadWeight = .wt80
        let fine = TatamiFillGenerator.generate(for: square, parameters: p).count
        #expect(Double(fine) > Double(standard) * 1.1, "80wt \(fine) vs 40wt \(standard)")
        // Round-trips; old documents decode as 40 wt.
        let back = try JSONDecoder().decode(StitchGenerationParameters.self, from: JSONEncoder().encode(p))
        #expect(back.threadWeight == .wt80)
        let old = try JSONDecoder().decode(StitchGenerationParameters.self, from: "{}".data(using: .utf8)!)
        #expect(old.threadWeight == .wt40 && old.fillJitterFraction == 0.15)
    }
}
