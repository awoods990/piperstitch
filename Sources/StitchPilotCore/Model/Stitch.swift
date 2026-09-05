import Foundation

/// One instruction in the flat manufacturing-level stitch sequence — what
/// the machine actually does. This is the "how to sew it" representation
/// produced by the engine from `EmbroideryObject`s; it is derived output,
/// never the source of truth (see ARCHITECTURE.md "Object model vs. stitch
/// model").
public enum StitchCommand: Codable, Hashable, Sendable {
    /// Move the needle down and sew a stitch to this point (design mm coordinates).
    case stitch(Point2D)
    /// Move to this point without sewing (needle up).
    case jump(Point2D)
    /// Switch to the next thread color in sequence.
    case colorChange
    /// Cut the thread.
    case trim
    /// Machine stop (e.g. for a manual thread/appliqué change).
    case stop
    /// End of design.
    case end

    public var point: Point2D? {
        switch self {
        case .stitch(let p), .jump(let p): return p
        default: return nil
        }
    }

    public var isMovement: Bool {
        switch self {
        case .stitch, .jump: return true
        default: return false
        }
    }
}

/// A flat, ordered stitch list — the neutral "manufacturing output" shared
/// by every machine-format writer. Produced by flattening a `StitchDocument`
/// through the auto-digitize pipeline.
public struct StitchPlan: Codable, Sendable {
    public var commands: [StitchCommand]

    public init(commands: [StitchCommand] = []) {
        self.commands = commands
    }

    public var stitchCount: Int { commands.reduce(0) { if case .stitch = $1 { return $0 + 1 } else { return $0 } } }
    public var colorChangeCount: Int { commands.reduce(0) { if case .colorChange = $1 { return $0 + 1 } else { return $0 } } }
    public var trimCount: Int { commands.reduce(0) { if case .trim = $1 { return $0 + 1 } else { return $0 } } }

    public var boundingBox: BoundingBox {
        BoundingBox(points: commands.compactMap { $0.point })
    }

    /// Length, in mm, of every needle-penetrating stitch segment (excludes jumps).
    public var totalStitchLength: Double {
        var total = 0.0
        var last: Point2D?
        for c in commands {
            switch c {
            case .stitch(let p):
                if let l = last { total += l.distance(to: p) }
                last = p
            case .jump(let p):
                last = p
            case .colorChange, .trim, .stop, .end:
                break
            }
        }
        return total
    }

    /// Longest single needle-penetrating stitch segment, in mm.
    public func maxStitchLength() -> Double {
        var maxLen = 0.0
        var last: Point2D?
        for c in commands {
            switch c {
            case .stitch(let p):
                if let l = last { maxLen = max(maxLen, l.distance(to: p)) }
                last = p
            case .jump(let p):
                last = p
            case .colorChange, .trim, .stop, .end:
                break
            }
        }
        return maxLen
    }
}
