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
/// The technique: stroke each color run's stitch path at a real thread
/// width (not a thin 1px wireframe line) with rounded caps/joins, then
/// stroke it again, thinner and in a light, low-opacity overlay, straight
/// down the same centerline. Overlapping thread-width strokes accumulate
/// into a solid, woven-looking block wherever stitches are dense (satin
/// zigzags, fill rows) — which is exactly the visual signature of real
/// embroidery — and the second, lighter pass suggests the sheen of a round
/// thread catching the light, cheaply (the same path stroked twice, not a
/// per-segment gradient computation).
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
        let highlightWidthPt = threadWidthPt * 0.4

        var colorIndex = 0
        var currentColor = colors.first?.rgb ?? RGBColor(hex: 0x000000)
        var lastPoint: CGPoint?
        var stitchPath = CGMutablePath()
        let jumpPath = CGMutablePath()
        var hasStitchSegment = false

        func flushStitchPath() {
            guard hasStitchSegment else { return }
            ctx.addPath(stitchPath)
            ctx.setStrokeColor(red: CGFloat(currentColor.r) / 255, green: CGFloat(currentColor.g) / 255, blue: CGFloat(currentColor.b) / 255, alpha: 1)
            ctx.setLineWidth(threadWidthPt)
            ctx.strokePath()

            ctx.addPath(stitchPath)
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.35)
            ctx.setLineWidth(highlightWidthPt)
            ctx.strokePath()

            stitchPath = CGMutablePath()
            hasStitchSegment = false
        }

        for command in plan.commands {
            switch command {
            case .stitch(let p):
                let cp = CGPoint(x: p.x, y: p.y)
                if let last = lastPoint {
                    stitchPath.move(to: last)
                    stitchPath.addLine(to: cp)
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
