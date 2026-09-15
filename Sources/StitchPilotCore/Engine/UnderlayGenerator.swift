import Foundation

/// Generates underlay — a lighter base layer of stitching sewn *before* the
/// object's main stitches to stabilize the fabric and anchor the final
/// stitches to (spec §16). "Users should generally not need to configure
/// underlay manually" (spec §16): `generate` picks a sensible default per
/// stitch type unless `parameters.underlayType` overrides it.
public enum UnderlayGenerator {
    /// The one or two underlay layers an object gets, in sewing order.
    public struct Plan: Equatable, Sendable {
        public var first: UnderlayType
        public var second: UnderlayType?
    }

    /// Every underlay stitch as one continuous sequence. Fine for satin
    /// (whose underlay types are all single open paths or one closed
    /// loop); a fill with a tatami underlay layer over a hole should use
    /// `generateLayers`, whose per-run structure keeps the underlay from
    /// bridging the hole -- flattening here would sew straight across it.
    public static func generate(for shape: VectorShape, stitchType: StitchType, parameters: StitchGenerationParameters) -> [Point2D] {
        generateLayers(for: shape, stitchType: stitchType, parameters: parameters).flatMap { $0.runs.flatMap { $0 } }
    }

    /// One entry per underlay layer, in sewing order, each as one or more
    /// runs: a run boundary means "don't sew a stitch between these" (a
    /// tatami underlay's chains on either side of a hole -- the same
    /// break the cover fill itself makes). `DigitizePipeline` seams a
    /// closed edge-run loop next to whatever follows it and turns run
    /// boundaries into trim+jumps. Empty layers are dropped.
    public struct Layer {
        public var type: UnderlayType
        public var runs: [[Point2D]]
    }

    public static func generateLayers(for shape: VectorShape, stitchType: StitchType, parameters: StitchGenerationParameters) -> [Layer] {
        let plan = plan(for: shape, stitchType: stitchType, parameters: parameters)
        var layers = [Layer(type: plan.first, runs: layerRuns(plan.first, shape: shape, parameters: parameters))]
        if let second = plan.second { layers.append(Layer(type: second, runs: layerRuns(second, shape: shape, parameters: parameters))) }
        return layers.map { Layer(type: $0.type, runs: $0.runs.filter { !$0.isEmpty }) }.filter { !$0.runs.isEmpty }
    }

    private static func layerRuns(_ type: UnderlayType, shape: VectorShape, parameters: StitchGenerationParameters) -> [[Point2D]] {
        switch type {
        case .none: return []
        case .centerRun: return [centerRun(shape: shape, parameters: parameters)]
        case .edgeRun: return [edgeRun(shape: shape, parameters: parameters)]
        case .zigzag: return [zigzag(shape: shape, parameters: parameters)]
        case .tatami: return tatami(shape: shape, parameters: parameters, angleOffsets: [90])
        case .doubleTatami: return tatami(shape: shape, parameters: parameters, angleOffsets: [45, -45])
        }
    }

    /// Below this longest dimension an object gets no underlay at all:
    /// the manual's lettering rule ("lettering with heights under 5 mm
    /// should not have underlay") generalised to any small object --
    /// there is nothing for a foundation layer to stabilise, and it only
    /// stiffens the piece and adds stitches.
    public static let noUnderlayBelowSizeMM = 5.0
    /// Satin narrower than this (a small letter's stroke) gets no
    /// underlay; up to `edgeRunFromWidthMM` a single center run (the
    /// manual: "letters 6-10 mm can have a center-run underlay"); wider
    /// than that an edge run ("lettering larger than 10 mm is large
    /// enough for edge-run") -- a normal font's column width is roughly a
    /// fifth of its height, which is where these come from.
    public static let noUnderlayBelowWidthMM = 1.2
    public static let edgeRunFromWidthMM = 2.5
    /// A satin column wider than this gets an edge run *under* its zigzag
    /// as a second layer ("combine Zigzag with Center Run or Edge Run").
    public static let secondSatinLayerFromWidthMM = 6.0
    /// A fill larger than this gets a tatami underlay over its edge run
    /// ("tatami underlay is used to stabilize large, filled shapes");
    /// stretchy or napped fabric lowers the bar to `extraUnderlayAreaMM2`.
    public static let tatamiUnderlayAreaMM2 = 400.0
    public static let extraUnderlayAreaMM2 = 150.0

