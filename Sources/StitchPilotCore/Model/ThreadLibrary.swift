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

    /// The single closest palette entry by Delta-E, or `nil` for an empty
    /// palette -- always searches *exactly* `palette` and nothing else,
    /// deliberately, even when the result is a poor match. A user's own
    /// curated "My Thread Inventory" (spec §9) is a real, common case this
    /// needs to keep respecting exactly: the whole point of restricting to
    /// an inventory is "match against what I actually own," and silently
    /// suggesting a thread the user doesn't have, just because it looks
    /// closer on paper, would defeat that. `bestMatch` below is the
    /// opt-in sibling for callers that specifically want "find the best
    /// available answer, widening the search if this palette's own answer
    /// is poor" -- automatic color-matching during raster import, where
    /// there's no "the user meant to restrict to exactly this" intent to
    /// respect, is the case that actually wants it.
    public static func nearestMatch(to color: RGBColor, in palette: [ThreadColor] = genericPalette) -> ThreadColor? {
        nearestWithDeltaE(color, in: palette)?.color
    }

    /// The closest `count` palette entries, nearest first — spec §9:
    /// "Present best match. Present alternative matches."
    public static func nearestMatches(to color: RGBColor, count: Int, in palette: [ThreadColor] = genericPalette) -> [ThreadColor] {
        Array(palette.sorted { RGBColor.deltaE(color, $0.rgb) < RGBColor.deltaE(color, $1.rgb) }.prefix(max(0, count)))
    }

    /// How good a thread match actually is, in CIE76 Delta-E terms spec §9
    /// never quantifies on its own ("Present best match" implies knowing
    /// whether it's actually close, not just which candidate happens to
    /// rank first). Roughly: `excellent` reads as visually indistinguishable
    /// once sewn; `good` is an ordinary, unremarkable match; `acceptable` is
    /// noticeably different but still the same general color; `poor` means
    /// the "nearest" available entry may not even be the same color family
    /// — exactly what a sparse or narrowly-curated custom thread library
    /// can produce for a source color it simply has nothing close to.
    public enum MatchQuality: Int, Comparable, Sendable {
        case excellent, good, acceptable, poor

        public static func < (lhs: MatchQuality, rhs: MatchQuality) -> Bool { lhs.rawValue < rhs.rawValue }

        static func forDeltaE(_ d: Double) -> MatchQuality {
            if d <= 5 { return .excellent }
            if d <= 12 { return .good }
            if d <= 20 { return .acceptable }
            return .poor
        }
    }

    /// A thread match with the confidence information `nearestMatch` alone
    /// discards — spec §9's own reasoning for wanting "present alternative
    /// matches" only makes sense if the caller can tell a great match from
    /// a desperate one in the first place.
    public struct ThreadMatch: Sendable {
        public var color: ThreadColor
        public var deltaE: Double
        public var quality: MatchQuality
        /// `true` when this match came from `genericPalette` rather than
        /// the palette the caller actually passed in — that palette's own
        /// best answer was poor enough that the broader generic palette
        /// produced a genuinely closer one instead.
        public var isFallback: Bool
    }

    /// The Delta-E above which a match is poor enough that checking the
    /// broader generic palette too (when the caller's own palette isn't
    /// already the generic one) is worth doing, rather than confidently
    /// returning something that may not even look like the source color.
    private static let fallbackThresholdDeltaE = 20.0

    /// `nearestMatch`'s richer sibling: the best match in `palette`, with
    /// quality information, and an automatic widen-the-search fallback to
    /// `genericPalette` when `palette`'s own best answer is poor. A
    /// sparse or narrowly-curated custom/manufacturer thread library
    /// (a user's own "My Thread Inventory," or one manufacturer's catalog
    /// with only a few colors actually added to it) can easily have
    /// nothing close to some color that's genuinely in the artwork —
    /// `nearestMatch` alone still confidently returns whatever's nearest
    /// *within that palette*, even a strikingly wrong-looking color, with
    /// no signal anywhere that the match was actually bad. This never
    /// invents a match closer than what's genuinely available in either
    /// palette — it only widens the search once the caller's own answer
    /// is bad enough that a different, better answer from the broader
    /// palette is more useful than confidently returning a poor one, and
    /// always reports whether that happened via `isFallback`.
    public static func bestMatch(to color: RGBColor, in palette: [ThreadColor] = genericPalette) -> ThreadMatch? {
        let primary = nearestWithDeltaE(color, in: palette)
        guard let primary else {
            guard let fallback = nearestWithDeltaE(color, in: genericPalette) else { return nil }
            return ThreadMatch(color: fallback.color, deltaE: fallback.deltaE, quality: .forDeltaE(fallback.deltaE), isFallback: true)
        }
        guard primary.deltaE > fallbackThresholdDeltaE,
              let fallback = nearestWithDeltaE(color, in: genericPalette),
              fallback.deltaE < primary.deltaE else {
            return ThreadMatch(color: primary.color, deltaE: primary.deltaE, quality: .forDeltaE(primary.deltaE), isFallback: false)
        }
        return ThreadMatch(color: fallback.color, deltaE: fallback.deltaE, quality: .forDeltaE(fallback.deltaE), isFallback: true)
    }

    private static func nearestWithDeltaE(_ color: RGBColor, in palette: [ThreadColor]) -> (color: ThreadColor, deltaE: Double)? {
        guard !palette.isEmpty else { return nil }
        var best: ThreadColor?
        var bestDist = Double.infinity
        for candidate in palette {
            let d = RGBColor.deltaE(color, candidate.rgb)
            if d < bestDist { bestDist = d; best = candidate }
        }
        guard let best else { return nil }
        return (best, bestDist)
    }
}
