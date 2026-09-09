import SwiftUI
import AppKit
import StitchPilotCore
import UniformTypeIdentifiers

/// All measurements in the UI are shown and edited in centimeters, but the
/// underlying model (`StitchPilotCore`, DST/PES export, every generator and
/// test) stays in millimeters -- that's the format embroidery machines and
/// files actually work in, and it's threaded through the whole engine.
/// Converting only at this display boundary keeps the tested core
/// untouched while still satisfying "show me cm" everywhere in the UI.
private func cmBinding(_ mmBinding: Binding<Double>) -> Binding<Double> {
    Binding(get: { mmBinding.wrappedValue / 10 }, set: { mmBinding.wrappedValue = $0 * 10 })
}

private func cmBinding(_ mmBinding: Binding<Double?>, defaultManualValueMM: Double) -> Binding<Double> {
    Binding(
        get: { (mmBinding.wrappedValue ?? defaultManualValueMM) / 10 },
        set: { mmBinding.wrappedValue = $0 * 10 }
    )
}

/// `NSColor.getRed(_:green:blue:alpha:)` can throw for colors outside the
/// RGB-convertible color spaces (some system picker selections use
/// catalog/pattern colors) -- converting to a known RGB space first avoids
/// that rather than crashing on an unlucky pick from a color swatch.
private func rgbColor(from color: Color) -> StitchPilotCore.RGBColor {
    let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
    return StitchPilotCore.RGBColor(r: UInt8(max(0, min(255, r * 255))), g: UInt8(max(0, min(255, g * 255))), b: UInt8(max(0, min(255, b * 255))))
}

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var isTargeted = false
    @State private var showingNewProjectConfirm = false
    @State private var showingRedoConfirm = false
    @State private var showingMergeColors = false
    @State private var showingThreadLibrary = false
    @State private var showingAddLettering = false
    @State private var showingDetectedText = false
    @State private var showingHelp = false

    var body: some View {
        HStack(spacing: 0) {
            ObjectListView()
                .frame(width: 176) // 20% narrower than the original 220pt, to give the canvas more room
            Divider()

            ZStack {
                StitchCanvasView(document: app.document, stitchPlan: app.stitchPlan, stitchPlanGeneration: app.stitchPlanGeneration,
                                  colors: app.lastColorSequence,
                                  hoop: app.selectedHoop, selectedObjectIDs: app.selectedObjectIDs,
                                  onSelectionChange: { app.selectedObjectIDs = $0 },
                                  isPaintMode: app.isPaintMode,
                                  paintColor: Color(red: Double(app.paintColorRGB.r) / 255, green: Double(app.paintColorRGB.g) / 255, blue: Double(app.paintColorRGB.b) / 255),
                                  paintBrushRadiusMM: app.paintBrushRadiusMM,
                                  onPaintStroke: { app.paintStroke(points: $0, radiusMM: app.paintBrushRadiusMM) },
                                  isEraseMode: app.isEraseMode,
                                  onEraseStroke: { app.eraseStroke(points: $0, radiusMM: app.paintBrushRadiusMM) },
                                  isPreviewStale: app.isPreviewStale,
                                  onMoveSelection: { app.translateSelection(dxMM: $0, dyMM: $1) },
                                  onResizeSelection: { app.scaleSelection(scale: $0, anchorMM: $1) },
                                  isRegeneratingPreview: app.isRegeneratingPreview)
                if app.document == nil {
                    dropPrompt
                }
                if isTargeted {
                    Rectangle().stroke(Color.accentColor, lineWidth: 3).padding(4)
                }
            }
            .frame(minWidth: 504, minHeight: 420) // 20% larger minimum than the original 420pt
            .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)

            Divider()
            InspectorView()
                .frame(width: 300) // wider than the original 260pt so longer parameter descriptions wrap less
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                fileToolbarRow
                Divider()
                editingToolbarRow
                Divider()
            }
            .background(.bar)
        }
        .sheet(isPresented: $showingMergeColors) { MergeColorsSheet() }
        .sheet(isPresented: $showingThreadLibrary) { ThreadLibrarySheet() }
        .sheet(isPresented: $showingAddLettering) { AddLetteringSheet() }
        .sheet(isPresented: $showingDetectedText) { DetectedTextSheet() }
        .sheet(isPresented: $showingHelp) { GlossarySheet() }
        .confirmationDialog(
            app.pendingPaintMerge.map { "This looks like it's filling a gap in \u{201C}\($0.targetObjectName)\u{201D}. Merge it in?" } ?? "",
            isPresented: Binding(get: { app.pendingPaintMerge != nil }, set: { if !$0 { app.cancelPaintMerge() } }),
            titleVisibility: .visible
        ) {
            Button("Merge Into It") { app.confirmPaintMerge() }
            Button("Keep as Separate Object") { app.keepPaintSeparate() }
            Button("Cancel", role: .cancel) { app.cancelPaintMerge() }
        } message: {
            Text("Either way, the new stitching will match its thread color.")
        }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .alert("OneClickStitch", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    /// File-related actions: creating/starting over, opening/saving, undo,
    /// and getting the finished file out (export/share) -- everything that
    /// touches the document as a whole or its life on disk, as opposed to
    /// editing what's actually in it (`editingToolbarRow`, the row below
    /// this one). A native `NSToolbar` can't lay out as two rows on its
    /// own, so both rows are a plain custom `HStack` pinned to the top via
    /// `.safeAreaInset` instead of the system `.toolbar` modifier.
    private var fileToolbarRow: some View {
        HStack(spacing: 14) {
            // The One-Click Stitch action: styled with the app's own mark
            // and a prominent tint so it's unmistakably *the* button in
            // this row, not one of an equal-weight row of icons —
            // everything else here is a secondary/manual path for users
            // who want to inspect or adjust before exporting. There's no
            // separate "Auto Digitize" action any more: every edit
            // (import, resize, per-object parameter change, color merge)
            // regenerates the preview on its own a moment later, so this
            // button's only remaining job is the export step itself.
            Button {
                app.createEmbroideryFile()
            } label: {
                HStack(spacing: 6) {
                    brandMark(size: 18)
                    Text("Click to Create").fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.09, green: 0.42, blue: 0.72))
            .disabled(app.document == nil)
            .help("One click: digitize this artwork and save it as a machine embroidery file.")

            Divider().frame(height: 20)

            Button {
                if app.document == nil {
                    app.newProject()
                } else {
                    showingNewProjectConfirm = true
                }
            } label: {
                Label("New", systemImage: "doc.badge.plus")
            }
            .confirmationDialog("Start a new project? The current design will be closed without saving.",
                                 isPresented: $showingNewProjectConfirm, titleVisibility: .visible) {
                Button("Start New Project", role: .destructive) { app.newProject() }
                Button("Cancel", role: .cancel) {}
            }

            // "Redo the whole thing from scratch" -- kept next to New
            // rather than off in the editing row, since both are ways of
            // starting over, just from a different point.
            Button {
                showingRedoConfirm = true
            } label: {
                Label("Start Over", systemImage: "arrow.clockwise")
            }
            .disabled(!app.hasOriginalArtwork)
            .help("Discard edits made since import and regenerate fresh from the original artwork.")
            .confirmationDialog("Redo from the original artwork? Edits made since import (color merges, per-object overrides, deletions) will be discarded.",
                                 isPresented: $showingRedoConfirm, titleVisibility: .visible) {
                Button("Start Over", role: .destructive) { app.redoEmbroideryFileCreation() }
                Button("Cancel", role: .cancel) {}
            }

            Menu {
                Button("Open Artwork...") { app.openArtworkWithPanel() }
                Button("Open Project...") { app.openProjectWithPanel() }
            } label: {
                Label("Open", systemImage: "folder")
            }
            Button {
                app.saveProject()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(app.document == nil)

            Button {
                app.undo()
            } label: {
                Label("Back", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!app.canUndo)
            .help("Undo the last edit.")

            Spacer()

            // "Export" saves a file to disk -- a download, not an upload,
            // hence the down-arrow icon (an earlier version of this
            // button used an up-arrow, which reads as "send," the job
            // Share below actually does).
            Menu {
                Button("Tajima (.dst)") { app.exportDST() }
                Button("Brother/Baby Lock (.pes)") { app.exportPES() }
                Button("Melco (.exp)") { app.exportEXP() }
                Button("Janome (.jef)") { app.exportJEF() }
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .disabled(app.stitchPlan == nil)
            Menu {
                Button("Tajima (.dst)") { app.shareCurrentFile(format: .dst) }
                Button("Brother/Baby Lock (.pes)") { app.shareCurrentFile(format: .pes) }
                Button("Melco (.exp)") { app.shareCurrentFile(format: .exp) }
                Button("Janome (.jef)") { app.shareCurrentFile(format: .jef) }
            } label: {
                Label("Send", systemImage: "square.and.arrow.up")
            }
            .disabled(app.stitchPlan == nil)
            .help("Send the embroidery file via AirDrop, Mail, Messages, and more.")

            Divider().frame(height: 20)

            Button {
                showingHelp = true
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .help("Definitions of the digitizing terms used throughout this app, and why they matter.")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Editing-related actions: everything that changes what's actually in
    /// the design -- adjusting the automatic color/fabric output, and the
    /// hands-on tools (lettering, merging, painting) -- as opposed to
    /// document-level actions in `fileToolbarRow` above.
    private var editingToolbarRow: some View {
        HStack(spacing: 14) {
            Button {
                showingMergeColors = true
            } label: {
                Label("Merge Colors", systemImage: "arrow.triangle.merge")
            }
            .disabled((app.document?.objects.count ?? 0) < 2)
            .help("Reassign several objects to the same thread color at once.")
            Button {
                showingThreadLibrary = true
            } label: {
                Label("Thread Library", systemImage: "paintpalette")
            }
            .help("Define your own thread colors to match against.")

            Menu {
                ForEach(FabricType.allCases, id: \.self) { fabric in
                    Button {
                        app.selectedFabricType = fabric
                    } label: {
                        if fabric == app.selectedFabricType {
                            Label(fabric.displayName, systemImage: "checkmark")
                        } else {
                            Text(fabric.displayName)
                        }
                    }
                }
            } label: {
                Label("Fabric: \(app.selectedFabricType.shortName)", systemImage: "square.stack.3d.up")
            }
            .help("Adjusts the automatic pull/push compensation estimate for the fabric this design will be sewn on -- a stretchier material needs more correction, a stable/rigid one needs less. Applies to every object; an object's own manually-set compensation always wins over this.")

            // A visible boundary between adjusting the automatic output
            // above (color/fabric) and the hands-on editing tools below
            // (lettering, merging, painting) -- both act on the current
            // design, but one tunes what auto-digitize already produced
            // while the other is direct manual editing.
            Divider().frame(height: 20)

            Button {
                showingAddLettering = true
            } label: {
                Label("Add Lettering", systemImage: "textformat")
            }
            .help("Type text and pick a font -- generates clean satin letters directly from the font's own outline, instead of tracing a raster image of text (which can never be sharper than the source image's own resolution).")

            if !app.detectedTextRegions.isEmpty {
                Button {
                    showingDetectedText = true
                } label: {
                    Label("Detected Text (\(app.detectedTextRegions.count))", systemImage: "text.viewfinder")
                }
                .tint(.orange)
                .help("This import appears to contain text -- review it and optionally replace the raster-traced version with clean generated lettering.")
            }

            Button {
                app.mergeSelectedShapesIntoOneObject()
            } label: {
                Label("Merge Shapes", systemImage: "puzzlepiece")
            }
            .disabled(!app.canMergeSelectedShapes)
            .help("Join the selected objects' outlines into one shape -- fixes a letter or detail that came in as several disconnected fragments. Rubber-band or shift-click several objects first.")

            Button {
                app.isPaintMode.toggle()
            } label: {
                Label("Paint", systemImage: "paintbrush.pointed")
            }
            .tint(app.isPaintMode ? Color.accentColor : nil)
            .help("Draw in missing coverage by hand -- extends the selected object, or draws a new shape if nothing's selected.")

            Button {
                app.isEraseMode.toggle()
            } label: {
                Label("Erase", systemImage: "eraser")
            }
            .tint(app.isEraseMode ? Color.red : nil)
            .help("Remove coverage by hand -- draw over whatever's wrong and it's taken out of whichever object(s) it touches, regardless of what's selected.")

            if app.isPaintMode || app.isEraseMode {
                Slider(value: cmBinding($app.paintBrushRadiusMM), in: 0.05...1.0)
                    .frame(width: 90)
                    .help("Brush size")
            }
            if app.isPaintMode {
                ColorPicker("", selection: Binding(
                    get: { Color(red: Double(app.paintColorRGB.r) / 255, green: Double(app.paintColorRGB.g) / 255, blue: Double(app.paintColorRGB.b) / 255) },
                    set: { app.paintColorRGB = rgbColor(from: $0) }
                ), supportsOpacity: false)
                .labelsHidden()
            }

            Spacer()
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The app's own mark (the stitched "S" + cursor-click glyph), bundled
    /// as a real image asset rather than an approximated SF Symbol — see
    /// `Resources/Branding/` for the source files this was generated from.
    @ViewBuilder
    private func brandMark(size: CGFloat) -> some View {
        if let url = Bundle.module.url(forResource: "OneClickStitchIcon", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }

    private var dropPrompt: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                brandMark(size: 64)
                Text("OneClickStitch").font(.title2).fontWeight(.semibold)
                Text("Turn any image into embroidery.")
                    .foregroundStyle(.secondary)
                Text("Drop an image or SVG file here, or click to choose one")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { app.openArtworkWithPanel() }

            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 36, height: 1)
                Text("or").font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 36, height: 1)
            }

            // No image required -- a design can be nothing but generated
            // lettering (spec: not every embroidery job starts from
            // artwork). `AddLetteringSheet` already handles `document ==
            // nil` by minting a brand-new document sized to the text
            // itself; this button is just making that path discoverable
            // instead of only reachable via the editing toolbar's "Add
            // Lettering," which a user staring at an empty drop target has
            // no reason to expect works with nothing imported yet.
            Button {
                showingAddLettering = true
            } label: {
                Label("Start with Text Only", systemImage: "textformat")
            }
            .help("Skip importing artwork -- type text and it becomes the whole design, generated directly from a font's own outline.")
        }
    }

    private var statusBar: some View {
        HStack {
            if app.isBusy { ProgressView().controlSize(.small) }
            Text(app.statusMessage)
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
            readinessBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// A compact, always-visible readiness score at the bottom-right of the
    /// window -- unlike the full "Embroidery Readiness" section in the
    /// Inspector (issue-by-issue detail, but only visible while scrolled
    /// to it), this stays on screen no matter what part of the Inspector
    /// is showing, and re-reads `app.readinessReport` directly, so it
    /// updates the moment an edit's live regenerate re-analyzes the
    /// design -- the user sees the score move as they make improvements,
    /// not just as a one-time snapshot.
    @ViewBuilder
    private var readinessBadge: some View {
        if let report = app.readinessReport {
            HStack(spacing: 6) {
                Image(systemName: report.isReadyToSew ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                Text("Readiness: \(report.score)/100")
            }
            .font(.callout)
            .foregroundStyle(report.isReadyToSew ? Color.green : Color.orange)
            .help(report.isReadyToSew
                  ? "Ready to sew -- no issues found."
                  : "\(report.issues.count) issue\(report.issues.count == 1 ? "" : "s") found -- see Embroidery Readiness in the Inspector for details.")
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            DispatchQueue.main.async {
                guard let url else {
                    // Previously silent -- a drag that failed to resolve to
                    // a file URL left whatever was already open untouched
                    // with no feedback at all, which reads as "the drop did
                    // nothing" or, worse, "it brought back old content."
                    app.errorMessage = "Couldn't read that dropped item\(error.map { ": \($0.localizedDescription)" } ?? "")."
                    return
                }
                app.openDroppedFile(url: url)
            }
        }
        return true
    }
}

private struct ObjectListView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Objects").font(.headline).padding(12)
            Divider()
            if let document = app.document, !document.objects.isEmpty {
                List(document.objects, selection: $app.selectedObjectIDs) { object in
                    HStack {
                        Circle()
                            .fill(Color(red: Double(object.threadColor.rgb.r) / 255,
                                        green: Double(object.threadColor.rgb.g) / 255,
                                        blue: Double(object.threadColor.rgb.b) / 255))
                            .frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(object.name)
                            Text(object.threadColor.name).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(object.stitchType.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(object.id)
                    .contextMenu {
                        Button("Delete Object", role: .destructive) {
                            app.selectedObjectIDs = [object.id]
                            app.deleteSelectedObject()
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                Spacer()
                Text("No objects yet").foregroundStyle(.secondary).padding()
                Spacer()
            }
        }
    }
}

private struct InspectorView: View {
    @EnvironmentObject var app: AppState
    /// Purely a picker convenience -- not synced back from the actual
    /// width/height fields, so it doesn't fight manual edits or claim a
    /// preset is still active once the user has nudged the numbers away
    /// from it. Selecting "Custom" is a no-op; it only exists so the list
    /// has an explicit "I'm not using a preset" option to land on.
    @State private var selectedSizePreset: GarmentSizePreset?

    var body: some View {
        Form {
            if app.selectedObject != nil {
                ObjectInspectorSection()
            } else if app.selectedObjectIDs.count > 1 {
                MultiSelectionSection()
            }

            Section("Finished Size") {
                Picker("Standard Size", selection: $selectedSizePreset) {
                    Text("Custom").tag(GarmentSizePreset?.none)
                    ForEach(GarmentSizePreset.standardPresets) { preset in
                        Text("\(preset.name) (\(cmString(preset.widthMM))×\(cmString(preset.heightMM))cm)").tag(GarmentSizePreset?.some(preset))
                    }
                }
                .onChange(of: selectedSizePreset) { newValue in
                    guard let newValue else { return }
                    app.applyGarmentSizePreset(newValue)
                }
                HStack {
                    TextField("Width (cm)", value: cmBinding($app.physicalWidthMM), format: .number)
                        .onSubmit { app.applyPhysicalSizeChange() }
                    Text("×")
                    TextField("Height (cm)", value: cmBinding($app.physicalHeightMM), format: .number)
                        .disabled(app.lockAspectRatio)
                        .onSubmit { app.applyPhysicalSizeChange() }
                }
                Toggle("Lock aspect ratio", isOn: $app.lockAspectRatio)
                Button("Apply Size") { app.applyPhysicalSizeChange() }
            }

            Section("Density (Entire Project)") {
                globalDensitySlider("Satin Density", value: $app.globalSatinDensityMM)
                globalDensitySlider("Fill Row Spacing", value: $app.globalFillSpacingMM)
                Text("Applies to every satin or fill object in the project at once. Select an individual object above to fine-tune just that one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hoop") {
                Picker("Hoop", selection: $app.selectedHoop) {
                    Text("None").tag(HoopProfile?.none)
                    ForEach(HoopProfile.commonHoops) { hoop in
                        Text("\(hoop.name) (\(cmString(hoop.widthMM))×\(cmString(hoop.heightMM))cm)").tag(HoopProfile?.some(hoop))
                    }
                }
            }

            Section("Color Reduction") {
                Picker("Preset", selection: $app.colorPreset) {
                    ForEach(ColorQuantizationPreset.allCases, id: \.self) { preset in
                        Text(presetLabel(preset)).tag(preset)
                    }
                }
                Text("Only affects images — vector art keeps its own colors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Thread Colors") {
                Toggle("Match to thread library", isOn: $app.matchToThreadLibrary)
                Text("Snaps each detected color to the nearest sewable thread color instead of the exact artwork color.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let plan = app.stitchPlan {
                Section("Production Statistics") {
                    LabeledContent("Stitches", value: "\(plan.stitchCount)")
                    // Distinct thread colors actually used -- not object
                    // count (many objects routinely share one color, e.g.
                    // every letter of a word), which this showed before
                    // and made a color-count-driven setting like the
                    // import color preset look like it was doing nothing:
                    // the object count barely moves even when the actual
                    // color count does.
                    LabeledContent("Colors", value: "\(Set((app.document?.objects ?? []).map { $0.threadColor.rgb }).count)")
                    LabeledContent("Color changes", value: "\(plan.colorChangeCount)")
                    LabeledContent("Trims", value: "\(plan.trimCount)")
                    LabeledContent("Max stitch", value: String(format: "%.3f cm", plan.maxStitchLength() / 10))
                }
            }

            if let report = app.readinessReport {
                Section {
                    HStack {
                        Text(report.isReadyToSew ? "Ready to Sew" : "Review Recommended")
                            .font(.headline)
                        Spacer()
                        Text("\(report.score)/100")
                            .font(.headline)
                            .foregroundStyle(report.isReadyToSew ? .green : .orange)
                    }
                    if report.issues.isEmpty {
                        Label("No issues found.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                            Label(issue.message, systemImage: icon(for: issue.severity))
                                .font(.caption)
                                .foregroundStyle(color(for: issue.severity))
                        }
                    }
                } header: {
                    Text("Embroidery Readiness")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func icon(for severity: IssueSeverity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private func color(for severity: IssueSeverity) -> Color {
        switch severity {
        case .info: return .secondary
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func presetLabel(_ preset: ColorQuantizationPreset) -> String {
        switch preset {
        case .preserveArtwork: return "Preserve Artwork"
        case .normalEmbroidery: return "Normal Embroidery"
        case .productionEfficient: return "Production Efficient"
        case .minimalColors: return "Minimal Colors"
        }
    }

    private func cmString(_ mm: Double) -> String {
        let cm = mm / 10
        return cm.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", cm) : String(format: "%.1f", cm)
    }

    /// Same range/step as the per-object density slider in
    /// `ObjectInspectorSection` (0.2-1.0mm, shown as 0.02-0.10cm) -- this
    /// one just writes to the project-wide value instead of one object's.
    @ViewBuilder
    private func globalDensitySlider(_ label: String, value: Binding<Double>) -> some View {
        let cmValue = cmBinding(value)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(label) (cm)")
                Spacer()
                Text(String(format: "%.3f", cmValue.wrappedValue)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: cmValue, in: 0.02...0.10, step: 0.005)
        }
    }
}

/// Shown instead of the single-object editor once the user has rubber-band-
/// or shift-selected more than one object -- editing individual stitch
/// parameters doesn't make sense for several objects at once, but merging
/// or deleting them together does (spec: fix a letter/logo detail that
/// digitized as several disconnected fragments without needing to
/// understand why it fragmented -- select the pieces, merge them).
private struct MultiSelectionSection: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Section("Selected Objects") {
            Text("\(app.selectedObjectIDs.count) objects selected")
                .font(.headline)
            Button {
                app.mergeSelectedShapesIntoOneObject()
            } label: {
                Label("Merge into One Shape", systemImage: "arrow.triangle.merge")
            }
            Button(role: .destructive) {
                app.deleteSelectedObject()
            } label: {
                Label("Delete Selected", systemImage: "trash")
            }
            Text("Drag a box around several broken pieces on the canvas (or shift-click them) to select them, then merge.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Manual per-object overrides before the embroidery file is created: pick
/// an object in the list, then override its stitch type or any of the
/// generation parameters the engine otherwise chooses automatically.
/// `StitchGenerationParameters` supports many more knobs than shown here
/// (underlay inset, fill row stagger, filter thresholds); this exposes the
/// ones a digitizer actually reaches for regularly, not every field.
/// Edits update the master document immediately; `AppState.
/// scheduleLiveRegenerate()` (triggered inside `updateSelectedObject`)
/// debounces an automatic re-digitize a moment later, so the density
/// sliders below show their effect in the canvas without a separate
/// manual "regenerate" step.
private struct ObjectInspectorSection: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Section("Selected Object") {
            if let object = app.selectedObject {
                HStack {
                    Text(object.name).font(.headline)
                    Spacer()
                    Button(role: .destructive) {
                        app.deleteSelectedObject()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this object")
                }

                Picker("Thread Color", selection: binding(object, \.threadColor)) {
                    ForEach(app.effectivePalette) { color in
                        Label {
                            Text(color.name)
                        } icon: {
                            Circle()
                                .fill(Color(red: Double(color.rgb.r) / 255, green: Double(color.rgb.g) / 255, blue: Double(color.rgb.b) / 255))
                                .frame(width: 10, height: 10)
                        }
                        .tag(color)
                    }
                }

                Picker("Stitch Type", selection: stitchTypeBinding(object)) {
                    ForEach(StitchType.allCases, id: \.self) { type in
                        Text(label(for: type)).tag(type)
                    }
                }

                Toggle("Applique", isOn: binding(object, \.isApplique))
                    .help("Sews a placement outline, then a tack-down outline slightly inset, before this object's own stitching -- trace the placement line, lay and trim the fabric by hand, then continue for the tack-down and the finished satin/fill on top.")

                switch object.stitchType {
                case .runningStitch, .tripleRun:
                    TextField("Stitch Length (cm)", value: cmBinding(binding(object, \.parameters.stitchLengthMM)), format: .number)
                case .satin:
                    densitySlider("Density", keyPath: \.parameters.satinDensityMM, object: object)
                    TextField("Max Width (cm)", value: cmBinding(binding(object, \.parameters.maxSatinWidthMM)), format: .number)
                    TextField("Min Width (cm)", value: cmBinding(binding(object, \.parameters.minSatinWidthMM)), format: .number)
                case .tatamiFill:
                    densitySlider("Row Spacing", keyPath: \.parameters.fillSpacingMM, object: object)
                    optionalDoubleField(object, label: "Fill Angle (°)", keyPath: \.parameters.fillAngleDegrees, defaultManualValue: 0, isAngle: true)
                    Picker("Fill Pattern", selection: binding(object, \.parameters.fillPattern)) {
                        ForEach(FillPattern.allCases, id: \.self) { pattern in
                            Text(pattern.displayName).tag(pattern)
                        }
                    }
                    .help("Cross-Hatch sews two overlapping passes at right angles instead of parallel rows -- a lattice texture that avoids the faint directional sheen plain rows can show on a large flat area.")
                }

                if object.stitchType == .satin || object.stitchType == .tatamiFill {
                    Picker("Underlay", selection: binding(object, \.parameters.underlayType)) {
                        Text("Automatic").tag(UnderlayType?.none)
                        ForEach(UnderlayType.allCases, id: \.self) { type in
                            Text(label(for: type)).tag(UnderlayType?.some(type))
                        }
                    }
                    optionalDoubleField(object, label: "Pull Compensation (cm)", keyPath: \.parameters.pullCompensationMM, defaultManualValue: 0.2)
                    optionalDoubleField(object, label: "Push Compensation (cm)", keyPath: \.parameters.pushCompensationMM, defaultManualValue: 0.2)
                }

                Text("Updates the preview automatically a moment after each change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// `object` is the current render pass's already-unwrapped selected
    /// object, used only as the fallback value if the selection changes out
    /// from under a binding's `get` between renders -- always overridden by
    /// `app.selectedObject`'s live value when it's still present.
    private func binding<T>(_ object: EmbroideryObject, _ keyPath: WritableKeyPath<EmbroideryObject, T>) -> Binding<T> {
        Binding(
            get: { app.selectedObject?[keyPath: keyPath] ?? object[keyPath: keyPath] },
            set: { newValue in app.updateSelectedObject { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Picking a stitch type here is a deliberate user override, not a
    /// side effect of geometry -- mark it so later operations that
    /// re-derive stitch type from shape (e.g. resizing the whole design)
    /// know to leave this object's choice alone.
    private func stitchTypeBinding(_ object: EmbroideryObject) -> Binding<StitchType> {
        Binding(
            get: { app.selectedObject?.stitchType ?? object.stitchType },
            set: { newValue in
                app.updateSelectedObject {
                    $0.stitchType = newValue
                    $0.stitchTypeIsManualOverride = true
                }
            }
        )
    }

    /// A density slider (satin crossing spacing or tatami row spacing) that
    /// shows its own current value and drags smoothly -- denser (smaller
    /// spacing) to the left, sparser to the right, `0.02...0.10cm` covering
    /// the practical range real embroidery software exposes for either
    /// stitch type (0.2-1.0mm). Bound through the same `binding(_:_:)`
    /// helper every other field here uses, so dragging it already goes
    /// through `AppState.updateSelectedObject` -> `scheduleLiveRegenerate()`
    /// and the canvas updates a moment after the drag settles, with no
    /// separate wiring needed for "live" here.
    @ViewBuilder
    private func densitySlider(_ label: String, keyPath: WritableKeyPath<EmbroideryObject, Double>, object: EmbroideryObject) -> some View {
        let value = cmBinding(binding(object, keyPath))
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(label) (cm)")
                Spacer()
                Text(String(format: "%.3f", value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: 0.02...0.10, step: 0.005)
        }
    }

    /// `isAngle` skips the mm<->cm conversion for the one caller (Fill
    /// Angle) that isn't a length at all -- everything else this is used
    /// for (pull/push compensation) is.
    @ViewBuilder
    private func optionalDoubleField(_ object: EmbroideryObject, label: String, keyPath: WritableKeyPath<EmbroideryObject, Double?>, defaultManualValue: Double, isAngle: Bool = false) -> some View {
        let isAutomatic = Binding<Bool>(
            get: { (app.selectedObject?[keyPath: keyPath] ?? object[keyPath: keyPath]) == nil },
            set: { auto in app.updateSelectedObject { $0[keyPath: keyPath] = auto ? nil : defaultManualValue } }
        )
        Toggle("\(label): Automatic", isOn: isAutomatic)
        if !isAutomatic.wrappedValue {
            let mmBinding = Binding<Double?>(
                get: { app.selectedObject?[keyPath: keyPath] ?? object[keyPath: keyPath] ?? defaultManualValue },
                set: { newValue in app.updateSelectedObject { $0[keyPath: keyPath] = newValue } }
            )
            TextField(label, value: isAngle ? Binding(get: { mmBinding.wrappedValue ?? defaultManualValue }, set: { mmBinding.wrappedValue = $0 })
                                             : cmBinding(mmBinding, defaultManualValueMM: defaultManualValue),
                      format: .number)
        }
    }

    private func label(for type: StitchType) -> String {
        switch type {
        case .runningStitch: return "Running Stitch"
        case .tripleRun: return "Triple Run"
        case .satin: return "Satin"
        case .tatamiFill: return "Tatami Fill"
        }
    }

    private func label(for type: UnderlayType) -> String {
        switch type {
        case .none: return "None"
        case .centerRun: return "Center Run"
        case .edgeRun: return "Edge Run"
        case .zigzag: return "Zigzag"
        }
    }
}

/// Reassigns several auto-detected objects to one thread color in a single
/// action -- a raster import especially can split what's visually one
/// color into many separate near-duplicate objects (anti-aliasing,
/// gradient banding), and fixing that one object at a time in the Object
/// Inspector doesn't scale. Groups the document's current objects by their
/// exact RGB value (not `ThreadColor.id`, which is unique per object even
/// for visually identical colors), lets the user check off which of those
/// groups to fold together, and picks the surviving color from the same
/// effective palette the per-object picker uses.
private struct MergeColorsSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    private struct ColorGroup: Identifiable {
        var id: StitchPilotCore.RGBColor { rgb }
        var rgb: StitchPilotCore.RGBColor
        var name: String
        var count: Int
    }

    @State private var selectedRGBs: Set<StitchPilotCore.RGBColor> = []
    @State private var targetColor: ThreadColor?

    private var groups: [ColorGroup] {
        guard let objects = app.document?.objects else { return [] }
        var counts: [StitchPilotCore.RGBColor: (name: String, count: Int)] = [:]
        for object in objects {
            counts[object.threadColor.rgb, default: (object.threadColor.name, 0)].count += 1
        }
        return counts.map { ColorGroup(rgb: $0.key, name: $0.value.name, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Merge Colors").font(.title3).fontWeight(.semibold).padding()
            Divider()

            Text("Select the colors to combine, then choose the color they should all become.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            List(groups) { group in
                Toggle(isOn: Binding(
                    get: { selectedRGBs.contains(group.rgb) },
                    set: { isOn in
                        if isOn { selectedRGBs.insert(group.rgb) } else { selectedRGBs.remove(group.rgb) }
                    }
                )) {
                    HStack {
                        swatch(group.rgb)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name)
                            Text("\(group.count) object\(group.count == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            Divider()
            HStack {
                Text("Merge into:")
                Picker("", selection: $targetColor) {
                    Text("Choose a color").tag(ThreadColor?.none)
                    ForEach(app.effectivePalette) { color in
                        Label { Text(color.name) } icon: { swatch(color.rgb) }.tag(ThreadColor?.some(color))
                    }
                }
                .labelsHidden()
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Merge") {
                    guard let targetColor else { return }
                    app.mergeColors(from: selectedRGBs, into: targetColor)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedRGBs.count < 2 || targetColor == nil)
            }
            .padding()
        }
        .frame(width: 420, height: 420)
    }

    private func swatch(_ rgb: StitchPilotCore.RGBColor) -> some View {
        Circle()
            .fill(Color(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255))
            .frame(width: 12, height: 12)
    }
}

/// Generates real satin lettering from a font's own vector outline
/// (`LetteringGenerator`) instead of raster-tracing an image of already-
/// rendered text -- the fix for text that tracing can never sharpen
/// beyond the source image's own pixel resolution, however the design is
/// sized or classified afterward (see CHANGELOG.md). The font preview
/// here is a plain SwiftUI `Text` in the chosen font -- a rough, cheap
/// stand-in for what the letterforms look like, not a real stitch
/// simulation; the canvas's own Realistic/Technical preview shows the
/// actual result once added.
private struct AddLetteringSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var text = "SARASOTA MILITARY ACADEMY"
    @State private var fonts: [(displayName: String, postScriptName: String)] = []
    @State private var selectedFontPostScriptName = ""
    @State private var fontSizeMM: Double = 8
    @State private var letterSpacingMM: Double = 0
    @State private var isCurved = false
    @State private var radiusMM: Double = 40
    @State private var color = Color.black
    /// Snapshotted once, when the sheet opens -- objects the user already
    /// had selected (e.g. the raster-traced fragments of some illegible
    /// text) that this new lettering is likely meant to replace. Captured
    /// up front rather than read live from `app.selectedObjectIDs` so it
    /// can't drift out from under the toggle below while the sheet is open.
    @State private var objectIDsToReplace: Set<EmbroideryObject.ID> = []
    @State private var replaceSelectedObjects = true

    private var selectedFontDisplayName: String {
        fonts.first { $0.postScriptName == selectedFontPostScriptName }?.displayName ?? selectedFontPostScriptName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Lettering").font(.title3).fontWeight(.semibold).padding()
            Divider()

            Form {
                TextField("Text", text: $text, prompt: Text("Type the text to add"))

                Picker("Font", selection: $selectedFontPostScriptName) {
                    ForEach(fonts, id: \.postScriptName) { font in
                        Group {
                            if let nsFont = NSFont(name: font.postScriptName, size: 15) {
                                Text(font.displayName).font(Font(nsFont))
                            } else {
                                Text(font.displayName)
                            }
                        }
                        .tag(font.postScriptName)
                    }
                }

                HStack {
                    Text("Letter height")
                    Slider(value: $fontSizeMM, in: 2...60, step: 0.5)
                    Text(String(format: "%.1f mm", fontSizeMM)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                HStack {
                    Text("Letter spacing")
                    Slider(value: $letterSpacingMM, in: -1...10, step: 0.1)
                    Text(String(format: "%.1f mm", letterSpacingMM)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }

                Toggle("Curve along a ring", isOn: $isCurved)
                    .help("Wraps the text along an arc -- e.g. a badge's curved title text -- instead of a straight line.")
                if isCurved {
                    HStack {
                        Text("Curve radius")
                        Slider(value: $radiusMM, in: 5...200, step: 1)
                        Text(String(format: "%.0f mm", radiusMM)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }

                ColorPicker("Thread color", selection: $color, supportsOpacity: false)

                if !objectIDsToReplace.isEmpty {
                    Toggle("Replace \(objectIDsToReplace.count) selected object\(objectIDsToReplace.count == 1 ? "" : "s")", isOn: $replaceSelectedObjects)
                        .help("Deletes the objects you had selected and puts this new lettering in their place, instead of just adding it alongside them.")
                }
            }
            .padding()
            .formStyle(.grouped)

            if !selectedFontPostScriptName.isEmpty, let nsFont = NSFont(name: selectedFontPostScriptName, size: 28) {
                Text(text.isEmpty ? " " : text)
                    .font(Font(nsFont))
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                    .foregroundStyle(color)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let spec = LetteringSpec(text: text, fontPostScriptName: selectedFontPostScriptName,
                                              fontSizeMM: fontSizeMM, letterSpacingMM: letterSpacingMM,
                                              baseline: isCurved ? .arc(radiusMM: radiusMM) : .straight)
                    let rgb = rgbColor(from: color)
                    let threadColor = app.matchToThreadLibrary
                        ? (ThreadLibrary.nearestMatch(to: rgb, in: app.effectivePalette) ?? .generic(rgb, name: "Lettering Color"))
                        : .generic(rgb, name: "Lettering Color")
                    if replaceSelectedObjects, !objectIDsToReplace.isEmpty {
                        app.addLettering(spec: spec, threadColor: threadColor, replacing: objectIDsToReplace)
                    } else {
                        app.addLettering(spec: spec, threadColor: threadColor)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedFontPostScriptName.isEmpty)
            }
            .padding()
        }
        .frame(width: 460, height: 480)
        .onAppear {
            if fonts.isEmpty {
                fonts = AppState.availableLetteringFonts()
                selectedFontPostScriptName = fonts.first { $0.displayName == "Helvetica" }?.postScriptName ?? fonts.first?.postScriptName ?? ""
            }
            objectIDsToReplace = app.selectedObjectIDs
        }
    }
}

/// Reviews text `TextDetector` found in the just-imported image, letting
/// the user replace the raster-traced version of each piece with real
/// generated lettering (`AppState.replaceDetectedText`) -- the transcription
/// and bold/regular weight are Vision's and a pixel-density heuristic's
/// best guess respectively, never presented as a guaranteed match, so
/// every field here stays editable before anything is replaced.
private struct DetectedTextSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    private struct Draft: Identifiable {
        var id: UUID
        var region: DetectedTextRegion
        var text: String
        var fontPostScriptName: String
        var color: Color
    }

    @State private var drafts: [Draft] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Detected Text").font(.title3).fontWeight(.semibold).padding()
            Divider()

            Text("Vision found this text in the imported image. Review and edit before replacing -- this is a starting suggestion, not a guaranteed match, especially for tightly curved text.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            List {
                ForEach($drafts) { $draft in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Text", text: $draft.text)
                            .textFieldStyle(.roundedBorder)
                        if abs(draft.region.rotationDegrees) > 5 {
                            Label("This looks tilted or curved -- Add Lettering's curve option may fit better than a straight replacement.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        HStack {
                            Picker("Font", selection: $draft.fontPostScriptName) {
                                Text("Helvetica Bold").font(Font(NSFont(name: "Helvetica-Bold", size: 15) ?? NSFont.systemFont(ofSize: 15))).tag("Helvetica-Bold")
                                Text("Helvetica").font(Font(NSFont(name: "Helvetica", size: 15) ?? NSFont.systemFont(ofSize: 15))).tag("Helvetica")
                            }
                            .labelsHidden()
                            .frame(width: 160)
                            ColorPicker("", selection: $draft.color, supportsOpacity: false)
                                .labelsHidden()
                            Text("\(Int(draft.region.confidence * 100))% confident")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Ignore") {
                                app.detectedTextRegions.removeAll { $0.id == draft.region.id }
                                drafts.removeAll { $0.id == draft.id }
                            }
                            Button("Replace") {
                                let spec = LetteringSpec(text: draft.text, fontPostScriptName: draft.fontPostScriptName,
                                                          fontSizeMM: app.suggestedLetterHeightMM(for: draft.region))
                                let rgb = rgbColor(from: draft.color)
                                let threadColor: ThreadColor = app.matchToThreadLibrary
                                    ? (ThreadLibrary.nearestMatch(to: rgb, in: app.effectivePalette) ?? .generic(rgb, name: "Lettering Color"))
                                    : .generic(rgb, name: "Lettering Color")
                                app.replaceDetectedText(draft.region, spec: spec, threadColor: threadColor)
                                drafts.removeAll { $0.id == draft.id }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 260)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
        }
        .frame(width: 540, height: 460)
        .onAppear {
            drafts = app.detectedTextRegions.map { region in
                Draft(id: region.id, region: region, text: region.text,
                      fontPostScriptName: region.suggestedWeight == .bold ? "Helvetica-Bold" : "Helvetica",
                      color: .black)
            }
        }
    }
}

/// Lets the user build their own thread inventory to match artwork colors
/// against (spec §9's "My Thread Inventory") instead of always matching
/// the built-in generic palette -- useful once you actually know which
/// spools you own and want detected colors snapped to *those*, not an
/// arbitrary nearby generic swatch you don't have.
private struct ThreadLibrarySheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var newName: String = ""
    @State private var newColor: Color = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("My Thread Library").font(.title3).fontWeight(.semibold).padding()
            Divider()

            Text(app.customThreadLibrary.isEmpty
                 ? "No colors defined yet — matching uses the built-in generic palette."
                 : "Detected colors are matched only against these while your library isn't empty.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            List {
                ForEach(app.customThreadLibrary) { color in
                    HStack {
                        Circle()
                            .fill(Color(red: Double(color.rgb.r) / 255, green: Double(color.rgb.g) / 255, blue: Double(color.rgb.b) / 255))
                            .frame(width: 12, height: 12)
                        Text(color.name)
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet { app.removeCustomThreadColor(id: app.customThreadLibrary[index].id) }
                }
            }
            .frame(minHeight: 200)

            Divider()
            HStack {
                ColorPicker("", selection: $newColor, supportsOpacity: false).labelsHidden()
                TextField("Color name", text: $newName)
                Button("Add") {
                    app.addCustomThreadColor(name: newName.isEmpty ? "Custom Color" : newName, rgb: rgbColor(from: newColor))
                    newName = ""
                }
            }
            .padding()

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 380, height: 420)
    }

}

/// One glossary entry -- a term used somewhere in the app's own UI, what
/// it means, and why it actually matters for digitizing quality (not just
/// a dictionary definition) -- shown by the toolbar's Help button.
private struct GlossaryEntry: Identifiable {
    let id = UUID()
    let term: String
    let definition: String
}

private struct GlossarySection: Identifiable {
    let id = UUID()
    let title: String
    let entries: [GlossaryEntry]
}

/// A reference glossary for every digitizing term this app's own UI uses --
/// stitch types, fill patterns, generation parameters, editing tools,
/// machine/production terms, and the readiness score -- each with a plain-
/// language definition and why it actually affects how a design sews out,
/// not just a dictionary entry. Opened from the toolbar's Help button;
/// content lives here as static data rather than pulled from the engine
/// itself, since it's meant to explain concepts a user encounters in the
/// UI, not document the code.
private struct GlossarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private let sections: [GlossarySection] = [
        GlossarySection(title: "Stitch Types", entries: [
            GlossaryEntry(term: "Running Stitch",
                           definition: "A single line of stitches tracing an outline, evenly spaced. The lightest-weight stitch type -- good for fine detail or a hairline stroke too thin for satin to hold cleanly, but reads as a thin line, not a filled shape."),
            GlossaryEntry(term: "Triple Run",
                           definition: "The same outline sewn three times (forward, back, forward) instead of once. Reads as a bolder, more solid line than a single running stitch -- this app uses it automatically for lettering too small for satin to hold a clean column, since it stays legible at any size."),
            GlossaryEntry(term: "Satin (Satin Stitch / Satin Column)",
                           definition: "Dense zigzag stitching between two \"rails\" running the length of a narrow shape -- a letter stroke, a logo outline segment. Gives a smooth, glossy, filled look, but only works well on a genuinely narrow column (roughly 1.5-12mm); too wide and it can gap, pucker, or snag."),
            GlossaryEntry(term: "Tatami Fill",
                           definition: "Parallel rows of stitching that solidly cover a wider area -- a background shape, a bold block letter, anywhere satin would be too wide to sew cleanly. Matte rather than glossy, and handles holes/counters (like a letter's own counter) correctly, which satin in this engine can't unless it's a single simple ring."),
        ]),
        GlossarySection(title: "Fill Patterns", entries: [
            GlossaryEntry(term: "Rows",
                           definition: "Tatami fill's default texture: straight parallel rows at one angle. Simple and reliable for most shapes."),
            GlossaryEntry(term: "Cross-Hatch",
                           definition: "Two overlapping row passes at right angles to each other, each at half density -- a lattice texture instead of parallel lines. Useful when plain rows show a faint directional sheen you'd rather avoid."),
            GlossaryEntry(term: "Basket Weave",
                           definition: "Splits a large fill area into a checkerboard of cells, alternating the fill angle 90° between neighboring cells. The standard technique for breaking up the \"grain\" a big flat area can show under one uniform fill direction -- most useful on genuinely large regions, not small detail."),
        ]),
        GlossarySection(title: "Stitch Parameters", entries: [
            GlossaryEntry(term: "Density",
                           definition: "How close together the stitches are (satin's crossing spacing, or fill's row spacing). Denser stitching gives fuller coverage and a richer look, but uses more thread, takes longer to sew, and can stiffen or even perforate the fabric if pushed too far."),
            GlossaryEntry(term: "Stitch Length",
                           definition: "How far apart individual stitch points are along a running/triple-run line. Shorter gives smoother curves and finer detail; longer sews faster but can look choppy on a tight curve."),
            GlossaryEntry(term: "Underlay",
                           definition: "A lighter foundation layer of stitching sewn *underneath* the visible stitching, before it. Stabilizes the fabric and keeps the top stitching from sinking into it -- without underlay, satin especially can look thin, uneven, or let the fabric show through. This app picks a sensible underlay automatically unless you override it (None, Center Run, Edge Run, or Zigzag)."),
            GlossaryEntry(term: "Pull Compensation",
                           definition: "How much a shape is widened before sewing to counteract fabric pulling inward, perpendicular to the stitching, as it's sewn -- without it, a design can sew narrower than digitized. Denser stitching and narrower shapes need more; this app estimates it automatically per object (and per fabric type), or you can set it by hand."),
            GlossaryEntry(term: "Push Compensation",
                           definition: "Pull compensation's counterpart along the stitching direction instead of across it -- fabric pushes apart lengthwise as it sews, so a shape can end up longer than digitized unless shortened first to compensate."),
            GlossaryEntry(term: "Fill Angle",
                           definition: "The direction tatami fill's rows run. Affects how light catches the finished stitching and how the fill interacts with neighboring shapes -- this app picks a sensible angle automatically (perpendicular to the shape's own elongation) unless you set one explicitly."),
            GlossaryEntry(term: "Max / Min Satin Width",
                           definition: "The practical width range satin can sew cleanly within (roughly 1.5-12mm by default). Narrower than the minimum sews as running/triple-run instead; wider than the maximum converts to tatami fill -- both automatic, so a shape is never left un-sewable just because its width falls outside satin's comfort zone."),
        ]),
        GlossarySection(title: "Editing Tools", entries: [
            GlossaryEntry(term: "Merge Colors",
                           definition: "Reassigns several objects to the same thread color at once. Most real logos use only a handful of thread colors, not a separate one for every distinct shape a raster import detected -- merging keeps the color count sewable and the thread changes to a minimum."),
            GlossaryEntry(term: "Merge Shapes",
                           definition: "Joins several selected objects' outlines into one combined shape. Fixes a letter or detail that came in as multiple disconnected fragments (common with a raster/photo import) so it sews as one clean piece instead of several overlapping ones."),
            GlossaryEntry(term: "Paint Tool",
                           definition: "Draws in missing coverage by hand -- extends the selected object with a brush stroke, or creates a new shape if nothing's selected. Useful for patching a gap the automatic import missed."),
            GlossaryEntry(term: "Add Lettering",
                           definition: "Generates clean letterforms directly from a font's own outline instead of tracing a raster image of text -- sharp at any size, unlike text that came in as part of an imported photo or logo file."),
            GlossaryEntry(term: "Applique",
                           definition: "A technique where a separate piece of fabric is placed on the garment and secured with stitching, rather than filling the whole shape with thread -- lighter, faster to sew for large areas, and gives a distinct fabric-texture look. This app can generate the placement outline and tack-down stitching that guide where to lay and secure the fabric by hand."),
            GlossaryEntry(term: "Fabric Type",
                           definition: "Adjusts the automatic pull/push compensation estimate for how stretchy or stable the target material is -- a stretch knit needs meaningfully more correction than a stable woven fabric like twill or canvas to sew out at the intended size."),
        ]),
        GlossarySection(title: "Machine & Production Terms", entries: [
            GlossaryEntry(term: "Trim",
                           definition: "A command that cuts the thread. Inserted automatically between color changes and across a long gap between same-color objects, so the machine doesn't drag a visible strand of thread across exposed fabric."),
            GlossaryEntry(term: "Jump",
                           definition: "The needle moves to a new position without stitching -- a \"travel\" move. A jump that's too long (and not trimmed) can leave a visible thread strand across the design, which is exactly what a trim before it prevents."),
            GlossaryEntry(term: "Color Change",
                           definition: "A stop point where the machine pauses for a thread color swap. Fewer color changes means faster, less error-prone production -- part of why merging colors and choosing a sensible object sewing order both matter."),
            GlossaryEntry(term: "Tie-In / Tie-Off",
                           definition: "A few small anchor stitches sewn at the start and end of each thread color, locking the thread in place so it can't work loose or pull out -- standard practice, applied automatically here."),
            GlossaryEntry(term: "Hoop",
                           definition: "The frame that holds fabric taut while it's being sewn. A design must fit within the hoop's usable sewing area -- this app checks the current design against your selected hoop and flags it if it doesn't fit."),
            GlossaryEntry(term: "Stitch Count",
                           definition: "The total number of individual needle penetrations in the design. Roughly proportional to how long the design takes to sew and how much thread it uses -- a useful sanity check before sending a design to production."),
        ]),
        GlossarySection(title: "Quality", entries: [
            GlossaryEntry(term: "Embroidery Readiness Score",
                           definition: "An automatic 0-100 score (shown at the bottom-right of the window and in the Inspector) checking a design for known problem patterns -- stitches that are too long or too short, a design that doesn't fit the selected hoop, and similar issues. Updates live as you edit, so you can watch it improve as you fix what it flags. A high score means fewer surprises at the embroidery machine, not a guarantee of a perfect sew-out."),
        ]),
    ]

    private var filteredSections: [GlossarySection] {
        guard !searchText.isEmpty else { return sections }
        return sections.compactMap { section in
            let matches = section.entries.filter {
                $0.term.localizedCaseInsensitiveContains(searchText) || $0.definition.localizedCaseInsensitiveContains(searchText)
            }
            return matches.isEmpty ? nil : GlossarySection(title: section.title, entries: matches)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Digitizing Terms").font(.title3).fontWeight(.semibold).padding()
            Divider()

            TextField("Search terms...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.top, 8)

            List {
                ForEach(filteredSections) { section in
                    Section(section.title) {
                        ForEach(section.entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.term).font(.headline)
                                Text(entry.definition)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                if filteredSections.isEmpty {
                    Text("No terms match \"\(searchText)\".")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 480, height: 560)
    }
}
