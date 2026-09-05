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
}
