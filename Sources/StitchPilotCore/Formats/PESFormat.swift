import Foundation

/// Brother/Baby Lock PES writer and independent reader.
///
/// This writes the widely-used "truncated PES version 1" structure: the
/// 8-byte `#PES0001` signature, a fixed 14-byte stub (in place of the
/// fuller version's embedded thread-chart/sewing-segment metadata, which
/// design software uses for re-editing but a machine doesn't need to sew),
/// followed directly by an embedded PEC block — the part that actually
/// carries stitch data and which the sewing machine reads. This is the same
/// simplification several other embroidery tools use to produce valid,
/// machine-sewable PES files without the much larger "full" wrapper.
///
/// As with `DSTFormat`, the exact byte layout below (short/long value
/// encoding, header field offsets, the Brother thread-index table in
/// `BrotherThreadPalette.swift`) was verified empirically against
/// pyembroidery (MIT license) — both by reading `PecWriter.py`/
/// `PecReader.py` and by generating real PES files with it and inspecting
/// the raw bytes — rather than reconstructed from memory, for the same
/// reason DST's layout was: getting a safety-critical byte layout wrong
/// produces a file that loads but sews incorrectly.
public enum PESFormatError: Error, LocalizedError {
    case emptyPattern
    case deltaOutOfRange(dx: Double, dy: Double)
    case truncatedFile
    case invalidSignature

    public var errorDescription: String? {
        switch self {
        case .emptyPattern: return "Pattern has no stitches to export."
        case .deltaOutOfRange(let dx, let dy):
            return "Stitch or jump moves \(dx)mm, \(dy)mm in one step — exceeds PES's per-record limit. The engine should have split this before export."
        case .truncatedFile: return "PES file ended unexpectedly."
        case .invalidSignature: return "This isn't a PES file (missing #PES signature)."
        }
    }
}

public enum PESFormat {
    public static let unitsPerMM = 10.0
    private static let maxLongDelta = 2047
    private static let iconByteStride = 6
    private static let iconHeight = 38
    private static let iconByteSize = iconByteStride * iconHeight // 228

    private static let jumpFlag = 0x10
    private static let trimFlag = 0x20
    private static let longFlag = 0x8000

    // MARK: - Writing

    /// - Parameter threadColors: one color per color *run* in sewing order
    ///   (i.e. `DigitizePipeline.colorSequence(for:)`'s output) — length
    ///   must be `plan.colorChangeCount + 1`.
    public static func write(_ plan: StitchPlan, designName: String, threadColors: [RGBColor]) throws -> Data {
        guard !plan.commands.isEmpty else { throw PESFormatError.emptyPattern }

        var data = Data()
        data.append("#PES0001".data(using: .ascii)!)
        data.append(contentsOf: [0x16] + [UInt8](repeating: 0, count: 13)) // fixed truncated-v1 stub

        let paletteIndices = threadColors.map { UInt8(BrotherThreadPalette.nearestIndex(to: $0)) }
        data.append(makeHeader(designName: designName, paletteIndices: paletteIndices))

        let stitchBlockStart = data.count
        data.append(contentsOf: [0x00, 0x00]) // placeholder, overwritten? no -- these two bytes are fixed per format
        data.append(contentsOf: [0, 0, 0]) // 3-byte length placeholder, backfilled below
        data.append(contentsOf: [0x31, 0xFF, 0xF0])
        let box = plan.boundingBox
        let width = box.isEmpty ? 0 : Int(box.width.rounded())
        let height = box.isEmpty ? 0 : Int(box.height.rounded())
        data.append(contentsOf: uint16le(width))
        data.append(contentsOf: uint16le(height))
        data.append(contentsOf: uint16le(0x1E0))
        data.append(contentsOf: uint16le(0x1B0))

        let stitchBytesStart = data.count
        try appendEncodedStitches(plan.commands, into: &data)
        let stitchBlockLength = data.count - stitchBlockStart

        // Backfill the 3-byte little-endian length at stitchBlockStart+2.
        let lengthBytes = uint24le(stitchBlockLength)
        data.replaceSubrange((stitchBlockStart + 2)..<(stitchBlockStart + 5), with: lengthBytes)
        _ = stitchBytesStart // (kept for clarity/documentation; not otherwise needed)

        // Graphics: one blank icon per (design + each color). Real preview
        // rendering is cosmetic only (spec doesn't require it for a
        // sewable file) — every icon is the same blank placeholder bitmap.
        let iconCount = 1 + threadColors.count
        for _ in 0..<iconCount {
            data.append(contentsOf: PESFormat.blankIcon)
        }

        return data
    }

