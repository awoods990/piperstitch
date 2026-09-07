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

    var body: some View {
        HStack(spacing: 0) {
            ObjectListView()
                .frame(width: 220)
            Divider()

            ZStack {
                StitchCanvasView(document: app.document, stitchPlan: app.stitchPlan, colors: app.lastColorSequence,
                                  hoop: app.selectedHoop, selectedObjectIDs: app.selectedObjectIDs,
                                  onSelectionChange: { app.selectedObjectIDs = $0 },
                                  isPaintMode: app.isPaintMode,
                                  paintColor: Color(red: Double(app.paintColorRGB.r) / 255, green: Double(app.paintColorRGB.g) / 255, blue: Double(app.paintColorRGB.b) / 255),
                                  paintBrushRadiusMM: app.paintBrushRadiusMM,
                                  onPaintStroke: { app.paintStroke(points: $0, radiusMM: app.paintBrushRadiusMM) })
                if app.document == nil {
                    dropPrompt
                }
                if isTargeted {
                    Rectangle().stroke(Color.accentColor, lineWidth: 3).padding(4)
                }
            }
            .frame(minWidth: 420, minHeight: 420)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)

            Divider()
            InspectorView()
                .frame(width: 260)
        }
        .toolbar {
            // The One-Click Stitch action: styled with the app's own mark
            // and a prominent tint so it's unmistakably *the* button in
            // this toolbar, not one of an equal-weight row of icons —
            // everything else here is a secondary/manual path for users
            // who want to inspect or adjust before exporting. There's no
            // separate "Auto Digitize" action any more: every edit
            // (import, resize, per-object parameter change, color merge)
            // regenerates the preview on its own a moment later, so this
            // button's only remaining job is the export step itself.
            ToolbarItemGroup {
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

                // Kept directly beside the primary action -- "redo the
                // whole thing from scratch" is the natural undo-adjacent
                // counterpart to "create," not a filing/editing action like
                // the New/Open/Save group below.
                Button {
                    showingRedoConfirm = true
                } label: {
                    Label("Redo from Original", systemImage: "arrow.clockwise")
                }
                .disabled(!app.hasOriginalArtwork)
                .help("Discard edits made since import and regenerate fresh from the original artwork.")
                .confirmationDialog("Redo from the original artwork? Edits made since import (color merges, per-object overrides, deletions) will be discarded.",
                                     isPresented: $showingRedoConfirm, titleVisibility: .visible) {
                    Button("Redo from Original", role: .destructive) { app.redoEmbroideryFileCreation() }
                    Button("Cancel", role: .cancel) {}
                }
            }

            ToolbarItemGroup {
                Button {
                    if app.document == nil {
                        app.newProject()
                    } else {
                        showingNewProjectConfirm = true
                    }
                } label: {
                    Label("New Project", systemImage: "doc.badge.plus")
                }
                .confirmationDialog("Start a new project? The current design will be closed without saving.",
                                     isPresented: $showingNewProjectConfirm, titleVisibility: .visible) {
                    Button("Start New Project", role: .destructive) { app.newProject() }
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
                    Label("Save Project", systemImage: "square.and.arrow.down")
                }
                .disabled(app.document == nil)

                Button {
                    app.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!app.canUndo)
                .help("Undo the last edit.")
            }

            ToolbarItemGroup {
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
            }

            ToolbarItemGroup {
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
                if app.isPaintMode {
                    Slider(value: cmBinding($app.paintBrushRadiusMM), in: 0.05...1.0)
                        .frame(width: 90)
                        .help("Brush size")
                    ColorPicker("", selection: Binding(
                        get: { Color(red: Double(app.paintColorRGB.r) / 255, green: Double(app.paintColorRGB.g) / 255, blue: Double(app.paintColorRGB.b) / 255) },
                        set: { app.paintColorRGB = rgbColor(from: $0) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
            }

            ToolbarItemGroup {
                // "Export" saves a file to disk -- a download, not an
                // upload, hence the down-arrow icon (an earlier version of
                // this button used an up-arrow, which reads as "send," the
                // job Share below actually does).
                Menu {
                    Button("Tajima (.dst)") { app.exportDST() }
                    Button("Brother/Baby Lock (.pes)") { app.exportPES() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(app.stitchPlan == nil)
                Menu {
                    Button("Tajima (.dst)") { app.shareCurrentFile(format: .dst) }
                    Button("Brother/Baby Lock (.pes)") { app.shareCurrentFile(format: .pes) }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(app.stitchPlan == nil)
                .help("Send the embroidery file via AirDrop, Mail, Messages, and more.")
            }
        }
        .sheet(isPresented: $showingMergeColors) { MergeColorsSheet() }
        .sheet(isPresented: $showingThreadLibrary) { ThreadLibrarySheet() }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .alert("OneClickStitch", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
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
    }

    private var statusBar: some View {
        HStack {
            if app.isBusy { ProgressView().controlSize(.small) }
            Text(app.statusMessage)
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { app.importFile(url: url) }
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
                    LabeledContent("Colors", value: "\(app.document?.objects.count ?? 0)")
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

                Picker("Stitch Type", selection: binding(object, \.stitchType)) {
                    ForEach(StitchType.allCases, id: \.self) { type in
                        Text(label(for: type)).tag(type)
                    }
                }

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
