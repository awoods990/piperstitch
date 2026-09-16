import Foundation

/// Tajima DST reader/writer.
///
/// DST is a flat 3-byte-per-stitch binary format with a 512-byte ASCII
/// header. The bit layout implemented here (the "Tajima ternary" delta
/// encoding) is reverse-engineered public knowledge; this implementation's
/// exact bit weights were cross-checked against pyembroidery's DstReader.py
/// / DstWriter.py (MIT license, see FORMATS.md) to avoid re-deriving a
/// safety-critical byte layout from memory. The code below is an
/// independent Swift implementation, not a transliteration — variable
/// names, control flow and the coordinate-sign convention all differ (see
/// "Coordinate convention" below) — written this way so DSTReader and
/// DSTWriter in this file, plus the reference Python library, form three
/// genuinely independent implementations for the cross-validation in
/// StitchPilotCoreTests (spec: "never assume a file is correct merely
/// because writing completed successfully").
///
/// Coordinate convention: StitchPilot's internal `Point2D` uses Y-increases-
/// downward (matching SVG/CoreGraphics-bitmap convention used elsewhere in
/// the import pipeline). DST's on-disk deltas increase Y *upward* (machine
/// convention), so every Y is negated on the way out and back on the way
/// in. This was originally written without the flip on the belief that
/// pyembroidery's internal model is Y-up; it is Y-down like ours (its PEC
/// code applies no flip, and PEC is Y-down), which is why pyembroidery's
/// DstWriter negates Y and so must we. Confirmed against a professionally
/// digitized design supplied as both DST and PES: the same feature sits at
/// y = +261 in the DST and y = -261 in the PES. Without the flip every
/// exported DST sewed upside-down (mirrored top to bottom).
public enum DSTFormatError: Error, LocalizedError {
    case deltaOutOfRange(dx: Double, dy: Double)
    case truncatedRecord
    case emptyPattern

    public var errorDescription: String? {
        switch self {
        case .deltaOutOfRange(let dx, let dy):
            return "Stitch or jump moves \(dx)mm, \(dy)mm in one step — exceeds DST's ±12.1mm per-record limit. The engine should have split this into multiple jumps before export."
        case .truncatedRecord:
            return "DST file ended mid-record (a stitch record must be exactly 3 bytes)."
        case .emptyPattern:
            return "Pattern has no stitches to export."
        }
    }
}

public enum DSTFormat {
    /// Native DST unit: 0.1mm. Max representable delta per record is ±121 units (±12.1mm).
    public static let unitsPerMM = 10.0
    public static let maxDeltaUnits = 121

    // MARK: - Writing

    public static func write(_ plan: StitchPlan, designName: String) throws -> Data {
        guard !plan.commands.isEmpty else { throw DSTFormatError.emptyPattern }

        var body = Data()
        // Tracked in integer 0.1mm units, not Double mm: each absolute
        // target is quantized to the nearest unit independently, and the
        // running position is advanced by exactly that quantized amount
        // (never by the unquantized float target). That keeps every
        // stitch's error bounded to at most half a unit (0.05mm)
        // regardless of stitch count. Computing each delta from exact float
        // positions instead (current = target, in mm) lets independent
        // per-record rounding remainders accumulate over hundreds of
        // stitches into visible drift — exactly the bug this replaced.
        var currentX = 0
        var currentY = 0
        var stitchCount = 0
        var colorChangeCount = 0

        func moveTo(_ target: Point2D, jump: Bool) throws {
            let targetX = Int((target.x * unitsPerMM).rounded())
            let targetY = Int((-target.y * unitsPerMM).rounded()) // DST is Y-up; see the coordinate note above
            try emitDeltaUnitsSplitIfNeeded(targetX - currentX, targetY - currentY, jump: jump, into: &body)
            currentX = targetX
            currentY = targetY
            if !jump { stitchCount += 1 }
        }

        for command in plan.commands {
            switch command {
            case .stitch(let p):
                try moveTo(p, jump: false)
            case .jump(let p):
                try moveTo(p, jump: true)
            case .colorChange:
                body.append(contentsOf: [0, 0, 0b1100_0011])
                colorChangeCount += 1
            case .stop:
                body.append(contentsOf: [0, 0, 0b1100_0011])
            case .trim:
                // No native trim byte; 3 small jumps summing to zero net
                // movement is the widely-supported "trim jiggle" convention
                // most machines/software interpret as an explicit trim.
                try body.append(contentsOf: emitRecord(dx: 2, dy: 2, jump: true))
                try body.append(contentsOf: emitRecord(dx: -4, dy: -4, jump: true))
                try body.append(contentsOf: emitRecord(dx: 2, dy: 2, jump: true))
            case .end:
                break // written explicitly below
            }
        }
        body.append(contentsOf: [0, 0, 0b1111_0011]) // end of design

        let box = plan.boundingBox
        let header = makeHeader(designName: designName, stitchCount: stitchCount,
                                 colorChangeCount: colorChangeCount, box: box,
                                 lastPoint: Point2D(Double(currentX) / unitsPerMM, Double(currentY) / unitsPerMM))
        return header + body
    }

