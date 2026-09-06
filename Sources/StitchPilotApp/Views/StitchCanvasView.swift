import SwiftUI
import StitchPilotCore

/// Two preview modes, switchable at any time once a stitch plan exists:
/// "Technical" draws the artwork's object outlines and the generated stitch
/// path as thin wireframe lines (solid for needle-down stitches, dashed for
/// jumps) — useful for verifying individual stitch placement. "Realistic"
/// renders the same plan through `StitchRenderer`'s thread simulation (spec
/// §41 "let the user see what the embroidered file will look like before
/// finalizing") so the canvas shows an approximation of the actual sewn-out
/// result rather than a technical diagram.
enum StitchPreviewMode: String, CaseIterable, Identifiable {
    case technical = "Technical"
    case realistic = "Realistic"
    var id: String { rawValue }
}

struct StitchCanvasView: View {
    let document: StitchDocument?
    let stitchPlan: StitchPlan?
    /// The plan's per-run color sequence, computed once alongside it (see
    /// `AppState.autoDigitize`/`DigitizePipeline.flattenWithColors`) and
    /// passed in rather than recomputed here — recomputing it means redoing
    /// the whole per-object generation pass again just for colors, real
    /// user-visible latency for a design with many objects.
    var colors: [ThreadColor] = []
    var hoop: HoopProfile?
    /// The object currently selected in the object list, highlighted in the
    /// canvas so the user can see which shape they're working on.
    var selectedObjectID: EmbroideryObject.ID?
    /// Called with the tapped object's id, or nil when the tap missed every
    /// object -- lets the user click directly on a shape to select it, the
    /// same selection the object list's own row-tap already produces.
    var onSelectObject: (EmbroideryObject.ID?) -> Void = { _ in }

    @State private var mode: StitchPreviewMode = .realistic
    @State private var realisticImage: CGImage?
    @State private var renderedSignature: Int?

    /// Pinch-to-zoom + click-drag-to-pan state, so the user can inspect any
    /// part of the design up close rather than only ever seeing it fit to
    /// the window. Zoom is centered on the canvas's own center (where the
    /// design/hoop frame is already centered by construction below), so
    /// pinching in place feels natural instead of drifting toward a corner.
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var showGrid = false

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard let document, let transform = computeTransform(document: document, size: size) else { return }
                let effectiveScale = transform.scale
                let centerX = transform.centerX
                let centerY = transform.centerY

                func toView(_ p: Point2D) -> CGPoint {
                    CGPoint(x: centerX + (p.x - document.physicalWidthMM / 2) * effectiveScale,
                            y: centerY + (p.y - document.physicalHeightMM / 2) * effectiveScale)
                }

