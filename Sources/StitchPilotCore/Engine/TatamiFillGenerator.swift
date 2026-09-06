import Foundation

/// Generates tatami (scanline) fill stitches for a closed region — spec
/// §11 "Tatami / Fill Stitch". The shape's sub-paths are treated as a
/// single even-odd-rule polygon set, so additional sub-paths beyond the
/// first are automatically holes (spec §21 "Negative Space") without any
/// special-casing: a hole's boundary just contributes scanline crossings
/// that toggle the inside/outside state like any other edge.
///
/// Algorithm: rotate the shape so the fill angle becomes horizontal, grow
/// the boundary for pull compensation, walk scanlines at `fillSpacingMM`
/// intervals computing edge-crossing intervals (standard even-odd scanline
/// fill), shrink each row's overall span for push compensation, resample
/// each interval into stitches at `stitchLengthMM`, alternate direction
/// each row (boustrophedon, so consecutive rows connect with a short
/// stitch instead of a jump), stagger the stitch phase between rows so
/// seams don't line up into a visible grid, then rotate the result back.
public enum TatamiFillGenerator {
    public static func generate(for shape: VectorShape, parameters: StitchGenerationParameters) -> [Point2D] {
        guard !shape.subPaths.isEmpty else { return [] }
        let angleDegrees = parameters.fillAngleDegrees ?? FillAngleSelector.selectAngle(for: shape)
        let angleRad = angleDegrees * .pi / 180
        let cosA = cos(-angleRad), sinA = sin(-angleRad) // rotate shape by -angle so fill rows become horizontal

        func rotate(_ p: Point2D, cos c: Double, sin s: Double) -> Point2D {
            Point2D(p.x * c - p.y * s, p.x * s + p.y * c)
        }

        var rotatedPolygons: [[Point2D]] = shape.subPaths.map { sp in sp.points.map { rotate($0, cos: cosA, sin: sinA) } }
        var box = BoundingBox.empty
        for poly in rotatedPolygons { box = box.union(BoundingBox(points: poly)) }
        guard !box.isEmpty, box.height > 0 else { return [] }

        // Pull compensation (spec §17): grow the outer boundary outward
        // before scanning, so the fill sews at its intended size after
        // fabric pulls it in. Holes are left as digitized for now (shrinking
        // them to compensate too is a follow-up — see DIGITIZING_ENGINE.md).
        let compensation = parameters.pullCompensationMM
            ?? PullCompensationCalculator.estimate(stitchType: .tatamiFill, densityMM: parameters.fillSpacingMM, objectWidthMM: box.height)
        // Skip compensation on a shape too small relative to it: growing a
        // near-degenerate sliver by pull compensation would fabricate a
        // fill region that wasn't really there rather than adjusting one
        // that was. Such shapes should be filtered upstream as
        // insignificant (spec §19) once that exists; this guard just keeps
        // this generator from doing something clearly wrong in the meantime.
        if compensation > 0, box.height > compensation * 4, !rotatedPolygons.isEmpty {
            rotatedPolygons[0] = PolygonGeometry.offsetPolygon(rotatedPolygons[0], by: -compensation)
            box = BoundingBox.empty
            for poly in rotatedPolygons { box = box.union(BoundingBox(points: poly)) }
        }

        let spacing = max(parameters.fillSpacingMM, 0.05)
        let stitchLength = max(parameters.stitchLengthMM, 0.3)
        let stagger = parameters.fillRowStaggerMM

        // Push compensation: fabric pushes apart *along* the stitching
        // direction (as opposed to pull, which narrows a design
        // perpendicular to it — see `PullCompensationCalculator`). Rows run
        // horizontally in this rotated space, so push acts along x: shrink
        // each row's *overall* span by insetting only its outermost start
        // and end, before resampling — not every enter/exit pair, which
        // would incorrectly nibble at a hole's boundary too. `box.width` is
        // the shape's extent along the row direction, the relevant "length"
        // axis for this effect (as opposed to `box.height`, along which
        // pull compensation above already grew the boundary).
        let pushCompMM = parameters.pushCompensationMM
            ?? PullCompensationCalculator.estimatePush(stitchType: .tatamiFill, densityMM: spacing, objectLengthMM: box.width)

        var rows: [[Point2D]] = [] // each row: resampled stitch points, in rotated space, in walking order
        var rowIndex = 0
        var y = box.minY + spacing / 2 // center rows within the shape rather than starting exactly on the edge

        while y < box.maxY {
            var crossings = scanlineCrossings(polygons: rotatedPolygons, y: y)
            if pushCompMM > 0, crossings.count >= 2, crossings.last! - crossings.first! > pushCompMM {
                crossings[0] += pushCompMM / 2
                crossings[crossings.count - 1] -= pushCompMM / 2
            }
            var rowPoints: [Point2D] = []
            let phase = (Double(rowIndex) * stagger).truncatingRemainder(dividingBy: stitchLength)

            var runIndex = 0
            while runIndex + 1 < crossings.count {
                let xStart = crossings[runIndex]
                let xEnd = crossings[runIndex + 1]
                runIndex += 2
                guard xEnd > xStart else { continue }
                rowPoints.append(contentsOf: resampleRun(y: y, xStart: xStart, xEnd: xEnd, stitchLength: stitchLength, phase: phase))
            }

            if !rowPoints.isEmpty {
                // Boustrophedon: alternate direction so consecutive rows connect end-to-end.
                if rowIndex % 2 == 1 { rowPoints.reverse() }
                rows.append(rowPoints)
            }
            rowIndex += 1
            y += spacing
        }

        let flatRotated = rows.flatMap { $0 }
        return flatRotated.map { rotate($0, cos: cos(angleRad), sin: sin(angleRad)) }
    }