    /// Splits a delta larger than the per-record range into multiple
    /// max-sized jump records plus a final remainder record, so the engine
    /// never has to reason about the 12.1mm DST limit directly.
    private static func emitDeltaUnitsSplitIfNeeded(_ dx: Int, _ dy: Int, jump: Bool, into data: inout Data) throws {
        var dxUnits = dx
        var dyUnits = dy

        if !jump, abs(dxUnits) <= maxDeltaUnits, abs(dyUnits) <= maxDeltaUnits {
            data.append(contentsOf: try emitRecord(dx: dxUnits, dy: dyUnits, jump: false))
            return
        }

        // For jumps (and any stitch delta exceeding range, which the
        // digitizing engine should avoid but we defend against anyway),
        // walk the distance in maximal steps as jumps.
        while abs(dxUnits) > maxDeltaUnits || abs(dyUnits) > maxDeltaUnits {
            let stepX = max(-maxDeltaUnits, min(maxDeltaUnits, dxUnits))
            let stepY = max(-maxDeltaUnits, min(maxDeltaUnits, dyUnits))
            // Scale the smaller axis proportionally so the step stays on a straight line.
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
            throw DSTFormatError.deltaOutOfRange(dx: Double(dx) / unitsPerMM, dy: Double(dy) / unitsPerMM)
        }
        var b0: UInt8 = 0, b1: UInt8 = 0, b2: UInt8 = 0
        var x = dx, y = dy

        func setBit(_ byte: inout UInt8, _ pos: Int) { byte |= (1 << pos) }

        if x > 40 { setBit(&b2, 2); x -= 81 }
        if x < -40 { setBit(&b2, 3); x += 81 }
        if x > 13 { setBit(&b1, 2); x -= 27 }
        if x < -13 { setBit(&b1, 3); x += 27 }
        if x > 4 { setBit(&b0, 2); x -= 9 }
        if x < -4 { setBit(&b0, 3); x += 9 }
        if x > 1 { setBit(&b1, 0); x -= 3 }
        if x < -1 { setBit(&b1, 1); x += 3 }
        if x > 0 { setBit(&b0, 0); x -= 1 }
        if x < 0 { setBit(&b0, 1); x += 1 }

        if y > 40 { setBit(&b2, 5); y -= 81 }
        if y < -40 { setBit(&b2, 4); y += 81 }
        if y > 13 { setBit(&b1, 5); y -= 27 }
        if y < -13 { setBit(&b1, 4); y += 27 }
        if y > 4 { setBit(&b0, 5); y -= 9 }
        if y < -4 { setBit(&b0, 4); y += 9 }
        if y > 1 { setBit(&b1, 7); y -= 3 }
        if y < -1 { setBit(&b1, 6); y += 3 }
        if y > 0 { setBit(&b0, 7); y -= 1 }
        if y < 0 { setBit(&b0, 6); y += 1 }

        setBit(&b2, 0); setBit(&b2, 1) // always-set flag bits for a coordinate record
        if jump { setBit(&b2, 7) }
        return [b0, b1, b2]
    }

