import Foundation

/// Melco EXP reader/writer.
///
/// EXP has no file header at all — it's a flat stream of stitch/jump
/// records plus a small set of escape-coded control records, in the same
/// 0.1mm units DST uses. The byte layout was cross-checked against
/// pyembroidery's `ExpReader.py` / `ExpWriter.py` (MIT license, see
/// FORMATS.md) rather than reconstructed from memory, matching the same
/// correctness approach `DSTFormat`/`PESFormat` use — getting this wrong
/// produces a file that opens but sews incorrectly (spec §59).
///
/// Coordinate convention: same as DST — StitchPilot's internal `Point2D`
/// (Y-down) already matches EXP's on-disk Y-down convention. Verified via
/// pyembroidery's writer, which negates Y going from its own Y-up internal
/// representation to EXP bytes (`delta_y = -dy & 0xFF`); since our own
/// internal representation is already Y-down, the equivalent negation
/// cancels out and no sign flip is needed here (same reasoning as
/// `DSTFormat`'s "Coordinate convention" note).
///
/// Layout: no header. Each record is one of:
/// - stitch: 2 bytes, `[dx & 0xFF, dy & 0xFF]` (each a signed byte, -128...127)
/// - jump: 4 bytes, `[0x80, 0x04, dx & 0xFF, dy & 0xFF]`
/// - trim: 4 fixed bytes, `[0x80, 0x80, 0x07, 0x00]` (the trailing two bytes
///   carry no real coordinate; the reference reader ignores them for this
///   control code, and this writer always emits the same fixed pair)
/// - color change: 4 fixed bytes, `[0x80, 0x01, 0x00, 0x00]`
/// - stop: the same 4 bytes as color change — EXP has no separate stop code
/// - end: nothing written; a reader detects the end of the pattern via EOF
public enum EXPFormatError: Error, LocalizedError {
    case deltaOutOfRange(dx: Double, dy: Double)
    case emptyPattern
    case truncatedRecord

    public var errorDescription: String? {
        switch self {
        case .deltaOutOfRange(let dx, let dy):
            return "Stitch or jump moves \(dx)mm, \(dy)mm in one step — exceeds EXP's ±12.7mm per-record limit. The engine should have split this into multiple jumps before export."
        case .emptyPattern:
            return "Pattern has no stitches to export."
        case .truncatedRecord:
            return "EXP file ended mid-record."
        }
    }
}

public enum EXPFormat {
    /// Native EXP unit: 0.1mm (same as DST).
    public static let unitsPerMM = 10.0
    /// Max representable delta per record: a single signed byte's range.
    public static let maxDeltaUnits = 127

    // MARK: - Writing

    /// `designName` is accepted for the same call signature every format
    /// writer shares, but EXP has no field anywhere in its layout to hold
    /// it -- unlike DST/PES, this is silently and correctly discarded, not
    /// an oversight.
    public static func write(_ plan: StitchPlan, designName: String) throws -> Data {
        guard !plan.commands.isEmpty else { throw EXPFormatError.emptyPattern }

        var body = Data()
        // Integer 0.1mm units, not Double mm, for the same reason DST's
        // writer tracks position this way: quantizing each absolute target
        // independently (rather than accumulating unquantized float deltas)
        // keeps per-stitch error bounded to half a unit regardless of
        // stitch count.
        var currentX = 0
        var currentY = 0

        func moveTo(_ target: Point2D, jump: Bool) throws {
            let targetX = Int((target.x * unitsPerMM).rounded())
            let targetY = Int((target.y * unitsPerMM).rounded())
            try emitDeltaUnitsSplitIfNeeded(targetX - currentX, targetY - currentY, jump: jump, into: &body)
            currentX = targetX
            currentY = targetY
        }

        for command in plan.commands {
            switch command {
            case .stitch(let p):
                try moveTo(p, jump: false)
            case .jump(let p):
                try moveTo(p, jump: true)
            case .colorChange, .stop:
                body.append(contentsOf: [0x80, 0x01, 0x00, 0x00])
            case .trim:
                body.append(contentsOf: [0x80, 0x80, 0x07, 0x00])
            case .end:
                break // EXP has no end-of-file marker
            }
        }
        return body
    }

