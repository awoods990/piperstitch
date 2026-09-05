import Foundation

public struct RGBColor: Codable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }

    public init(hex: UInt32) {
        r = UInt8((hex >> 16) & 0xFF)
        g = UInt8((hex >> 8) & 0xFF)
        b = UInt8(hex & 0xFF)
    }
}

/// A thread color, optionally tied to a manufacturer catalog entry.
/// See THREAD LIBRARY (spec §9): matching is done in CIE LAB / Delta-E,
/// but the neutral document only ever stores the resolved RGB + optional
/// catalog reference — the matching algorithm lives in the engine, not the model.
public struct ThreadColor: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var brand: String?
    public var catalogNumber: String?
    public var rgb: RGBColor

    public init(id: UUID = UUID(), name: String, brand: String? = nil, catalogNumber: String? = nil, rgb: RGBColor) {
        self.id = id
        self.name = name
        self.brand = brand
        self.catalogNumber = catalogNumber
        self.rgb = rgb
    }

    public static func generic(_ rgb: RGBColor, name: String = "Custom Color") -> ThreadColor {
        ThreadColor(name: name, brand: nil, catalogNumber: nil, rgb: rgb)
    }
}
