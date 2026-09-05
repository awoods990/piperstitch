import Foundation

public enum SatinGenerationError: Error, LocalizedError {
    case shapeNotSuitable(String)
    case columnTooWide(maxWidthMM: Double, limitMM: Double)
    case columnTooNarrow(minWidthMM: Double, limitMM: Double)

    public var errorDescription: String? {
        switch self {
        case .shapeNotSuitable(let reason):
            return "This shape isn't a usable satin column: \(reason)"
        case .columnTooWide(let width, let limit):
            return String(format: "This satin column is %.1fmm wide at its widest point, beyond the %.1fmm practical satin limit. Split it into sections or convert it to a fill.", width, limit)
        case .columnTooNarrow(let width, let limit):
            return String(format: "This satin column narrows to %.1fmm, below the %.1fmm practical minimum. Sew it as a running/triple-run line instead.", width, limit)
        }
    }
}

/// Generates satin-column stitches for a shape — spec §11/§12. Satin sews a
/// zigzag between two "rails" running the length of a narrow column (a
/// letter stroke, a logo outline segment, a star point), crossing from one
/// rail to the other at regular intervals along the column.
///
/// This first implementation derives the two rails heuristically from a
/// single closed boundary rather than from an author-specified centerline:
/// it finds the shape's elongation direction (principal axis via PCA), then
/// finds the two boundary *edges* whose average position is most extreme
/// along that axis — the column's two end caps — and splits the polygon
/// there, using each end cap's midpoint as the shared start/end point of
/// both rails. Splitting at edges (not vertices) matters: picking whichever
/// two *vertices* are extremal fails on the simplest possible case, an
/// axis-aligned rectangle, where the two vertices of the short "end" side
/// tie in projection and there's no vertex at the true end-cap
/// midpoint — you have to actually find that side (the edge) and cut there.
/// This works well for the common "sausage" case — a single long, roughly
/// symmetric outline (letter strokes, simple logo strokes, star points) —
/// but will misbehave on branching or very irregular shapes; robust
/// centerline/skeleton-based detection for arbitrary geometry is a
/// follow-up (see DIGITIZING_ENGINE.md).
///
/// Known limitation: both rails share a single point at each end cap, so
/// width always tapers to exactly 0 at the very tip. That's correct for a
/// genuinely pointed end (a star point, a leaf tip) but is an approximation
/// for a flat/square-capped column (e.g. a plain rectangle) — real
/// digitizing software typically sews a full-width closing stitch straight
/// across a square end instead of tapering into it. Distinguishing "this
/// end cap is a point" from "this end cap is a flat edge that needs a
/// squared crossing" is a follow-up refinement.
public enum SatinColumnGenerator {
    /// Splits a shape's outer boundary into two rails — see the type-level
    /// doc comment for the PCA + edge-based end-cap algorithm. Exposed
    /// (module-internal) so `UnderlayGenerator` can derive a satin column's
    /// centerline from the same two rails `generate` sews between, instead
    /// of recomputing "where is this column's centerline" a second way.
    static func computeRails(for shape: VectorShape) throws -> (railA: [Point2D], railB: [Point2D]) {
        guard let sub = shape.subPaths.first else {
            throw SatinGenerationError.shapeNotSuitable("no outline was provided")
        }
        var polygon = sub.points
        if polygon.count > 1, polygon.first == polygon.last { polygon.removeLast() }
        guard polygon.count >= 4 else {
            throw SatinGenerationError.shapeNotSuitable("the outline needs at least 4 distinct points")
        }

        let (axis, mean) = PolygonGeometry.principalAxis(polygon)
        let (startEdge, endEdge) = endCapEdges(polygon, axis: axis, mean: mean)
        guard startEdge != endEdge else {
            throw SatinGenerationError.shapeNotSuitable("couldn't identify two distinct ends for this outline")
        }

        let n = polygon.count
        let startMid = midpoint(polygon[startEdge], polygon[(startEdge + 1) % n])
        let endMid = midpoint(polygon[endEdge], polygon[(endEdge + 1) % n])

        let railACore = walkForward(polygon, from: (startEdge + 1) % n, to: endEdge)
        let railBCore = Array(walkForward(polygon, from: (endEdge + 1) % n, to: startEdge).reversed())
        return ([startMid] + railACore + [endMid], [startMid] + railBCore + [endMid])
    }