                // Design bounding box, for scale reference.
                let boundsRect = CGRect(x: centerX - CGFloat(document.physicalWidthMM / 2) * effectiveScale,
                                         y: centerY - CGFloat(document.physicalHeightMM / 2) * effectiveScale,
                                         width: document.physicalWidthMM * effectiveScale, height: document.physicalHeightMM * effectiveScale)
                context.stroke(Path(boundsRect), with: .color(.gray.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                if let hoop {
                    // Drawn as a rectangle regardless of the hoop's physical
                    // shape (round/oval/rectangular hoops all exist) --
                    // what matters here is the usable sewing field's W x H,
                    // which is how hoops are actually specified.
                    let designFits = document.physicalWidthMM <= hoop.widthMM && document.physicalHeightMM <= hoop.heightMM
                    let hoopRect = CGRect(x: centerX - CGFloat(hoop.widthMM) * effectiveScale / 2, y: centerY - CGFloat(hoop.heightMM) * effectiveScale / 2,
                                           width: CGFloat(hoop.widthMM) * effectiveScale, height: CGFloat(hoop.heightMM) * effectiveScale)
                    context.stroke(Path(hoopRect), with: .color(designFits ? .blue.opacity(0.6) : .red.opacity(0.8)),
                                    style: StrokeStyle(lineWidth: 1.5))
                }

                guard let stitchPlan else {
                    // No plan yet -- nothing to preview realistically, so
                    // always show the artwork reference fill regardless of mode.
                    drawArtworkFill(document, context: context, toView: toView, opacity: 0.85)
                    if showGrid { drawSizeGrid(document, context: context, toView: toView, effectiveScale: effectiveScale) }
                    drawSelectionHighlight(document, context: context, toView: toView)
                    return
                }

                if mode == .realistic, let realisticImage {
                    context.draw(Image(decorative: realisticImage, scale: 1, orientation: .up), in: boundsRect)
                    if showGrid { drawSizeGrid(document, context: context, toView: toView, effectiveScale: effectiveScale) }
                    drawSelectionHighlight(document, context: context, toView: toView)
                    return
                }

                drawArtworkFill(document, context: context, toView: toView, opacity: 0.12)

                var colorIndex = 0
                var currentColor = colorFor(index: 0)
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
                        currentColor = colorFor(index: colorIndex)
                        lastPoint = nil
                    case .trim, .stop:
                        // Thread's cut here -- don't let the next point draw
                        // a spurious line back to wherever it was last cut.
                        lastPoint = nil
                    case .end:
                        break
                    }
                }
                flushStitchPath()
                context.stroke(jumpPath, with: .color(.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 2]))
                if showGrid { drawSizeGrid(document, context: context, toView: toView, effectiveScale: effectiveScale) }
                drawSelectionHighlight(document, context: context, toView: toView)
            }
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in selectObject(at: value.location, in: geo.size) }
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .gesture(
            MagnificationGesture()
                .onChanged { value in zoomScale = clampZoom(lastZoomScale * value) }
                .onEnded { _ in
                    lastZoomScale = zoomScale
                    if zoomScale <= 1.0 { panOffset = .zero; lastPanOffset = .zero }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard zoomScale > 1.01 else { return }
                    panOffset = CGSize(width: lastPanOffset.width + value.translation.width,
                                        height: lastPanOffset.height + value.translation.height)
                }
                .onEnded { _ in lastPanOffset = panOffset }
        )
        .overlay(alignment: .top) {
            if stitchPlan != nil {
                Picker("Preview", selection: $mode) {
                    ForEach(StitchPreviewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if document != nil {
                VStack(spacing: 8) {
                    Toggle(isOn: $showGrid) {
                        Image(systemName: "grid")
                    }
                    .toggleStyle(.button)
                    .help("Show a size grid, in centimeters, over the preview.")

                    Divider().frame(width: 22)

                    Button { setZoom(zoomScale + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Zoom in")
                    Text("\(Int(zoomScale * 100))%")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    Button { setZoom(zoomScale - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Zoom out")
                    Button { resetZoom() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                        .help("Reset zoom")
                        .disabled(zoomScale == 1 && panOffset == .zero)
                }
                .buttonStyle(.borderless)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            }
        }
        .onAppear { regenerateRealisticImageIfNeeded() }
        .onChange(of: mode) { _ in regenerateRealisticImageIfNeeded() }
        .onChange(of: planSignature) { _ in regenerateRealisticImageIfNeeded() }
        .onChange(of: document?.name) { _ in resetZoom() }
    }

    private struct CanvasTransform {
        var scale: CGFloat
        var centerX: CGFloat
        var centerY: CGFloat
    }

    /// The same fit-to-view + zoom/pan math the `Canvas` draw pass uses,
    /// pulled out so hit-testing (`selectObject`) can convert a click back
    /// to document-space coordinates with the exact same transform that put
    /// the shapes on screen -- computing this twice, slightly differently,
    /// would make clicks land on the wrong object right at the edges.
    private func computeTransform(document: StitchDocument, size: CGSize) -> CanvasTransform? {
        guard document.physicalWidthMM > 0, document.physicalHeightMM > 0 else { return nil }
        let margin: CGFloat = 24
        let availableW = size.width - margin * 2
        let availableH = size.height - margin * 2
        // Fit whichever is larger, the design or the hoop, so a hoop bigger
        // than the design (the common case) still shows the full hoop, and
        // an oversized design against a small hoop still shows how much it
        // overflows (spec §36).
        let frameW = max(document.physicalWidthMM, hoop?.widthMM ?? 0)
        let frameH = max(document.physicalHeightMM, hoop?.heightMM ?? 0)
        let fitScale = min(availableW / frameW, availableH / frameH)
        return CanvasTransform(scale: fitScale * zoomScale,
                                centerX: margin + availableW / 2 + panOffset.width,
                                centerY: margin + availableH / 2 + panOffset.height)
    }

    /// Hit-tests a click against every object's shape (even-odd across its
    /// subpaths, so a click inside a hole -- a letter's counter -- correctly
    /// misses), topmost-drawn object first since later objects are drawn
    /// over earlier ones. A click that misses everything deselects, the
    /// same as clicking empty canvas does in other design tools.
    private func selectObject(at location: CGPoint, in size: CGSize) {
        guard let document, let transform = computeTransform(document: document, size: size) else { return }
        let docPoint = Point2D((location.x - transform.centerX) / transform.scale + document.physicalWidthMM / 2,
                                (location.y - transform.centerY) / transform.scale + document.physicalHeightMM / 2)
        for object in document.objects.reversed() {
            let polygons = object.shape.subPaths.map { $0.points }
            if PolygonGeometry.pointInPolygons(docPoint, polygons: polygons) {
                onSelectObject(object.id)
                return
            }
        }
        onSelectObject(nil)
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat { min(max(value, 1.0), 8.0) }

    private func setZoom(_ value: CGFloat) {
        zoomScale = clampZoom(value)
        lastZoomScale = zoomScale
        if zoomScale <= 1.0 { panOffset = .zero; lastPanOffset = .zero }
    }

    private func resetZoom() {
        zoomScale = 1.0
        lastZoomScale = 1.0
        panOffset = .zero
        lastPanOffset = .zero
    }

    /// A cheap stand-in for "has the plan actually changed" -- exact
    /// equality isn't needed here, just enough sensitivity that a real
    /// digitize re-run reliably invalidates the cached realistic render.
    private var planSignature: Int? {
        guard let stitchPlan else { return nil }
        return stitchPlan.commands.hashValue
    }

    private func regenerateRealisticImageIfNeeded() {
        guard mode == .realistic, let document, let stitchPlan, planSignature != renderedSignature else { return }
        realisticImage = StitchRenderer.render(stitchPlan, widthMM: document.physicalWidthMM, heightMM: document.physicalHeightMM, colors: colors)
        renderedSignature = planSignature
    }

    private func drawArtworkFill(_ document: StitchDocument, context: GraphicsContext, toView: (Point2D) -> CGPoint, opacity: Double) {
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
            context.fill(path, with: .color(swiftColor.opacity(opacity)))
        }
    }

    /// Outlines the selected object's shape in an accent color so the user
    /// can see which object the Object Inspector is currently editing,
    /// regardless of preview mode -- drawn last, on top of everything else,
    /// with a white halo underneath so it stays visible against any thread
    /// or background color.
    private func drawSelectionHighlight(_ document: StitchDocument, context: GraphicsContext, toView: (Point2D) -> CGPoint) {
        guard let selectedObjectID, let object = document.objects.first(where: { $0.id == selectedObjectID }) else { return }
        var path = Path()
        for subPath in object.shape.subPaths {
            guard let first = subPath.points.first else { continue }
            path.move(to: toView(first))
            for pt in subPath.points.dropFirst() { path.addLine(to: toView(pt)) }
            if subPath.closed { path.closeSubpath() }
        }
        context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 4.5, lineJoin: .round))
        context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round, dash: [6, 4]))
    }

    /// Overlays a size-reference grid across the design's own bounds (not
    /// the wider hoop frame -- the point is to gauge the design's own
    /// dimensions), labeled in centimeters to match the rest of the app's
    /// measurements. The step size adapts to the current zoom level so
    /// lines stay legibly spaced (roughly 28pt+ apart) whether zoomed out
    /// to fit the whole design or zoomed in on one corner of it.
    private func drawSizeGrid(_ document: StitchDocument, context: GraphicsContext, toView: (Point2D) -> CGPoint, effectiveScale: CGFloat) {
        let candidateStepsCM: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100]
        let stepCM = candidateStepsCM.first(where: { $0 * 10 * effectiveScale >= 28 }) ?? candidateStepsCM[candidateStepsCM.count - 1]
        let stepMM = stepCM * 10
        let lineColor = Color.gray.opacity(0.3)
        let labelColor = Color.secondary
        let widthMM = document.physicalWidthMM
        let heightMM = document.physicalHeightMM

        var x = 0.0
        while x <= widthMM + 0.001 {
            let top = toView(Point2D(x, 0))
            let bottom = toView(Point2D(x, heightMM))
            var path = Path()
            path.move(to: top)
            path.addLine(to: bottom)
            context.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: 0.6))
            context.draw(Text(formatCM(x / 10)).font(.system(size: 9)).foregroundColor(labelColor),
                         at: CGPoint(x: top.x, y: max(top.y - 8, 8)))
            x += stepMM
        }

        var y = 0.0
        while y <= heightMM + 0.001 {
            let left = toView(Point2D(0, y))
            let right = toView(Point2D(widthMM, y))
            var path = Path()
            path.move(to: left)
            path.addLine(to: right)
            context.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: 0.6))
            context.draw(Text(formatCM(y / 10)).font(.system(size: 9)).foregroundColor(labelColor),
                         at: CGPoint(x: max(left.x - 14, 14), y: left.y))
            y += stepMM
        }
    }

    private func formatCM(_ cm: Double) -> String {
        cm.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", cm) : String(format: "%.1f", cm)
    }

    /// `colors` is the actual per-run color sequence (see this type's
    /// `colors` property doc comment) -- indexing into it directly, rather
    /// than into `document.objects`, matters once `ObjectSequencer` has
    /// reordered objects relative to the document's own order.
    private func colorFor(index: Int) -> Color {
        guard !colors.isEmpty else { return .black }
        let color = colors[min(index, colors.count - 1)]
        return Color(red: Double(color.rgb.r) / 255, green: Double(color.rgb.g) / 255, blue: Double(color.rgb.b) / 255)
    }
}
