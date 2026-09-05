import Foundation

/// Generic (non-manufacturer) thread color library — spec §9: "Do not copy
/// proprietary databases if licensing prevents it. Provide generic RGB/LAB
/// thread matching regardless." Manufacturer catalogs (Madeira, Isacord,
/// Robison-Anton, etc.) are a separate, licensing-gated addition; this
/// palette is original, descriptively-named data, not sourced from or
/// matched to any specific manufacturer's numbering.
///
/// The matching *engine* (`nearestMatch`/`nearestMatches`, using
/// `RGBColor.deltaE`) is what spec §9 actually requires and is
/// manufacturer-agnostic: pass any `[ThreadColor]` palette — including a
/// user's "My Thread Inventory" subset (spec §9) — and it works the same way.
public enum ThreadLibrary {
    /// A representative ~40-color generic assortment spanning primaries,
    /// secondaries, tints/shades, and neutrals — enough spread that most
    /// artwork colors have a reasonably close match, without pretending to
    /// be a real manufacturer's actual catalog.
    public static let genericPalette: [ThreadColor] = [
        ThreadColor(name: "Generic Black", rgb: RGBColor(hex: 0x000000)),
        ThreadColor(name: "Generic White", rgb: RGBColor(hex: 0xFFFFFF)),
        ThreadColor(name: "Generic Light Gray", rgb: RGBColor(hex: 0xBFBFBF)),
        ThreadColor(name: "Generic Gray", rgb: RGBColor(hex: 0x808080)),
        ThreadColor(name: "Generic Charcoal", rgb: RGBColor(hex: 0x404040)),
        ThreadColor(name: "Generic Cream", rgb: RGBColor(hex: 0xF5F0DC)),
        ThreadColor(name: "Generic Tan", rgb: RGBColor(hex: 0xD2B48C)),
        ThreadColor(name: "Generic Brown", rgb: RGBColor(hex: 0x8B5A2B)),
        ThreadColor(name: "Generic Dark Brown", rgb: RGBColor(hex: 0x4A2C13)),

        ThreadColor(name: "Generic Red", rgb: RGBColor(hex: 0xD0202A)),
        ThreadColor(name: "Generic Dark Red", rgb: RGBColor(hex: 0x8B1420)),
        ThreadColor(name: "Generic Coral", rgb: RGBColor(hex: 0xFF6F5E)),
        ThreadColor(name: "Generic Orange", rgb: RGBColor(hex: 0xF07C1E)),
        ThreadColor(name: "Generic Gold", rgb: RGBColor(hex: 0xD4AF37)),
        ThreadColor(name: "Generic Yellow", rgb: RGBColor(hex: 0xFFD700)),
        ThreadColor(name: "Generic Pale Yellow", rgb: RGBColor(hex: 0xFCE883)),

        ThreadColor(name: "Generic Lime", rgb: RGBColor(hex: 0x9ACD32)),
        ThreadColor(name: "Generic Green", rgb: RGBColor(hex: 0x1E8A3C)),
        ThreadColor(name: "Generic Dark Green", rgb: RGBColor(hex: 0x0F5C26)),
        ThreadColor(name: "Generic Forest", rgb: RGBColor(hex: 0x1B4D2E)),
        ThreadColor(name: "Generic Mint", rgb: RGBColor(hex: 0x8FD9B6)),
        ThreadColor(name: "Generic Teal", rgb: RGBColor(hex: 0x148A8A)),

        ThreadColor(name: "Generic Sky Blue", rgb: RGBColor(hex: 0x5FB4E5)),
        ThreadColor(name: "Generic Blue", rgb: RGBColor(hex: 0x1A5CB0)),
        ThreadColor(name: "Generic Dark Blue", rgb: RGBColor(hex: 0x0E2F6B)),
        ThreadColor(name: "Generic Navy", rgb: RGBColor(hex: 0x0A1F44)),
        ThreadColor(name: "Generic Turquoise", rgb: RGBColor(hex: 0x30C0C0)),
        ThreadColor(name: "Generic Periwinkle", rgb: RGBColor(hex: 0x8A9EE0)),

        ThreadColor(name: "Generic Purple", rgb: RGBColor(hex: 0x7A3FA0)),
        ThreadColor(name: "Generic Dark Purple", rgb: RGBColor(hex: 0x4B2066)),
        ThreadColor(name: "Generic Lavender", rgb: RGBColor(hex: 0xC9A6E0)),
        ThreadColor(name: "Generic Magenta", rgb: RGBColor(hex: 0xC0217A)),
        ThreadColor(name: "Generic Pink", rgb: RGBColor(hex: 0xF2A0C0)),
        ThreadColor(name: "Generic Hot Pink", rgb: RGBColor(hex: 0xFF4FA0)),

        ThreadColor(name: "Generic Rust", rgb: RGBColor(hex: 0xB1521E)),
        ThreadColor(name: "Generic Olive", rgb: RGBColor(hex: 0x6B6B1E)),
        ThreadColor(name: "Generic Khaki", rgb: RGBColor(hex: 0xBFB27A)),
        ThreadColor(name: "Generic Beige", rgb: RGBColor(hex: 0xE6D9BE)),
        ThreadColor(name: "Generic Silver", rgb: RGBColor(hex: 0xC8C8CC)),
        ThreadColor(name: "Generic Steel Blue", rgb: RGBColor(hex: 0x4A6FA5)),
        ThreadColor(name: "Generic Burgundy", rgb: RGBColor(hex: 0x6E1B2E)),
        ThreadColor(name: "Generic Peach", rgb: RGBColor(hex: 0xF7C9A0)),
    ]

    /// The single closest palette entry by Delta-E, or `nil` for an empty palette.
    public static func nearestMatch(to color: RGBColor, in palette: [ThreadColor] = genericPalette) -> ThreadColor? {
        palette.min { RGBColor.deltaE(color, $0.rgb) < RGBColor.deltaE(color, $1.rgb) }
    }

    /// The closest `count` palette entries, nearest first — spec §9:
    /// "Present best match. Present alternative matches."
    public static func nearestMatches(to color: RGBColor, count: Int, in palette: [ThreadColor] = genericPalette) -> [ThreadColor] {
        Array(palette.sorted { RGBColor.deltaE(color, $0.rgb) < RGBColor.deltaE(color, $1.rgb) }.prefix(max(0, count)))
    }
}
