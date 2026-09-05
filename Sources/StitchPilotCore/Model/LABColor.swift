import Foundation

/// CIE L*a*b* color — perceptually-uniform color space used for thread
/// matching and color quantization (spec §8/§9: "convert image colors into
/// perceptual color space such as CIE LAB" before comparing them, since
/// Euclidean distance in raw RGB doesn't track how different two colors
/// actually *look*).
public struct LABColor: Hashable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l; self.a = a; self.b = b
    }
}

public extension RGBColor {
    /// sRGB -> linear RGB -> CIE XYZ (D65) -> CIE L*a*b*.
    var lab: LABColor {
        func toLinear(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let rl = toLinear(r), gl = toLinear(g), bl = toLinear(b)

        // sRGB -> XYZ (D65) matrix.
        let x = rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375
        let y = rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750
        let z = rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041

        // D65 reference white.
        let xn = 0.95047, yn = 1.0, zn = 1.08883
        func f(_ t: Double) -> Double {
            let delta = 6.0 / 29.0
            return t > delta * delta * delta ? cbrt(t) : t / (3 * delta * delta) + 4.0 / 29.0
        }
        let fx = f(x / xn), fy = f(y / yn), fz = f(z / zn)

        return LABColor(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    /// CIE76 Delta-E: Euclidean distance in L*a*b* space. Simpler than
    /// CIE94/CIEDE2000 and slightly less perceptually accurate for some hues,
    /// but adequate for thread-matching and color-quantization ranking where
    /// what matters is relative ordering of candidates, not an exact
    /// psychophysical distance; documented here so upgrading to CIEDE2000
    /// later is a localized change.
    static func deltaE(_ a: RGBColor, _ b: RGBColor) -> Double {
        let la = a.lab, lb = b.lab
        let dl = la.l - lb.l, da = la.a - lb.a, db = la.b - lb.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}
