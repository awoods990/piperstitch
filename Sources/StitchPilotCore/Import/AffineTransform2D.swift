import Foundation

/// A 2D affine transform: [a c e; b d f; 0 0 1], matching SVG's `matrix()` convention.
public struct AffineTransform2D: Sendable {
    public var a, b, c, d, e, f: Double

    public static let identity = AffineTransform2D(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    public static func translation(_ tx: Double, _ ty: Double) -> AffineTransform2D {
        AffineTransform2D(a: 1, b: 0, c: 0, d: 1, e: tx, f: ty)
    }

    public static func scale(_ sx: Double, _ sy: Double) -> AffineTransform2D {
        AffineTransform2D(a: sx, b: 0, c: 0, d: sy, e: 0, f: 0)
    }

    public static func rotation(degrees: Double) -> AffineTransform2D {
        let r = degrees * .pi / 180
        return AffineTransform2D(a: cos(r), b: sin(r), c: -sin(r), d: cos(r), e: 0, f: 0)
    }

    public func concatenating(_ other: AffineTransform2D) -> AffineTransform2D {
        // self applied first, then other: other * self
        AffineTransform2D(
            a: other.a * a + other.c * b,
            b: other.b * a + other.d * b,
            c: other.a * c + other.c * d,
            d: other.b * c + other.d * d,
            e: other.a * e + other.c * f + other.e,
            f: other.b * e + other.d * f + other.f
        )
    }

    public func apply(_ p: Point2D) -> Point2D {
        Point2D(a * p.x + c * p.y + e, b * p.x + d * p.y + f)
    }

    /// Approximate uniform scale factor, used to pick curve-flattening resolution in output units.
    public var approximateScale: Double {
        ((a * a + b * b).squareRoot() + (c * c + d * d).squareRoot()) / 2
    }
}
