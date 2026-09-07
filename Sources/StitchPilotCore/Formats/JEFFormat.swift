import Foundation

/// Janome JEF reader/writer.
///
/// JEF has a fixed 116-byte binary header (offsets, a date string, color
/// count, a hoop-size code, and four hoop-edge-distance blocks) followed by
/// a palette array (one thread-table index per color) and then the stitch
/// data, in the same 0.1mm units DST/EXP use. The exact field layout,
/// byte widths, and stitch-encoding escape bytes were read directly from
/// pyembroidery's `JefWriter.py` / `JefReader.py` / `EmbThreadJef.py` (MIT
/// license, see FORMATS.md) rather than reconstructed from memory, the
/// same correctness approach every format in this file uses — getting
/// this wrong produces a file that opens but sews incorrectly (spec §59).
///
/// Coordinate convention: same as DST/EXP — StitchPilot's internal
/// `Point2D` (Y-down) already matches JEF's on-disk Y-down convention, so
/// no sign flip is needed converting between them (verified via the
/// reference writer, which negates Y going from its own Y-up internal
/// model to JEF bytes).
///
/// Layout: a 116-byte header (see `makeHeader` for the exact field-by-field
/// breakdown), then `colorCount` big-endian... no — little-endian 32-bit
/// palette entries (one Janome thread-table index per color, `0` reserved
/// as a "stop" sentinel), then the stitch stream:
/// - stitch: 2 bytes, `[dx & 0xFF, dy & 0xFF]` (each a signed byte, so
///   ±12.7mm per record — split into multiple jumps the same way DST/EXP
///   split an over-limit delta)
/// - jump: 4 bytes, `[0x80, 0x02, dx & 0xFF, dy & 0xFF]`
/// - color change: 4 bytes, `[0x80, 0x01, dx & 0xFF, dy & 0xFF]` — unlike
///   EXP, JEF's color-change record *can* carry a real position delta, but
///   `StitchCommand.colorChange` (like DST's) never carries one, so this
///   writer always emits a zero delta here, matching the "engine places
///   objects so a color change doesn't imply a position jump" contract
///   documented on `DSTFormat`
/// - trim: three consecutive zero-delta jump records (`[0x80, 0x02, 0x00,
///   0x00]` x3) — JEF has no dedicated trim byte either; this mirrors
///   DST's "several small jumps signal a trim" convention (a different
///   specific pattern, verified against the reference writer's own
///   `trims`-enabled output) rather than DST's exact jiggle shape
/// - end: `[0x80, 0x10]`
public enum JEFFormatError: Error, LocalizedError {
    case deltaOutOfRange(dx: Double, dy: Double)
    case emptyPattern
    case truncatedRecord

    public var errorDescription: String? {
        switch self {
        case .deltaOutOfRange(let dx, let dy):
            return "Stitch or jump moves \(dx)mm, \(dy)mm in one step — exceeds JEF's ±12.7mm per-record limit. The engine should have split this into multiple jumps before export."
        case .emptyPattern:
            return "Pattern has no stitches to export."
        case .truncatedRecord:
            return "JEF file ended mid-record."
        }
    }
}

public enum JEFFormat {
    public static let unitsPerMM = 10.0
    public static let maxDeltaUnits = 127
    /// How many consecutive zero-delta jump records this writer emits (and
    /// this reader collapses back into one `.trim`) to mark a trim -- JEF's
    /// own writer settings call this `trim_at`, defaulting to 3.
    private static let trimRecordCount = 3

    // MARK: - Writing

    public static func write(_ plan: StitchPlan, designName: String, threadColors: [RGBColor]) throws -> Data {
        guard !plan.commands.isEmpty else { throw JEFFormatError.emptyPattern }

        let colorCount = max(threadColors.count, 1)
        let palette = buildPalette(threadColors)

        var body = Data()
        var currentX = 0
        var currentY = 0

        func moveTo(_ target: Point2D, jump: Bool) throws {
            let targetX = Int((target.x * unitsPerMM).rounded())
            let targetY = Int((target.y * unitsPerMM).rounded())
            if jump, targetX == currentX, targetY == currentY {
                // A zero-distance jump moves the needle nowhere -- skip it
                // entirely rather than encode it. JEF's on-disk zero-delta
                // jump-escape bytes (`0x80 0x02 0x00 0x00`) are otherwise
                // indistinguishable from this writer's own trim marker
                // (three of that same record in a row): a genuine jump
                // that happens to land exactly where the needle already
                // is -- e.g. the very first command in a design, jumping
                // to (0,0) from this writer's own (0,0) starting position
                // -- would otherwise be misread back as part of a trim.
                return
            }
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
                // `StitchCommand.colorChange` never carries a position
                // (see DSTFormat's "Coordinate convention" note) -- a real
                // delta here would need a payload this case doesn't have.
                body.append(contentsOf: [0x80, 0x01, 0x00, 0x00])
            case .trim:
                for _ in 0..<trimRecordCount {
                    body.append(contentsOf: [0x80, 0x02, 0x00, 0x00])
                }
            case .end:
                break // written explicitly below
            }
        }
        body.append(contentsOf: [0x80, 0x10])

