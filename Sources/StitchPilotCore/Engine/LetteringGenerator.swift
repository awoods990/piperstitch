import Foundation
#if canImport(CoreText)
import CoreText
import CoreGraphics
#endif

/// How a run of lettering follows its own baseline. `.arc` is the common
/// "ring text" case (a badge's curved title, wrapping the top of a
/// circular seal) -- text is laid out straight first, then remapped onto
/// a circle of the given radius, centered on the arc's topmost point.
public enum LetteringBaseline: Codable, Hashable, Sendable {
    case straight
    case arc(radiusMM: Double)
}

public struct LetteringSpec: Codable, Hashable, Sendable {
    public var text: String
    /// A PostScript font name (`CTFontCreateWithName`'s own currency,
    /// e.g. "Helvetica-Bold") -- resolved from whatever the UI's font
    /// picker offers, so this type stays free of any AppKit/NSFont
    /// dependency.
    public var fontPostScriptName: String
    /// The letter's own capital-letter height, in mm -- not a raw font
    /// point size, since "how tall will this actually sew" is what an
    /// embroiderer cares about, and that depends on the font's own
    /// proportions (a condensed font's point size doesn't mean the same
    /// physical cap height as a wide one at the same point size).
    public var fontSizeMM: Double
    /// Extra spacing added beyond the font's own natural glyph advance,
    /// in mm -- 0 uses the font's normal spacing untouched.
    public var letterSpacingMM: Double
    public var baseline: LetteringBaseline

    public init(text: String, fontPostScriptName: String, fontSizeMM: Double = 20,
                letterSpacingMM: Double = 0, baseline: LetteringBaseline = .straight) {
        self.text = text
        self.fontPostScriptName = fontPostScriptName
        self.fontSizeMM = fontSizeMM
        self.letterSpacingMM = letterSpacingMM
        self.baseline = baseline
    }
}

public enum LetteringGenerationError: Error, LocalizedError {
    case emptyText
    case fontNotFound(String)
    case noGlyphsProduced

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Enter some text to generate lettering."
        case .fontNotFound(let name):
            return "Couldn't find the font \"\(name)\"."
        case .noGlyphsProduced:
            return "This text produced no visible letterforms (all whitespace, or characters this font doesn't have)."
        }
    }
}

/// Generates embroidery-ready vector letterforms directly from a system
/// font's own outlines -- the "Lettering" feature real digitizing software
/// uses for text, rather than raster-tracing an already-rendered image of
/// text (`ImageImporter`'s approach). Raster tracing can never recover
/// more detail than the source image's own pixel resolution allows, a
/// hard, unfixable ceiling for small or tightly curved text (found
/// directly against a real team-crest PNG whose ring text and tagline
/// stayed illegible no matter how the design was resized or reclassified
/// -- see CHANGELOG.md). A font's outline is mathematically exact at any
/// size, so text generated this way is clean regardless of how small or
/// how tightly curved it ends up needing to be.
///
/// One `VectorShape` per glyph, not one shape for the whole string: each
/// letter becomes its own independently-classified, independently-sewn
/// object downstream, exactly matching how a raster import already
/// produces one shape per traced letter fragment. `StitchTypeClassifier`
/// still picks satin for a normal bold letter and running stitch for an
/// unusually thin stroke; `SatinColumnGenerator` gets a genuinely single
/// column to fit rails to, not a whole disconnected word.
#if canImport(CoreText)
public enum LetteringGenerator {
    /// How many samples per glyph outline's bezier curve segment when
    /// flattening it to a polyline -- matches `SVGPathParser`'s own
    /// curve-flattening resolution (a font glyph's curves are
    /// geometrically the same kind of cubic/quadratic bezier an SVG
    /// path uses).
    private static let curveSegments = 28
    /// The point size a font is measured/laid out at before scaling its
    /// output to the requested `fontSizeMM` -- arbitrary but large enough
    /// that CoreText's own internal rounding doesn't meaningfully affect
    /// the measurement.
    private static let referencePointSize: CGFloat = 200

