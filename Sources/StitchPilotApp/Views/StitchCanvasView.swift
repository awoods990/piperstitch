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

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard let document, document.physicalWidthMM > 0, document.physicalHeightMM > 0 else { return }
                let margin: CGFloat = 24
                let availableW = size.width - margin * 2
                let availableH = size.height - margin * 2
                let scale = min(availableW / document.physicalWidthMM, availableH / document.physicalHeightMM)
                let offsetX = margin + (availableW - document.physicalWidthMM * scale) / 2
                let offsetY = margin + (availableH - document.physicalHeightMM * scale) / 2

                func toView(_ p: Point2D) -> CGPoint {
                    CGPoint(x: offsetX + p.x * scale, y: offsetY + p.y * scale)
                }

                // Design bounding box, for scale reference.
                let boundsRect = CGRect(x: offsetX, y: offsetY,
                                         width: document.physicalWidthMM * scale, height: document.physicalHeightMM * scale)
                context.stroke(Path(boundsRect), with: .color(.gray.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

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
