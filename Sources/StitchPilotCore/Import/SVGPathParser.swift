import Foundation

/// Parses an SVG path `d` attribute into flattened `SubPath`s (curves are
/// subdivided into line segments — see Geometry.swift for why that's the
/// chosen representation). Supports M/L/H/V/C/S/Q/T/A/Z in both absolute and
/// relative form. Skew transforms and `use`/`symbol` reuse are not yet
/// supported (tracked in CHANGELOG.md as a known Phase-1 limitation).
struct SVGPathParser {
    private let scan: Scanner
    private let transform: AffineTransform2D
    private var subPaths: [SubPath] = []
    private var currentPoints: [Point2D] = []
    private var current = Point2D.zero          // untransformed, path-local space
    private var subPathStart = Point2D.zero
    private var lastControl: Point2D?            // for smooth S/T reflection, path-local space
    private var lastCommand: Character?

    /// Segments used to flatten one bezier curve. Fixed-resolution rather
    /// than adaptive-flatness for Phase 1 simplicity; fine enough that a
    /// curve spanning a typical few-cm logo shows no visible faceting.
    private static let curveSegments = 28
    private static let arcSegments = 48

    init(_ d: String, transform: AffineTransform2D) {
        self.scan = Scanner(string: d)
        self.transform = transform
    }

    mutating func parse() -> [SubPath] {
        while !scan.isAtEnd {
            scan.charactersToBeSkipped = .whitespacesAndNewlines
            guard let cmdChar = scan.scanCharacter() else { break }
            guard cmdChar.isLetter else { continue }
            execute(cmdChar)
        }
        flushSubPath(closed: false)
        return subPaths
    }

    private mutating func execute(_ command: Character) {
        let relative = command.isLowercase
        switch command.lowercased().first! {
        case "m":
            let p = readPoint()
            flushSubPath(closed: false)
            current = relative && lastCommand != nil ? current + p : p
            subPathStart = current
            currentPoints = [current]
            lastControl = nil
            consumeImplicitLineTos(relative: relative)
        case "l":
            while let p = tryReadPoint() {
                current = relative ? current + p : p
                appendCurrent()
            }
            lastControl = nil
        case "h":
            while let x = tryReadNumber() {
                current = Point2D(relative ? current.x + x : x, current.y)
                appendCurrent()
            }
            lastControl = nil
        case "v":
            while let y = tryReadNumber() {
                current = Point2D(current.x, relative ? current.y + y : y)
                appendCurrent()
            }
            lastControl = nil
        case "c":
            while let c1 = tryReadPoint() {
                let c2 = readPoint(), end = readPoint()
                let base = relative ? current : Point2D.zero
                appendCubic(c1: base + c1, c2: base + c2, end: base + end)
            }
        case "s":
            while let c2raw = tryReadPoint() {
                let end = readPoint()
                let base = relative ? current : Point2D.zero
                let c1 = lastControl.map { current + (current - $0) } ?? current
                appendCubic(c1: c1, c2: base + c2raw, end: base + end)
            }
        case "q":
            while let c1 = tryReadPoint() {
                let end = readPoint()
                let base = relative ? current : Point2D.zero
                appendQuadratic(c1: base + c1, end: base + end)
            }
        case "t":
            while let endRaw = tryReadPoint() {
                let base = relative ? current : Point2D.zero
                let c1 = lastControl.map { current + (current - $0) } ?? current
                appendQuadratic(c1: c1, end: base + endRaw)
            }
        case "a":
            while let radii = tryReadPoint() {
                let rot = readNumber()
                let largeArc = readFlag()
                let sweep = readFlag()
                let end = readPoint()
                let endAbs = relative ? current + end : end
                appendArc(rx: radii.x, ry: radii.y, rotationDeg: rot, largeArc: largeArc, sweep: sweep, end: endAbs)
                current = endAbs
                appendCurrent()
            }
            lastControl = nil
        case "z":
            flushSubPath(closed: true)
            current = subPathStart
            currentPoints = [current]
        default:
            break
        }
        lastCommand = command
    }