    public static func generateShapes(spec: LetteringSpec) throws -> [VectorShape] {
        guard !spec.text.isEmpty else { throw LetteringGenerationError.emptyText }
        guard let font = CTFontCreateWithNameIfAvailable(spec.fontPostScriptName, size: referencePointSize) else {
            throw LetteringGenerationError.fontNotFound(spec.fontPostScriptName)
        }
        let capHeight = CTFontGetCapHeight(font)
        guard capHeight > 0 else { throw LetteringGenerationError.fontNotFound(spec.fontPostScriptName) }
        let mmPerPoint = spec.fontSizeMM / Double(capHeight)
        let extraSpacingPoints = mmPerPoint > 0 ? spec.letterSpacingMM / mmPerPoint : 0

        // `kCTFontAttributeName` (not the AppKit-only `.font` convenience
        // key) so this stays usable without importing AppKit.
        let attributed = NSAttributedString(string: spec.text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { throw LetteringGenerationError.noGlyphsProduced }

        // Straight-baseline layout first (mm, Y-down, baseline at y=0);
        // `baseline == .arc` remaps every point afterward, once the full
        // string's total width is known.
        var straightShapes: [[Point2D]] = [] // one entry per subpath (flat across all glyphs)
        var glyphSubPathCounts: [Int] = [] // per glyph: how many of straightShapes' entries belong to it
        var maxAdvanceX = 0.0

        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetGlyphs(run, CFRange(location: 0, length: glyphCount), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: glyphCount), &positions)

            for i in 0..<glyphCount {
                let extraOffset = Double(i) * extraSpacingPoints
                let originX = Double(positions[i].x) + extraOffset
                let originY = Double(positions[i].y)
                maxAdvanceX = max(maxAdvanceX, originX)
                guard let path = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
                let subPaths = flattenGlyphPath(path)
                guard !subPaths.isEmpty else { continue }
                for sp in subPaths {
                    straightShapes.append(sp.map { p in
                        Point2D((p.x + originX) * mmPerPoint, -(p.y + originY) * mmPerPoint)
                    })
                }
                glyphSubPathCounts.append(subPaths.count)
            }
        }

        guard !straightShapes.isEmpty else { throw LetteringGenerationError.noGlyphsProduced }

        let totalWidthMM = maxAdvanceX * mmPerPoint
        let remapped: [[Point2D]]
        switch spec.baseline {
        case .straight:
            remapped = straightShapes
        case .arc(let radiusMM):
            remapped = straightShapes.map { $0.map { remapToArc($0, totalWidthMM: totalWidthMM, radiusMM: radiusMM) } }
        }

