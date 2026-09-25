import Foundation

/// What the outline says should be there, minus what the needle actually
/// covers.
///
/// Every generator here works forward: read a shape, decide a stitch type,
/// lay down columns or rows. None of them ever looks back at what came out
/// and asks whether it covers the shape it was given. So when a column
/// stops short, or a junction falls between two of them, the gap reaches
/// the customer — the outline drawn on screen with bare fabric inside it.
/// The engine had no way to know, because nothing measured.
///
/// This measures. Rasterize the shape, rasterize the stitches as the width
/// of thread they actually are, and subtract. What is left is a pocket the
/// outline claims and the needle never reaches, and a pocket bigger than a
/// stitch or two is simply sewn.
///
/// It is a backstop, not a strategy: the generators should cover their
/// shapes, and where this fires it is worth knowing why. But a hole in a
/// letter is a defect whatever caused it, and the customer would rather
/// have it filled than explained.
public enum CoverageBackstop {
    /// Fine enough to see a gap a stitch wide, coarse enough that a whole
    /// design's objects can each afford the check.
    public static let pixelsPerMM = 8.0
    /// What one stitch actually covers: 40-weight thread lies about this
    /// wide on the fabric. Deliberately not generous — claiming more
    /// coverage than the thread gives is how the gap got here.
    public static let threadWidthMM = 0.45
    /// Below this a gap is invisible against the fabric's own texture.
    /// Above it, it reads as a hole in a letter.
    public static let minimumPocketMM2 = 1.2
    /// A pocket thinner than this in both directions is a rim along an
    /// edge, not a hole: sewing it adds density where the edge already is.
    public static let minimumPocketWidthMM = 0.7
    /// More than this and the object has not got gaps, it has a wrong
    /// stitch plan, and filling them one by one is not the answer.
    /// A pocket only reachable by cutting the thread has to be worth the
    /// cut. Below this it is not: the trim costs the operator more than
    /// the gap costs the eye.
    public static let worthATrimMM2 = 4.0
    public static let maximumPockets = 16
    public static let maximumPixels = 1_500_000

    /// Off only for measuring what it is worth — see the tests and the
    /// CLI's BACKSTOP=off.
    public nonisolated(unsafe) static var isEnabled = true

    /// The parts of `shape` that `runs` never reach, largest first.
    public static func missingRegions(in shape: VectorShape, covered runs: [[Point2D]]) -> [VectorShape] {
        let box = shape.boundingBox
        guard box.width > 0, box.height > 0 else { return [] }
        let margin = 1.0
        var scale = pixelsPerMM
        var width = Int(((box.width + margin * 2) * scale).rounded(.up))
        var height = Int(((box.height + margin * 2) * scale).rounded(.up))
        if width * height > maximumPixels {
            let shrink = (Double(maximumPixels) / Double(width * height)).squareRoot()
            scale *= shrink
            width = Int(((box.width + margin * 2) * scale).rounded(.up))
            height = Int(((box.height + margin * 2) * scale).rounded(.up))
        }
        guard width > 2, height > 2 else { return [] }
        let originX = box.minX - margin, originY = box.minY - margin
        func pixel(_ point: Point2D) -> (x: Int, y: Int) {
            (Int((point.x - originX) * scale), Int((point.y - originY) * scale))
        }

        var target = [Bool](repeating: false, count: width * height)
        for row in 0..<height {
            let y = originY + (Double(row) + 0.5) / scale
            var spans: [Double] = []
            for subPath in shape.subPaths {
                let points = subPath.points
                guard points.count >= 3 else { continue }
                for i in points.indices {
                    let a = points[i], b = points[(i + 1) % points.count]
                    if (a.y > y) != (b.y > y) { spans.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)) }
                }
            }
            spans.sort()
            var index = 0
            while index + 1 < spans.count {
                let from = max(0, Int((spans[index] - originX) * scale))
                let to = min(width - 1, Int((spans[index + 1] - originX) * scale))
                if from <= to { for column in from...to { target[row * width + column] = true } }
                index += 2
            }
        }

        var covered = [Bool](repeating: false, count: width * height)
        let radius = max(1, Int((threadWidthMM / 2 * scale).rounded()))
        func stamp(_ point: Point2D) {
            let (cx, cy) = pixel(point)
            for dy in -radius...radius {
                let y = cy + dy
                guard y >= 0, y < height else { continue }
                for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                    let x = cx + dx
                    guard x >= 0, x < width else { continue }
                    covered[y * width + x] = true
                }
            }
        }
        let step = 1.0 / scale
        for run in runs where run.count >= 2 {
            for i in 0..<(run.count - 1) {
                let a = run[i], b = run[i + 1]
                let distance = a.distance(to: b)
                let pieces = max(1, Int(distance / step))
                for j in 0...pieces {
                    let t = Double(j) / Double(pieces)
                    stamp(Point2D(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
                }
            }
        }

        var missing = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) { missing[i] = target[i] && !covered[i] }
        let minimumPixels = Int(minimumPocketMM2 * scale * scale)
        let components = RasterTracing.connectedComponents(mask: missing, width: width, height: height,
                                                           minAreaPixels: max(4, minimumPixels))
        var out: [(area: Int, shape: VectorShape)] = []
        for component in components.sorted(by: { $0.area > $1.area }).prefix(maximumPockets * 2) {
            var minX = width, maxX = 0, minY = height, maxY = 0
            for index in component.pixelIndices {
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
            let widthMM = Double(maxX - minX + 1) / scale, heightMM = Double(maxY - minY + 1) / scale
            guard min(widthMM, heightMM) >= minimumPocketWidthMM else { continue }
            var only = [Bool](repeating: false, count: width * height)
            for index in component.pixelIndices { only[index] = true }
            guard let boundary = RasterTracing.traceBoundary(mask: only, width: width, height: height,
                                                             start: component.topLeftMost), boundary.count >= 3 else { continue }
            let points = boundary.map { Point2D(originX + ($0.x + 0.5) / scale, originY + ($0.y + 0.5) / scale) }
            out.append((component.area, VectorShape(subPaths: [SubPath(points: points, closed: true)])))
        }
        return out.sorted { $0.area > $1.area }.prefix(maximumPockets).map { $0.shape }
    }
}
