import Foundation

/// Husqvarna Viking / Pfaff VP3 reader/writer.
///
/// VP3 is a nested, length-prefixed binary structure: a file block
/// containing one design block, containing one colorblock per thread
/// color, each colorblock containing a stitches sub-block. Every block
/// after its own 3-byte marker (`\x00\x02\x00`, `\x00\x03\x00`, or
/// `\x00\x05\x00`/`\x00\x01\x00`) is prefixed with a 4-byte big-endian
/// length — the number of bytes remaining in that block, measured from
/// immediately after the length field itself — so a reader can skip
/// straight past a block it doesn't care about.
///
/// **Two different numeric scales in one file** — confirmed empirically,
/// not just read off the reference source, because the source alone is
/// actively misleading here (see below):
/// - Every stitch delta inside a colorblock's own stitches sub-block uses
///   the same 0.1mm-per-unit convention DST/EXP/JEF all use.
/// - Every OTHER numeric field — the design's overall extends, its
///   center, and each colorblock's own start-position-from-center and
///   block-shift — uses a completely different, ten-times-finer
///   0.001mm-per-unit convention.
///
/// `pyembroidery`'s reference writer computes the second group as
/// `int(value * 100)`, which reads like "the same unit, just ×100" — but
/// `value` there is already in *pyembroidery's own* internal 0.1mm-per-unit
/// representation, not real mm, so the true scale relative to real
/// millimeters is 100 × 10 = 1000, not 100. This was verified directly:
/// building a pattern of a known real-world size with pyembroidery's own
/// writer and reading the raw bytes back at both kinds of field, rather
/// than trusting the arithmetic implied by the source alone.
///
/// **Coordinate convention — the one place VP3 differs from DST/EXP/JEF:**
/// StitchPilot's internal `Point2D` is Y-down, as is pyembroidery's
/// internal model (see `DSTFormat`'s "Coordinate convention" note for how
/// that was established). VP3's stitch-delta bytes are Y-down too --
/// `Vp3Writer.py` writes `y - last_y` unnegated -- so stitch deltas go out
/// with NO sign change, unlike DST/EXP/JEF. The header/position fields are
/// the reverse: the reference negates every Y there (`* -100` on "top"/
/// "bottom", the design centre, and each block's start-from-centre and
/// shift), and since our Y is its Y, we negate the same fields. An earlier
/// version of this writer had both halves inverted (deltas negated, header
/// not) on the belief that pyembroidery was Y-up internally; the result
/// sewed upside-down.
///
/// **No jump command exists.** VP3 has no distinct "needle up, travel"
/// record at all (per `Vp3Writer.py`'s own comment: "VP3 has no jump
/// commands. These are skipped. It moves to the relevant location
/// without needing to block the needlebar."). A `.jump` in `StitchPlan`
/// is simply dropped — not encoded, and not counted toward the stitch-delta
/// baseline — so the *next* real stitch's own delta naturally spans
/// however far the jump moved, since nothing updated the baseline in
/// between. The same applies to `.stop`, which VP3 has no representation
/// for at all.
///
/// **Trim and end share one marker.** Both `.trim` and `.end` write the
/// same 2-byte `\x80\x03` sequence with no position payload — VP3 doesn't
/// distinguish "cut the thread and keep going" from "cut the thread, this
/// design is over" at the byte level; the file's own nested block
/// structure is what actually terminates a design, not an in-stream byte.
/// `read` below always decodes `\x80\x03` as `.trim` and appends one
/// unconditional trailing `.end`, the same convention `JEFFormat.read`
/// and `DSTFormat.read` already use.
public enum VP3FormatError: Error, LocalizedError {
    case emptyPattern
    case deltaOutOfRange(dx: Double, dy: Double)
    case truncatedRecord

    public var errorDescription: String? {
        switch self {
        case .emptyPattern:
            return "Pattern has no stitches to export."
        case .deltaOutOfRange(let dx, let dy):
            return "Stitch moves \(dx)mm, \(dy)mm in one step — exceeds VP3's representable per-record range (roughly ±3276mm)."
        case .truncatedRecord:
            return "VP3 file ended mid-record."
        }
    }
}

