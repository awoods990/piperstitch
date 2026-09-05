import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum SVGImportError: Error, LocalizedError {
    case invalidXML
    case noDrawableShapes

    public var errorDescription: String? {
        switch self {
        case .invalidXML: return "The file isn't valid SVG (XML parsing failed)."
        case .noDrawableShapes: return "No drawable vector shapes were found in this SVG."
        }
    }
}

public struct SVGImportResult {
    /// One VectorShape per top-level drawable element, in the SVG's own
    /// user-space units (aspect ratio is meaningful; absolute scale is not —
    /// call `fitToPhysicalSize` to map onto a finished embroidery size).
    public var shapes: [VectorShape]
    public var fillColors: [RGBColor?]
}

/// Imports SVG vector artwork by walking the XML tree directly and
/// flattening paths/basic shapes — this preserves the original vector
/// geometry (per spec §4: "Do not rasterize vector artwork unnecessarily")
/// rather than rendering to a bitmap and re-tracing it.
public enum SVGImporter {
    public static func importShapes(from data: Data) throws -> SVGImportResult {
        let delegate = SVGParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw SVGImportError.invalidXML }
        guard !delegate.shapes.isEmpty else { throw SVGImportError.noDrawableShapes }
        return SVGImportResult(shapes: delegate.shapes, fillColors: delegate.fillColors)
    }
}

public extension VectorShape {
    /// Uniformly scales + translates this shape so its bounding box fits
    /// within (widthMM, heightMM), preserving aspect ratio and centering —
    /// resizing an *object's geometry*, never its already-generated stitches
    /// (spec §39: physical size changes must regenerate from geometry).
    func fitToPhysicalSize(widthMM: Double, heightMM: Double, within combinedBounds: BoundingBox) -> VectorShape {
        guard !combinedBounds.isEmpty, combinedBounds.width > 0, combinedBounds.height > 0 else { return self }
        let scale = min(widthMM / combinedBounds.width, heightMM / combinedBounds.height)
        let offsetX = -combinedBounds.minX * scale + (widthMM - combinedBounds.width * scale) / 2
        let offsetY = -combinedBounds.minY * scale + (heightMM - combinedBounds.height * scale) / 2
        let newSubPaths = subPaths.map { sp in
            SubPath(points: sp.points.map { Point2D($0.x * scale + offsetX, $0.y * scale + offsetY) }, closed: sp.closed)
        }
        return VectorShape(subPaths: newSubPaths)
    }
}

private final class SVGParserDelegate: NSObject, XMLParserDelegate {
    var shapes: [VectorShape] = []
    var fillColors: [RGBColor?] = []
    private var transformStack: [AffineTransform2D] = [.identity]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let parentTransform = transformStack.last ?? .identity
        var localTransform = AffineTransform2D.identity

        if local == "svg", let viewBox = attrs["viewBox"] {
            let parts = viewBox.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if parts.count == 4 {
                localTransform = AffineTransform2D.translation(-parts[0], -parts[1])
            }
        }
        if let t = attrs["transform"] {
            localTransform = SVGParserDelegate.parseTransform(t).concatenating(localTransform)
        }
        let effective = localTransform.concatenating(parentTransform)
        transformStack.append(effective)

