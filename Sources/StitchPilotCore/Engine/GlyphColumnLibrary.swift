import Foundation

/// A font's glyphs as pre-digitized satin columns -- what commercial
/// embroidery software calls a keyboard font. Each glyph was run through
/// `SatinColumnGenerator.columnPlan` once, at a cap height where the
/// generator is reliable (22 mm), reviewed on a rendered sheet, and stored
/// as rails in cap-height units; at sew time the rails are scaled to the
/// requested cap height and crossed at the document's density
/// (`SatinColumnGenerator.sewColumns`). The same letter therefore sews the
/// same way at every size, and nothing is rediscovered from pixels.
///
/// Units: 1000 per cap height, glyph origin at the baseline's left, y down
/// (the font's own frame as opentype.js hands it to the web app, scaled).
public struct GlyphColumnFont: Codable, Sendable {
    public var fontID: String
    public var version: Int
    /// The cap height the columns were digitized at, for the record.
    public var digitizedCapHeightMM: Double
    public var glyphs: [String: GlyphColumns]
    /// Characters the generator could not make columns for; the lettering
    /// route falls back to the generic path for these.
    public var missing: [String]

    public init(fontID: String, version: Int = 1, digitizedCapHeightMM: Double, glyphs: [String: GlyphColumns], missing: [String]) {
        self.fontID = fontID; self.version = version; self.digitizedCapHeightMM = digitizedCapHeightMM; self.glyphs = glyphs; self.missing = missing
    }

    private enum CodingKeys: String, CodingKey { case fontID = "font", version = "v", digitizedCapHeightMM = "cap", glyphs = "g", missing = "m" }
}

public struct GlyphColumns: Codable, Sendable {
    /// Advance width in cap-height units, for the record (the web app
    /// places glyphs itself).
    public var advance: Double
    public var columns: [SatinColumn]

    public init(advance: Double, columns: [SatinColumn]) { self.advance = advance; self.columns = columns }

    private enum CodingKeys: String, CodingKey { case advance = "adv", columns = "c" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        advance = try c.decode(Double.self, forKey: .advance)
        columns = try c.decode([CompactColumn].self, forKey: .columns).map { $0.column }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(advance, forKey: .advance)
        try c.encode(columns.map { CompactColumn($0) }, forKey: .columns)
    }
}

/// A column as flat coordinate lists, rounded to units -- a third the
/// size of the point-by-point form.
struct CompactColumn: Codable {
    var a: [Double]
    var b: [Double]
    var t: Bool?

    init(_ column: SatinColumn) {
        a = column.railA.flatMap { [$0.x.rounded(), $0.y.rounded()] }
        b = column.railB.flatMap { [$0.x.rounded(), $0.y.rounded()] }
        t = column.travelOut ? true : nil
    }

    var column: SatinColumn {
        func points(_ flat: [Double]) -> [Point2D] { stride(from: 0, to: flat.count - 1, by: 2).map { Point2D(flat[$0], flat[$0 + 1]) } }
        return SatinColumn(railA: points(a), railB: points(b), travelOut: t ?? false)
    }
}

public enum GlyphColumnLibrary {
    /// Cap height in library units.
    public static let capHeightUnits = 1000.0

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: GlyphColumnFont?] = [:]

    /// The library for a web font id ("roboto", "open-sans", ...), or nil
    /// when no glyphs have been digitized for it.
    public static func font(_ id: String) -> GlyphColumnFont? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[id] { return cached }
        var loaded: GlyphColumnFont? = nil
        if let json = GlyphColumnData.json(for: id), let data = json.data(using: .utf8) {
            loaded = try? JSONDecoder().decode(GlyphColumnFont.self, from: data)
        }
        cache[id] = loaded
        return loaded
    }

    /// Decodes a library file (for the CLI's sheet and for tests).
    public static func load(from url: URL) throws -> GlyphColumnFont {
        try JSONDecoder().decode(GlyphColumnFont.self, from: Data(contentsOf: url))
    }

    /// A glyph's columns placed in millimetres: scaled so the cap height
    /// is `capHeightMM`, the glyph origin at `origin` (its baseline-left
    /// point), then `transform` applied to every point (the run's arc,
    /// rotation and centring).
    public static func columns(font: GlyphColumnFont, character: String, capHeightMM: Double, origin: Point2D,
                               transform: ((Point2D) -> Point2D)? = nil) -> [SatinColumn]? {
        guard let glyph = font.glyphs[character] else { return nil }
        let scale = capHeightMM / capHeightUnits
        return glyph.columns.map { column in
            column.mapped { p in
                let placed = Point2D(p.x * scale + origin.x, p.y * scale + origin.y)
                return transform?(placed) ?? placed
            }
        }
    }
}