    /// What an object gets by default, from its stitch type, size, width
    /// and fabric -- unless `parameters.underlayType` / `secondUnderlayType`
    /// override either layer. See docs/WILCOM_MANUAL_REVIEW.md A5/A7 for the
    /// manual's rules these encode.
    public static func plan(for shape: VectorShape, stitchType: StitchType, parameters: StitchGenerationParameters) -> Plan {
        var plan = defaultPlan(for: stitchType, shape: shape, parameters: parameters)
        if let forced = parameters.underlayType { plan.first = forced }
        if let forcedSecond = parameters.secondUnderlayType { plan.second = forcedSecond == .none ? nil : forcedSecond }
        if plan.first == .none, parameters.secondUnderlayType == nil {
            plan.second = nil  // "no underlay" -- by size, or forced -- beats an automatic second layer
        }
        return plan
    }

    private static func defaultPlan(for stitchType: StitchType, shape: VectorShape, parameters: StitchGenerationParameters) -> Plan {
        let box = shape.boundingBox
        let longest = max(box.width, box.height)
        let fabric = parameters.fabricType
        switch stitchType {
        case .runningStitch, .tripleRun:
            return Plan(first: .none, second: nil) // already a single light pass; no fabric buildup to stabilize
        case .satin:
            guard longest >= noUnderlayBelowSizeMM else { return Plan(first: .none, second: nil) }
            guard let width = averageColumnWidth(shape) else { return Plan(first: .centerRun, second: nil) }
            if width < noUnderlayBelowWidthMM { return Plan(first: .none, second: nil) }
            if width < edgeRunFromWidthMM { return Plan(first: .centerRun, second: nil) }
            if width <= parameters.zigzagUnderlayWidthThresholdMM { return Plan(first: .edgeRun, second: nil) }
            let wantsSecond = width > secondSatinLayerFromWidthMM || fabric.needsExtraUnderlay
            return Plan(first: .zigzag, second: wantsSecond ? .edgeRun : nil)
        case .tatamiFill:
            guard longest >= noUnderlayBelowSizeMM else { return Plan(first: .none, second: nil) }
            let area = shapeArea(shape)
            let threshold = fabric.needsExtraUnderlay ? extraUnderlayAreaMM2 : tatamiUnderlayAreaMM2
            guard area >= threshold else { return Plan(first: .edgeRun, second: nil) }
            return Plan(first: .edgeRun, second: fabric.needsCrossHatchUnderlay ? .doubleTatami : .tatami)
        }
    }

    /// Average distance between a satin column's rails, or nil when the
    /// shape doesn't rail-fit as a column at all.
    private static func averageColumnWidth(_ shape: VectorShape) -> Double? {
        guard let (railA, railB) = try? SatinColumnGenerator.computeRails(for: shape) else { return nil }
        let sampleCount = 10
        let a = PolygonGeometry.resampleByCount(railA, count: sampleCount)
        let b = PolygonGeometry.resampleByCount(railB, count: sampleCount)
        return zip(a, b).map { $0.distance(to: $1) }.reduce(0, +) / Double(a.count)
    }

    /// Outer area minus holes, in mm².
    private static func shapeArea(_ shape: VectorShape) -> Double {
        guard let outer = shape.subPaths.first else { return 0 }
        var area = abs(PolygonGeometry.signedArea(outer.points))
        for hole in shape.subPaths.dropFirst() { area -= abs(PolygonGeometry.signedArea(hole.points)) }
        return max(0, area)
    }

