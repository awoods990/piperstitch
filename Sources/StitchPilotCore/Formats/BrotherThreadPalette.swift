import Foundation

/// Brother's 64-entry PEC thread color palette (indices 1-64; index 0 is
/// reserved/unused in the format). PES/PEC files reference colors by index
/// into this fixed table, not by RGB value directly, so writing a valid
/// file requires mapping each object's thread color to its nearest index
/// here.
///
/// This is factual interoperability data (index -> RGB -> manufacturer name
/// for a commercial file format), not creative expression — the same
/// category as DST's byte layout — and is reproduced here for that reason,
/// cross-checked against pyembroidery's `EmbThreadPec.py` (MIT license) per
/// the same policy as `DSTFormat.swift`. It is Brother's own thread
/// numbering, included only to make PES/PEC files that reference these
/// standard colors by index, the way the format requires; it is not a
/// substitute for a licensed manufacturer catalog (spec §9's actual thread
/// libraries — Madeira, Isacord, etc. — remain a separate, licensing-gated
/// addition).
public enum BrotherThreadPalette {
    public struct Entry: Sendable {
        public let index: Int
        public let rgb: RGBColor
        public let name: String
    }

    /// Index 0 has no entry (Brother reserves it); indices 1-64 follow.
    public static let entries: [Entry] = [
        Entry(index: 1, rgb: RGBColor(r: 14, g: 31, b: 124), name: "Prussian Blue"),
        Entry(index: 2, rgb: RGBColor(r: 10, g: 85, b: 163), name: "Blue"),
        Entry(index: 3, rgb: RGBColor(r: 0, g: 135, b: 119), name: "Teal Green"),
        Entry(index: 4, rgb: RGBColor(r: 75, g: 107, b: 175), name: "Cornflower Blue"),
        Entry(index: 5, rgb: RGBColor(r: 237, g: 23, b: 31), name: "Red"),
        Entry(index: 6, rgb: RGBColor(r: 209, g: 92, b: 0), name: "Reddish Brown"),
        Entry(index: 7, rgb: RGBColor(r: 145, g: 54, b: 151), name: "Magenta"),
        Entry(index: 8, rgb: RGBColor(r: 228, g: 154, b: 203), name: "Light Lilac"),
        Entry(index: 9, rgb: RGBColor(r: 145, g: 95, b: 172), name: "Lilac"),
        Entry(index: 10, rgb: RGBColor(r: 158, g: 214, b: 125), name: "Mint Green"),
        Entry(index: 11, rgb: RGBColor(r: 232, g: 169, b: 0), name: "Deep Gold"),
        Entry(index: 12, rgb: RGBColor(r: 254, g: 186, b: 53), name: "Orange"),
        Entry(index: 13, rgb: RGBColor(r: 255, g: 255, b: 0), name: "Yellow"),
        Entry(index: 14, rgb: RGBColor(r: 112, g: 188, b: 31), name: "Lime Green"),
        Entry(index: 15, rgb: RGBColor(r: 186, g: 152, b: 0), name: "Brass"),
        Entry(index: 16, rgb: RGBColor(r: 168, g: 168, b: 168), name: "Silver"),
        Entry(index: 17, rgb: RGBColor(r: 125, g: 111, b: 0), name: "Russet Brown"),
        Entry(index: 18, rgb: RGBColor(r: 255, g: 255, b: 179), name: "Cream Brown"),
        Entry(index: 19, rgb: RGBColor(r: 79, g: 85, b: 86), name: "Pewter"),
        Entry(index: 20, rgb: RGBColor(r: 0, g: 0, b: 0), name: "Black"),
        Entry(index: 21, rgb: RGBColor(r: 11, g: 61, b: 145), name: "Ultramarine"),
        Entry(index: 22, rgb: RGBColor(r: 119, g: 1, b: 118), name: "Royal Purple"),
        Entry(index: 23, rgb: RGBColor(r: 41, g: 49, b: 51), name: "Dark Gray"),
        Entry(index: 24, rgb: RGBColor(r: 42, g: 19, b: 1), name: "Dark Brown"),
        Entry(index: 25, rgb: RGBColor(r: 246, g: 74, b: 138), name: "Deep Rose"),
        Entry(index: 26, rgb: RGBColor(r: 178, g: 118, b: 36), name: "Light Brown"),
        Entry(index: 27, rgb: RGBColor(r: 252, g: 187, b: 197), name: "Salmon Pink"),
        Entry(index: 28, rgb: RGBColor(r: 254, g: 55, b: 15), name: "Vermilion"),
        Entry(index: 29, rgb: RGBColor(r: 240, g: 240, b: 240), name: "White"),
        Entry(index: 30, rgb: RGBColor(r: 106, g: 28, b: 138), name: "Violet"),
        Entry(index: 31, rgb: RGBColor(r: 168, g: 221, b: 196), name: "Seacrest"),
        Entry(index: 32, rgb: RGBColor(r: 37, g: 132, b: 187), name: "Sky Blue"),
        Entry(index: 33, rgb: RGBColor(r: 254, g: 179, b: 67), name: "Pumpkin"),
        Entry(index: 34, rgb: RGBColor(r: 255, g: 243, b: 107), name: "Cream Yellow"),
        Entry(index: 35, rgb: RGBColor(r: 208, g: 166, b: 96), name: "Khaki"),
        Entry(index: 36, rgb: RGBColor(r: 209, g: 84, b: 0), name: "Clay Brown"),
        Entry(index: 37, rgb: RGBColor(r: 102, g: 186, b: 73), name: "Leaf Green"),
        Entry(index: 38, rgb: RGBColor(r: 19, g: 74, b: 70), name: "Peacock Blue"),
        Entry(index: 39, rgb: RGBColor(r: 135, g: 135, b: 135), name: "Gray"),
        Entry(index: 40, rgb: RGBColor(r: 216, g: 204, b: 198), name: "Warm Gray"),
        Entry(index: 41, rgb: RGBColor(r: 67, g: 86, b: 7), name: "Dark Olive"),
        Entry(index: 42, rgb: RGBColor(r: 253, g: 217, b: 222), name: "Flesh Pink"),
        Entry(index: 43, rgb: RGBColor(r: 249, g: 147, b: 188), name: "Pink"),
        Entry(index: 44, rgb: RGBColor(r: 0, g: 56, b: 34), name: "Deep Green"),
        Entry(index: 45, rgb: RGBColor(r: 178, g: 175, b: 212), name: "Lavender"),
        Entry(index: 46, rgb: RGBColor(r: 104, g: 106, b: 176), name: "Wisteria Violet"),
        Entry(index: 47, rgb: RGBColor(r: 239, g: 227, b: 185), name: "Beige"),
        Entry(index: 48, rgb: RGBColor(r: 247, g: 56, b: 102), name: "Carmine"),
        Entry(index: 49, rgb: RGBColor(r: 181, g: 75, b: 100), name: "Amber Red"),
        Entry(index: 50, rgb: RGBColor(r: 19, g: 43, b: 26), name: "Olive Green"),
        Entry(index: 51, rgb: RGBColor(r: 199, g: 1, b: 86), name: "Dark Fuchsia"),
        Entry(index: 52, rgb: RGBColor(r: 254, g: 158, b: 50), name: "Tangerine"),
        Entry(index: 53, rgb: RGBColor(r: 168, g: 222, b: 235), name: "Light Blue"),
        Entry(index: 54, rgb: RGBColor(r: 0, g: 103, b: 62), name: "Emerald Green"),
        Entry(index: 55, rgb: RGBColor(r: 78, g: 41, b: 144), name: "Purple"),
        Entry(index: 56, rgb: RGBColor(r: 47, g: 126, b: 32), name: "Moss Green"),
        Entry(index: 57, rgb: RGBColor(r: 255, g: 204, b: 204), name: "Flesh Pink"),
        Entry(index: 58, rgb: RGBColor(r: 255, g: 217, b: 17), name: "Harvest Gold"),
        Entry(index: 59, rgb: RGBColor(r: 9, g: 91, b: 166), name: "Electric Blue"),
        Entry(index: 60, rgb: RGBColor(r: 240, g: 249, b: 112), name: "Lemon Yellow"),
        Entry(index: 61, rgb: RGBColor(r: 227, g: 243, b: 91), name: "Fresh Green"),
        Entry(index: 62, rgb: RGBColor(r: 255, g: 153, b: 0), name: "Orange"),
        Entry(index: 63, rgb: RGBColor(r: 255, g: 240, b: 141), name: "Cream Yellow"),
        Entry(index: 64, rgb: RGBColor(r: 255, g: 200, b: 200), name: "Applique"),
    ]

    /// The palette index (1-64) whose color is closest to `color` by Delta-E.
    public static func nearestIndex(to color: RGBColor) -> Int {
        entries.min { RGBColor.deltaE(color, $0.rgb) < RGBColor.deltaE(color, $1.rgb) }?.index ?? 20 // fall back to Black
    }
}
