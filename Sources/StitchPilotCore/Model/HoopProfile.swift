import Foundation

/// A hoop's sewing field size — spec §36: "show hoop visually, enforce
/// safety margin, alert if design exceeds sewing area." Sizes here are
/// generic, commonly-used dimensions (public physical facts about common
/// hoop hardware, not tied to any specific manufacturer's proprietary
/// data) — machine-specific hoop profiles are a Phase 5 addition alongside
/// machine profiles generally.
public struct HoopProfile: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var widthMM: Double
    public var heightMM: Double

    public init(name: String, widthMM: Double, heightMM: Double) {
        self.name = name; self.widthMM = widthMM; self.heightMM = heightMM
    }

    public static let commonHoops: [HoopProfile] = [
        HoopProfile(name: "4\" × 4\"", widthMM: 100, heightMM: 100),
        HoopProfile(name: "5\" × 7\"", widthMM: 130, heightMM: 180),
        HoopProfile(name: "6\" × 10\"", widthMM: 160, heightMM: 260),
        HoopProfile(name: "8\" × 8\"", widthMM: 200, heightMM: 200),
        HoopProfile(name: "9\" × 9\"", widthMM: 240, heightMM: 240),
        HoopProfile(name: "10\" × 10\"", widthMM: 260, heightMM: 260),
        // Appended after the standard sizes above rather than inserted --
        // AppState keeps its default hoop as a fixed index into this array,
        // so a new entry always belongs at the end, never in the middle.
        //
        // Cap/hat hoop: the narrow curved frame used for embroidering
        // caps, common across home and commercial multi-needle machines
        // (e.g. Brother's cap frames) at roughly this sewing area.
        HoopProfile(name: "Cap/Hat Hoop", widthMM: 130, heightMM: 60),
        // Mighty Hoop (HoopMaster / Midwest Products): magnet-clamped
        // hoops named by their NOMINAL size. The usable sewing field is
        // smaller -- HoopMaster's own guidance is a design "approximately
        // 1 inch smaller than the size of your hoop", and the fields they
        // publish per size bear that out (4.25" -> ~3.27", 5.5" -> ~4.8",
        // 4.25 x 13 -> ~3.5 x 12.25, 9 x 4.25 -> ~8 x 3.5). Sizes below use
        // the published field where one is given and nominal minus 1"
        // otherwise. These two were previously the generic "Magic Hoop"
        // entries in the same positions.
        HoopProfile(name: "Mighty Hoop 5.5\" × 5.5\"", widthMM: 122, heightMM: 122),
        HoopProfile(name: "Mighty Hoop 8\" × 13\"", widthMM: 184, heightMM: 292),
        HoopProfile(name: "Mighty Hoop 4.25\" × 4.25\"", widthMM: 83, heightMM: 83),
        HoopProfile(name: "Mighty Hoop 6.5\" × 6.5\"", widthMM: 140, heightMM: 140),
        HoopProfile(name: "Mighty Hoop 7.25\" × 7.25\"", widthMM: 159, heightMM: 159),
        HoopProfile(name: "Mighty Hoop 9\" × 3\" (sleeve)", widthMM: 203, heightMM: 51),
        HoopProfile(name: "Mighty Hoop 9\" × 4.25\"", widthMM: 205, heightMM: 89),
        HoopProfile(name: "Mighty Hoop 9\" × 5\"", widthMM: 203, heightMM: 102),
        HoopProfile(name: "Mighty Hoop 9\" × 6\"", widthMM: 203, heightMM: 127),
        HoopProfile(name: "Mighty Hoop 4.25\" × 13\" (sleeve)", widthMM: 89, heightMM: 311),
        HoopProfile(name: "Mighty Hoop 12\" × 3.25\" (sleeve)", widthMM: 279, heightMM: 57),
        HoopProfile(name: "Mighty Hoop 8\" × 9\"", widthMM: 178, heightMM: 203),
        HoopProfile(name: "Mighty Hoop 10\" × 10\"", widthMM: 229, heightMM: 229),
        HoopProfile(name: "Mighty Hoop 11\" × 13\"", widthMM: 254, heightMM: 305),
        HoopProfile(name: "Mighty Hoop 12\" × 15\"", widthMM: 279, heightMM: 356),
        HoopProfile(name: "Mighty Hoop 13\" × 16\"", widthMM: 305, heightMM: 381),
        // Durkee EZ Frames: rigid aluminium frames named by their SEWING
        // FIELD, not the frame -- Durkee lists the "5 x 5" as a 5" x 5"
        // sewing field inside a 6" x 6" frame -- so these are the listed
        // sizes converted directly to mm. Width first, as Durkee lists
        // them (they sell both a 4 x 12 and a 12 x 8, so orientation is
        // part of the product).
        HoopProfile(name: "Durkee EZ Frame Cap 5\" × 4\"", widthMM: 127, heightMM: 102),
        HoopProfile(name: "Durkee EZ Frame 1.5\" × 4\"", widthMM: 38, heightMM: 102),
        HoopProfile(name: "Durkee EZ Frame 2\" × 4\"", widthMM: 51, heightMM: 102),
        HoopProfile(name: "Durkee EZ Frame 2.5\" × 4\"", widthMM: 64, heightMM: 102),
        HoopProfile(name: "Durkee EZ Frame 3\" × 4\"", widthMM: 76, heightMM: 102),
        HoopProfile(name: "Durkee EZ Frame 3\" × 8\"", widthMM: 76, heightMM: 203),
        HoopProfile(name: "Durkee EZ Frame 4\" × 4\"", widthMM: 102, heightMM: 102),
        HoopProfile(name: "Durkee EZ Frame 4\" × 12\"", widthMM: 102, heightMM: 305),
        HoopProfile(name: "Durkee EZ Frame 5\" × 4\"", widthMM: 127, heightMM: 102),
        HoopProfile(name: "Durkee EZ Frame 5\" × 5\"", widthMM: 127, heightMM: 127),
        HoopProfile(name: "Durkee EZ Frame 5\" × 8\"", widthMM: 127, heightMM: 203),
        HoopProfile(name: "Durkee EZ Frame 6\" × 6\"", widthMM: 152, heightMM: 152),
        HoopProfile(name: "Durkee EZ Frame 7\" × 5\"", widthMM: 178, heightMM: 127),
        HoopProfile(name: "Durkee EZ Frame 7\" × 7\"", widthMM: 178, heightMM: 178),
        HoopProfile(name: "Durkee EZ Frame 8\" × 8\"", widthMM: 203, heightMM: 203),
        HoopProfile(name: "Durkee EZ Frame 9\" × 9\"", widthMM: 229, heightMM: 229),
        HoopProfile(name: "Durkee EZ Frame 12\" × 4\"", widthMM: 305, heightMM: 102),
        HoopProfile(name: "Durkee EZ Frame 12\" × 8\"", widthMM: 305, heightMM: 203),
    ]

    /// Picks a sensible hoop for a design of this size, for a user who
    /// doesn't already know which hoop they'll use -- the smallest common
    /// hoop the design actually fits in both dimensions (smaller hoops
    /// hold fabric taut more evenly, so "smallest that fits" is the right
    /// default, not "largest available"). A design bigger than every
    /// common hoop falls back to the largest one, as the closest available
    /// answer, rather than nil or a hoop guaranteed not to fit anything.
    ///
    /// Prefers the generic sizes, which nearly every machine has, over a
    /// brand-specific frame (`isBrandSpecific`) the user may not own -- a
    /// branded one is only recommended when no generic hoop fits at all.
    public static func recommended(forDesignWidthMM widthMM: Double, heightMM: Double) -> HoopProfile {
        let fitting = commonHoops.filter { $0.widthMM >= widthMM && $0.heightMM >= heightMM }
        let byArea: (HoopProfile, HoopProfile) -> Bool = { $0.widthMM * $0.heightMM < $1.widthMM * $1.heightMM }
        if let smallestGeneric = fitting.filter({ !$0.isBrandSpecific }).min(by: byArea) {
            return smallestGeneric
        }
        if let smallestFitting = fitting.min(by: byArea) {
            return smallestFitting
        }
        return commonHoops.max(by: byArea) ?? commonHoops[0]
    }

    /// A named manufacturer's frame line (Mighty Hoop, Durkee EZ Frame)
    /// rather than a generic size -- listed for users who own one, never
    /// recommended unprompted.
    public var isBrandSpecific: Bool {
        name.hasPrefix("Mighty Hoop") || name.hasPrefix("Durkee")
    }
}