        // Regroup the flattened subpath list back into one VectorShape per
        // glyph, using the per-glyph subpath counts recorded above.
        var shapes: [VectorShape] = []
        var cursor = 0
        for subPathCount in glyphSubPathCounts {
            var subPaths: [SubPath] = []
            for _ in 0..<subPathCount {
                subPaths.append(SubPath(points: remapped[cursor], closed: true))
                cursor += 1
            }
            shapes.append(VectorShape(subPaths: subPaths))
        }
        return shapes
    }

    /// Bends a straight-layout point (x = distance along the baseline from
    /// its own left edge, y = perpendicular offset, negative above the
    /// baseline) onto a circle of `radiusMM`, centered horizontally on the
    /// text and anchored at the circle's topmost point -- the common
    /// "ring text wrapping the top of a badge" layout. `x` becomes arc
    /// length from center (`theta = x / radius`); `y` pushes the point
    /// further from the arc's own center for ascenders (radius - y, since
    /// y is negative above the baseline), so upright letters actually
    /// radiate outward the way real ring lettering does, not just slide
    /// along a circle keeping their own straight-layout orientation.
    private static func remapToArc(_ point: Point2D, totalWidthMM: Double, radiusMM: Double) -> Point2D {
        guard radiusMM != 0 else { return point }
        let centeredX = point.x - totalWidthMM / 2
        let theta = centeredX / radiusMM
        let effectiveRadius = radiusMM - point.y
        let newX = effectiveRadius * sin(theta)
        let newY = effectiveRadius * (1 - cos(theta)) - (effectiveRadius - radiusMM)
        return Point2D(newX, newY)
    }

    /// Flattens a glyph's `CGPath` (moveto/lineto/curveto/closepath,
    /// possibly several subpaths for one glyph -- an "O" is an outer
    /// contour plus an inner hole, a "B" outer plus two) into polylines,
    /// one array of points per subpath, using the same fixed-sample
    /// bezier flattening `SVGPathParser` uses for SVG curves.
    private static func flattenGlyphPath(_ path: CGPath) -> [[Point2D]] {
        var subPaths: [[Point2D]] = []
        var current: [Point2D] = []
        var currentPoint = CGPoint.zero
        var subPathStart = CGPoint.zero

        func finishCurrent() {
            guard current.count > 2 else { current = []; return }
            subPaths.append(current)
            current = []
        }

        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                finishCurrent()
                let p = element.points[0]
                currentPoint = p
                subPathStart = p
                current = [Point2D(Double(p.x), Double(p.y))]
            case .addLineToPoint:
                let p = element.points[0]
                current.append(Point2D(Double(p.x), Double(p.y)))
                currentPoint = p
            case .addQuadCurveToPoint:
                let c = element.points[0], end = element.points[1]
                for i in 1...curveSegments {
                    let t = Double(i) / Double(curveSegments)
                    current.append(quadraticBezier(currentPoint, c, end, t))
                }
                currentPoint = end
            case .addCurveToPoint:
                let c1 = element.points[0], c2 = element.points[1], end = element.points[2]
                for i in 1...curveSegments {
                    let t = Double(i) / Double(curveSegments)
                    current.append(cubicBezier(currentPoint, c1, c2, end, t))
                }
                currentPoint = end
            case .closeSubpath:
                currentPoint = subPathStart
            @unknown default:
                break
            }
        }
        finishCurrent()
        return subPaths
    }

    private static func cubicBezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: Double) -> Point2D {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return Point2D(a * Double(p0.x) + b * Double(p1.x) + c * Double(p2.x) + d * Double(p3.x),
                        a * Double(p0.y) + b * Double(p1.y) + c * Double(p2.y) + d * Double(p3.y))
    }

    private static func quadraticBezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ t: Double) -> Point2D {
        let mt = 1 - t
        let a = mt * mt, b = 2 * mt * t, c = t * t
        return Point2D(a * Double(p0.x) + b * Double(p1.x) + c * Double(p2.x),
                        a * Double(p0.y) + b * Double(p1.y) + c * Double(p2.y))
    }

    private static func CTFontCreateWithNameIfAvailable(_ name: String, size: CGFloat) -> CTFont? {
        guard !name.isEmpty else { return nil }
        let font = CTFontCreateWithName(name as CFString, size, nil)
        // CTFontCreateWithName never returns nil (it falls back to a
        // system default for an unrecognized name) -- detect that
        // fallback by comparing the resolved PostScript name back against
        // what was actually requested, so an unknown font name surfaces
        // as a real error instead of silently substituting Helvetica.
        let resolvedName = CTFontCopyPostScriptName(font) as String
        guard resolvedName.caseInsensitiveCompare(name) == .orderedSame else { return nil }
        return font
    }
}
#else
/// CoreText is Apple-only. The Linux server build (see server/) generates no
/// glyph outlines itself; the web app produces them in the browser (from the
/// same font files) and submits finished `VectorShape`s, so this stub only
/// exists so the type resolves. Calling it is a programming error there.
public enum LetteringGenerator {
    public static func generateShapes(spec: LetteringSpec) throws -> [VectorShape] {
        guard !spec.text.isEmpty else { throw LetteringGenerationError.emptyText }
        throw LetteringGenerationError.fontNotFound(spec.fontPostScriptName)
    }
}
#endif