        let box = plan.boundingBox
        let header = makeHeader(colorCount: colorCount, palette: palette, box: box)
        var paletteData = Data()
        for index in palette { paletteData.append(littleEndian32(Int32(index))) }
        for _ in 0..<colorCount { paletteData.append(littleEndian32(0x0D)) }

        return header + paletteData + body
    }

    /// Maps each color to its nearest Janome thread-table index, avoiding
    /// two *different* requested colors mapping to the same index
    /// back-to-back -- with a fixed thread-number table, a repeated index
    /// would show the machine operator the same "insert thread #NN"
    /// prompt for colors that were meant to be different threads.
    private static func buildPalette(_ threadColors: [RGBColor]) -> [Int] {
        var palette: [Int] = []
        var lastIndex: Int?
        var lastColor: RGBColor?
        for color in threadColors {
            var index = JanomeThreadPalette.nearestIndex(to: color)
            if let lastIndex, let lastColor, lastIndex == index, lastColor != color {
                index = JanomeThreadPalette.nearestIndex(to: color, excluding: lastIndex)
            }
            palette.append(index)
            lastIndex = index
            lastColor = color
        }
        return palette
    }

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
            throw JEFFormatError.deltaOutOfRange(dx: Double(dx) / unitsPerMM, dy: Double(dy) / unitsPerMM)
        }
        let dxByte = UInt8(bitPattern: Int8(dx))
        let dyByte = UInt8(bitPattern: Int8(dy))
        return jump ? [0x80, 0x02, dxByte, dyByte] : [dxByte, dyByte]
    }

    private static func littleEndian32(_ value: Int32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }

    /// The fixed 116-byte header: offset to the stitch data (`116 +
    /// colorCount*8`, matching the palette array's own size below it), a
    /// constant, a 14-byte (unpadded) date string, 2 unknown/padding
    /// bytes, color count, an approximate point count (informational only
    /// -- the reference reader never uses it to decode), a hoop-size
    /// bucket code, the design's half-width/half-height (written twice,
    /// matching the reference layout exactly), and four 16-byte
    /// hoop-edge-distance blocks for JEF's four named default hoop sizes.
    private static func makeHeader(colorCount: Int, palette: [Int], box: BoundingBox) -> Data {
        var header = Data()
        let stitchOffset: Int32 = 116 + Int32(colorCount * 8)
        header.append(littleEndian32(stitchOffset))
        header.append(littleEndian32(20))

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMddHHmmss"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let dateString = dateFormatter.string(from: Date())
        header.append(dateString.data(using: .ascii) ?? Data(repeating: 0x30, count: 14))
        header.append(contentsOf: [0, 0])

        header.append(littleEndian32(Int32(colorCount)))
        header.append(littleEndian32(1)) // point count: informational only, see doc comment

        let designWidth = box.isEmpty ? 0 : Int((box.width * unitsPerMM).rounded())
        let designHeight = box.isEmpty ? 0 : Int((box.height * unitsPerMM).rounded())
        header.append(littleEndian32(Int32(hoopSizeCode(width: designWidth, height: designHeight))))

        let halfWidth = designWidth / 2
        let halfHeight = designHeight / 2
        header.append(littleEndian32(Int32(halfWidth)))
        header.append(littleEndian32(Int32(halfHeight)))
        header.append(littleEndian32(Int32(halfWidth)))
        header.append(littleEndian32(Int32(halfHeight)))

        appendHoopEdgeDistance(&header, x: 550 - halfWidth, y: 550 - halfHeight)   // default 110x110
        appendHoopEdgeDistance(&header, x: 250 - halfWidth, y: 250 - halfHeight)   // default 50x50
        appendHoopEdgeDistance(&header, x: 700 - halfWidth, y: 1000 - halfHeight)  // default 140x200
        appendHoopEdgeDistance(&header, x: 700 - halfWidth, y: 1000 - halfHeight)  // custom hoop (mirrors reference)

        return header
    }

    private static func appendHoopEdgeDistance(_ header: inout Data, x: Int, y: Int) {
        if min(x, y) >= 0 {
            header.append(littleEndian32(Int32(x)))
            header.append(littleEndian32(Int32(y)))
            header.append(littleEndian32(Int32(x)))
            header.append(littleEndian32(Int32(y)))
        } else {
            for _ in 0..<4 { header.append(littleEndian32(-1)) }
        }
    }

    private static func hoopSizeCode(width: Int, height: Int) -> Int {
        if width < 500, height < 500 { return 1 }       // 50x50
        if width < 1260, height < 1100 { return 3 }      // 126x110
        if width < 1400, height < 2000 { return 2 }      // 140x200
        if width < 2000, height < 2000 { return 4 }      // 200x200
        return 0                                          // 110x110 (reference's own fallback)
    }

    // MARK: - Reading (independent decode path, used for export self-validation)

    public struct DecodedPattern {
        public var commands: [StitchCommand]
    }

    public static func read(_ data: Data) throws -> DecodedPattern {
        guard data.count >= 20 else { throw JEFFormatError.truncatedRecord }
        let stitchOffset = Int(readLittleEndian32(data, at: 0))
        let colorCount = Int(readLittleEndian32(data, at: 16))
        guard stitchOffset >= 0, stitchOffset <= data.count else { throw JEFFormatError.truncatedRecord }
        _ = colorCount // palette itself isn't needed to decode the stitch stream

        var commands: [StitchCommand] = []
        var current = Point2D.zero
        var index = data.index(data.startIndex, offsetBy: stitchOffset)
        var pendingZeroJumps = 0

        func flushPendingTrim() {
            if pendingZeroJumps > 0 {
                commands.append(.trim)
                pendingZeroJumps = 0
            }
        }
        func readByte() -> UInt8? {
            guard index < data.endIndex else { return nil }
            let b = data[index]
            index = data.index(after: index)
            return b
        }
        func delta(_ b: UInt8) -> Double { Double(Int8(bitPattern: b)) / unitsPerMM }

        while let b0 = readByte() {
            if b0 != 0x80 {
                guard let b1 = readByte() else { throw JEFFormatError.truncatedRecord }
                flushPendingTrim()
                current = Point2D(current.x + delta(b0), current.y + delta(b1))
                commands.append(.stitch(current))
                continue
            }
            guard let control = readByte() else { throw JEFFormatError.truncatedRecord }
            if control == 0x10 {
                flushPendingTrim()
                break // end of design
            }
            guard let b2 = readByte(), let b3 = readByte() else { throw JEFFormatError.truncatedRecord }
            switch control {
            case 0x02:
                let dx = delta(b2), dy = delta(b3)
                if dx == 0, dy == 0 {
                    // Part of a trim marker (see `write`'s doc comment) --
                    // collapse any run of these into one `.trim` rather
                    // than several zero-distance jumps.
                    pendingZeroJumps += 1
                } else {
                    flushPendingTrim()
                    current = Point2D(current.x + dx, current.y + dy)
                    commands.append(.jump(current))
                }
            case 0x01:
                flushPendingTrim()
                commands.append(.colorChange)
                let dx = delta(b2), dy = delta(b3)
                if dx != 0 || dy != 0 {
                    current = Point2D(current.x + dx, current.y + dy)
                    commands.append(.jump(current))
                }
            default:
                throw JEFFormatError.truncatedRecord
            }
        }
        flushPendingTrim()
        commands.append(.end)
        return DecodedPattern(commands: commands)
    }

    private static func readLittleEndian32(_ data: Data, at offset: Int) -> Int32 {
        let start = data.index(data.startIndex, offsetBy: offset)
        let b0 = UInt32(data[start])
        let b1 = UInt32(data[data.index(start, offsetBy: 1)])
        let b2 = UInt32(data[data.index(start, offsetBy: 2)])
        let b3 = UInt32(data[data.index(start, offsetBy: 3)])
        return Int32(bitPattern: b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
    }
}