    /// Open rows of running stitch across the shape at each of
    /// `angleOffsets` degrees from the cover fill's own angle -- one pass
    /// for `.tatami`, two for `.doubleTatami`. Generated by the fill
    /// generator itself at an open spacing, on the shape's *true*
    /// outline (an offset outline self-intersects at a letterform's
    /// concave corners and breaks the edge routing that keeps this to one
    /// run) with each row's ends pulled in from the boundary by
    /// `underlayInsetMM` through the generator's push-compensation path,
    /// pull compensation off (the cover fill carries it), and connectors
    /// that would cross a hole routed along the hole's edge.
    private static func tatami(shape: VectorShape, parameters: StitchGenerationParameters, angleOffsets: [Double]) -> [[Point2D]] {
        guard let outer = shape.subPaths.first, outer.points.count >= 3 else { return [] }
        let coverAngle = parameters.fillAngleDegrees ?? FillAngleSelector.selectAngle(for: shape)

        var underlayParameters = parameters
        underlayParameters.fillSpacingMM = max(parameters.tatamiUnderlaySpacingMM, 1.0)
        underlayParameters.stitchLengthMM = max(parameters.underlayStitchLengthMM, 2.0)
        underlayParameters.fillPattern = .rows
        underlayParameters.pullCompensationMM = 0
        underlayParameters.pushCompensationMM = 2 * max(parameters.underlayInsetMM, 0)
        underlayParameters.underlayType = UnderlayType.none
        underlayParameters.secondUnderlayType = UnderlayType.none

        var runs: [[Point2D]] = []
        for offset in angleOffsets {
            underlayParameters.fillAngleDegrees = coverAngle + offset
            runs.append(contentsOf: TatamiFillGenerator.generateRuns(for: shape, parameters: underlayParameters, breakThresholdMM: DigitizePipeline.defaultMaxJumpWithoutTrimMM, routeConnectorsAlongEdges: true))
        }
        // The row nearest an edge that runs parallel to it can sit closer
        // than the margin (rows start half a spacing in from the bounding
        // box and just keep going); drop any run that hugs the outer
        // boundary that closely along its whole length. Routed travel
        // and row ends are already held in by the push compensation and
        // the routing inset.
        let margin = max(parameters.underlayInsetMM, 0) * 0.9
        guard margin > 0 else { return runs }
        return runs.filter { run in
            let samples = stride(from: 0, to: run.count, by: max(1, run.count / 8)).map { run[$0] }
            return !samples.allSatisfy { distanceToBoundary($0, polygon: outer.points) < margin }
        }
    }

    private static func distanceToBoundary(_ p: Point2D, polygon: [Point2D]) -> Double {
        let n = polygon.count
        var best = Double.infinity
        for i in 0..<n {
            let a = polygon[i], b = polygon[(i + 1) % n]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
            best = min(best, p.distance(to: Point2D(a.x + dx * t, a.y + dy * t)))
        }
        return best
    }

    /// A running stitch along a satin column's centerline (the average of
    /// its two rails), inset from the true ends so the underlay doesn't
    /// poke out past the satin's own tapered tips — spec §16: underlay
    /// selection depends on "object geometry, stitch type... width."
    private static func centerRun(shape: VectorShape, parameters: StitchGenerationParameters) -> [Point2D] {
        guard let (railA, railB) = try? SatinColumnGenerator.computeRails(for: shape) else { return [] }
        // A ring column (a letterform counter -- O, P, R...) has no real
        // "ends" to inset away from the way an open column's tapered tips
        // need -- `SatinColumnGenerator.computeRails` signals this by
        // returning both rails explicitly closed (first point repeated at
        // the end). Trimming it the same way as an open column would cut
        // a gap into otherwise-continuous underlay coverage at whatever
        // point the ring's rails happened to start.
        let isClosedRing = railA.count > 1 && railA.first == railA.last

        let approxLength = max(PolygonGeometry.pathLength(railA), PolygonGeometry.pathLength(railB))
        let count = max(4, Int((approxLength / max(parameters.underlayStitchLengthMM, 0.5)).rounded()))
        let resampledA = PolygonGeometry.resampleByCount(railA, count: count)
        let resampledB = PolygonGeometry.resampleByCount(railB, count: count)
        // Same rails the actual satin crossings validate before use (see
        // `SatinColumnGenerator.crossingsEscapeTheShape`'s doc comment) --
        // but resampled far more coarsely here (a handful of underlay
        // stitches rather than a full crossing per `satinDensityMM`), so a
        // rail-length mismatch too small to visibly misalign any single
        // fine-grained satin crossing can still misalign these few, much
        // longer strides badly enough to cut straight across a concave
        // bend (e.g. an "L"). Found directly against a real raster-
        // imported logo's own "L", whose finished satin coverage was
        // correct but whose *underlay* -- sewn first, and exposed wherever
        // it strays outside the satin that later covers it -- cut a
        // visible diagonal scratch across the letter's own open notch,
        // where no top stitching exists to hide it. Underlay is a
        // stabilizing nicety, not required output, so skipping it
        // entirely for the rare shape this affects is a safe fallback --
        // far better than a visible defect. See CHANGELOG.md.
        // Rings are exempt, same as `SatinColumnGenerator`'s own check --
        // their rails come from angular ray-casting, which can't misalign
        // like this by construction.
        if !isClosedRing, SatinColumnGenerator.crossingsEscapeTheShape(resampledA, resampledB, polygon: shape.subPaths.first?.points ?? []) {
            return []
        }

        let centerline = zip(resampledA, resampledB).map { Point2D(($0.x + $1.x) / 2, ($0.y + $1.y) / 2) }
        let path = isClosedRing ? centerline : trimPolylineEnds(centerline, insetMM: parameters.underlayInsetMM)
        guard path.count > 1 else { return [] }

        return RunningStitchGenerator.generate(for: SubPath(points: path, closed: isClosedRing),
                                                stitchLengthMM: parameters.underlayStitchLengthMM, minStitchLengthMM: 0.4)
    }