    private static func makeHeader(designName: String, stitchCount: Int, colorChangeCount: Int,
                                    box: BoundingBox, lastPoint: Point2D) -> Data {
        func field(_ s: String) -> Data { s.data(using: .ascii) ?? s.data(using: .utf8)! }

        let name = String(designName.prefix(16))
        var s = ""
        s += "LA:\(name.padding(toLength: 16, withPad: " ", startingAt: 0))\r"
        s += "ST:\(pad(stitchCount, 7))\r"
        s += "CO:\(pad(colorChangeCount, 3))\r"
        let maxX = box.isEmpty ? 0 : Int((box.maxX * unitsPerMM).rounded())
        let minX = box.isEmpty ? 0 : Int((box.minX * unitsPerMM).rounded())
        // Header extents describe the file's own (Y-up) coordinates.
        let maxY = box.isEmpty ? 0 : Int((-box.minY * unitsPerMM).rounded())
        let minY = box.isEmpty ? 0 : Int((-box.maxY * unitsPerMM).rounded())
        s += "+X:\(pad(abs(maxX), 5))\r"
        s += "-X:\(pad(abs(minX), 5))\r"
        s += "+Y:\(pad(abs(maxY), 5))\r"
        s += "-Y:\(pad(abs(minY), 5))\r"
        let ax = Int((lastPoint.x * unitsPerMM).rounded())
        let ay = Int((-lastPoint.y * unitsPerMM).rounded())
        s += "AX:\(signedPad(ax, 5))\r"
        s += "AY:\(signedPad(ay, 5))\r"
        s += "MX:\(signedPad(0, 5))\r"
        s += "MY:\(signedPad(0, 5))\r"
        s += "PD:******\r"

        var data = field(s)
        data.append(0x1A)
        while data.count < 512 { data.append(0x20) }
        return data
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    private static func signedPad(_ n: Int, _ width: Int) -> String {
        let sign = n < 0 ? "-" : "+"
        return sign + pad(abs(n), width)
    }

    // MARK: - Reading (independent decode path, used for export self-validation)

    public struct DecodedPattern {
        public var commands: [StitchCommand]
        public var name: String?
    }

    public static func read(_ data: Data) throws -> DecodedPattern {
        guard data.count >= 512 else { throw DSTFormatError.truncatedRecord }
        let header = data.prefix(512)
        let name = parseHeaderField(header, key: "LA")

        var commands: [StitchCommand] = []
        var current = Point2D.zero
        var index = data.index(data.startIndex, offsetBy: 512)
        while data.distance(from: index, to: data.endIndex) >= 3 {
            let b0 = data[index], b1 = data[data.index(after: index)], b2 = data[data.index(index, offsetBy: 2)]
            index = data.index(index, offsetBy: 3)

            if b2 & 0b1111_0011 == 0b1111_0011 {
                commands.append(.end)
                break
            }
            let dx = Double(decodeAxis(b0: b0, b1: b1, b2: b2, isY: false)) / unitsPerMM
            let dy = Double(decodeAxis(b0: b0, b1: b1, b2: b2, isY: true)) / unitsPerMM
            current = Point2D(current.x + dx, current.y - dy) // file Y-up -> internal Y-down

            if b2 & 0b1100_0011 == 0b1100_0011 {
                commands.append(.colorChange)
            } else if b2 & 0b1000_0011 == 0b1000_0011 {
                commands.append(.jump(current))
            } else {
                commands.append(.stitch(current))
            }
        }
        return DecodedPattern(commands: commands, name: name)
    }

    private static func decodeAxis(b0: UInt8, b1: UInt8, b2: UInt8, isY: Bool) -> Int {
        func bit(_ b: UInt8, _ pos: Int) -> Int { Int((b >> pos) & 1) }
        if isY {
            var y = 0
            y += bit(b2, 5) * 81; y -= bit(b2, 4) * 81
            y += bit(b1, 5) * 27; y -= bit(b1, 4) * 27
            y += bit(b0, 5) * 9;  y -= bit(b0, 4) * 9
            y += bit(b1, 7) * 3;  y -= bit(b1, 6) * 3
            y += bit(b0, 7) * 1;  y -= bit(b0, 6) * 1
            return y
        } else {
            var x = 0
            x += bit(b2, 2) * 81; x -= bit(b2, 3) * 81
            x += bit(b1, 2) * 27; x -= bit(b1, 3) * 27
            x += bit(b0, 2) * 9;  x -= bit(b0, 3) * 9
            x += bit(b1, 0) * 3;  x -= bit(b1, 1) * 3
            x += bit(b0, 0) * 1;  x -= bit(b0, 1) * 1
            return x
        }
    }

    private static func parseHeaderField(_ header: Data.SubSequence, key: String) -> String? {
        guard let text = String(data: header, encoding: .ascii) ?? String(data: header, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") {
                return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
