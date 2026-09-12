import SwiftUI
import AppKit
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
    /// Which edit generation `stitchPlan` was actually computed from
    /// (`AppState.stitchPlanGeneration`) -- an exact, cheap identity for
    /// "has the plan actually changed," replacing this view's previous
    /// `stitchPlan.commands.hashValue`-based signature (which could only
    /// ever be a probabilistic stand-in for equality, however unlikely a
    /// real collision was in practice).
    var stitchPlanGeneration: Int?
    /// The plan's per-run color sequence, computed once alongside it (see
    /// `AppState.autoDigitize`/`DigitizePipeline.flattenWithColors`) and
    /// passed in rather than recomputed here — recomputing it means redoing
    /// the whole per-object generation pass again just for colors, real
    /// user-visible latency for a design with many objects.
    var colors: [ThreadColor] = []
    var hoop: HoopProfile?
    /// Every object currently selected in the object list, highlighted in
    /// the canvas so the user can see which shapes they're working on --
    /// more than one when the user has rubber-band-, shift-, or
    /// command-selected several, e.g. to merge them.
    var selectedObjectIDs: Set<EmbroideryObject.ID> = []
    /// Called with the tapped object's id (added to or replacing the
    /// selection depending on shift/command), or an empty set when a plain tap
    /// missed every object -- lets the user click directly on a shape to
    /// select it, the same selection the object list's own row-tap already
    /// produces. Rubber-band drags go through this too.
    var onSelectionChange: (Set<EmbroideryObject.ID>) -> Void = { _ in }
    /// Whether the paint tool is active -- while true, click/drag draws a
    /// brush stroke (`onPaintStroke`) instead of selecting or panning.
    var isPaintMode: Bool = false
    var paintColor: Color = .black
    var paintBrushRadiusMM: Double = 1.5
    /// Called with a completed stroke's points, in document space (mm),
    /// once the user releases after painting.
    var onPaintStroke: ([Point2D]) -> Void = { _ in }
    /// Whether the delete pen is active -- mutually exclusive with
    /// `isPaintMode` (`AppState` itself enforces that neither is ever true
    /// while the other is), sharing the same click/drag gesture to erase
    /// coverage instead of adding it.
    var isEraseMode: Bool = false
    /// Called with a completed stroke's points, in document space (mm),
    /// once the user releases after erasing.
    var onEraseStroke: ([Point2D]) -> Void = { _ in }
    /// True while the on-screen stitch plan (and therefore the realistic
    /// bitmap) doesn't yet reflect the latest edit
    /// (`AppState.isPreviewStale`) -- distinct from `isRegeneratingPreview`
    /// (which only says a regenerate is *in flight*): this stays true for
    /// the entire gap between an edit and the moment its regenerate
    /// actually lands, including the debounce delay before that regenerate
    /// even starts. Used to visibly mark the stitch/realistic layer as not
    /// yet caught up, rather than silently drawing possibly-stale content
    /// as if it were current -- see `AppState.stitchPlanGeneration`'s doc
    /// comment for the exact "changed, then changed back" illusion this
    /// fixes.
    var isPreviewStale: Bool = false
    /// Called with (dxMM, dyMM) once the user finishes dragging an
    /// already-selected object (or group, e.g. a lettering group) to a new
    /// position -- clicking directly on a selected shape and dragging
    /// moves it, rather than starting a rubber-band selection.
    var onMoveSelection: (Double, Double) -> Void = { _, _ in }
    /// Called with the final scale factor and the fixed anchor point (the
    /// corner opposite whichever handle was dragged, in document mm) once
    /// the user finishes dragging a corner handle to resize the current
    /// selection.
    var onResizeSelection: (Double, Point2D) -> Void = { _, _ in }
    /// True while an edit's debounced stitch-plan regenerate is pending or
    /// running (`AppState.isRegeneratingPreview`) -- combined with this
    /// view's own realistic-bitmap render being in flight
    /// (`activeRealisticRenderCount`) to show one "Refreshing…" indicator
    /// covering the whole pipeline from edit to updated pixels, so a
    /// regenerate that takes a moment doesn't read as the app being stuck.
    var isRegeneratingPreview: Bool = false

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
    /// The canvas's own measured size, tracked so the realistic preview can
    /// be rendered at a resolution matched to how big the design actually
    /// appears on screen right now -- see `desiredPixelsPerMM`'s doc comment.
    @State private var canvasSize: CGSize = .zero
    /// The `pixelsPerMM` the current `realisticImage` was actually rendered
    /// at, so a zoom/resize can be compared against it and only trigger a
    /// re-render when the mismatch is large enough to matter.
    @State private var renderedPixelsPerMM: Double = 0
    /// The in-flight background render, if any -- cancelling and replacing
    /// this on every new `regenerateRealisticImageIfNeeded` call (mirroring
    /// `AppState.scheduleLiveRegenerate`/`liveRegenerateTask`'s already-
    /// proven pattern) is what lets a render superseded by a newer one
    /// detect that reliably via real `Task.isCancelled`, rather than an
    /// earlier version of this code's own hand-rolled "generation counter"
    /// comparison, which could let a stale render's result win the race and
    /// overwrite a newer one's -- the on-screen bitmap silently going stale
    /// until something else (switching preview mode and back) happened to
    /// trigger another regenerate attempt.
    @State private var renderTask: Task<Void, Never>?
    /// How many background bitmap renders are currently in flight -- shown
    /// as part of the "Refreshing…" indicator alongside
    /// `isRegeneratingPreview`. A count rather than a bool for the same
    /// reason `AppState.regenerateInFlightCount` is: an older render's own
    /// completion shouldn't be able to clear this while a newer one it
    /// overlapped with is still genuinely running.
    @State private var activeRealisticRenderCount = 0

    /// Rubber-band selection box, in view (canvas) coordinates, while a
    /// selection drag is in progress -- nil the rest of the time.
    @State private var rubberBandRect: CGRect?
    /// The in-progress paint stroke's points, in document space (mm), so
    /// the live preview and the final `onPaintStroke` callback both use
    /// the same coordinates the merge engine expects.
    @State private var currentStrokePoints: [Point2D] = []
    @State private var isDragActive = false

    /// Which of the four corners a selection's combined bounding box
    /// resize handle represents -- `opposite` is the corner that stays
    /// fixed in place while dragging this one, i.e. the scale anchor.
    private enum SelectionCorner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var opposite: SelectionCorner {
            switch self {
            case .topLeft: return .bottomRight
            case .topRight: return .bottomLeft
            case .bottomLeft: return .topRight
            case .bottomRight: return .topLeft
            }
        }
        func point(in box: BoundingBox) -> Point2D {
            switch self {
            case .topLeft: return Point2D(box.minX, box.minY)
            case .topRight: return Point2D(box.maxX, box.minY)
            case .bottomLeft: return Point2D(box.minX, box.maxY)
            case .bottomRight: return Point2D(box.maxX, box.maxY)
            }
        }
    }

    /// What a drag currently means, decided once at the start of each
    /// gesture (see `determineDragMode`) and held for its whole duration --
    /// except `.pan`/`.rubberBand`, which stay live every call so Option
    /// can be pressed or released mid-drag and it still does the right
    /// thing (unchanged from before move/resize existed).
    private enum CanvasDragMode {
        case pan
        case rubberBand
        case moveSelection
        case resizeSelection(anchorMM: Point2D, originalCornerMM: Point2D)
    }
    @State private var activeDragMode: CanvasDragMode?
    /// Live in-progress move offset, in document mm, drawn as a ghost
    /// outline of the selection during the drag -- the real objects aren't
    /// touched until `handleDragEnded` commits via `onMoveSelection`.
    @State private var liveMoveDeltaMM: (dx: Double, dy: Double) = (0, 0)
    /// Live in-progress resize scale factor, likewise only a ghost preview
    /// until commit via `onResizeSelection`.
    @State private var liveResizeScale: Double = 1.0
    /// A resize handle's hit-test radius in view points -- generous enough
    /// to grab reliably without needing pixel-perfect precision on a small
    /// glyph's corner.
    private let handleHitRadius: CGFloat = 9

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

                func drawOverlays() {
                    if showGrid { drawSizeGrid(document, context: context, toView: toView, effectiveScale: effectiveScale) }
                    drawSelectionHighlight(document, context: context, toView: toView)
                    if !isPaintMode, !isEraseMode {
                        drawLiveTransformGhost(document, context: context, toView: toView)
                        drawResizeHandles(document, context: context, toView: toView)
                    }
                    if (isPaintMode || isEraseMode), currentStrokePoints.count > 1 {
                        var path = Path()
                        path.move(to: toView(currentStrokePoints[0]))
                        for p in currentStrokePoints.dropFirst() { path.addLine(to: toView(p)) }
                        // The delete pen's live stroke is always drawn red
                        // regardless of the paint color picker, so a brush
                        // stroke visibly reads as "removing" rather than
                        // "adding" while it's still in progress.
                        let strokeColor = isEraseMode ? Color.red : paintColor
                        context.stroke(path, with: .color(strokeColor.opacity(0.55)),
                                       style: StrokeStyle(lineWidth: max(2, CGFloat(paintBrushRadiusMM * 2) * effectiveScale), lineCap: .round, lineJoin: .round))
                    }
                    if let rubberBandRect {
                        context.fill(Path(rubberBandRect), with: .color(.accentColor.opacity(0.12)))
                        context.stroke(Path(rubberBandRect), with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }

                guard let stitchPlan else {
                    // No plan yet -- nothing to preview realistically, so
                    // always show the artwork reference fill regardless of mode.
                    drawArtworkFill(document, context: context, toView: toView, opacity: 0.85)
                    drawOverlays()
                    return
                }

                // While the shown plan hasn't caught up to the latest edit
                // yet (`isPreviewStale`), dim it and raise the always-live
                // artwork outline underneath so the two layers read as
                // "still catching up" instead of silently disagreeing --
                // see `AppState.stitchPlanGeneration`'s doc comment for the
                // "changed, then changed back" illusion this replaces.
                let stitchLayerOpacity = isPreviewStale ? 0.4 : 1.0
                let liveOutlineOpacity = isPreviewStale ? 0.4 : 0.12

                if mode == .realistic, let realisticImage {
                    if isPreviewStale {
                        drawArtworkFill(document, context: context, toView: toView, opacity: liveOutlineOpacity)
                    }
                    drawRealisticLayer(realisticImage, into: &context, rect: boundsRect, opacity: stitchLayerOpacity)
                    drawOverlays()
                    return
                }

                drawArtworkFill(document, context: context, toView: toView, opacity: liveOutlineOpacity)

                var colorIndex = 0
                var currentColor = colorFor(index: 0)
                var lastPoint: CGPoint?
                var stitchPath = Path()
                var jumpPath = Path()

                func flushStitchPath() {
                    context.stroke(stitchPath, with: .color(currentColor.opacity(stitchLayerOpacity)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
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
                context.stroke(jumpPath, with: .color(.gray.opacity(0.5 * stitchLayerOpacity)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 2]))
                drawOverlays()
            }
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in handleTap(at: value.location, in: geo.size) }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in handleDragChanged(value, size: geo.size) }
                    .onEnded { value in handleDragEnded(value, size: geo.size) }
            )
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { canvasSize = $0 }
        }
        .background(PSColor.paper)
        .gesture(
            MagnificationGesture()
                .onChanged { value in zoomScale = clampZoom(lastZoomScale * value) }
                .onEnded { _ in
                    lastZoomScale = zoomScale
                    if zoomScale <= 1.0 { panOffset = .zero; lastPanOffset = .zero }
                }
        )
        .overlay(alignment: .topLeading) {
            // Both halves of the pipeline (AppState's stitch-plan
            // regenerate and this view's own realistic-bitmap render) run
            // in the background now rather than blocking the UI -- which
            // fixed the stall, but also means there's a real gap between
            // "you made an edit" and "the preview visibly caught up" that
            // used to not exist (the old synchronous version just froze
            // for that same span, which -- if anything -- made it obvious
            // something was happening). Surfacing that gap explicitly so
            // it doesn't read as the app being stuck.
            if isRegeneratingPreview || activeRealisticRenderCount > 0 || isPreviewStale {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Refreshing…").font(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .padding(8)
            }
        }
        .overlay(alignment: .top) {
            if stitchPlan != nil {
                Picker("Mode", selection: $mode) {
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
        .overlay(alignment: .top) {
            if isPaintMode {
                Text(selectedObjectIDs.count == 1 ? "Painting extends the selected object" : "Painting creates a new shape")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 44)
            } else if isEraseMode {
                Text("Erasing removes coverage from whatever the stroke touches")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 44)
            } else if zoomScale > 1.01 {
                Text("Drag to select \u{2022} Option-drag to pan")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 44)
            }
        }
        .onAppear { regenerateRealisticImageIfNeeded() }
        .onChange(of: mode) { _ in regenerateRealisticImageIfNeeded() }
        .onChange(of: stitchPlanGeneration) { _ in regenerateRealisticImageIfNeeded() }
        .onChange(of: canvasSize) { _ in regenerateRealisticImageIfNeeded() }
        // `lastZoomScale` (not the continuously-updating `zoomScale`) only
        // changes once a pinch gesture ends or a zoom button is pressed --
        // re-rendering the whole bitmap on every frame of an in-progress
        // pinch would be a real, user-visible stutter.
        .onChange(of: lastZoomScale) { _ in regenerateRealisticImageIfNeeded() }
        .onChange(of: document?.name) { _ in resetZoom() }
    }

    private struct CanvasTransform {
        var scale: CGFloat
        var centerX: CGFloat
        var centerY: CGFloat
    }

    /// The same fit-to-view + zoom/pan math the `Canvas` draw pass uses,
    /// pulled out so hit-testing can convert a click back to document-space
    /// coordinates with the exact same transform that put the shapes on
    /// screen -- computing this twice, slightly differently, would make
    /// clicks land on the wrong object right at the edges.
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

    private func docPoint(from location: CGPoint, document: StitchDocument, transform: CanvasTransform) -> Point2D {
        Point2D((location.x - transform.centerX) / transform.scale + document.physicalWidthMM / 2,
                 (location.y - transform.centerY) / transform.scale + document.physicalHeightMM / 2)
    }

    private func objectID(at docPoint: Point2D, in document: StitchDocument) -> EmbroideryObject.ID? {
        for object in document.objects.reversed() {
            let polygons = object.shape.subPaths.map { $0.points }
            if PolygonGeometry.pointInPolygons(docPoint, polygons: polygons) { return object.id }
        }
        return nil
    }

    /// The forward counterpart to `docPoint(from:document:transform:)` --
    /// needed for resize-handle hit-testing in `determineDragMode`, which
    /// runs outside the `Canvas` draw closure where the equivalent inline
    /// `toView` closure lives.
    private func viewPoint(from docPoint: Point2D, document: StitchDocument, transform: CanvasTransform) -> CGPoint {
        CGPoint(x: transform.centerX + CGFloat(docPoint.x - document.physicalWidthMM / 2) * transform.scale,
                y: transform.centerY + CGFloat(docPoint.y - document.physicalHeightMM / 2) * transform.scale)
    }

    /// The combined bounding box (document mm) of every currently-selected
    /// object, or nil when nothing's selected -- the box the resize
    /// handles sit on and the move/resize gestures operate against.
    private func selectionBoundingBoxMM(_ document: StitchDocument) -> BoundingBox? {
        guard !selectedObjectIDs.isEmpty else { return nil }
        var box = BoundingBox.empty
        for object in document.objects where selectedObjectIDs.contains(object.id) {
            box = box.union(object.shape.boundingBox)
        }
        return box.isEmpty ? nil : box
    }

    /// Decides what a fresh drag gesture means, checked once at its start
    /// (`value.startLocation` doesn't move during a gesture): Option always
    /// pans; otherwise landing on a resize handle resizes, landing on an
    /// already-selected object moves the selection, and anything else
    /// starts a rubber-band selection -- the existing behavior.
    private func determineDragMode(startLocation: CGPoint, document: StitchDocument, transform: CanvasTransform) -> CanvasDragMode {
        if NSEvent.modifierFlags.contains(.option) { return .pan }
        if let box = selectionBoundingBoxMM(document) {
            for corner in SelectionCorner.allCases {
                let handleView = viewPoint(from: corner.point(in: box), document: document, transform: transform)
                if hypot(startLocation.x - handleView.x, startLocation.y - handleView.y) <= handleHitRadius {
                    return .resizeSelection(anchorMM: corner.opposite.point(in: box), originalCornerMM: corner.point(in: box))
                }
            }
        }
        let startDoc = docPoint(from: startLocation, document: document, transform: transform)
        if let hit = objectID(at: startDoc, in: document), selectedObjectIDs.contains(hit) {
            return .moveSelection
        }
        return .rubberBand
    }

    /// A plain tap selects just the tapped object (or clears the selection
    /// if it missed); a shift- or command-tap toggles that one object
    /// in/out of whatever's already selected -- both are the standard
    /// multi-select convention on macOS, so either modifier does the same
    /// thing here rather than picking just one. In paint or erase mode a
    /// tap instead paints/erases a single dab at that point -- the
    /// zero-length case of a stroke, using the same code path a drag does.
    private func handleTap(at location: CGPoint, in size: CGSize) {
        guard let document, let transform = computeTransform(document: document, size: size) else { return }
        let point = docPoint(from: location, document: document, transform: transform)
        if isPaintMode {
            onPaintStroke([point])
            return
        }
        if isEraseMode {
            onEraseStroke([point])
            return
        }
        let hit = objectID(at: point, in: document)
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            guard let hit else { return }
            var updated = selectedObjectIDs
            if updated.contains(hit) { updated.remove(hit) } else { updated.insert(hit) }
            onSelectionChange(updated)
        } else {
            onSelectionChange(hit.map { [$0] } ?? [])
        }
    }

    private func handleDragChanged(_ value: DragGesture.Value, size: CGSize) {
        if isPaintMode || isEraseMode {
            guard let document, let transform = computeTransform(document: document, size: size) else { return }
            if !isDragActive { isDragActive = true; currentStrokePoints = [] }
            currentStrokePoints.append(docPoint(from: value.location, document: document, transform: transform))
            return
        }
        guard let document, let transform = computeTransform(document: document, size: size) else { return }

        if activeDragMode == nil {
            activeDragMode = determineDragMode(startLocation: value.startLocation, document: document, transform: transform)
        }

        switch activeDragMode! {
        case .pan, .rubberBand:
            // Plain drag always rubber-band selects, at any zoom level --
            // Option is the pan modifier instead (checked live, every
            // call, so it still works correctly if the key is pressed or
            // released partway through a drag). Previously a drag panned
            // whenever zoomed in at all, which left no way to rubber-band
            // select once zoomed -- exactly the situation selecting
            // several small, now-close-together objects (to merge or
            // replace with lettering) most needs zoom for.
            if NSEvent.modifierFlags.contains(.option) {
                panOffset = CGSize(width: lastPanOffset.width + value.translation.width,
                                    height: lastPanOffset.height + value.translation.height)
                rubberBandRect = nil
                activeDragMode = .pan
            } else {
                rubberBandRect = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                         width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                activeDragMode = .rubberBand
            }
        case .moveSelection:
            liveMoveDeltaMM = (Double(value.translation.width) / Double(transform.scale),
                                Double(value.translation.height) / Double(transform.scale))
        case .resizeSelection(let anchorMM, let originalCornerMM):
            let currentDoc = docPoint(from: value.location, document: document, transform: transform)
            let anchorDist = hypot(originalCornerMM.x - anchorMM.x, originalCornerMM.y - anchorMM.y)
            let currentDist = hypot(currentDoc.x - anchorMM.x, currentDoc.y - anchorMM.y)
            // Floored well above zero so dragging a handle past its anchor
            // can't collapse or invert the selection.
            liveResizeScale = anchorDist > 0.0001 ? max(0.05, currentDist / anchorDist) : 1.0
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, size: CGSize) {
        if isPaintMode || isEraseMode {
            isDragActive = false
            if isPaintMode {
                onPaintStroke(currentStrokePoints)
            } else {
                onEraseStroke(currentStrokePoints)
            }
            currentStrokePoints = []
            return
        }
        defer { activeDragMode = nil }
        guard let mode = activeDragMode else { return }

        switch mode {
        case .pan:
            lastPanOffset = panOffset
            rubberBandRect = nil
        case .rubberBand:
            defer { rubberBandRect = nil }
            guard let rect = rubberBandRect, let document, let transform = computeTransform(document: document, size: size) else { return }
            let corner1 = docPoint(from: CGPoint(x: rect.minX, y: rect.minY), document: document, transform: transform)
            let corner2 = docPoint(from: CGPoint(x: rect.maxX, y: rect.maxY), document: document, transform: transform)
            let selectionBox = BoundingBox(minX: min(corner1.x, corner2.x), minY: min(corner1.y, corner2.y),
                                            maxX: max(corner1.x, corner2.x), maxY: max(corner1.y, corner2.y))
            var hits: Set<EmbroideryObject.ID> = []
            for object in document.objects where selectionBox.contains(object.shape.boundingBox) {
                hits.insert(object.id)
            }
            // A drag too small to plausibly be an intentional rubber band
            // (a near-click that happened to trip the 1pt drag threshold)
            // selects nothing rather than everything under a 1x1 box at
            // the pointer.
            guard rect.width > 2 || rect.height > 2 else { return }
            let addToSelection = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
            onSelectionChange(addToSelection ? selectedObjectIDs.union(hits) : hits)
        case .moveSelection:
            defer { liveMoveDeltaMM = (0, 0) }
            guard liveMoveDeltaMM.dx != 0 || liveMoveDeltaMM.dy != 0 else { return }
            onMoveSelection(liveMoveDeltaMM.dx, liveMoveDeltaMM.dy)
        case .resizeSelection(let anchorMM, _):
            defer { liveResizeScale = 1.0 }
            guard abs(liveResizeScale - 1) > 0.001 else { return }
            onResizeSelection(liveResizeScale, anchorMM)
        }
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

    /// `StitchRenderer` deliberately renders fine detail -- thin per-stitch
    /// highlight lines, alternating shading every other stitch -- at a
    /// fixed source resolution (12px/mm) independent of the canvas's
    /// current on-screen size or zoom level. An `Image` handed to
    /// `GraphicsContext.draw` without an explicit `.interpolation(_:)`
    /// modifier is not guaranteed the same smooth default a plain SwiftUI
    /// `Image` view gets, so that fine detail can come out visibly
    /// aliased/jagged on screen even though the source bitmap itself (and
    /// any exported render of the same plan) is clean -- found directly
    /// against a real design whose fine satin text read as an illegible
    /// scribble on this canvas despite rendering correctly everywhere
    /// else. Requesting `.high` interpolation explicitly fixes the
    /// on-screen preview to match. Pulled into its own function (rather
    /// than inlined in the `Canvas` closure) because that closure is
    /// already near Swift's type-checker complexity limit -- adding even
    /// one more statement directly inside it fails to compile ("unable to
    /// type-check this expression in reasonable time").
    private func drawRealisticLayer(_ image: CGImage, into context: inout GraphicsContext, rect: CGRect, opacity: Double = 1.0) {
        let highQualityImage = Image(decorative: image, scale: 1, orientation: .up).interpolation(.high)
        // `Image.opacity(_:)` returns `some View`, not an `Image` --
        // useless to `GraphicsContext.draw`, which needs the concrete
        // `Image` overload. `GraphicsContext.opacity` is the actual knob
        // for scaling a draw call's alpha; restored right after so it
        // doesn't leak into whatever `drawOverlays()` draws next.
        let previousOpacity = context.opacity
        context.opacity = opacity
        context.draw(highQualityImage, in: rect)
        context.opacity = previousOpacity
    }

    /// The realistic preview's target resolution, matched to how big the
    /// design actually appears on screen right now (`canvasSize` and
    /// `lastZoomScale`) rather than always using one fixed value --
    /// otherwise a large, detailed design viewed at a modest on-screen
    /// size forces a big single-step downscale of `StitchRenderer`'s fine
    /// repeating detail (thin per-stitch highlight lines, alternating
    /// shading), which still visibly aliases even with high-quality
    /// interpolation (`drawRealisticLayer`'s fix helps, but can't fully
    /// compensate for a large enough scale mismatch -- found directly
    /// against a real design's fine satin text still reading as an
    /// illegible scribble at a fixed 12px/mm even after that fix). Retina-
    /// aware (multiplied by the screen's backing scale factor) so the
    /// preview stays crisp at 100% zoom on a Retina display, not just at
    /// the bitmap's own native resolution. Clamped to a sane range so a
    /// tiny window or a deep zoom-in never requests an absurd bitmap size.
    private func desiredPixelsPerMM(document: StitchDocument) -> Double {
        let fallback = StitchRenderer.Options().pixelsPerMM
        guard canvasSize.width > 0, canvasSize.height > 0 else { return fallback }
        let margin: CGFloat = 24
        let availableW = canvasSize.width - margin * 2
        let availableH = canvasSize.height - margin * 2
        let frameW = max(document.physicalWidthMM, hoop?.widthMM ?? 0)
        let frameH = max(document.physicalHeightMM, hoop?.heightMM ?? 0)
        guard frameW > 0, frameH > 0, availableW > 0, availableH > 0 else { return fallback }
        let fitScale = min(availableW / frameW, availableH / frameH) // points per mm, on screen
        let effectiveScale = Double(fitScale * lastZoomScale)
        let backingScale = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        return min(40, max(6, effectiveScale * backingScale))
    }

    /// Renders the realistic preview bitmap off the main thread -- on a
    /// detailed design (many objects/stitches, exactly the case a raster
    /// import or lettering-heavy design produces), `StitchRenderer.render`
    /// walking every stitch command is expensive enough to visibly stall
    /// the UI if run synchronously inside a SwiftUI `onChange` the way it
    /// used to be. Nothing touches `@State` until the render is actually
    /// done, and `realisticRenderGeneration` discards a result that a
    /// newer edit has since superseded.
    private func regenerateRealisticImageIfNeeded() {
        guard mode == .realistic, let document, let stitchPlan else { return }
        let targetPixelsPerMM = desiredPixelsPerMM(document: document)
        // A real digitize change (plan) always needs a fresh render; a
        // resolution target drifting by less than ~25% from what's already
        // rendered isn't worth the cost of re-rendering the whole bitmap
        // again (every small window resize or zoom tick would otherwise
        // trigger one).
        let resolutionDrifted = renderedPixelsPerMM <= 0 || abs(targetPixelsPerMM - renderedPixelsPerMM) / renderedPixelsPerMM > 0.25
        guard stitchPlanGeneration != renderedSignature || resolutionDrifted else { return }

        var options = StitchRenderer.Options()
        options.pixelsPerMM = targetPixelsPerMM
        let widthMM = document.physicalWidthMM
        let heightMM = document.physicalHeightMM
        let colorsSnapshot = colors
        let targetSignature = stitchPlanGeneration

        renderTask?.cancel()
        activeRealisticRenderCount += 1
        renderTask = Task {
            defer { activeRealisticRenderCount = max(0, activeRealisticRenderCount - 1) }
            let image = await Task.detached(priority: .userInitiated) {
                StitchRenderer.render(stitchPlan, widthMM: widthMM, heightMM: heightMM, colors: colorsSnapshot, options: options)
            }.value
            guard !Task.isCancelled else { return }
            realisticImage = image
            renderedSignature = targetSignature
            renderedPixelsPerMM = targetPixelsPerMM
        }
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

    /// Outlines every selected object's shape in an accent color so the
    /// user can see what's selected regardless of preview mode -- drawn
    /// last, on top of everything else, with a white halo underneath so it
    /// stays visible against any thread or background color.
    private func drawSelectionHighlight(_ document: StitchDocument, context: GraphicsContext, toView: (Point2D) -> CGPoint) {
        guard !selectedObjectIDs.isEmpty else { return }
        for object in document.objects where selectedObjectIDs.contains(object.id) {
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
    }

    /// While a move or resize drag is in progress, outlines the selected
    /// shapes at their in-progress (not-yet-committed) position/size --
    /// the underlying objects aren't touched until `handleDragEnded`
    /// commits via `onMoveSelection`/`onResizeSelection`, so this is the
    /// only feedback the user sees while dragging.
    private func drawLiveTransformGhost(_ document: StitchDocument, context: GraphicsContext, toView: (Point2D) -> CGPoint) {
        let transform: AffineTransform2D
        switch activeDragMode {
        case .moveSelection:
            guard liveMoveDeltaMM.dx != 0 || liveMoveDeltaMM.dy != 0 else { return }
            transform = .translation(liveMoveDeltaMM.dx, liveMoveDeltaMM.dy)
        case .resizeSelection(let anchorMM, _):
            guard abs(liveResizeScale - 1) > 0.001 else { return }
            transform = AffineTransform2D.translation(-anchorMM.x, -anchorMM.y)
                .concatenating(.scale(liveResizeScale, liveResizeScale))
                .concatenating(.translation(anchorMM.x, anchorMM.y))
        case .pan, .rubberBand, nil:
            return
        }
        for object in document.objects where selectedObjectIDs.contains(object.id) {
            var path = Path()
            for subPath in object.shape.subPaths {
                guard let first = subPath.points.first else { continue }
                path.move(to: toView(transform.apply(first)))
                for pt in subPath.points.dropFirst() { path.addLine(to: toView(transform.apply(pt))) }
                if subPath.closed { path.closeSubpath() }
            }
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
        }
    }

    /// Small draggable circles at the four corners of the selection's
    /// combined bounding box -- click one and pull to resize the whole
    /// selection, anchored at the opposite corner (`determineDragMode`).
    private func drawResizeHandles(_ document: StitchDocument, context: GraphicsContext, toView: (Point2D) -> CGPoint) {
        guard let box = selectionBoundingBoxMM(document) else { return }
        for corner in SelectionCorner.allCases {
            let center = toView(corner.point(in: box))
            let rect = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: rect), with: .color(.white))
            context.stroke(Path(ellipseIn: rect), with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5))
        }
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
