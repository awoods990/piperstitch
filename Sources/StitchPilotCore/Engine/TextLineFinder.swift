import Foundation

/// A run of letter-sized shapes in a line: what a tagline looks like to
/// the importer before anyone reads it. Pixel space, like the shapes.
public struct TextLine: Codable, Sendable, Equatable {
    /// Indices into the imported shapes that make up the line.
    public var shapeIndices: [Int]
    public var boundingBoxPixels: BoundingBox
    /// Degrees the line's baseline is rotated from horizontal (positive =
    /// the right end lower, in the image's Y-down convention).
    public var rotationDegrees: Double
    /// The line's letter height -- the taller letters, so a capital's
    /// height for mixed-case text -- in pixels.
    public var capHeightPixels: Double
    /// Strokes cover this share of their letters' boxes; bold from ~0.42.
    public var inkFraction: Double
    /// The letters' centres sit on an arc rather than a line (a badge's
    /// ring text). `arcRadiusPixels` is then a rough fit of that arc.
    public var curved: Bool
    public var arcRadiusPixels: Double?
    public var color: RGBColor?
    /// Letters of two clearly different heights (capitals and x-height
    /// letters, or ascenders): mixed case rather than all capitals.
    public var mixedCase: Bool = false
    /// Median letter width over cap height: about 0.5 for a condensed
    /// face, 0.7-0.8 for a normal one, over 0.9 for a wide one.
    public var letterAspect: Double = 0.7

    public var suggestsBold: Bool { inkFraction >= TextLineFinder.boldInkFraction }

    /// Whether the engine may leave this line out on its own when it is
    /// too small: straight text, or ring text long enough to be sure of.
    /// A short curved run is as likely a wing's feathers as a word, and
    /// dropping feathers is worse than sewing small letters; the Text
    /// step still shows it and the user decides.
    public var dropsWhenTooSmall: Bool { !curved || shapeIndices.count >= TextLineFinder.minimumCurvedLettersToDrop }
}

/// Finds text in imported artwork by its geometry alone -- a row of
/// letter-sized shapes of one colour, evenly spaced, similar heights --
/// with no OCR and no Vision, so it runs the same on the Linux server as
/// on a Mac. It does not know what the text says; it knows where a line
/// of text is, how tall its letters are, which way it runs and roughly
/// how bold it is. That is enough to decide whether the line can be sewn
/// at the chosen size, to remove it whole rather than let it fragment,
/// and to place re-typed lettering exactly where it was.
///
/// Twenty studio samples (September 2026) made the case: every tagline
/// under about 3 mm was either dropped or, worse, sewn as readable
/// fragments of half-letters, while the studio re-sets each one as
/// lettering at a size that works.
public enum TextLineFinder {
    /// Ink coverage of a letter's own box from which the line reads as bold.
    public static let boldInkFraction = 0.42

    /// The shortest capital that sews as lettering, by thread weight: 5 mm
    /// for 40-weight, 4 mm for the fine threads, 6 mm for 30-weight.
    ///
    /// Raised a millimetre in September 2026, on the evidence of a serif
    /// tagline at 4.6 mm -- comfortably over the old 4 mm floor, and mush
    /// on the fabric. The old numbers were the point below which letters
    /// fragment; these are the point below which they stop being worth
    /// sewing, which is the question a customer is actually asking. The
    /// floor costs less than it used to, because a line that misses it
    /// narrowly is now grown into range rather than simply dropped -- see
    /// `SmallTextRescue`.
    public static func minimumCapHeightMM(for weight: ThreadWeight) -> Double {
        switch weight {
        case .wt30: return 6.0
        case .wt40: return 5.0
        case .wt60, .wt80: return 4.0
        }
    }

    /// Fewer letters than this is not a line of text.
    public static let minimumLetters = 3

    /// Letters in one line vary in height by at most this much (standard
    /// deviation over mean): mixed case with ascenders is about 0.25.
    public static let maximumHeightSpread = 0.35

    /// Neighbouring letters may be this many letter-heights apart: a
    /// letter-spaced title ("Y E A R S") runs to about two.
    public static let maximumLetterGapFactor = 2.2