    /// After an `M`, any additional coordinate pairs are implicit `L` commands.
    private mutating func consumeImplicitLineTos(relative: Bool) {
        while let p = tryReadPoint() {
            current = relative ? current + p : p
            appendCurrent()
        }
    }

    private mutating func appendCurrent() {
        currentPoints.append(current)
    }

    private mutating func appendCubic(c1: Point2D, c2: Point2D, end: Point2D) {
        let p0 = current
        for i in 1...Self.curveSegments {
            let t = Double(i) / Double(Self.curveSegments)
            currentPoints.append(cubicBezier(p0, c1, c2, end, t))
        }
        current = end
        lastControl = c2
    }

    private mutating func appendQuadratic(c1: Point2D, end: Point2D) {
        let p0 = current
        for i in 1...Self.curveSegments {
            let t = Double(i) / Double(Self.curveSegments)
            currentPoints.append(quadraticBezier(p0, c1, end, t))
        }
        current = end
        lastControl = c1
    }

    private func cubicBezier(_ p0: Point2D, _ p1: Point2D, _ p2: Point2D, _ p3: Point2D, _ t: Double) -> Point2D {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return Point2D(a * p0.x + b * p1.x + c * p2.x + d * p3.x, a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    private func quadraticBezier(_ p0: Point2D, _ p1: Point2D, _ p2: Point2D, _ t: Double) -> Point2D {
        let mt = 1 - t
        let a = mt * mt, b = 2 * mt * t, c = t * t
        return Point2D(a * p0.x + b * p1.x + c * p2.x, a * p0.y + b * p1.y + c * p2.y)
    }

    /// SVG elliptical-arc endpoint-to-center parameterization (SVG 1.1 Appendix F.6).
    private mutating func appendArc(rx: Double, ry: Double, rotationDeg: Double, largeArc: Bool, sweep: Bool, end: Point2D) {
        let p1 = current, p2 = end
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 || p1 == p2 {
            currentPoints.append(p2)
            return
        }
        let phi = rotationDeg * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (p1.x - p2.x) / 2, dy2 = (p1.y - p2.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = lambda.squareRoot()
            rx *= s; ry *= s
        }

        let sign: Double = (largeArc != sweep) ? 1 : -1
        let num = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = den == 0 ? 0 : sign * (num / den).squareRoot()
        let cxp = coef * (rx * y1p) / ry
        let cyp = coef * -(ry * x1p) / rx

        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var ang = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { ang = -ang }
            return ang
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, dTheta > 0 { dTheta -= 2 * .pi }
        if sweep, dTheta < 0 { dTheta += 2 * .pi }

        for i in 1...Self.arcSegments {
            let t = theta1 + dTheta * Double(i) / Double(Self.arcSegments)
            let x = cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi
            let y = cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi
            currentPoints.append(Point2D(x, y))
        }
    }

    private mutating func flushSubPath(closed: Bool) {
        defer { currentPoints.removeAll() }
        guard currentPoints.count > 1 else { return }
        let transformed = currentPoints.map { transform.apply($0) }
        subPaths.append(SubPath(points: transformed, closed: closed))
    }

    // MARK: - Number scanning

    private mutating func tryReadNumber() -> Double? {
        scan.charactersToBeSkipped = CharacterSet(charactersIn: " \t\r\n,")
        let save = scan.currentIndex
        if let d = scan.scanDouble() { return d }
        scan.currentIndex = save
        return nil
    }

    private mutating func readNumber() -> Double { tryReadNumber() ?? 0 }

    private mutating func tryReadPoint() -> Point2D? {
        guard let x = tryReadNumber() else { return nil }
        let y = readNumber()
        return Point2D(x, y)
    }

    private mutating func readPoint() -> Point2D { tryReadPoint() ?? .zero }

    private mutating func readFlag() -> Bool {
        scan.charactersToBeSkipped = CharacterSet(charactersIn: " \t\r\n,")
        if let c = scan.scanCharacter() { return c == "1" }
        return false
    }
}