    private static func makeHeader(designName: String, paletteIndices: [UInt8]) -> Data {
        var data = Data()
        let name = String(designName.prefix(8))
        data.append("LA:\(name.padding(toLength: 16, withPad: " ", startingAt: 0))\r".data(using: .ascii)!)
        data.append(contentsOf: [UInt8](repeating: 0x20, count: 12) + [0xFF, 0x00])
        data.append(UInt8(iconByteStride))
        data.append(UInt8(iconHeight))
        data.append(contentsOf: [UInt8](repeating: 0x20, count: 12))

        let count = max(1, paletteIndices.count)
        data.append(UInt8(count - 1)) // Brother's "count minus one" convention; 0xFF (i.e. 255) would mean 0, not relevant at our scale
        if paletteIndices.isEmpty {
            data.append(20) // default to Black if somehow no colors were supplied
        } else {
            data.append(contentsOf: paletteIndices)
        }

        while data.count < 512 { data.append(0x20) }
        return data.prefix(512) // defensive: never exceed the fixed 512-byte header even with an unusually large palette list
    }

    /// State machine mirroring the verified PEC stitch-encoding behavior:
    /// every jump other than the very first movement in the design is
    /// encoded as an implicit trim+jump (Brother's format has no separate
    /// bare "trim" record — trimming is a flag on the jump that follows
    /// it), and a defensive zero-delta stitch closes out a run of jumps
    /// before the next real stitch or color change, matching behavior
    /// verified against the reference implementation.
    private static func appendEncodedStitches(_ commands: [StitchCommand], into data: inout Data) throws {
        var currentX = 0, currentY = 0
        var wasJumping = true
        var isFirstMovement = true
        var colorToggle = true

        func targetUnits(_ p: Point2D) -> (Int, Int) {
            (Int((p.x * unitsPerMM).rounded()), Int((p.y * unitsPerMM).rounded()))
        }

        for command in commands {
            switch command {
            case .stitch(let p):
                let (tx, ty) = targetUnits(p)
                if wasJumping {
                    data.append(contentsOf: try encodeRecord(dx: 0, dy: 0, forceLong: false, flag: 0))
                    wasJumping = false
                }
                try appendDeltaSplit(dx: tx - currentX, dy: ty - currentY, jump: false, forceTrimFlag: false, into: &data)
                currentX = tx; currentY = ty
                isFirstMovement = false
            case .jump(let p):
                let (tx, ty) = targetUnits(p)
                try appendDeltaSplit(dx: tx - currentX, dy: ty - currentY, jump: true, forceTrimFlag: !isFirstMovement, into: &data)
                currentX = tx; currentY = ty
                wasJumping = true
                isFirstMovement = false
            case .colorChange:
                if wasJumping {
                    data.append(contentsOf: try encodeRecord(dx: 0, dy: 0, forceLong: false, flag: 0))
                    wasJumping = false
                }
                data.append(contentsOf: [0xFE, 0xB0, colorToggle ? 0x02 : 0x01])
                colorToggle.toggle()
            case .trim, .stop:
                break // no independent byte -- captured by the jump that follows, or simply dropped if none does
            case .end:
                data.append(contentsOf: [0xFF, 0x00])
                return
            }
        }
        data.append(contentsOf: [0xFF, 0x00]) // defensive: always terminate even if the plan didn't end with .end
    }

    private static func appendDeltaSplit(dx: Int, dy: Int, jump: Bool, forceTrimFlag: Bool, into data: inout Data) throws {
        var dx = dx, dy = dy
        while abs(dx) > maxLongDelta || abs(dy) > maxLongDelta {
            let stepX = max(-maxLongDelta, min(maxLongDelta, dx))
            let stepY = max(-maxLongDelta, min(maxLongDelta, dy))
            data.append(contentsOf: try encodeRecord(dx: stepX, dy: stepY, forceLong: true, flag: jump ? UInt8(jumpFlag) : 0))
            dx -= stepX; dy -= stepY
        }
        let flag: UInt8 = jump ? UInt8(forceTrimFlag ? trimFlag : jumpFlag) : 0
        data.append(contentsOf: try encodeRecord(dx: dx, dy: dy, forceLong: jump, flag: flag))
    }

    private static func encodeRecord(dx: Int, dy: Int, forceLong: Bool, flag: UInt8) throws -> [UInt8] {
        guard abs(dx) <= maxLongDelta, abs(dy) <= maxLongDelta else {
            throw PESFormatError.deltaOutOfRange(dx: Double(dx) / unitsPerMM, dy: Double(dy) / unitsPerMM)
        }
        return try encodeAxis(dx, forceLong: forceLong, flag: flag) + encodeAxis(dy, forceLong: forceLong, flag: flag)
    }

