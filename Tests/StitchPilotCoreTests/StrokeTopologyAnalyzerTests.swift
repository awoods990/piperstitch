import Foundation
import Testing
@testable import StitchPilotCore

/// Stage 1 of the branching-letter satin work (see DIGITIZING_ENGINE.md):
/// `StrokeTopologyAnalyzer` isn't wired into classification or stitch
/// generation anywhere yet -- these tests only verify the topology graph
/// itself is structurally correct on synthetic shapes chosen to exercise
/// each case the later stages will depend on: a plain open column (no
/// branching at all, the common case), a ring (a hole with no junction),
/// a single T-junction, a genuinely branching "H" (the exact shape
/// `SatinColumnGeneratorTests.branchingHShapeIsRejectedRatherThan
/// ProducingTwistedRails` already proves today's single-column path
/// correctly rejects), degenerate input, and spurious-branch pruning.
struct StrokeTopologyAnalyzerTests {

    @Test func straightColumnHasNoJunctionsAndOneEdge() throws {
        let column = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(3, 0), Point2D(3, 20), Point2D(0, 20),
        ], closed: true)])

        let topology = try #require(StrokeTopologyAnalyzer.analyze(shape: column))

        #expect(topology.nodes.count == 2)
        #expect(topology.nodes.allSatisfy { !$0.isJunction })
        #expect(topology.edges.count == 1)
        let edge = try #require(topology.edges.first)
        #expect(!edge.isClosedLoop)
        #expect(edge.polyline.count == edge.widthsMM.count)
        // The skeleton's endpoints sit slightly inside the flat end caps
        // (a well-known thinning boundary effect), so the traced length
        // is a bit short of the full 20mm -- not exactly 20.
        let length = pathLength(edge.polyline)
        #expect(length > 14 && length <= 20.5, "expected roughly the column's own 20mm length, got \(length)")
        #expect(edge.widthsMM.allSatisfy { $0 > 0 && $0 < 6 }, "stroke width should stay near the column's own 3mm")
    }

    /// A genuinely circular ring's medial axis is itself a perfect
    /// circle -- equidistant from both boundaries everywhere, with no
    /// point favoring one direction over another the way a corner does.
    /// Approximated here as a 32-sided polygon (close enough to circular
    /// that no spurious corner branch should survive pruning), rotated
    /// by a small phase offset so no facet lands exactly axis-aligned:
    /// both boundaries share the same regular subdivision, so a facet
    /// sitting exactly horizontal or vertical makes that whole span
    /// exactly mirror-symmetric top-to-bottom (or side-to-side) at the
    /// pixel grid -- a genuine, if narrow, medial-axis ambiguity real
    /// (imperfectly traced) ring artwork essentially never produces, but
    /// a perfectly regular synthetic polygon can hit outright. A small
    /// phase offset is a more representative fixture, not a workaround.
    @Test func circularRingShapeIsASingleClosedLoopWithNoNodes() throws {
        let ring = VectorShape(subPaths: [regularPolygon(sides: 32, radius: 10, center: Point2D(10, 10), phase: 0.1),
                                           regularPolygon(sides: 32, radius: 4, center: Point2D(10, 10), phase: 0.1)].map { SubPath(points: $0, closed: true) })

        let topology = try #require(StrokeTopologyAnalyzer.analyze(shape: ring))

        #expect(topology.nodes.isEmpty, "a circular ring shouldn't produce any junction/endpoint nodes, got \(topology.nodes.count)")
        #expect(topology.edges.count == 1)
        let edge = try #require(topology.edges.first)
        #expect(edge.isClosedLoop)
        #expect(edge.polyline.count >= 8, "a ring's traced loop should have several samples around it, not collapse to a handful")
        #expect(edge.widthsMM.allSatisfy { $0 > 0 })
    }

    private func regularPolygon(sides: Int, radius: Double, center: Point2D, phase: Double = 0) -> [Point2D] {
        (0..<sides).map { i in
            let angle = phase + 2 * Double.pi * Double(i) / Double(sides)
            return Point2D(center.x + radius * cos(angle), center.y + radius * sin(angle))
        }
    }

    @Test func tJunctionShapeHasExactlyOneJunctionAndThreeEndpoints() throws {
        // A horizontal bar with one stem hanging from its underside --
        // the simplest possible branching shape (one junction, degree 3).
        let tShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 17), Point2D(0, 20), Point2D(20, 20), Point2D(20, 17),
            Point2D(11.5, 17), Point2D(11.5, 0), Point2D(8.5, 0), Point2D(8.5, 17),
        ], closed: true)])

        let topology = try #require(StrokeTopologyAnalyzer.analyze(shape: tShape))

        let junctions = topology.nodes.filter { $0.isJunction }
        let endpoints = topology.nodes.filter { !$0.isJunction }
        #expect(junctions.count == 1, "expected exactly one T-junction, got \(junctions.count) among \(topology.nodes.count) nodes")
        #expect(endpoints.count == 3, "expected the bar's two ends plus the stem's bottom, got \(endpoints.count)")
        #expect(topology.edges.count == 3)
        #expect(topology.edges.allSatisfy { !$0.isClosedLoop })
    }

    /// The exact shape `SatinColumnGeneratorTests.
    /// branchingHShapeIsRejectedRatherThanProducingTwistedRails` uses to
    /// prove today's single-column satin path correctly falls back to
    /// tatami rather than producing twisted rails -- this is the shape
    /// stage 2+ of the branching work needs to turn back into real satin,
    /// so its topology needs to come back structurally sane: two
    /// junctions (where the crossbar meets each stem) and four endpoints
    /// (each stem's own top and bottom).
    @Test func branchingHShapeHasTwoJunctionsAndFourEndpoints() throws {
        let hShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(3, 0), Point2D(3, 8.5), Point2D(12, 8.5), Point2D(12, 0),
            Point2D(15, 0), Point2D(15, 20), Point2D(12, 20), Point2D(12, 11.5), Point2D(3, 11.5),
            Point2D(3, 20), Point2D(0, 20),
        ], closed: true)])

        let topology = try #require(StrokeTopologyAnalyzer.analyze(shape: hShape))

        let junctions = topology.nodes.filter { $0.isJunction }
        let endpoints = topology.nodes.filter { !$0.isJunction }
        #expect(junctions.count == 2, "expected the two stem/crossbar junctions, got \(junctions.count) among \(topology.nodes.count) nodes")
        #expect(endpoints.count == 4, "expected each stem's own top and bottom endpoint, got \(endpoints.count)")
        #expect(topology.edges.count == 5, "two stem-to-junction edges per stem plus the crossbar itself")
        #expect(topology.edges.allSatisfy { !$0.isClosedLoop })
    }

    /// A boundary-noise-sized outward spike (0.15mm deep over a 0.3mm
    /// span, on an otherwise plain 3mm-wide column) is exactly the kind
    /// of artifact real raster-traced logos produce constantly -- this is
    /// the concrete case `Parameters.pruneBranchLengthFactor` exists for.
    /// Without pruning, thinning would throw a short spurious branch off
    /// the skeleton at the spike; with it, the shape should come back
    /// indistinguishable in topology from a plain straight column.
    @Test func subThresholdBoundarySpikeIsPrunedAway() throws {
        let columnWithSpike = VectorShape(subPaths: [SubPath(points: [
            Point2D(0, 0), Point2D(3, 0), Point2D(3, 9.85), Point2D(3.15, 10), Point2D(3, 10.15),
            Point2D(3, 20), Point2D(0, 20),
        ], closed: true)])

        let topology = try #require(StrokeTopologyAnalyzer.analyze(shape: columnWithSpike))

        #expect(topology.nodes.allSatisfy { !$0.isJunction }, "the spike should be pruned away, not survive as a spurious junction")
        #expect(topology.nodes.count == 2)
        #expect(topology.edges.count == 1)
    }

    /// A junction whose branches *all but one* get pruned as spurious
    /// (a T whose two bar arms are both short enough to prune, leaving
    /// only the stem) must be relabeled a plain endpoint, not survive
    /// mislabeled as a junction with a single remaining edge. Distinct
    /// from `subThresholdBoundarySpikeIsPrunedAway` above, which tests
    /// pruning a junction down to exactly two remaining edges (a
    /// different, already-correct code path that collapses the junction
    /// into one straight-through edge rather than merely relabeling it).
    /// Found directly against a real large logo shape (a bold "A"'s own
    /// leg): a genuine junction pixel survived mislabeled after both its
    /// real branches were correctly pruned as raster noise, making
    /// `SatinColumnGenerator.canRepresentAsBranchingSatinColumn` treat an
    /// ordinary single connector as "genuinely branching."
    @Test func junctionPrunedDownToOneEdgeIsDemotedNotMislabeled() throws {
        // A stem whose top flares into two short, tapering points -- the
        // raster noise the pruning exists for. (A flat-topped T with two
        // matched square-ended arms is a slab serif and is kept now.)
        let shortArmedTShape = VectorShape(subPaths: [SubPath(points: [
            Point2D(0.3, 8.6), Point2D(1.5, 9.2), Point2D(4.5, 9.2), Point2D(5.4, 8.7),
            Point2D(4.5, 8), Point2D(4.5, 0), Point2D(1.5, 0), Point2D(1.5, 8),
        ], closed: true)])

        let topology = try #require(StrokeTopologyAnalyzer.analyze(shape: shortArmedTShape))

        #expect(topology.nodes.allSatisfy { !$0.isJunction }, "both short bar arms should prune away, demoting the junction to a plain endpoint")
        #expect(topology.nodes.count == 2)
        #expect(topology.edges.count == 1)
    }

    @Test func degenerateShapeReturnsNilRatherThanCrashing() {
        let collapsedPoint = VectorShape(subPaths: [SubPath(points: [
            Point2D(5, 5), Point2D(5, 5), Point2D(5, 5),
        ], closed: true)])
        #expect(StrokeTopologyAnalyzer.analyze(shape: collapsedPoint) == nil)

        let empty = VectorShape(subPaths: [])
        #expect(StrokeTopologyAnalyzer.analyze(shape: empty) == nil)
    }

    private func pathLength(_ points: [Point2D]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count { total += points[i - 1].distance(to: points[i]) }
        return total
    }
}