public enum VP3Format {
    /// In-stream stitch deltas: same 0.1mm-per-unit convention as
    /// DST/EXP/JEF.
    public static let stitchUnitsPerMM = 10.0
    /// Every other numeric field (extends, center, per-block start
    /// position, block shift): 0.001mm-per-unit, confirmed empirically —
    /// see this file's top doc comment.
    public static let headerUnitsPerMM = 1000.0
    /// A plain single-byte delta stays a plain byte only up to ±127, not
    /// the full signed-byte range down to -128 — `0x80` is reserved as the
    /// escape-record lead byte, so a literal delta of exactly -128 (whose
    /// two's-complement byte value is also `0x80`) would be indistinguishable
    /// from an escape record if allowed through.
    private static let maxPlainStitchDeltaUnits = 127
    private static let maxEscapedStitchDeltaUnits = 32767

    // MARK: - Writing

    public static func write(_ plan: StitchPlan, designName: String, threadColors: [RGBColor]) throws -> Data {
        guard !plan.commands.isEmpty else { throw VP3FormatError.emptyPattern }
        let box = plan.boundingBox
        guard !box.isEmpty else { throw VP3FormatError.emptyPattern }

        let blocks = try buildColorBlocks(plan.commands)
        let colorCount = max(threadColors.count, 1)
        let centerX = (box.minX + box.maxX) / 2
        let centerY = (box.minY + box.maxY) / 2
        let halfWidth = box.width / 2
        let halfHeight = box.height / 2

        var file = Data()
        file.append(asciiString: "%vsm%")
        file.append(0)
        file.append(utf16String: "Produced by     Software Ltd")
        file.append(try writeFileBlock(blocks: blocks, threadColors: threadColors, colorCount: colorCount,
                                        box: box, centerX: centerX, centerY: centerY, halfWidth: halfWidth, halfHeight: halfHeight))
        return file
    }

    private struct ColorBlock {
        var stitchBytes = Data()
        /// The block's own first and last point-carrying command
        /// (`.stitch`/`.jump`), forced to `(0, 0)` for the very first
        /// block's `firstPos` regardless of its real first point — matches
        /// the reference writer's own `if first: first_pos = 0, 0`, and
        /// (since this same, possibly-forced value feeds both the
        /// start-position and block-shift fields below) also makes the
        /// first block's block-shift come out as just its own last point,
        /// not a true shift — a reference quirk this mirrors deliberately
        /// rather than "fixes."
        var firstPos: Point2D = .zero
        var lastPos: Point2D = .zero
    }

    private static func buildColorBlocks(_ commands: [StitchCommand]) throws -> [ColorBlock] {
        var blocks: [ColorBlock] = [ColorBlock()]
        var haveFirstPos = false
        var deltaBaseline = Point2D.zero

        func currentIndex() -> Int { blocks.count - 1 }
        func noteAnyPoint(_ p: Point2D) {
            let i = currentIndex()
            if !haveFirstPos {
                blocks[i].firstPos = (i == 0) ? .zero : p
                haveFirstPos = true
            }
            blocks[i].lastPos = p
        }

        for command in commands {
            switch command {
            case .stitch(let p):
                noteAnyPoint(p)
                let dxMM = p.x - deltaBaseline.x
                let dyMM = p.y - deltaBaseline.y // VP3 deltas are Y-down like us; see "Coordinate convention" above
                deltaBaseline = p
                try appendStitchDelta(dxMM: dxMM, dyMM: dyMM, into: &blocks[currentIndex()].stitchBytes)
            case .jump(let p):
                // No jump record exists in VP3 -- note the position for
                // block-boundary bookkeeping only; the delta baseline is
                // deliberately left where it was, so the next real stitch's
                // own delta spans the jump too. See this file's doc comment.
                noteAnyPoint(p)
            case .colorChange:
                blocks.append(ColorBlock())
                haveFirstPos = false
            case .trim, .end:
                blocks[currentIndex()].stitchBytes.append(contentsOf: [0x80, 0x03])
            case .stop:
                break // VP3 has no representation for this; silently dropped, matching the reference.
            }
        }
        return blocks
    }

    private static func appendStitchDelta(dxMM: Double, dyMM: Double, into data: inout Data) throws {
        let dx = Int((dxMM * stitchUnitsPerMM).rounded())
        let dy = Int((dyMM * stitchUnitsPerMM).rounded())
        if abs(dx) <= maxPlainStitchDeltaUnits, abs(dy) <= maxPlainStitchDeltaUnits {
            data.append(UInt8(bitPattern: Int8(dx)))
            data.append(UInt8(bitPattern: Int8(dy)))
            return
        }
        guard abs(dx) <= maxEscapedStitchDeltaUnits, abs(dy) <= maxEscapedStitchDeltaUnits else {
            throw VP3FormatError.deltaOutOfRange(dx: dxMM, dy: dyMM)
        }
        data.append(contentsOf: [0x80, 0x01])
        data.append(bigEndian16(Int16(dx)))
        data.append(bigEndian16(Int16(dy)))
        data.append(contentsOf: [0x80, 0x02])
    }

