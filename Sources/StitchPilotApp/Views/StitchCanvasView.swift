import SwiftUI
import StitchPilotCore

/// Phase 1 preview: draws the artwork's object outlines, and — once Auto
/// Digitize has run — the actual generated stitch path on top (solid lines
/// for needle-down stitches, dashed for jumps). Later phases add the
/// remaining preview modes from spec §41 (realistic thread, density
/// heatmap, sequence playback) as additional render passes here.
struct StitchCanvasView: View {
    let document: StitchDocument?
    let stitchPlan: StitchPlan?
    var hoop: HoopProfile?

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard let document, document.physicalWidthMM > 0, document.physicalHeightMM > 0 else { return }
                let margin: CGFloat = 24
                let availableW = size.width - margin * 2
                let availableH = size.height - margin * 2
                // Fit whichever is larger, the design or the hoop, so a
                // hoop bigger than the design (the common case) still shows
                // the full hoop, and an oversized design against a small
                // hoop still shows how much it overflows (spec §36).
                let frameW = max(document.physicalWidthMM, hoop?.widthMM ?? 0)
                let frameH = max(document.physicalHeightMM, hoop?.heightMM ?? 0)
                let scale = min(availableW / frameW, availableH / frameH)
                let centerX = margin + availableW / 2
                let centerY = margin + availableH / 2
                let offsetX = centerX - (document.physicalWidthMM / 2) * scale
                let offsetY = centerY - (document.physicalHeightMM / 2) * scale

                func toView(_ p: Point2D) -> CGPoint {
                    CGPoint(x: offsetX + p.x * scale, y: offsetY + p.y * scale)
                }

                // Design bounding box, for scale reference.
                let boundsRect = CGRect(x: offsetX, y: offsetY,
                                         width: document.physicalWidthMM * scale, height: document.physicalHeightMM * scale)
                context.stroke(Path(boundsRect), with: .color(.gray.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                if let hoop {
                    // Drawn as a rectangle regardless of the hoop's physical
                    // shape (round/oval/rectangular hoops all exist) --
                    // what matters here is the usable sewing field's W x H,
                    // which is how hoops are actually specified.
                    let designFits = document.physicalWidthMM <= hoop.widthMM && document.physicalHeightMM <= hoop.heightMM
                    let hoopRect = CGRect(x: centerX - CGFloat(hoop.widthMM) * scale / 2, y: centerY - CGFloat(hoop.heightMM) * scale / 2,
                                           width: CGFloat(hoop.widthMM) * scale, height: CGFloat(hoop.heightMM) * scale)
                    context.stroke(Path(hoopRect), with: .color(designFits ? .blue.opacity(0.6) : .red.opacity(0.8)),
                                    style: StrokeStyle(lineWidth: 1.5))
                }

                // Artwork reference (faint fill of each object's shape).
                for object in document.objects {
                    var path = Path()
                    for subPath in object.shape.subPaths {
                        guard let first = subPath.points.first else { continue }
                        path.move(to: toView(first))
                        for pt in subPath.points.dropFirst() { path.addLine(to: toView(pt)) }
                        if subPath.closed { path.closeSubpath() }
                    }
                    let swiftColor = Color(red: Double(object.threadColor.rgb.r) / 255,
                                            green: Double(object.threadColor.rgb.g) / 255,
                                            blue: Double(object.threadColor.rgb.b) / 255)
                    context.fill(path, with: .color(swiftColor.opacity(stitchPlan == nil ? 0.85 : 0.12)))
                }

                guard let stitchPlan else { return }

                var colorIndex = 0
                var currentColor = colorFor(document, index: 0)
                var lastPoint: CGPoint?
                var stitchPath = Path()
                var jumpPath = Path()

                func flushStitchPath() {
                    context.stroke(stitchPath, with: .color(currentColor), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    stitchPath = Path()
                }

                for command in stitchPlan.commands {
                    switch command {
                    case .stitch(let p):
                        let cp = toView(p)
                        if let last = lastPoint {
                            stitchPath.move(to: last)
                            stitchPath.addLine(to: cp)
                        }
                        lastPoint = cp
                    case .jump(let p):
                        let cp = toView(p)
                        if let last = lastPoint {
                            jumpPath.move(to: last)
                            jumpPath.addLine(to: cp)
                        }
                        lastPoint = cp
                    case .colorChange:
                        flushStitchPath()
                        colorIndex += 1
                        currentColor = colorFor(document, index: colorIndex)
                    case .trim, .stop, .end:
                        break
                    }
                }
                flushStitchPath()
                context.stroke(jumpPath, with: .color(.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 2]))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func colorFor(_ document: StitchDocument, index: Int) -> Color {
        guard !document.objects.isEmpty else { return .black }
        let obj = document.objects[min(index, document.objects.count - 1)]
        return Color(red: Double(obj.threadColor.rgb.r) / 255,
                      green: Double(obj.threadColor.rgb.g) / 255,
                      blue: Double(obj.threadColor.rgb.b) / 255)
    }
}
