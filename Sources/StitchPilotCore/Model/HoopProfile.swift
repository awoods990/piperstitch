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
    ]

    /// Picks a sensible hoop for a design of this size, for a user who
    /// doesn't already know which hoop they'll use -- the smallest common
    /// hoop the design actually fits in both dimensions (smaller hoops
    /// hold fabric taut more evenly, so "smallest that fits" is the right
    /// default, not "largest available"). A design bigger than every
    /// common hoop falls back to the largest one, as the closest available
    /// answer, rather than nil or a hoop guaranteed not to fit anything.
    public static func recommended(forDesignWidthMM widthMM: Double, heightMM: Double) -> HoopProfile {
        let fitting = commonHoops.filter { $0.widthMM >= widthMM && $0.heightMM >= heightMM }
        if let smallestFitting = fitting.min(by: { $0.widthMM * $0.heightMM < $1.widthMM * $1.heightMM }) {
            return smallestFitting
        }
        return commonHoops.max(by: { $0.widthMM * $0.heightMM < $1.widthMM * $1.heightMM }) ?? commonHoops[0]
    }
}