    public static func generate(for shape: VectorShape, parameters: StitchGenerationParameters) throws -> [Point2D] {
        let crossings = try computeCrossings(for: shape, parameters: parameters)

        let maxWidth = crossings.widths.max() ?? 0
        if maxWidth > parameters.maxSatinWidthMM {
            throw SatinGenerationError.columnTooWide(maxWidthMM: maxWidth, limitMM: parameters.maxSatinWidthMM)
        }

        // Only check "too narrow" in the interior (see `interiorRange`):
        // every column tapers to near-zero width at its very tips by
        // design (see this type's own doc comment on tapered end caps),
        // which isn't the same thing as being impractically narrow
        // throughout a real section of the column.
        let interior = interiorRange(count: crossings.widths.count)
        if let minWidth = crossings.widths[interior].min(), minWidth < parameters.minSatinWidthMM {
            throw SatinGenerationError.columnTooNarrow(minWidthMM: minWidth, limitMM: parameters.minSatinWidthMM)
        }

        var stitches: [Point2D] = []
        for i in 0..<crossings.expandedA.count {
            stitches.append(crossings.expandedA[i])
            stitches.append(crossings.expandedB[i])
        }
        return stitches
    }

    /// The crossing-index range excluded from natural end-cap tapering —
    /// both `generate`'s strict narrow check and `generatePartial`'s
    /// narrow-run detection only look here, since every column's width
    /// tapers toward zero at its very tips by construction (both rails
    /// share a single point at each end cap), which would otherwise make
    /// every column look "too narrow" right where it's supposed to. Mirrors
    /// the margin used by `SatinColumnGeneratorTests` to exclude the same
    /// zone when checking width against an expected value.
    private static func interiorRange(count: Int) -> Range<Int> {
        let margin = min(count / 2, max(2, count / 10))
        return margin..<(count - margin)
    }

    /// Resampled, compensated rail crossings shared by `generate` and
    /// `generatePartial` — the two differ only in what they do once they
    /// know each crossing's final (post-compensation) width, not in how
    /// that width is computed.
    private static func computeCrossings(for shape: VectorShape, parameters: StitchGenerationParameters) throws -> (expandedA: [Point2D], expandedB: [Point2D], widths: [Double]) {
        let (railA, railB) = try computeRails(for: shape)

        let density = max(parameters.satinDensityMM, 0.1)
        let approxLength = max(PolygonGeometry.pathLength(railA), PolygonGeometry.pathLength(railB))
        let crossingCount = max(2, Int((approxLength / density).rounded()))

        let resampledA = PolygonGeometry.resampleByCount(railA, count: crossingCount)
        let resampledB = PolygonGeometry.resampleByCount(railB, count: crossingCount)

        // Push compensation: fabric pushes apart *along* the stitching
        // direction (as opposed to pull, which narrows a design
        // perpendicular to it — see `PullCompensationCalculator`), so drop
        // crossings from both ends of the column before sewing, so it sews
        // at its intended length after that push. This can't be done by
        // trimming the raw rail *polylines* by arc length: each rail's
        // first/last few millimeters are the perpendicular "jog" from the
        // shared end-cap midpoint out to the boundary corner (see this
        // type's own doc comment on tapered end caps), not travel along the
        // column's actual length — arc-length trimming would eat into that
        // sideways jog almost without moving along the column at all.
        // Instead, measure each crossing by projecting its midpoint onto
        // the column's principal axis, and drop crossings whose projection
        // falls within the compensation distance of the column's true
        // (projected) extremes — immune to the end-cap jog since it
        // measures the real length axis directly.
        let (axis, mean) = PolygonGeometry.principalAxis(railA + railB)
        func projection(_ p: Point2D) -> Double { (p.x - mean.x) * axis.x + (p.y - mean.y) * axis.y }
        let midpointProjections = (0...crossingCount).map { projection(midpoint(resampledA[$0], resampledB[$0])) }

        let pushCompMM = parameters.pushCompensationMM
            ?? PullCompensationCalculator.estimatePush(stitchType: .satin, densityMM: density, objectLengthMM: approxLength)

        var lo = 0, hi = crossingCount
        if pushCompMM > 0, let minProj = midpointProjections.min(), let maxProj = midpointProjections.max(), maxProj - minProj > pushCompMM {
            let loTarget = minProj + pushCompMM / 2
            let hiTarget = maxProj - pushCompMM / 2
            lo = midpointProjections.firstIndex(where: { $0 >= loTarget }) ?? 0
            hi = midpointProjections.lastIndex(where: { $0 <= hiTarget }) ?? crossingCount
            if lo >= hi { lo = 0; hi = crossingCount } // degenerate guard: keep everything rather than nothing
        }

        let rawWidths = (lo...hi).map { resampledA[$0].distance(to: resampledB[$0]) }
        let averageWidth = rawWidths.reduce(0, +) / Double(max(1, rawWidths.count))
        let pullCompMM = parameters.pullCompensationMM
            ?? PullCompensationCalculator.estimate(stitchType: .satin, densityMM: density, objectWidthMM: averageWidth)

        var expandedA: [Point2D] = []
        var expandedB: [Point2D] = []
        var widths: [Double] = []
        for i in lo...hi {
            let a = resampledA[i], b = resampledB[i]
            // Pull compensation (spec §17): push each rail point outward,
            // away from the crossing's midpoint, so the column sews at the
            // intended width after fabric pulls it narrower. Expanding
            // symmetrically about the midpoint keeps the centerline (and
            // therefore the underlay generated from these same rails)
            // exactly where it was digitized.
            let ea = pushOutward(a, from: b, by: pullCompMM / 2)
            let eb = pushOutward(b, from: a, by: pullCompMM / 2)
            expandedA.append(ea)
            expandedB.append(eb)
            widths.append(ea.distance(to: eb))
        }
        return (expandedA, expandedB, widths)
    }