    /// Even-odd rule: all edges from all sub-paths (holes included) are
    /// tested against the scanline together; sorted crossing X-values pair
    /// up as [enter, exit, enter, exit, ...].
    private static func scanlineCrossings(polygons: [[Point2D]], y: Double) -> [Double] {
        var xs: [Double] = []
        for poly in polygons {
            guard poly.count > 1 else { continue }
            for i in 0..<poly.count {
                let a = poly[i]
                let b = poly[(i + 1) % poly.count] // treat every fill sub-path as implicitly closed
                let (lo, hi) = a.y < b.y ? (a, b) : (b, a)
                guard y >= lo.y, y < hi.y, hi.y > lo.y else { continue } // half-open avoids double-counting at shared vertices
                let t = (y - lo.y) / (hi.y - lo.y)
                xs.append(lo.x + t * (hi.x - lo.x))
            }
        }
        return xs.sorted()
    }

    /// Resamples one row's interval at approximately `stitchLength`,
    /// starting the first interior stitch at the staggered `phase` offset
    /// (preserving the anti-grid benefit of staggering — see this type's
    /// own doc comment on why rows are staggered at all), but then evenly
    /// redistributing the *remaining* distance to `xEnd` across a whole
    /// number of steps close to `stitchLength`, rather than stepping by a
    /// fixed `stitchLength` and appending one final "catch-up" point
    /// wherever that happens to land. A fixed step leaves that catch-up
    /// segment anywhere from ~0 to a full `stitchLength` long; evening out
    /// the remainder keeps every row landing exactly on the true edge with
    /// a uniform final step instead — a small cleanliness improvement, not
    /// a fix for any specific visible defect (a dramatic-looking
    /// criss-cross pattern initially suspected to be caused by this turned
    /// out, on direct inspection, to be the ordinary tie-in/tie-off anchor
    /// stitches — see CHANGELOG.md).
    private static func resampleRun(y: Double, xStart: Double, xEnd: Double, stitchLength: Double, phase: Double) -> [Point2D] {
        var points: [Point2D] = [Point2D(xStart, y)]
        let firstOffset = phase > 0 ? phase : stitchLength
        let firstInterior = xStart + firstOffset
        guard firstInterior < xEnd else {
            if xEnd - xStart > 0.01 { points.append(Point2D(xEnd, y)) }
            return points
        }
        let remaining = xEnd - firstInterior
        let stepCount = max(1, Int((remaining / stitchLength).rounded()))
        let step = remaining / Double(stepCount)
        for i in 0...stepCount {
            points.append(Point2D(firstInterior + step * Double(i), y))
        }
        return points
    }
}