    private static func writeFileBlock(blocks: [ColorBlock], threadColors: [RGBColor], colorCount: Int, box: BoundingBox,
                                        centerX: Double, centerY: Double, halfWidth: Double, halfHeight: Double) throws -> Data {
        var body = Data()
        body.append(utf16String: "") // global notes/settings

        // Extends, with the reference's Y negation (`extends[1] * -100`,
        // `extends[3] * -100`): the file stores the top and bottom edges
        // with Y pointing up. See this file's top doc comment.
        body.append(bigEndian32(headerUnits(box.maxX)))   // right
        body.append(bigEndian32(-headerUnits(box.minY)))  // -top
        body.append(bigEndian32(headerUnits(box.minX)))   // left
        body.append(bigEndian32(-headerUnits(box.maxY)))  // -bottom

        let stitchCount = blocks.reduce(0) { $0 + countPlainStitches($1) }
        body.append(bigEndian32(Int32(stitchCount)))
        body.append(0)
        body.append(UInt8(clamping: blocks.count))
        body.append(12)
        body.append(0)
        body.append(1) // one design

        body.append(try writeDesignBlock(blocks: blocks, threadColors: threadColors, colorCount: colorCount,
                                          centerX: centerX, centerY: centerY, halfWidth: halfWidth, halfHeight: halfHeight, box: box))

        var block = Data()
        block.append(contentsOf: [0x00, 0x02, 0x00])
        block.append(bigEndian32(Int32(body.count)))
        block.append(body)
        return block
    }

    /// Counts stitch *bytes* worth of plain stitches for the informational
    /// header count -- approximated as the number of 2-or-6-byte records
    /// actually written, which is close enough for a field the reference
    /// reader never uses to decode anything (see this format's own "count
    /// stitch-point count: informational only" precedent in JEFFormat).
    private static func countPlainStitches(_ block: ColorBlock) -> Int {
        var count = 0
        var i = block.stitchBytes.startIndex
        let bytes = block.stitchBytes
        while i < bytes.endIndex {
            if bytes[i] == 0x80 {
                let control = i + 1 < bytes.endIndex ? bytes[i + 1] : 0
                if control == 0x01 { i += 6 } else { i += 2 }
            } else {
                count += 1
                i += 2
            }
        }
        return count
    }

    private static func writeDesignBlock(blocks: [ColorBlock], threadColors: [RGBColor], colorCount: Int,
                                          centerX: Double, centerY: Double, halfWidth: Double, halfHeight: Double, box: BoundingBox) throws -> Data {
        var body = Data()
        body.append(bigEndian32(headerUnits(centerX)))
        body.append(bigEndian32(-headerUnits(centerY))) // `center_y * -100` in the reference
        body.append(contentsOf: [0, 0, 0])

        body.append(bigEndian32(-headerUnits(halfWidth)))
        body.append(bigEndian32(headerUnits(halfWidth)))
        body.append(bigEndian32(-headerUnits(halfHeight)))
        body.append(bigEndian32(headerUnits(halfHeight)))

        body.append(bigEndian32(headerUnits(box.width)))
        body.append(bigEndian32(headerUnits(box.height)))
        body.append(utf16String: "") // design notes/settings

        body.append(contentsOf: [0x64, 0x64])
        body.append(bigEndian32(4096))
        body.append(bigEndian32(0))
        body.append(bigEndian32(0))
        body.append(bigEndian32(4096))
        body.append(asciiString: "xxPP")
        body.append(contentsOf: [0x01, 0x00])
        body.append(utf16String: "Produced by     Software Ltd")

        body.append(bigEndian16(UInt16(colorCount)))
        for (index, block) in blocks.enumerated() {
            let color = index < threadColors.count ? threadColors[index] : RGBColor(hex: 0x000000)
            body.append(writeColorBlock(block, isFirst: index == 0, centerX: centerX, centerY: centerY, color: color))
        }

        var wrapped = Data()
        wrapped.append(contentsOf: [0x00, 0x03, 0x00])
        wrapped.append(bigEndian32(Int32(body.count)))
        wrapped.append(body)
        return wrapped
    }

