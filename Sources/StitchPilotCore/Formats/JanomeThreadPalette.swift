import Foundation

/// Janome's JEF thread color table (indices 1-79; index 0 is reserved as a
/// "stop"/placeholder marker, not a real color). JEF files reference
/// colors by index into this fixed table, not by RGB value directly, so
/// writing a valid file requires mapping each object's thread color to its
/// nearest index here.
///
/// This is factual interoperability data (index -> RGB -> manufacturer
/// name for a commercial file format), not creative expression — the same
/// category as DST's byte layout — and is reproduced here for that reason,
/// cross-checked against pyembroidery's `EmbThreadJef.py` (MIT license)
/// per the same policy as `DSTFormat.swift`/`BrotherThreadPalette.swift`.
/// It is Janome's own thread numbering, included only to make JEF files
/// that reference these standard colors by index, the way the format
/// requires; it is not a substitute for a licensed manufacturer catalog.
public enum JanomeThreadPalette {
    public struct Entry: Sendable {
        public let index: Int
        public let rgb: RGBColor
        public let name: String
    }

    /// Index 0 has no entry (JEF reserves it for the reader's own "stop"
    /// sentinel); indices 1-79 follow.
    public static let entries: [Entry] = [
        Entry(index: 1, rgb: RGBColor(hex: 0x000000), name: "Black"),
        Entry(index: 2, rgb: RGBColor(hex: 0xFFFFFF), name: "White"),
        Entry(index: 3, rgb: RGBColor(hex: 0xFFFF17), name: "Yellow"),
        Entry(index: 4, rgb: RGBColor(hex: 0xFF6600), name: "Orange"),
        Entry(index: 5, rgb: RGBColor(hex: 0x2F5933), name: "Olive Green"),
        Entry(index: 6, rgb: RGBColor(hex: 0x237336), name: "Green"),
        Entry(index: 7, rgb: RGBColor(hex: 0x65C2C8), name: "Sky"),
        Entry(index: 8, rgb: RGBColor(hex: 0xAB5A96), name: "Purple"),
        Entry(index: 9, rgb: RGBColor(hex: 0xF669A0), name: "Pink"),
        Entry(index: 10, rgb: RGBColor(hex: 0xFF0000), name: "Red"),
        Entry(index: 11, rgb: RGBColor(hex: 0xB1704E), name: "Brown"),
        Entry(index: 12, rgb: RGBColor(hex: 0x0B2F84), name: "Blue"),
        Entry(index: 13, rgb: RGBColor(hex: 0xE4C35D), name: "Gold"),
        Entry(index: 14, rgb: RGBColor(hex: 0x481A05), name: "Dark Brown"),
        Entry(index: 15, rgb: RGBColor(hex: 0xAC9CC7), name: "Pale Violet"),
        Entry(index: 16, rgb: RGBColor(hex: 0xFCF294), name: "Pale Yellow"),
        Entry(index: 17, rgb: RGBColor(hex: 0xF999B7), name: "Pale Pink"),
        Entry(index: 18, rgb: RGBColor(hex: 0xFAB381), name: "Peach"),
        Entry(index: 19, rgb: RGBColor(hex: 0xC9A480), name: "Beige"),
        Entry(index: 20, rgb: RGBColor(hex: 0x970533), name: "Wine Red"),
        Entry(index: 21, rgb: RGBColor(hex: 0xA0B8CC), name: "Pale Sky"),
        Entry(index: 22, rgb: RGBColor(hex: 0x7FC21C), name: "Yellow Green"),
        Entry(index: 23, rgb: RGBColor(hex: 0xE5E5E5), name: "Silver Gray"),
        Entry(index: 24, rgb: RGBColor(hex: 0x889B9B), name: "Gray"),
        Entry(index: 25, rgb: RGBColor(hex: 0x98D6BD), name: "Pale Aqua"),
        Entry(index: 26, rgb: RGBColor(hex: 0xB2E1E3), name: "Baby Blue"),
        Entry(index: 27, rgb: RGBColor(hex: 0x368BA0), name: "Powder Blue"),
        Entry(index: 28, rgb: RGBColor(hex: 0x4F83AB), name: "Bright Blue"),
        Entry(index: 29, rgb: RGBColor(hex: 0x386A91), name: "Slate Blue"),
        Entry(index: 30, rgb: RGBColor(hex: 0x071650), name: "Navy Blue"),
        Entry(index: 31, rgb: RGBColor(hex: 0xF999A2), name: "Salmon Pink"),
        Entry(index: 32, rgb: RGBColor(hex: 0xF9676B), name: "Coral"),
        Entry(index: 33, rgb: RGBColor(hex: 0xE3311F), name: "Burnt Orange"),
        Entry(index: 34, rgb: RGBColor(hex: 0xE2A188), name: "Cinnamon"),
        Entry(index: 35, rgb: RGBColor(hex: 0xB59474), name: "Umber"),
        Entry(index: 36, rgb: RGBColor(hex: 0xE4CF99), name: "Blond"),
        Entry(index: 37, rgb: RGBColor(hex: 0xFFCB00), name: "Sunflower"),
        Entry(index: 38, rgb: RGBColor(hex: 0xE1ADD4), name: "Orchid Pink"),
        Entry(index: 39, rgb: RGBColor(hex: 0xC3007E), name: "Peony Purple"),
        Entry(index: 40, rgb: RGBColor(hex: 0x80004B), name: "Burgundy"),
        Entry(index: 41, rgb: RGBColor(hex: 0x540571), name: "Royal Purple"),
        Entry(index: 42, rgb: RGBColor(hex: 0xB10525), name: "Cardinal Red"),
        Entry(index: 43, rgb: RGBColor(hex: 0xCAE0C0), name: "Opal Green"),
        Entry(index: 44, rgb: RGBColor(hex: 0x899856), name: "Moss Green"),
        Entry(index: 45, rgb: RGBColor(hex: 0x5C941A), name: "Meadow Green"),
        Entry(index: 46, rgb: RGBColor(hex: 0x003114), name: "Dark Green"),
        Entry(index: 47, rgb: RGBColor(hex: 0x5DAE94), name: "Aquamarine"),
        Entry(index: 48, rgb: RGBColor(hex: 0x4CBF8F), name: "Emerald Green"),
        Entry(index: 49, rgb: RGBColor(hex: 0x007772), name: "Peacock Green"),
        Entry(index: 50, rgb: RGBColor(hex: 0x595B61), name: "Dark Gray"),
        Entry(index: 51, rgb: RGBColor(hex: 0xFFFFF2), name: "Ivory White"),
        Entry(index: 52, rgb: RGBColor(hex: 0xB15818), name: "Hazel"),
        Entry(index: 53, rgb: RGBColor(hex: 0xCB8A07), name: "Toast"),
        Entry(index: 54, rgb: RGBColor(hex: 0x986C80), name: "Salmon"),
        Entry(index: 55, rgb: RGBColor(hex: 0x98692D), name: "Cocoa Brown"),
        Entry(index: 56, rgb: RGBColor(hex: 0x4D3419), name: "Sienna"),
        Entry(index: 57, rgb: RGBColor(hex: 0x4C330B), name: "Sepia"),
        Entry(index: 58, rgb: RGBColor(hex: 0x33200A), name: "Dark Sepia"),
        Entry(index: 59, rgb: RGBColor(hex: 0x523A97), name: "Violet Blue"),
        Entry(index: 60, rgb: RGBColor(hex: 0x0D217E), name: "Blue Ink"),
        Entry(index: 61, rgb: RGBColor(hex: 0x1E77AC), name: "Sola Blue"),
        Entry(index: 62, rgb: RGBColor(hex: 0xB2DD53), name: "Green Dust"),
        Entry(index: 63, rgb: RGBColor(hex: 0xF33689), name: "Crimson"),
        Entry(index: 64, rgb: RGBColor(hex: 0xDE649E), name: "Floral Pink"),
        Entry(index: 65, rgb: RGBColor(hex: 0x984161), name: "Wine"),
        Entry(index: 66, rgb: RGBColor(hex: 0x4C5612), name: "Olive Drab"),
        Entry(index: 67, rgb: RGBColor(hex: 0x4C881F), name: "Meadow"),
        Entry(index: 68, rgb: RGBColor(hex: 0xE4DE79), name: "Mustard"),
        Entry(index: 69, rgb: RGBColor(hex: 0xCB8A1A), name: "Yellow Ocher"),
        Entry(index: 70, rgb: RGBColor(hex: 0xCBA21C), name: "Old Gold"),
        Entry(index: 71, rgb: RGBColor(hex: 0xFF9805), name: "Honey Dew"),
        Entry(index: 72, rgb: RGBColor(hex: 0xFCB257), name: "Tangerine"),
        Entry(index: 73, rgb: RGBColor(hex: 0xFFE505), name: "Canary Yellow"),
        Entry(index: 74, rgb: RGBColor(hex: 0xF0331F), name: "Vermilion"),
        Entry(index: 75, rgb: RGBColor(hex: 0x1A842D), name: "Bright Green"),
        Entry(index: 76, rgb: RGBColor(hex: 0x386CAE), name: "Ocean Blue"),
        Entry(index: 77, rgb: RGBColor(hex: 0xE3C4B4), name: "Beige Gray"),
        Entry(index: 78, rgb: RGBColor(hex: 0xE3AC81), name: "Bamboo"),
    ]

    /// The palette index (1-78) whose color is closest to `color` by
    /// Delta-E, optionally excluding one index (JEF's own writer avoids
    /// mapping two *different* requested colors to the same table entry
    /// back-to-back — with a fixed thread-number table, that would show
    /// the machine operator the same "insert thread #NN" prompt for two
    /// colors that were actually meant to be different threads).
    public static func nearestIndex(to color: RGBColor, excluding: Int? = nil) -> Int {
        let candidates = excluding == nil ? entries : entries.filter { $0.index != excluding }
        return candidates.min { RGBColor.deltaE(color, $0.rgb) < RGBColor.deltaE(color, $1.rgb) }?.index ?? 1 // fall back to Black
    }
}
