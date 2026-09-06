import SwiftUI
import AppKit
import StitchPilotCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            ObjectListView()
                .frame(width: 220)
            Divider()

            ZStack {
                StitchCanvasView(document: app.document, stitchPlan: app.stitchPlan, colors: app.lastColorSequence,
                                  hoop: app.selectedHoop, selectedObjectID: app.selectedObjectID)
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
            // who want to inspect or adjust before exporting.
            ToolbarItem {
                Button {
                    app.createEmbroideryFile()
                } label: {
                    HStack(spacing: 6) {
                        brandMark(size: 18)
                        Text("Create Embroidery File").fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.09, green: 0.42, blue: 0.72))
                .disabled(app.document == nil)
                .help("One click: digitize this artwork and save it as a machine embroidery file.")
            }

            ToolbarItemGroup {
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
                    app.autoDigitize()
                } label: {
                    Label("Auto Digitize", systemImage: "wand.and.stars")
                }
                .disabled(app.document == nil)
                Menu {
                    Button("Tajima (.dst)") { app.exportDST() }
                    Button("Brother/Baby Lock (.pes)") { app.exportPES() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(app.stitchPlan == nil)
            }
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
                List(document.objects, selection: $app.selectedObjectID) { object in
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
                            app.selectedObjectID = object.id
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

    var body: some View {
        Form {
            if app.selectedObject != nil {
                ObjectInspectorSection()
            }

            Section("Finished Size") {
                HStack {
                    TextField("Width (mm)", value: $app.physicalWidthMM, format: .number)
                        .onSubmit { app.applyPhysicalSizeChange() }
                    Text("×")
                    TextField("Height (mm)", value: $app.physicalHeightMM, format: .number)
                        .disabled(app.lockAspectRatio)
                        .onSubmit { app.applyPhysicalSizeChange() }
                }
                Toggle("Lock aspect ratio", isOn: $app.lockAspectRatio)
                Button("Apply Size") { app.applyPhysicalSizeChange() }
            }

            Section("Hoop") {
                Picker("Hoop", selection: $app.selectedHoop) {
                    Text("None").tag(HoopProfile?.none)
                    ForEach(HoopProfile.commonHoops) { hoop in
                        Text("\(hoop.name) (\(Int(hoop.widthMM))×\(Int(hoop.heightMM))mm)").tag(HoopProfile?.some(hoop))
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
                    LabeledContent("Max stitch", value: String(format: "%.2f mm", plan.maxStitchLength()))
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
}

/// Manual per-object overrides before the embroidery file is created: pick
/// an object in the list, then override its stitch type or any of the
/// generation parameters the engine otherwise chooses automatically.
/// `StitchGenerationParameters` supports many more knobs than shown here
/// (underlay inset, fill row stagger, filter thresholds); this exposes the
/// ones a digitizer actually reaches for regularly, not every field.
/// Edits update the master document immediately but don't re-flatten the
/// stitch plan on every keystroke — click Auto Digitize to see the result,
/// the same "edit, then explicitly regenerate" flow resizing already uses.
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
                    ForEach(ThreadLibrary.genericPalette) { color in
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
                    TextField("Stitch Length (mm)", value: binding(object, \.parameters.stitchLengthMM), format: .number)
                case .satin:
                    TextField("Density (mm)", value: binding(object, \.parameters.satinDensityMM), format: .number)
                    TextField("Max Width (mm)", value: binding(object, \.parameters.maxSatinWidthMM), format: .number)
                    TextField("Min Width (mm)", value: binding(object, \.parameters.minSatinWidthMM), format: .number)
                case .tatamiFill:
                    TextField("Row Spacing (mm)", value: binding(object, \.parameters.fillSpacingMM), format: .number)
                    optionalDoubleField(object, label: "Fill Angle (°)", keyPath: \.parameters.fillAngleDegrees, defaultManualValue: 0)
                }

                if object.stitchType == .satin || object.stitchType == .tatamiFill {
                    Picker("Underlay", selection: binding(object, \.parameters.underlayType)) {
                        Text("Automatic").tag(UnderlayType?.none)
                        ForEach(UnderlayType.allCases, id: \.self) { type in
                            Text(label(for: type)).tag(UnderlayType?.some(type))
                        }
                    }
                    optionalDoubleField(object, label: "Pull Compensation (mm)", keyPath: \.parameters.pullCompensationMM, defaultManualValue: 0.2)
                    optionalDoubleField(object, label: "Push Compensation (mm)", keyPath: \.parameters.pushCompensationMM, defaultManualValue: 0.2)
                }

                Text("Applies the next time you click Auto Digitize.")
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

    @ViewBuilder
    private func optionalDoubleField(_ object: EmbroideryObject, label: String, keyPath: WritableKeyPath<EmbroideryObject, Double?>, defaultManualValue: Double) -> some View {
        let isAutomatic = Binding<Bool>(
            get: { (app.selectedObject?[keyPath: keyPath] ?? object[keyPath: keyPath]) == nil },
            set: { auto in app.updateSelectedObject { $0[keyPath: keyPath] = auto ? nil : defaultManualValue } }
        )
        Toggle("\(label): Automatic", isOn: isAutomatic)
        if !isAutomatic.wrappedValue {
            TextField(label, value: Binding(
                get: { app.selectedObject?[keyPath: keyPath] ?? object[keyPath: keyPath] ?? defaultManualValue },
                set: { newValue in app.updateSelectedObject { $0[keyPath: keyPath] = newValue } }
            ), format: .number)
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