    private enum CrossingKind { case satin, fill, narrowRun }

    /// Like `generate`, but never rejects a column for being too wide *or*
    /// too narrow: crossings that exceed `maxSatinWidthMM` are converted to
    /// tatami fill sub-regions, crossings that fall below `minSatinWidthMM`
    /// (checked only in the interior — see `interiorRange`) are converted
    /// to a triple-run line along the centerline instead, and crossings
    /// that fit stay genuine satin — the width-aware partial version of
    /// `generate`'s all-or-nothing checks, closer to Ink/Stitch's
    /// `SatinColumn.split()` idea (see `EMBROIDERY_ALGORITHM_REFERENCE.md`)
    /// than converting the *whole* object over a width violation in one
    /// section. `generate` itself is kept as the strict, pure-satin variant
    /// (used directly by tests that want a hard guarantee, and available to
    /// any future preflight/validation check that wants to know "would
    /// this column fit as clean satin?"); `DigitizePipeline` calls this one,
    /// since a design should never simply fail to produce output over a
    /// width violation in one section of one object.
    ///
    /// A lone over/under-width crossing surrounded by in-range ones is
    /// folded back into satin rather than becoming a one-crossing "fill"
    /// or "narrow-run" sliver — there's no meaningful polygon (or
    /// meaningful line) from a single crossing, and it's well within the
    /// kind of measurement noise a column that's otherwise a good satin
    /// candidate can have. A real fill or narrow-run sub-region only forms
    /// from two or more consecutive out-of-range crossings.
    public static func generatePartial(for shape: VectorShape, parameters: StitchGenerationParameters) throws -> [Point2D] {
        let crossings = try computeCrossings(for: shape, parameters: parameters)
        let expandedA = crossings.expandedA, expandedB = crossings.expandedB
        let interior = interiorRange(count: crossings.widths.count)

        var kind: [CrossingKind] = crossings.widths.enumerated().map { i, width in
            if width > parameters.maxSatinWidthMM { return .fill }
            if interior.contains(i), width < parameters.minSatinWidthMM { return .narrowRun }
            return .satin
        }
        for i in 0..<kind.count where kind[i] != .satin {
            let prevSame = i > 0 && kind[i - 1] == kind[i]
            let nextSame = i < kind.count - 1 && kind[i + 1] == kind[i]
            if !prevSame && !nextSame { kind[i] = .satin }
        }

        var stitches: [Point2D] = []
        var i = 0
        while i < kind.count {
            var j = i
            while j < kind.count, kind[j] == kind[i] { j += 1 }
            switch kind[i] {
            case .fill:
                stitches.append(contentsOf: fillSegment(expandedA: expandedA, expandedB: expandedB, range: i...(j - 1), parameters: parameters))
            case .narrowRun:
                stitches.append(contentsOf: narrowRunSegment(expandedA: expandedA, expandedB: expandedB, range: i...(j - 1), parameters: parameters))
            case .satin:
                for k in i..<j {
                    stitches.append(expandedA[k])
                    stitches.append(expandedB[k])
                }
            }
            i = j
        }
        return stitches
    }

