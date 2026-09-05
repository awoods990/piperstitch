import Foundation

/// A point in the design's physical coordinate space, in millimeters.
/// Millimeters (not pixels, not machine units) are the canonical unit
/// throughout the internal model — see ARCHITECTURE.md "Units" section.
public struct Point2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2D(0, 0)

    public func distance(to other: Point2D) -> Double {
        (self - other).length
    }

    public var length: Double { (x * x + y * y).squareRoot() }

    public static func + (a: Point2D, b: Point2D) -> Point2D { Point2D(a.x + b.x, a.y + b.y) }
    public static func - (a: Point2D, b: Point2D) -> Point2D { Point2D(a.x - b.x, a.y - b.y) }
    public static func * (a: Point2D, s: Double) -> Point2D { Point2D(a.x * s, a.y * s) }
}

/// A single open or closed polyline, in millimeters, in object-local space.
/// Curves from source vector artwork are flattened to polylines at import
/// time (with a fine tolerance) rather than rasterized — geometry stays
/// vector-precision, just represented piecewise-linearly so every downstream
/// stitch algorithm (resampling, offsetting, satin-rail generation) can work
/// with plain line segments instead of re-deriving curve math everywhere.
public struct SubPath: Codable, Hashable, Sendable {
    public var points: [Point2D]
    public var closed: Bool

    public init(points: [Point2D], closed: Bool) {
        self.points = points
        self.closed = closed
    }

    public var length: Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count { total += points[i - 1].distance(to: points[i]) }
        if closed, let first = points.first, let last = points.last {
            total += last.distance(to: first)
        }
        return total
    }

    public var boundingBox: BoundingBox {
        BoundingBox(points: points)
    }
}

/// The geometric shape of one embroidery object: one or more sub-paths
/// (e.g. a letter "O" is an outer subpath plus an inner hole subpath).
public struct VectorShape: Codable, Hashable, Sendable {
    public var subPaths: [SubPath]

    public init(subPaths: [SubPath]) {
        self.subPaths = subPaths
    }

    public var boundingBox: BoundingBox {
        var box = BoundingBox.empty
        for sp in subPaths { box = box.union(sp.boundingBox) }
        return box
    }
}

public struct BoundingBox: Codable, Hashable, Sendable {
    public var minX, minY, maxX, maxY: Double

    public static let empty = BoundingBox(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    public init(points: [Point2D]) {
        self = points.reduce(BoundingBox.empty) { box, p in
            BoundingBox(minX: min(box.minX, p.x), minY: min(box.minY, p.y),
                        maxX: max(box.maxX, p.x), maxY: max(box.maxY, p.y))
        }
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var isEmpty: Bool { minX > maxX || minY > maxY }

    public func union(_ other: BoundingBox) -> BoundingBox {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return BoundingBox(minX: min(minX, other.minX), minY: min(minY, other.minY),
                            maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
    }
}