    /// At least this share of a line's letters end on its baseline (within
    /// a fifth of the cap height): real text scores 0.67 and up even with
    /// descenders and dotted i's; a wing's feathers about 0.2.
    public static let minimumBaselineAlignment = 0.45

    /// See `TextLine.dropsWhenTooSmall`.
    public static let minimumCurvedLettersToDrop = 8

    /// `imageHeightPixels` is the raster's height; pass 0 for vector input
    /// (an SVG's shapes, in its own units) and the drawing's height stands
    /// in. Everything else is relative, so the result is in the shapes'
    /// units either way.
    public static func find(shapes: [VectorShape], fillColors: [RGBColor?], imageHeightPixels: Int) -> [TextLine] {
        let debug = ProcessInfo.processInfo.environment["DEBUG_TEXT"] != nil
        guard shapes.count >= minimumLetters else { return [] }
        struct Glyph { var index: Int; var box: BoundingBox; var area: Double; var color: RGBColor? }
        var glyphs: [Glyph] = []
        var frameHeight = Double(imageHeightPixels)
        var minHeight = 3.0
        if imageHeightPixels <= 0 {
            var all = BoundingBox.empty
            for shape in shapes { all = all.union(shape.boundingBox) }
            frameHeight = max(1e-9, all.height)
            minHeight = frameHeight * 0.005
        }
        let maxHeight = frameHeight * 0.35
        for (i, shape) in shapes.enumerated() {
            guard let outer = shape.subPaths.first, outer.points.count >= 3 else { continue }
            let box = shape.boundingBox
            guard box.height >= minHeight, box.height <= maxHeight, box.width <= box.height * 3, box.width >= minHeight / 3 else {
                if debug { print("  text: shape \(i) \(Int(box.width))x\(Int(box.height)) px not letter-sized (max height \(Int(maxHeight)))") }
                continue
            }
            let area = abs(PolygonGeometry.signedArea(outer.points))
            guard area >= 0.1 * box.width * box.height else {
                if debug { print("  text: shape \(i) \(Int(box.width))x\(Int(box.height)) px too sparse") }
                continue
            }
            glyphs.append(Glyph(index: i, box: box, area: area, color: i < fillColors.count ? fillColors[i] : nil))
        }
        guard glyphs.count >= minimumLetters else { return [] }

        // Link letters of one colour that sit close together at a similar
        // height; each connected group is a candidate line.
        func gap(_ a: BoundingBox, _ b: BoundingBox) -> Double {
            let dx = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
            let dy = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
            return (dx * dx + dy * dy).squareRoot()
        }
        var parent = Array(0..<glyphs.count)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in glyphs.indices {
            for j in glyphs.indices where j > i {
                let a = glyphs[i], b = glyphs[j]
                guard a.color == b.color else { continue }
                let h = max(a.box.height, b.box.height), small = min(a.box.height, b.box.height)
                guard small >= h * 0.45 else { continue }
                guard gap(a.box, b.box) <= h * maximumLetterGapFactor else { continue }
                // Side by side: the boxes overlap vertically. Neighbours
                // that do not -- ring text running down the side of a
                // badge, or two rows of one tagline -- must be alike in
                // height and close; a title over its smaller tagline is
                // never one line.
                let overlap = min(a.box.maxY, b.box.maxY) - max(a.box.minY, b.box.minY)
                if overlap < small * 0.5 {
                    guard small >= h * 0.7, overlap >= -h * 0.6 else { continue }
                }
                let ra = root(i), rb = root(j)
                if ra != rb { parent[ra] = rb }
            }
        }
        var groups: [Int: [Glyph]] = [:]
        for i in glyphs.indices { groups[root(i), default: []].append(glyphs[i]) }

        var lines: [TextLine] = []
        // A group is a line when its letters are alike in height and sit
        // on one row (straight or arced). A title that chained to its
        // tagline, or two rows of one tagline, is split at the height or
        // row gap and each part tried on its own, so a shield's stripes
        // still fail while stacked text is found line by line.
        func evaluate(_ members: [Glyph], depth: Int) {
            guard members.count >= minimumLetters, depth < 6 else { return }
            let heights = members.map { $0.box.height }.sorted()
            if debug { print("  text: group of \(members.count) shapes \(members.map { $0.index }.sorted()) heights \(heights.map { Int($0) })") }
            let capHeight = heights[min(heights.count - 1, Int(Double(heights.count) * 0.75))]
            var box = BoundingBox.empty
            for m in members { box = box.union(m.box) }
            let meanHeight = heights.reduce(0, +) / Double(heights.count)
            let heightSpread = (heights.reduce(0) { $0 + ($1 - meanHeight) * ($1 - meanHeight) } / Double(heights.count)).squareRoot() / max(1e-9, meanHeight)
            if heightSpread > maximumHeightSpread {
                // Split at the widest ratio between neighbouring heights.
                var bestRatio = 1.0, cut = heights[0]
                for k in 1..<heights.count where heights[k] / max(1e-9, heights[k - 1]) > bestRatio { bestRatio = heights[k] / heights[k - 1]; cut = heights[k] }
                guard bestRatio >= 1.35 else { if debug { print("    rejected: height spread \(heightSpread)") }; return }
                if debug { print("    split by height at \(Int(cut)) px") }
                evaluate(members.filter { $0.box.height < cut }, depth: depth + 1)
                evaluate(members.filter { $0.box.height >= cut }, depth: depth + 1)
                return
            }
            let centres = members.map { Point2D($0.box.minX + $0.box.width / 2, $0.box.minY + $0.box.height / 2) }
            let (axis, mean) = PolygonGeometry.principalAxis(centres)
            var angle = atan2(axis.y, axis.x) * 180 / .pi
            if angle > 90 { angle -= 180 } else if angle < -90 { angle += 180 }
            // Residual from the fitted line tells straight from curved --
            // or two rows: a clear gap in the residuals, with letters on
            // both sides, is a second line of the same size.
            let normal = Point2D(-axis.y, axis.x)
            let residuals = centres.map { ($0.x - mean.x) * normal.x + ($0.y - mean.y) * normal.y }
            let ordered = residuals.enumerated().sorted { $0.element < $1.element }
            var widestGap = 0.0, rowCut = 0.0
            for k in 1..<ordered.count where ordered[k].element - ordered[k - 1].element > widestGap {
                widestGap = ordered[k].element - ordered[k - 1].element; rowCut = (ordered[k].element + ordered[k - 1].element) / 2
            }
            if widestGap > capHeight * 0.7 {
                let above = members.indices.filter { residuals[$0] < rowCut }
                let below = members.indices.filter { residuals[$0] >= rowCut }
                // Both sides flat: an arc has gaps in its residuals too,
                // but neither half of an arc is a straight row.
                func range(_ idx: [Int]) -> Double { (idx.map { residuals[$0] }.max() ?? 0) - (idx.map { residuals[$0] }.min() ?? 0) }
                if above.count >= minimumLetters, below.count >= minimumLetters,
                   range(above) <= capHeight * 0.35, range(below) <= capHeight * 0.35 {
                    let above = above.map { members[$0] }, below = below.map { members[$0] }
                    if debug { print("    split into two rows") }
                    evaluate(above, depth: depth + 1); evaluate(below, depth: depth + 1)
                    return
                }
            }
            // A line is much longer than it is tall: a shield's stripes or
            // an owl's feathers chain up too, but not in a row.
            guard max(box.width, box.height) >= capHeight * 2.5 else { if debug { print("    rejected: not long enough") }; return }
            let rms = (residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count)).squareRoot()
            // Curved when the centres leave the line by more than letter
            // wobble (descenders, a taller capital) AND a circle fits them
            // clearly better than the line does.
            var curved = false
            var radius: Double? = nil
            if members.count >= 5, rms > capHeight * 0.18, let fit = circleFit(centres) {
                let circleRMS = (centres.reduce(0.0) { acc, c in
                    let d = ((c.x - fit.center.x) * (c.x - fit.center.x) + (c.y - fit.center.y) * (c.y - fit.center.y)).squareRoot() - fit.radius
                    return acc + d * d
                } / Double(centres.count)).squareRoot()
                if circleRMS < rms * 0.5 { curved = true; radius = fit.radius }
            }
            // Letters share a baseline: most of them end at the same
            // distance along the line's normal (descenders and rotated
            // boxes excepted). A wing's feathers or a shield's stripes
            // chain like letters but stagger.
            // Measured along the normal, so only straight text is held to
            // it: a wing's feathers fan from a centre much as ring text
            // does, and the radial version told them apart no better than
            // chance.
            let bottoms = members.map { m -> Double in
                let corners = [Point2D(m.box.minX, m.box.minY), Point2D(m.box.maxX, m.box.minY), Point2D(m.box.minX, m.box.maxY), Point2D(m.box.maxX, m.box.maxY)]
                return corners.map { ($0.x - mean.x) * normal.x + ($0.y - mean.y) * normal.y }.max() ?? 0
            }.sorted()
            let baseline = bottoms[bottoms.count / 2]
            let aligned = Double(bottoms.filter { abs($0 - baseline) <= capHeight * 0.2 }.count) / Double(bottoms.count)
            if debug { print("    baseline alignment \(aligned) angle \(Int(angle))") }
            guard curved || aligned >= minimumBaselineAlignment else { if debug { print("    rejected: no common baseline") }; return }
            let ink = members.reduce(0.0) { $0 + $1.area } / max(1, members.reduce(0.0) { $0 + $1.box.width * $1.box.height })
            // Mixed case: a real share of the letters are markedly shorter
            // than the capitals (x-height is ~70% of cap height in most
            // faces); all-capital lines are all within a few percent.
            let shortCount = heights.filter { $0 < capHeight * 0.85 }.count
            let mixedCase = shortCount >= max(1, Int(Double(heights.count) * 0.3)) && shortCount < heights.count
            let widths = members.map { $0.box.width / max(1e-6, $0.box.height) }.sorted()
            let aspect = widths[widths.count / 2]
            var line = TextLine(shapeIndices: members.map { $0.index }.sorted(), boundingBoxPixels: box, rotationDegrees: angle,
                                capHeightPixels: capHeight, inkFraction: ink, curved: curved, arcRadiusPixels: radius, color: members[0].color)
            line.mixedCase = mixedCase
            line.letterAspect = aspect
            lines.append(line)
        }
        for members in groups.values { evaluate(members, depth: 0) }
        return lines.sorted { ($0.boundingBoxPixels.minY, $0.boundingBoxPixels.minX) < ($1.boundingBoxPixels.minY, $1.boundingBoxPixels.minX) }
    }

    /// Algebraic (Kåsa) circle fit through the points.
    static func circleFit(_ points: [Point2D]) -> (center: Point2D, radius: Double)? {
        guard points.count >= 3 else { return nil }
        let n = Double(points.count)
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, sxz = 0.0, syz = 0.0, sz = 0.0
        for p in points {
            let z = p.x * p.x + p.y * p.y
            sx += p.x; sy += p.y; sxx += p.x * p.x; syy += p.y * p.y; sxy += p.x * p.y; sxz += p.x * z; syz += p.y * z; sz += z
        }
        // Solve for a, b, c in x² + y² + a x + b y + c = 0 (least squares).
        let a11 = sxx, a12 = sxy, a13 = sx, a22 = syy, a23 = sy, a33 = n
        let b1 = -sxz, b2 = -syz, b3 = -sz
        let det = a11 * (a22 * a33 - a23 * a23) - a12 * (a12 * a33 - a23 * a13) + a13 * (a12 * a23 - a22 * a13)
        guard abs(det) > 1e-9 else { return nil }
        let a = (b1 * (a22 * a33 - a23 * a23) - a12 * (b2 * a33 - a23 * b3) + a13 * (b2 * a23 - a22 * b3)) / det
        let b = (a11 * (b2 * a33 - a23 * b3) - b1 * (a12 * a33 - a23 * a13) + a13 * (a12 * b3 - b2 * a13)) / det
        let c = (a11 * (a22 * b3 - b2 * a23) - a12 * (a12 * b3 - b2 * a13) + b1 * (a12 * a23 - a22 * a13)) / det
        let cx = -a / 2, cy = -b / 2
        let r2 = cx * cx + cy * cy - c
        guard r2 > 0 else { return nil }
        return (Point2D(cx, cy), r2.squareRoot())
    }
}