    private static func writeColorBlock(_ block: ColorBlock, isFirst: Bool, centerX: Double, centerY: Double, color: RGBColor) -> Data {
        var body = Data()
        let startFromCenterX = block.firstPos.x - centerX
        let startFromCenterY = -(block.firstPos.y - centerY) // negated like the reference
        body.append(bigEndian32(headerUnits(startFromCenterX)))
        body.append(bigEndian32(headerUnits(startFromCenterY)))

        body.append(writeThread(color))

        let shiftX = block.lastPos.x - block.firstPos.x
        let shiftY = -(block.lastPos.y - block.firstPos.y) // negated like the reference
        body.append(bigEndian32(headerUnits(shiftX)))
        body.append(bigEndian32(headerUnits(shiftY)))

        var stitchesBlock = Data()
        stitchesBlock.append(contentsOf: [0x0A, 0xF6, 0x00])
        stitchesBlock.append(block.stitchBytes)
        var stitchesWrapped = Data()
        stitchesWrapped.append(contentsOf: [0x00, 0x01, 0x00])
        stitchesWrapped.append(bigEndian32(Int32(stitchesBlock.count)))
        stitchesWrapped.append(stitchesBlock)
        body.append(stitchesWrapped)
        body.append(0)

        var wrapped = Data()
        wrapped.append(contentsOf: [0x00, 0x05, 0x00])
        wrapped.append(bigEndian32(Int32(body.count)))
        wrapped.append(body)
        return wrapped
    }

