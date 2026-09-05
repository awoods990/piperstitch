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
                        Text(object.name)
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

            if let plan = app.stitchPlan {
                Section("Production Statistics") {
                    LabeledContent("Stitches", value: "\(plan.stitchCount)")
                    LabeledContent("Colors", value: "\(app.document?.objects.count ?? 0)")
                    LabeledContent("Color changes", value: "\(plan.colorChangeCount)")
                    LabeledContent("Trims", value: "\(plan.trimCount)")
                    LabeledContent("Max stitch", value: String(format: "%.2f mm", plan.maxStitchLength()))
                }
            }
        }
        .formStyle(.grouped)
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
