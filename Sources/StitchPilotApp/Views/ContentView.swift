import SwiftUI
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
                StitchCanvasView(document: app.document, stitchPlan: app.stitchPlan)
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
            ToolbarItemGroup {
                Button {
                    openFilePicker()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                Button {
                    app.autoDigitize()
                } label: {
                    Label("Auto Digitize", systemImage: "wand.and.stars")
                }
                .disabled(app.document == nil)
                Button {
                    app.exportDST()
                } label: {
                    Label("Export DST", systemImage: "square.and.arrow.up")
                }
                .disabled(app.stitchPlan == nil)
            }
        }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .alert("StitchPilot", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    private var dropPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Drop an image or SVG file here")
                .foregroundStyle(.secondary)
        }
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

    private func openFilePicker() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.svg, .png, .jpeg, .tiff, .bmp, .gif]
        if let webp = UTType(filenameExtension: "webp") { types.append(webp) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            app.importFile(url: url)
        }
    }
}

private struct ObjectListView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Objects").font(.headline).padding(12)
            Divider()
            if let document = app.document, !document.objects.isEmpty {
                List(document.objects) { object in
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