    /// A wider-spaced zigzag between the satin column's rails, inset toward
    /// the centerline so it stays narrower than the final satin coverage —
    /// see the doc comment on `defaultUnderlay` for why this exists
    /// alongside center-run rather than replacing it.
    private static func zigzag(shape: VectorShape, parameters: StitchGenerationParameters) -> [Point2D] {
        guard let (railA, railB) = try? SatinColumnGenerator.computeRails(for: shape) else { return [] }
        let isClosedRing = railA.count > 1 && railA.first == railA.last

        let approxLength = max(PolygonGeometry.pathLength(railA), PolygonGeometry.pathLength(railB))
        let spacing = max(parameters.zigzagUnderlaySpacingMM, 0.3)
        let count = max(3, Int((approxLength / spacing).rounded()))
        let resampledA = PolygonGeometry.resampleByCount(railA, count: count)
        let resampledB = PolygonGeometry.resampleByCount(railB, count: count)
        // See `centerRun`'s own doc comment on this same check.
        if !isClosedRing, SatinColumnGenerator.crossingsEscapeTheShape(resampledA, resampledB, polygon: shape.subPaths.first?.points ?? []) {
            return []
        }

        let inset = max(parameters.underlayInsetMM, 0)
        var points: [Point2D] = []
        for i in 0...count {
            let a = resampledA[i], b = resampledB[i]
            let insetA = moveToward(a, target: b, by: inset)
            let insetB = moveToward(b, target: a, by: inset)
            // Alternate which rail comes first each step, so the path
            // actually zigzags instead of running two parallel lines.
            if i % 2 == 0 {
                points.append(insetA); points.append(insetB)
            } else {
                points.append(insetB); points.append(insetA)
            }
        }
        return points
    }

    /// Moves `point` toward `target` by `distance` (clamped so it never overshoots past `target`).
    private static func moveToward(_ point: Point2D, target: Point2D, by distance: Double) -> Point2D {
        guard distance > 0 else { return point }
        let dx = target.x - point.x, dy = target.y - point.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.0001 else { return point }
        let clamped = min(distance, len / 2) // never cross the midpoint -- that would invert the rails
        return Point2D(point.x + dx / len * clamped, point.y + dy / len * clamped)
    }

    /// A running stitch around the shape's boundary, inset inward so it
    /// falls entirely underneath the fill that follows — spec §16 "edge run."
    private static func edgeRun(shape: VectorShape, parameters: StitchGenerationParameters) -> [Point2D] {
        guard let outer = shape.subPaths.first, outer.points.count >= 3 else { return [] }
        let inset = PolygonGeometry.offsetPolygon(outer.points, by: parameters.underlayInsetMM)
        guard inset.count >= 3 else { return [] }
        return RunningStitchGenerator.generate(for: SubPath(points: inset, closed: true),
                                                stitchLengthMM: parameters.underlayStitchLengthMM, minStitchLengthMM: 0.4)
    }

    /// Removes the first/last `insetMM` of arc length from an open
    /// polyline, interpolating new endpoints exactly at that distance.
    private static func trimPolylineEnds(_ points: [Point2D], insetMM: Double) -> [Point2D] {
        guard points.count > 1, insetMM > 0 else { return points }
        let total = PolygonGeometry.pathLength(points)
        guard total > insetMM * 2 else { return [] } // too short to inset at all

        func pointAtDistance(_ target: Double) -> (point: Point2D, index: Int) {
            var covered = 0.0
            for i in 1..<points.count {
                let segLen = points[i - 1].distance(to: points[i])
                if covered + segLen >= target || i == points.count - 1 {
                    let t = segLen > 0 ? min(1, max(0, (target - covered) / segLen)) : 0
                    let a = points[i - 1], b = points[i]
                    return (Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t), i)
                }
                covered += segLen
            }
            return (points.last!, points.count - 1)
        }

        let (startPoint, startIndex) = pointAtDistance(insetMM)
        let (endPoint, endIndex) = pointAtDistance(total - insetMM)
        guard startIndex <= endIndex else { return [startPoint, endPoint] }

        var result: [Point2D] = [startPoint]
        result.append(contentsOf: points[startIndex..<endIndex])
        result.append(endPoint)
        return result
    }
}