        switch local {
        case "path":
            if let d = attrs["d"] {
                var pathParser = SVGPathParser(d, transform: effective)
                let subPaths = pathParser.parse()
                if !subPaths.isEmpty {
                    shapes.append(VectorShape(subPaths: subPaths))
                    fillColors.append(SVGParserDelegate.parseFill(attrs))
                }
            }
        case "rect":
            let x = attrs["x"].flatMap(Double.init) ?? 0.0
            let y = attrs["y"].flatMap(Double.init) ?? 0.0
            if let w = attrs["width"].flatMap(Double.init), let h = attrs["height"].flatMap(Double.init), w > 0, h > 0 {
                let pts = [Point2D(x, y), Point2D(x + w, y), Point2D(x + w, y + h), Point2D(x, y + h)].map { effective.apply($0) }
                shapes.append(VectorShape(subPaths: [SubPath(points: pts, closed: true)]))
                fillColors.append(SVGParserDelegate.parseFill(attrs))
            }
        case "circle", "ellipse":
            let cx = attrs["cx"].flatMap(Double.init) ?? 0
            let cy = attrs["cy"].flatMap(Double.init) ?? 0
            let rx = local == "circle" ? (attrs["r"].flatMap(Double.init) ?? 0) : (attrs["rx"].flatMap(Double.init) ?? 0)
            let ry = local == "circle" ? rx : (attrs["ry"].flatMap(Double.init) ?? 0)
            if rx > 0, ry > 0 {
                let segments = 48
                let pts = (0..<segments).map { i -> Point2D in
                    let t = 2 * Double.pi * Double(i) / Double(segments)
                    return effective.apply(Point2D(cx + rx * cos(t), cy + ry * sin(t)))
                }
                shapes.append(VectorShape(subPaths: [SubPath(points: pts, closed: true)]))
                fillColors.append(SVGParserDelegate.parseFill(attrs))
            }
        case "polygon", "polyline":
            if let pointsStr = attrs["points"] {
                let nums = pointsStr.split(whereSeparator: { " ,\t\n".contains($0) }).compactMap { Double($0) }
                var pts: [Point2D] = []
                var i = 0
                while i + 1 < nums.count { pts.append(effective.apply(Point2D(nums[i], nums[i + 1]))); i += 2 }
                if pts.count > 1 {
                    shapes.append(VectorShape(subPaths: [SubPath(points: pts, closed: local == "polygon")]))
                    fillColors.append(SVGParserDelegate.parseFill(attrs))
                }
            }
        case "line":
            if let x1 = attrs["x1"].flatMap(Double.init), let y1 = attrs["y1"].flatMap(Double.init),
               let x2 = attrs["x2"].flatMap(Double.init), let y2 = attrs["y2"].flatMap(Double.init) {
                let pts = [Point2D(x1, y1), Point2D(x2, y2)].map { effective.apply($0) }
                shapes.append(VectorShape(subPaths: [SubPath(points: pts, closed: false)]))
                fillColors.append(nil)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if transformStack.count > 1 { transformStack.removeLast() }
    }

    private static func parseFill(_ attrs: [String: String]) -> RGBColor? {
        var fillString = attrs["fill"]
        if let style = attrs["style"] {
            for decl in style.split(separator: ";") {
                let kv = decl.split(separator: ":", maxSplits: 1)
                if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "fill" {
                    fillString = kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        guard let s = fillString else { return RGBColor(hex: 0x000000) } // SVG default fill is black
        if s == "none" { return nil }
        return parseColor(s) ?? RGBColor(hex: 0x000000)
    }

    static func parseColor(_ s: String) -> RGBColor? {
        var s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            s.removeFirst()
            if s.count == 3 {
                let chars = Array(s)
                s = chars.map { String([$0, $0]) }.joined()
            }
            guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
            return RGBColor(hex: v)
        }
        if s.hasPrefix("rgb(") {
            let inner = s.dropFirst(4).dropLast()
            let parts = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3 else { return nil }
            return RGBColor(r: UInt8(clamping: parts[0]), g: UInt8(clamping: parts[1]), b: UInt8(clamping: parts[2]))
        }
        return namedColors[s.lowercased()]
    }

    private static let namedColors: [String: RGBColor] = [
        "black": RGBColor(hex: 0x000000), "white": RGBColor(hex: 0xFFFFFF),
        "red": RGBColor(hex: 0xFF0000), "green": RGBColor(hex: 0x008000),
        "blue": RGBColor(hex: 0x0000FF), "yellow": RGBColor(hex: 0xFFFF00),
        "orange": RGBColor(hex: 0xFFA500), "purple": RGBColor(hex: 0x800080),
        "gray": RGBColor(hex: 0x808080), "grey": RGBColor(hex: 0x808080),
    ]

    static func parseTransform(_ s: String) -> AffineTransform2D {
        var result = AffineTransform2D.identity
        let scanner = Scanner(string: s)
        while !scanner.isAtEnd {
            scanner.charactersToBeSkipped = .whitespaces
            guard let name = scanner.scanUpToString("(") else { break }
            _ = scanner.scanString("(")
            guard let argsStr = scanner.scanUpToString(")") else { break }
            _ = scanner.scanString(")")
            let args = argsStr.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
            let name2 = name.trimmingCharacters(in: .whitespaces)
            var t = AffineTransform2D.identity
            switch name2 {
            case "translate":
                t = .translation(args.first ?? 0, args.count > 1 ? args[1] : 0)
            case "scale":
                t = .scale(args.first ?? 1, args.count > 1 ? args[1] : (args.first ?? 1))
            case "rotate":
                if args.count >= 3 {
                    let toOrigin = AffineTransform2D.translation(-args[1], -args[2])
                    let rot = AffineTransform2D.rotation(degrees: args[0])
                    let back = AffineTransform2D.translation(args[1], args[2])
                    t = toOrigin.concatenating(rot).concatenating(back)
                } else {
                    t = .rotation(degrees: args.first ?? 0)
                }
            case "matrix":
                if args.count == 6 {
                    t = AffineTransform2D(a: args[0], b: args[1], c: args[2], d: args[3], e: args[4], f: args[5])
                }
            default:
                break
            }
            result = result.concatenating(t)
        }
        return result
    }
}
