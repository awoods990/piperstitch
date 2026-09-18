// Raster preview rendering is a CoreGraphics concern. The Linux server
// build (see server/) never renders -- the browser draws the stitch plan
// itself -- so this whole file compiles only where CoreGraphics exists.
// On Apple platforms the code below is unchanged.
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// Renders a `StitchPlan` to a raster image approximating what the design
/// will actually look like sewn out, not a technical wireframe of stitch
/// points. This is both what the app's live canvas preview is built on
/// (spec: let the user see what the embroidered file will look like before
/// finalizing) and a standalone diagnostic tool for inspecting digitized
/// output without a GUI — `render(...)` returns a `CGImage` a SwiftUI view
/// can display directly, and `renderPNGData(...)` is the same thing encoded
/// to PNG bytes for command-line/test tooling.
///
/// The technique: stroke each individual stitch segment (not one merged
/// polyline per color run) at a real thread width with rounded caps/joins,
/// alternating a slightly darker/lighter shade every other stitch so
/// individual stitches actually read as separate threads rather than one
/// flat ribbon. Then stroke a thin, bright highlight over each segment
/// *offset perpendicular to that segment's own direction* (not down its
/// centerline) — a real thread is a cylinder, so its specular highlight
/// runs along one side of it, and which side that is rotates with the
/// thread's own direction; a centered highlight looks like a flat painted
/// stripe, an offset one reads as round. Overlapping thread-width strokes
/// still accumulate into a solid, woven-looking block wherever stitches are
/// dense (satin zigzags, fill rows), which is the real visual signature of
/// embroidery.
public enum StitchRenderer {
    public struct Options {
        /// Real machine embroidery thread is roughly 0.3-0.5mm in diameter
        /// (a common 40wt polyester is close to 0.3mm) — this is what makes
        /// stitches actually look like thread instead of a wireframe line.
        public var threadWidthMM: Double
        public var pixelsPerMM: Double
        public var backgroundColor: (r: Double, g: Double, b: Double)
        /// Trimmed jumps leave no visible thread; an untrimmed same-color
        /// jump does carry a thin strand, but real digitizing practice
        /// routes those to be short/hidden (see `HiddenTravelRouter`) —
        /// so a *realistic* render hides jump travel entirely by default.
        /// `showJumps` is for technical/debugging views only.
        public var showJumps: Bool

        public init(threadWidthMM: Double = 0.35, pixelsPerMM: Double = 12,
                    backgroundColor: (r: Double, g: Double, b: Double) = (0.97, 0.96, 0.94), showJumps: Bool = false) {
            self.threadWidthMM = threadWidthMM
            self.pixelsPerMM = pixelsPerMM
            self.backgroundColor = backgroundColor
            self.showJumps = showJumps
        }
    }

    /// Renders `plan` at `widthMM` x `heightMM` (the document's physical
    /// size — stitch coordinates are in the same mm space). `colors` must
    /// be the actual per-run color sequence — `DigitizePipeline.
    /// colorSequence(for:)` — not guessed from a document's raw object
    /// order, since `ObjectSequencer` can reorder objects relative to that.
    /// `RGBColor.isPreviewGround`, kept here for the renderer's callers.
    public static func isPreviewGround(_ color: RGBColor) -> Bool { color.isPreviewGround }

