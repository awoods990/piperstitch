import Foundation

/// Standard finished-size shortcuts for the placement types a garment
/// decorator digitizes for every day (spec: let the user pick a standard
/// project size instead of typing exact millimeters for a left chest logo
/// every single time). These are commonly-cited industry starting points,
/// not a guarantee for any specific garment -- selecting one just fills in
/// the same width/height fields manual entry does, so the user can still
/// nudge them for a particular shirt or hat afterward.
public struct GarmentSizePreset: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var widthMM: Double
    public var heightMM: Double

    public init(name: String, widthMM: Double, heightMM: Double) {
        self.name = name; self.widthMM = widthMM; self.heightMM = heightMM
    }

    public static let standardPresets: [GarmentSizePreset] = [
        GarmentSizePreset(name: "Cap / Hat Front", widthMM: 114.3, heightMM: 50.8),      // 4.5" x 2"
        GarmentSizePreset(name: "Left Chest", widthMM: 101.6, heightMM: 101.6),          // 4" x 4"
        GarmentSizePreset(name: "Polo Shirt (Left Chest)", widthMM: 88.9, heightMM: 88.9), // 3.5" x 3.5"
        GarmentSizePreset(name: "Youth Left Chest", widthMM: 63.5, heightMM: 63.5),      // 2.5" x 2.5"
        GarmentSizePreset(name: "Sleeve", widthMM: 76.2, heightMM: 76.2),                // 3" x 3"
        GarmentSizePreset(name: "Full Back", widthMM: 304.8, heightMM: 355.6),           // 12" x 14"
    ]
}