    /// Builds the closed quad-strip polygon spanning rail crossings `range`
    /// (both rails, one walked forward and the other back, so it traces the
    /// sub-region's boundary) and fills it with tatami stitches. Pull
    /// compensation is zeroed for this sub-fill call since it was already
    /// baked into `expandedA`/`expandedB` by the caller — applying it again
    /// here would expand the boundary twice.
    private static func fillSegment(expandedA: [Point2D], expandedB: [Point2D], range: ClosedRange<Int>, parameters: StitchGenerationParameters) -> [Point2D] {
        var points: [Point2D] = []
        for i in range { points.append(expandedA[i]) }
        for i in range.reversed() { points.append(expandedB[i]) }
        guard points.count >= 3 else { return [] }

        let polygon = VectorShape(subPaths: [SubPath(points: points, closed: true)])
        var subParameters = parameters
        // Both compensations were already baked into expandedA/expandedB by
        // the caller (pull via the rail-level outward push, push via the
        // rail-length trim); applying either again here, independently, on
        // this sub-region's own local axes would double up on the same two
        // effects rather than adding anything new.
        subParameters.pullCompensationMM = 0
        subParameters.pushCompensationMM = 0
        return TatamiFillGenerator.generate(for: polygon, parameters: subParameters)
    }

    /// Sews rail crossings `range` as a triple-run (bean-stitch) line along
    /// their centerline instead of a satin zigzag — a column section too
    /// narrow to zigzag reliably still needs to read as a bold line, and a
    /// single plain running stitch would look visually thin next to actual
    /// satin elsewhere on the same object. Resamples at `stitchLengthMM`
    /// (not the much finer `satinDensityMM` the crossings themselves are
    /// spaced at) before tripling, the same technique
    /// `DigitizePipeline`'s `.tripleRun` case uses.
    private static func narrowRunSegment(expandedA: [Point2D], expandedB: [Point2D], range: ClosedRange<Int>, parameters: StitchGenerationParameters) -> [Point2D] {
        let centerline = range.map { midpoint(expandedA[$0], expandedB[$0]) }
        guard centerline.count >= 2 else { return centerline }

        let base = RunningStitchGenerator.generate(for: SubPath(points: centerline, closed: false),
                                                     stitchLengthMM: parameters.stitchLengthMM,
                                                     minStitchLengthMM: parameters.minStitchLengthMM)
        guard base.count > 1 else { return base }
        return base + base.reversed() + base
    }

    /// Moves `point` further away from `other` along the line between them, by `distance`.
    private static func pushOutward(_ point: Point2D, from other: Point2D, by distance: Double) -> Point2D {
        guard distance != 0 else { return point }
        let dx = point.x - other.x, dy = point.y - other.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.0001 else { return point }
        return Point2D(point.x + dx / len * distance, point.y + dy / len * distance)
    }

    private static func midpoint(_ a: Point2D, _ b: Point2D) -> Point2D {
        Point2D((a.x + b.x) / 2, (a.y + b.y) / 2)
    }

    /// The two boundary edges whose average projection onto `axis` is most
    /// extreme — the column's two end caps.
    private static func endCapEdges(_ polygon: [Point2D], axis: Point2D, mean: Point2D) -> (Int, Int) {
        func proj(_ p: Point2D) -> Double { (p.x - mean.x) * axis.x + (p.y - mean.y) * axis.y }
        let n = polygon.count
        var startEdge = 0, startVal = Double.infinity
        var endEdge = 0, endVal = -Double.infinity
        for i in 0..<n {
            let avg = (proj(polygon[i]) + proj(polygon[(i + 1) % n])) / 2
            if avg < startVal { startVal = avg; startEdge = i }
            if avg > endVal { endVal = avg; endEdge = i }
        }
        return (startEdge, endEdge)
    }

    /// Walks the closed polygon's boundary forward (increasing index,
    /// wrapping) from `from` to `to`, inclusive of both endpoints.
    private static func walkForward(_ polygon: [Point2D], from: Int, to: Int) -> [Point2D] {
        var result: [Point2D] = [polygon[from]]
        var i = from
        while i != to {
            i = (i + 1) % polygon.count
            result.append(polygon[i])
        }
        return result
    }

}