    /// Splits a delta larger than the per-record range into multiple
    /// max-sized jump records plus a final remainder record, so the engine
    /// never has to reason about the 12.7mm EXP limit directly -- the same
    /// approach `DSTFormat` uses for its own (slightly smaller) limit.
    private static func emitDeltaUnitsSplitIfNeeded(_ dx: Int, _ dy: Int, jump: Bool, into data: inout Data) throws {
        var dxUnits = dx
        var dyUnits = dy

        if !jump, abs(dxUnits) <= maxDeltaUnits, abs(dyUnits) <= maxDeltaUnits {
            data.append(contentsOf: try emitRecord(dx: dxUnits, dy: dyUnits, jump: false))
            return
        }

        while abs(dxUnits) > maxDeltaUnits || abs(dyUnits) > maxDeltaUnits {
            let stepX = max(-maxDeltaUnits, min(maxDeltaUnits, dxUnits))
            let stepY = max(-maxDeltaUnits, min(maxDeltaUnits, dyUnits))
            let scale = max(abs(Double(stepX)) > 0 ? Double(stepX) / Double(dxUnits == 0 ? 1 : dxUnits) : 0,
                             abs(Double(stepY)) > 0 ? Double(stepY) / Double(dyUnits == 0 ? 1 : dyUnits) : 0)
            let thisX = dxUnits == 0 ? 0 : Int((Double(dxUnits) * scale).rounded())
            let thisY = dyUnits == 0 ? 0 : Int((Double(dyUnits) * scale).rounded())
            let clampedX = max(-maxDeltaUnits, min(maxDeltaUnits, thisX))
            let clampedY = max(-maxDeltaUnits, min(maxDeltaUnits, thisY))
            data.append(contentsOf: try emitRecord(dx: clampedX, dy: clampedY, jump: true))
            dxUnits -= clampedX
            dyUnits -= clampedY
        }
        data.append(contentsOf: try emitRecord(dx: dxUnits, dy: dyUnits, jump: jump))
    }

    private static func emitRecord(dx: Int, dy: Int, jump: Bool) throws -> [UInt8] {
        guard abs(dx) <= maxDeltaUnits, abs(dy) <= maxDeltaUnits else {
            throw EXPFormatError.deltaOutOfRange(dx: Double(dx) / unitsPerMM, dy: Double(dy) / unitsPerMM)
        }
        let dxByte = UInt8(bitPattern: Int8(dx))
        let dyByte = UInt8(bitPattern: Int8(dy))
        return jump ? [0x80, 0x04, dxByte, dyByte] : [dxByte, dyByte]
    }

    // MARK: - Reading (independent decode path, used for export self-validation)

    public struct DecodedPattern {
        public var commands: [StitchCommand]
    }

    public static func read(_ data: Data) throws -> DecodedPattern {
        var commands: [StitchCommand] = []
        var current = Point2D.zero
        var index = data.startIndex

        func readByte() -> UInt8? {
            guard index < data.endIndex else { return nil }
            let b = data[index]
            index = data.index(after: index)
            return b
        }
        func delta(_ b: UInt8) -> Double { Double(Int8(bitPattern: b)) / unitsPerMM }

        while let b0 = readByte() {
            if b0 != 0x80 {
                guard let b1 = readByte() else { throw EXPFormatError.truncatedRecord }
                current = Point2D(current.x + delta(b0), current.y + delta(b1))
                commands.append(.stitch(current))
                continue
            }
            guard let control = readByte(), let b2 = readByte(), let b3 = readByte() else {
                throw EXPFormatError.truncatedRecord
            }
            switch control {
            case 0x80:
                commands.append(.trim)
            case 0x04:
                current = Point2D(current.x + delta(b2), current.y + delta(b3))
                commands.append(.jump(current))
            case 0x02:
                // "This shouldn't exist" per the reference reader -- a
                // stitch delivered through the escape encoding rather than
                // the normal 2-byte form. Handled the same as a plain
                // stitch for files that do contain it.
                current = Point2D(current.x + delta(b2), current.y + delta(b3))
                commands.append(.stitch(current))
            case 0x01:
                commands.append(.colorChange)
                let dx = delta(b2), dy = delta(b3)
                if dx != 0 || dy != 0 {
                    current = Point2D(current.x + dx, current.y + dy)
                    commands.append(.jump(current))
                }
            default:
                throw EXPFormatError.truncatedRecord
            }
        }
        commands.append(.end)
        return DecodedPattern(commands: commands)
    }
}