    private static func encodeAxis(_ value: Int, forceLong: Bool, flag: UInt8) throws -> [UInt8] {
        if !forceLong, value > -64, value < 63 {
            return [UInt8(value & 0x7F)]
        }
        var v = value & 0xFFF
        v |= longFlag
        v |= Int(flag) << 8
        return [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func uint16le(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func uint24le(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF)] }

    // MARK: - Reading (independent decode path, used for export self-validation)

    public struct DecodedPattern {
        public var commands: [StitchCommand]
        public var name: String?
    }

    public static func read(_ data: Data) throws -> DecodedPattern {
        guard data.count > 22, let sig = String(data: data.prefix(8), encoding: .ascii), sig.hasPrefix("#PES") else {
            throw PESFormatError.invalidSignature
        }
        // 8 (signature) + 14 (truncated-v1 stub) = 22 bytes before the PEC header.
        let headerStart = 22
        guard data.count >= headerStart + 512 else { throw PESFormatError.truncatedFile }

        let laLine = data[headerStart..<(headerStart + 20)]
        let name = String(data: laLine, encoding: .ascii)?
            .replacingOccurrences(of: "LA:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let colorCountByte = data[data.index(data.startIndex, offsetBy: headerStart + 48)]
        let colorCount = Int(colorCountByte) + 1

        let stitchBlockStart = headerStart + 512
        guard data.count >= stitchBlockStart + 16 else { throw PESFormatError.truncatedFile }
        var index = data.index(data.startIndex, offsetBy: stitchBlockStart + 16) // skip 00 00 + len3 + 31 FF F0 + w2 + h2 + 2 + 2

        var commands: [StitchCommand] = []
        var currentX = 0, currentY = 0

        func decodeAxis(_ index: inout Data.Index) throws -> Int {
            guard index < data.endIndex else { throw PESFormatError.truncatedFile }
            let b0 = data[index]
            index = data.index(after: index)
            if b0 & 0x80 == 0 {
                let signed = b0 > 63 ? Int(b0) - 128 : Int(b0)
                return signed
            }
            guard index < data.endIndex else { throw PESFormatError.truncatedFile }
            let b1 = data[index]
            index = data.index(after: index)
            let code = (Int(b0) << 8) | Int(b1)
            let masked = code & 0xFFF
            return masked > 0x7FF ? masked - 0x1000 : masked
        }

        while data.distance(from: index, to: data.endIndex) >= 2 {
            let peek0 = data[index]
            let peekNext = data.index(after: index)
            let peek1 = data[peekNext]

            if peek0 == 0xFF, peek1 == 0x00 {
                commands.append(.end)
                break
            }
            if peek0 == 0xFE, peek1 == 0xB0 {
                index = data.index(index, offsetBy: 3) // 0xFE 0xB0 <toggle byte>
                commands.append(.colorChange)
                continue
            }

            let b0 = peek0
            let isFlagged = b0 & 0x80 != 0
            let dx = try decodeAxis(&index)
            let dy = try decodeAxis(&index)
            currentX += dx; currentY += dy
            let point = Point2D(Double(currentX) / unitsPerMM, Double(currentY) / unitsPerMM)

            if isFlagged, (Int(b0) & jumpFlag) != 0 {
                commands.append(.jump(point))
            } else if isFlagged, (Int(b0) & trimFlag) != 0 {
                commands.append(.trim)
                commands.append(.jump(point))
            } else {
                // Decoded literally, including the zero-delta "closing"
                // stitch the writer inserts after every jump run before
                // resuming real stitching or hitting a color change: on
                // real hardware a zero-movement stitch is behaviorally
                // identical to not having one (one needle penetration at
                // wherever the needle already is), so there's no reliable
                // way -- or need -- to distinguish "defensive placeholder"
                // from "a real stitch that happens to land back on the
                // jump target" from the bytes alone. Round-trip tests
                // compare against what the writer actually emitted, not an
                // idealized "real stitches only" count.
                commands.append(.stitch(point))
            }
        }

        _ = colorCount
        return DecodedPattern(commands: commands, name: name?.isEmpty == true ? nil : name)
    }

    /// Brother's fixed 228-byte (38 rows x 6-byte stride) blank-icon bitmap
    /// used for every thumbnail this writer emits (see the type doc comment
    /// for why real icon rendering is out of scope).
    static let blankIcon: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F,
        0x08, 0x00, 0x00, 0x00, 0x00, 0x10, 0x04, 0x00, 0x00, 0x00, 0x00, 0x20,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x40,
        0x04, 0x00, 0x00, 0x00, 0x00, 0x20, 0x08, 0x00, 0x00, 0x00, 0x00, 0x10,
        0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]
}
