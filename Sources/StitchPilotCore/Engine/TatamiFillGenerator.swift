import Foundation

/// Generates tatami (scanline) fill stitches for a closed region — spec
/// §11 "Tatami / Fill Stitch". The shape's sub-paths are treated as a
/// single even-odd-rule polygon set, so additional sub-paths beyond the
/// first are automatically holes (spec §21 "Negative Space") without any
/// special-casing: a hole's boundary just contributes scanline crossings
/// that toggle the inside/outside state like any other edge.
///
/// Algorithm: rotate the shape so the fill angle becomes horizontal, walk
/// scanlines at `fillSpacingMM` intervals computing edge-crossing intervals
/// (standard even-odd scanline fill), resample each interval into stitches
/// at `stitchLengthMM`, alternate direction each row (boustrophedon, so
/// consecutive rows connect with a short stitch instead of a jump), stagger
/// the stitch phase between rows so seams don't line up into a visible
/// grid, then rotate the result back.
public enum TatamiFillGenerator {
    public static func generate(for shape: VectorShape, parameters: StitchGenerationParameters) -> [Point2D] {
        guard !shape.subPaths.isEmpty else { return [] }
        let angleRad = parameters.fillAngleDegrees * .pi / 180
        let cosA = cos(-angleRad), sinA = sin(-angleRad) // rotate shape by -angle so fill rows become horizontal

        func rotate(_ p: Point2D, cos c: Double, sin s: Double) -> Point2D {
            Point2D(p.x * c - p.y * s, p.x * s + p.y * c)
        }

        let rotatedPolygons: [[Point2D]] = shape.subPaths.map { sp in sp.points.map { rotate($0, cos: cosA, sin: sinA) } }
        var box = BoundingBox.empty
        for poly in rotatedPolygons { box = box.union(BoundingBox(points: poly)) }
        guard !box.isEmpty, box.height > 0 else { return [] }

        let spacing = max(parameters.fillSpacingMM, 0.05)
        let stitchLength = max(parameters.stitchLengthMM, 0.3)
        let stagger = parameters.fillRowStaggerMM

        var rows: [[Point2D]] = [] // each row: resampled stitch points, in rotated space, in walking order
        var rowIndex = 0
        var y = box.minY + spacing / 2 // center rows within the shape rather than starting exactly on the edge

        while y < box.maxY {
            let crossings = scanlineCrossings(polygons: rotatedPolygons, y: y)
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

    private static func resampleRun(y: Double, xStart: Double, xEnd: Double, stitchLength: Double, phase: Double) -> [Point2D] {
        var points: [Point2D] = [Point2D(xStart, y)]
        var x = xStart + (phase > 0 ? phase : stitchLength)
        while x < xEnd {
            points.append(Point2D(x, y))
            x += stitchLength
        }
        if points.last!.x < xEnd - 0.01 {
            points.append(Point2D(xEnd, y))
        }
        return points
    }
}