    private static func writeThread(_ color: RGBColor) -> Data {
        var data = Data()
        data.append(contentsOf: [0x01, 0x00]) // single color, no transition
        let rgb = (UInt32(color.r) << 16) | (UInt32(color.g) << 8) | UInt32(color.b)
        data.append(UInt8((rgb >> 16) & 0xFF))
        data.append(UInt8((rgb >> 8) & 0xFF))
        data.append(UInt8(rgb & 0xFF))
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x05, 0x28]) // no parts, no length, Rayon 40-weight
        data.append(utf8String8: "") // catalog number
        data.append(utf8String8: String(format: "#%02X%02X%02X", color.r, color.g, color.b)) // description
        data.append(utf8String8: "") // brand
        return data
    }

    private static func headerUnits(_ mm: Double) -> Int32 {
        Int32((mm * headerUnitsPerMM).rounded())
    }

    private static func bigEndian32(_ value: Int32) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 4)
    }

    private static func bigEndian16(_ value: Int16) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 2)
    }

    private static func bigEndian16(_ value: UInt16) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 2)
    }

    // MARK: - Reading (independent decode path, used for export self-validation)

    public struct DecodedPattern {
        public var commands: [StitchCommand]
    }

    public static func read(_ data: Data) throws -> DecodedPattern {
        var cursor = Cursor(data: data)
        _ = try cursor.take(6) // magic
        _ = try cursor.readUTF16String()
        try cursor.skip(7)
        _ = try cursor.readUTF16String()
        try cursor.skip(16) // extends
        try cursor.skip(4)  // count_just_stitches
        try cursor.skip(5)  // five fixed bytes
        try cursor.skip(3)  // design block marker
        try cursor.skip(4)  // design block length placeholder
        // Center position: not needed for decoding -- block continuity is
        // guaranteed by construction (this writer's own colorblocks are
        // contiguous slices of one continuous position chain), so no
        // absolute repositioning is ever required between blocks. See this
        // file's top doc comment.
        try cursor.skip(8) // center x, y
        try cursor.skip(3 + 16 + 8) // three zero bytes, half-width/height extents, width/height
        _ = try cursor.readUTF16String()
        try cursor.skip(2 + 4 + 4 + 4 + 4 + 6) // 64 64, four int32, "xxPP\x01\x00"
        _ = try cursor.readUTF16String()
        let colorCount = try cursor.readUInt16()

        var commands: [StitchCommand] = []
        var runningPos = Point2D.zero
        for blockIndex in 0..<Int(colorCount) {
            if blockIndex > 0 { commands.append(.colorChange) }
            try cursor.skip(3) // colorblock marker
            let blockLength = try cursor.readInt32()
            let blockEnd = cursor.position + Int(blockLength)
            try cursor.skip(8) // start-position-from-center (informational only, see doc comment)
            try readThread(&cursor)
            try cursor.skip(8) // block shift (informational only)
            try cursor.skip(3) // stitches sub-block marker
            let stitchLength = try cursor.readInt32()
            let stitchEnd = cursor.position + Int(stitchLength)
            try cursor.skip(3) // \x0A\xF6\x00
            try readStitches(&cursor, until: stitchEnd, runningPos: &runningPos, into: &commands)
            cursor.position = blockEnd
        }
        commands.append(.end)
        return DecodedPattern(commands: commands)
    }

    private static func readThread(_ cursor: inout Cursor) throws {
        let colors = try cursor.readUInt8()
        _ = try cursor.readUInt8() // transition
        // Per color: 3-byte RGB, then 1-byte "parts" and 2-byte
        // "color_length" -- easy to miss since this writer only ever
        // emits a single flat-looking 5-byte tail (`\x00\x00\x00\x05\x28`)
        // for its one always-single-color thread, which is actually
        // parts(1)+color_length(2) followed by thread_type(1)+weight(1),
        // not a single opaque blob.
        for _ in 0..<colors {
            try cursor.skip(3) // color 24be
            try cursor.skip(1) // parts
            try cursor.skip(2) // color_length
        }
        try cursor.skip(2) // thread_type, weight
        for _ in 0..<3 { _ = try cursor.readUTF8String() }
    }

    private static func readStitches(_ cursor: inout Cursor, until end: Int, runningPos: inout Point2D, into commands: inout [StitchCommand]) throws {
        while cursor.position < end {
            let b0 = try cursor.readUInt8()
            if b0 != 0x80 {
                let b1 = try cursor.readUInt8()
                let dx = Double(Int8(bitPattern: b0)) / stitchUnitsPerMM
                let dy = Double(Int8(bitPattern: b1)) / stitchUnitsPerMM
                runningPos = Point2D(runningPos.x + dx, runningPos.y + dy) // deltas are Y-down, same as internal
                commands.append(.stitch(runningPos))
                continue
            }
            let control = try cursor.readUInt8()
            switch control {
            case 0x01:
                let dxRaw = try cursor.readInt16()
                let dyRaw = try cursor.readInt16()
                _ = try cursor.take(2) // trailing \x80\x02 closer
                let dx = Double(dxRaw) / stitchUnitsPerMM
                let dy = Double(dyRaw) / stitchUnitsPerMM
                runningPos = Point2D(runningPos.x + dx, runningPos.y + dy)
                commands.append(.stitch(runningPos))
            case 0x03:
                commands.append(.trim)
            default:
                throw VP3FormatError.truncatedRecord
            }
        }
    }

    private struct Cursor {
        let data: Data
        var position: Int
        init(data: Data) { self.data = data; position = data.startIndex }

        mutating func take(_ count: Int) throws -> Data {
            guard position + count <= data.endIndex else { throw VP3FormatError.truncatedRecord }
            let slice = data.subdata(in: position..<(position + count))
            position += count
            return slice
        }
        mutating func skip(_ count: Int) throws {
            guard position + count <= data.endIndex else { throw VP3FormatError.truncatedRecord }
            position += count
        }
        mutating func readUInt8() throws -> UInt8 {
            guard position < data.endIndex else { throw VP3FormatError.truncatedRecord }
            let b = data[position]
            position += 1
            return b
        }
        mutating func readUInt16() throws -> UInt16 {
            let bytes = try take(2)
            return UInt16(bytes[bytes.startIndex]) << 8 | UInt16(bytes[bytes.startIndex + 1])
        }
        mutating func readInt16() throws -> Int16 {
            Int16(bitPattern: try readUInt16())
        }
        mutating func readInt32() throws -> Int32 {
            let bytes = try take(4)
            var value: UInt32 = 0
            for byte in bytes { value = (value << 8) | UInt32(byte) }
            return Int32(bitPattern: value)
        }
        mutating func readUTF16String() throws -> String {
            let byteLength = Int(try readUInt16())
            let bytes = try take(byteLength)
            return String(data: bytes, encoding: .utf16BigEndian) ?? ""
        }
        mutating func readUTF8String() throws -> String {
            let byteLength = Int(try readUInt16())
            let bytes = try take(byteLength)
            return String(data: bytes, encoding: .utf8) ?? ""
        }
    }
}

private extension Data {
    mutating func append(asciiString string: String) {
        append(string.data(using: .ascii) ?? Data())
    }
    mutating func append(utf8String8 string: String) {
        let bytes = string.data(using: .utf8) ?? Data()
        var length = UInt16(bytes.count).bigEndian
        append(Data(bytes: &length, count: 2))
        append(bytes)
    }
    mutating func append(utf16String string: String) {
        let bytes = string.data(using: .utf16BigEndian) ?? Data()
        var length = UInt16(bytes.count).bigEndian
        append(Data(bytes: &length, count: 2))
        append(bytes)
    }
}