    public static func render(_ plan: StitchPlan, widthMM: Double, heightMM: Double, colors: [ThreadColor], options: Options = Options()) -> CGImage? {
        let pxWidth = max(1, Int((widthMM * options.pixelsPerMM).rounded()))
        let pxHeight = max(1, Int((heightMM * options.pixelsPerMM).rounded()))
        guard let ctx = CGContext(data: nil, width: pxWidth, height: pxHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        ctx.setFillColor(red: CGFloat(options.backgroundColor.r), green: CGFloat(options.backgroundColor.g), blue: CGFloat(options.backgroundColor.b), alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight))

        let scale = CGFloat(options.pixelsPerMM)
        // Stitch coordinates are Y-down (design/SVG convention throughout
        // this codebase); CGContext's default drawing space is Y-up, so
        // flip once here rather than negating every point.
        ctx.translateBy(x: 0, y: CGFloat(pxHeight))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let threadWidthPt = CGFloat(options.threadWidthMM)
        let highlightWidthPt = threadWidthPt * 0.35

        var colorIndex = 0
        var currentColor = colors.first?.rgb ?? RGBColor(hex: 0x000000)
        var lastPoint: CGPoint?
        // Two shade buckets (alternating per stitch) instead of one merged
        // path, so consecutive stitches read as distinct threads rather
        // than a flat ribbon; a separate highlight path holds each
        // segment's own perpendicular-offset sheen line (see the type doc
        // comment on why it's offset rather than centered).
        var darkPath = CGMutablePath()
        var lightPath = CGMutablePath()
        var highlightPath = CGMutablePath()
        let jumpPath = CGMutablePath()
        var segmentParity = false
        var hasStitchSegment = false

        func flushStitchPath() {
            guard hasStitchSegment else { return }
            let r = CGFloat(currentColor.r) / 255, g = CGFloat(currentColor.g) / 255, b = CGFloat(currentColor.b) / 255

            ctx.addPath(darkPath)
            ctx.setStrokeColor(red: r * 0.88, green: g * 0.88, blue: b * 0.88, alpha: 1)
            ctx.setLineWidth(threadWidthPt)
            ctx.strokePath()

            ctx.addPath(lightPath)
            ctx.setStrokeColor(red: min(1, r * 1.08 + 0.02), green: min(1, g * 1.08 + 0.02), blue: min(1, b * 1.08 + 0.02), alpha: 1)
            ctx.setLineWidth(threadWidthPt)
            ctx.strokePath()

            ctx.addPath(highlightPath)
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.4)
            ctx.setLineWidth(highlightWidthPt)
            ctx.strokePath()

            darkPath = CGMutablePath()
            lightPath = CGMutablePath()
            highlightPath = CGMutablePath()
            hasStitchSegment = false
        }

        for command in plan.commands {
            switch command {
            case .stitch(let p):
                let cp = CGPoint(x: p.x, y: p.y)
                if let last = lastPoint {
                    (segmentParity ? lightPath : darkPath).addLines(between: [last, cp])
                    segmentParity.toggle()

                    let dx = cp.x - last.x, dy = cp.y - last.y
                    let len = (dx * dx + dy * dy).squareRoot()
                    if len > 0.0001 {
                        // Perpendicular to this segment's own direction,
                        // offset toward one consistent side (a thread's
                        // sheen runs along whichever side faces the light,
                        // which rotates with the thread but stays on one
                        // side of it) -- not centered on the stitch.
                        let nx = -dy / len, ny = dx / len
                        let offset = CGFloat(options.threadWidthMM) * 0.2
                        let a = CGPoint(x: last.x + nx * offset, y: last.y + ny * offset)
                        let b = CGPoint(x: cp.x + nx * offset, y: cp.y + ny * offset)
                        highlightPath.addLines(between: [a, b])
                    }
                    hasStitchSegment = true
                }
                lastPoint = cp
            case .jump(let p):
                let cp = CGPoint(x: p.x, y: p.y)
                if options.showJumps, let last = lastPoint {
                    jumpPath.move(to: last)
                    jumpPath.addLine(to: cp)
                }
                lastPoint = cp
            case .colorChange:
                flushStitchPath()
                colorIndex += 1
                if colorIndex < colors.count { currentColor = colors[colorIndex].rgb }
                lastPoint = nil
            case .trim, .stop:
                // Thread's cut here -- the next point starts a new,
                // physically disconnected thread. Without this, the first
                // stitch of the next run would draw a spurious line all the
                // way back to wherever the thread was last cut.
                lastPoint = nil
            case .end:
                break
            }
        }
        flushStitchPath()

        if options.showJumps {
            ctx.addPath(jumpPath)
            ctx.setStrokeColor(gray: 0.5, alpha: 0.6)
            ctx.setLineWidth(max(0.1, threadWidthPt * 0.2))
            ctx.setLineDash(phase: 0, lengths: [threadWidthPt, threadWidthPt])
            ctx.strokePath()
        }

        return ctx.makeImage()
    }

    /// `render(...)`, encoded to PNG bytes — for command-line diagnostic
    /// tooling and automated visual regression checks, where there's no
    /// SwiftUI view to hand a `CGImage` to directly.
    public static func renderPNGData(_ plan: StitchPlan, widthMM: Double, heightMM: Double, colors: [ThreadColor], options: Options = Options()) -> Data? {
        guard let image = render(plan, widthMM: widthMM, heightMM: heightMM, colors: colors, options: options) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
#endif
