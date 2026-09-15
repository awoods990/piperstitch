import SwiftUI
import AppKit
import StitchPilotCore

/// The questions PiperStitch asks right after a fresh import, as a short
/// stepped flow of tappable choices rather than a settings form: where the
/// design is going, how big, which hoop, what it's sewn on, how many
/// thread colours. Each answer nudges the next step -- pick "Cap / Hat
/// Front" and the fabric step leads with the three headwear options and
/// pre-selects a structured cap; pick a hoop and the size step says
/// whether the design fits it -- so it reads as the app adapting to the
/// person, not the person filling in the app's fields.
///
/// Every choice binds to the same `AppState` properties the Inspector
/// exposes, so nothing here is a one-time gate; but the stitch preview is
/// deliberately withheld until the last step (`AppState.displayedStitchPlan`),
/// so the first stitches the user sees were generated from their answers.
struct ImportSetupSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable {
        case placement, size, hoop, fabric, colors

        var title: String {
            switch self {
            case .placement: return "Where is this going?"
            case .size: return "How big should it be?"
            case .hoop: return "Which hoop will you use?"
            case .fabric: return "What will it be sewn on?"
            case .colors: return "How many thread colours?"
            }
        }
    }

    private enum Placement: Hashable {
        case preset(GarmentSizePreset)
        case custom
    }

    private enum HoopChoice: Hashable {
        case specific(HoopProfile)
        case recommend
        case none
    }

    @State private var step: Step = .placement
    @State private var placement: Placement?
    @State private var hoopChoice: HoopChoice?
    /// The size the recommender picked from the artwork before any answer,
    /// so the size step can offer it back as "Recommended".
    @State private var recommendedWidthMM: Double = 0
    @State private var recommendedHeightMM: Double = 0

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(step.title).font(.title2.weight(.semibold)).foregroundStyle(PSColor.navy800)
                    Text(subtitle).font(.callout).foregroundStyle(PSColor.muted).fixedSize(horizontal: false, vertical: true)
                    stepContent
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 540)
        .background(PSColor.paper)
        .onAppear {
            recommendedWidthMM = app.physicalWidthMM
            recommendedHeightMM = app.physicalHeightMM
            hoopChoice = app.selectedHoop.map { .specific($0) }
        }
    }

    // MARK: - chrome

    private var header: some View {
        HStack(spacing: 12) {
            if let url = Bundle.module.url(forResource: "PiperStitchIcon", withExtension: "png"), let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Let's set up this design").font(.headline).foregroundStyle(PSColor.navy800)
                Text("Five quick questions. Everything can be changed later in the Inspector.").font(.caption).foregroundStyle(PSColor.muted)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? PSColor.blue500 : PSColor.line)
                        .frame(width: s == step ? 22 : 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: step)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(PSColor.panel)
    }

    private var footer: some View {
        HStack {
            if step != .placement {
                Button("Back") { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .placement } }
            }
            Spacer()
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)").font(.caption).foregroundStyle(PSColor.muted)
            Spacer()
            if step == .colors {
                Button {
                    dismiss()  // AppState runs the deferred digitize when the sheet closes
                } label: {
                    Label("Create My Stitch Preview", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(PSColor.blue500)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") { withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .colors } }
                    .buttonStyle(.borderedProminent)
                    .tint(PSColor.blue500)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .placement && placement == nil)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(PSColor.panel)
    }

    // MARK: - adaptive copy

    private var isCapDesign: Bool {
        if case .preset(let p) = placement { return p.name.localizedCaseInsensitiveContains("cap") || p.name.localizedCaseInsensitiveContains("hat") }
        return false
    }

    private var subtitle: String {
        switch step {
        case .placement:
            return "Pick the spot on the garment and I'll start from the size that's standard there."
        case .size:
            if case .preset(let p) = placement { return "Standard for \(p.name.lowercased()) is \(cm(p.widthMM)) × \(cm(p.heightMM)) cm. Adjust if you like — the finest detail in your artwork looks good down to about \(cm(recommendedWidthMM)) cm wide." }
            return "Based on the finest detail in your artwork, I'd suggest about \(cm(recommendedWidthMM)) × \(cm(recommendedHeightMM)) cm. Type any size you want."
        case .hoop:
            return isCapDesign
                ? "Cap frames vary by machine — pick the closest size, or let me choose one that fits."
                : "I'll warn you if the design won't fit. Not sure? Let me pick the smallest one that does."
        case .fabric:
            return isCapDesign
                ? "For a cap front I've started with a structured cap. A stiff buckram front barely pulls; a soft cap or a knit beanie pulls a lot more, so I compensate differently for each."
                : "Stretchier material pulls more as it sews, so I widen the shapes more to keep the finished size true."
        case .colors:
            return "Fewer colours means fewer thread changes and a faster sew-out. Vector artwork always keeps its own colours."
        }
    }

    // MARK: - steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .placement: placementStep
        case .size: sizeStep
        case .hoop: hoopStep
        case .fabric: fabricStep
        case .colors: colorsStep
        }
    }

    private var placementStep: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(GarmentSizePreset.standardPresets) { preset in
                ChoiceButton(title: preset.name, subtitle: "\(cm(preset.widthMM)) × \(cm(preset.heightMM)) cm", symbol: symbol(for: preset), selected: placement == .preset(preset)) {
                    let placementChanged = placement != .preset(preset)
                    placement = .preset(preset)
                    app.applyGarmentSizePreset(preset)
                    // Predicts the fabric step's own answer from the
                    // placement the moment it's picked -- a polo shirt is
                    // knit, a cap front is a structured buckram panel --
                    // so that step already starts somewhere sensible
                    // instead of the generic "Standard" default, the same
                    // "choosing one answer pre-chooses the logical next
                    // one" adaptiveness the fabric-leads-with-headwear
                    // reordering below already does. Guarded on the
                    // placement actually *changing* so re-tapping the same
                    // already-selected card doesn't stomp a fabric the
                    // user has since deliberately picked for themselves.
                    if placementChanged, let predicted = predictedFabric(for: preset) {
                        app.selectedFabricType = predicted
                    }
                }
            }
            ChoiceButton(title: "Something else", subtitle: "I'll set the size myself", symbol: "ruler", selected: placement == .custom) {
                placement = .custom
            }
        }
    }

    /// Deliberately conservative: only the placements whose *name* names
    /// an actual garment/material commits to a guess (a bare "Left Chest"
    /// or "Sleeve" could be on anything from a woven jacket to a knit tee,
    /// so those are left alone rather than guessing wrong and requiring a
    /// correction the user didn't ask for).
    private func predictedFabric(for preset: GarmentSizePreset) -> FabricType? {
        let n = preset.name.lowercased()
        if n.contains("cap") || n.contains("hat") { return .structuredCap }
        if n.contains("polo") { return .knit }
        return nil
    }

    private var sizeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if case .preset(let p) = placement {
                    ChoiceButton(title: "Standard \(p.name.lowercased())", subtitle: "\(cm(p.widthMM)) × \(cm(p.heightMM)) cm", symbol: "checkmark.seal", selected: approx(app.physicalWidthMM, p.widthMM)) {
                        app.applyGarmentSizePreset(p)
                    }
                }
                ChoiceButton(title: "Recommended for this artwork", subtitle: "\(cm(recommendedWidthMM)) × \(cm(recommendedHeightMM)) cm", symbol: "wand.and.stars", selected: approx(app.physicalWidthMM, recommendedWidthMM)) {
                    app.physicalWidthMM = recommendedWidthMM
                    app.physicalHeightMM = recommendedHeightMM
                    app.applyPhysicalSizeChange()
                }
            }
            HStack(spacing: 10) {
                Text("Width").foregroundStyle(PSColor.muted)
                TextField("cm", value: cmBinding($app.physicalWidthMM), format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                    .onSubmit { app.applyPhysicalSizeChange() }
                Text("×").foregroundStyle(PSColor.muted)
                Text("Height").foregroundStyle(PSColor.muted)
                TextField("cm", value: cmBinding($app.physicalHeightMM), format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                    .disabled(app.lockAspectRatio)
                    .onSubmit { app.applyPhysicalSizeChange() }
                Text("cm").foregroundStyle(PSColor.muted)
                Spacer()
                Toggle("Keep proportions", isOn: $app.lockAspectRatio).toggleStyle(.checkbox)
            }
            if let hoop = app.selectedHoop {
                fitNote(for: hoop)
            }
        }
    }

    private var hoopStep: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(HoopProfile.commonHoops) { hoop in
                let fits = hoop.widthMM >= app.physicalWidthMM && hoop.heightMM >= app.physicalHeightMM
                ChoiceButton(title: hoop.name, subtitle: fits ? "\(cm(hoop.widthMM)) × \(cm(hoop.heightMM)) cm · fits" : "too small for \(cm(app.physicalWidthMM)) cm", symbol: "square.dashed", selected: hoopChoice == .specific(hoop), warning: !fits) {
                    hoopChoice = .specific(hoop)
                    app.selectedHoop = hoop
                }
            }
            ChoiceButton(title: "Choose one for me", subtitle: "the smallest that fits", symbol: "wand.and.stars", selected: hoopChoice == .recommend) {
                let recommended = HoopProfile.recommended(forDesignWidthMM: app.physicalWidthMM, heightMM: app.physicalHeightMM)
                app.selectedHoop = recommended
                hoopChoice = .specific(recommended)
            }
            ChoiceButton(title: "Skip for now", subtitle: "no fit check", symbol: "minus.circle", selected: hoopChoice == HoopChoice.none) {
                hoopChoice = HoopChoice.none
                app.selectedHoop = nil
            }
        }
    }

    private var fabricStep: some View {
        let headwear = FabricType.allCases.filter(\.isHeadwear)
        let garments: [FabricType] = [.standard, .stableWoven, .knit, .stretchKnit]
        let other: [FabricType] = [.terry, .leatherOrVinyl]
        let groups: [(String, [FabricType])] = isCapDesign
            ? [("Hats & caps", headwear), ("Garments", garments), ("Other", other)]
            : [("Garments", garments), ("Hats & caps", headwear), ("Other", other)]
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.0) { name, fabrics in
                VStack(alignment: .leading, spacing: 8) {
                    PSSectionLabel(name)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(fabrics, id: \.self) { fabric in
                            ChoiceButton(title: fabric.shortName, subtitle: fabricHint(fabric), symbol: fabricSymbol(fabric), selected: app.selectedFabricType == fabric) {
                                app.selectedFabricType = fabric
                            }
                        }
                    }
                }
            }
            // What to hoop it with (C6) -- shown for whichever fabric is picked.
            (Text("Stabilizer for \(app.selectedFabricType.shortName.lowercased()): ").fontWeight(.semibold).foregroundColor(PSColor.ink)
             + Text(app.selectedFabricType.stabilizerAdvice).foregroundColor(PSColor.muted))
                .font(.system(size: 12))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(PSColor.paper))
        }
    }

    private var colorsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ColorQuantizationPreset.allCases, id: \.self) { preset in
                    ChoiceButton(title: presetLabel(preset), subtitle: presetHint(preset), symbol: "paintpalette", selected: app.colorPreset == preset) {
                        app.colorPreset = preset
                    }
                }
            }
            Toggle("Match colours to my thread library", isOn: $app.matchToThreadLibrary).toggleStyle(.checkbox)
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            PSSectionLabel("Your choices")
            Text("\(placementName) · \(cm(app.physicalWidthMM)) × \(cm(app.physicalHeightMM)) cm · \(app.selectedHoop?.name ?? "no hoop") · \(app.selectedFabricType.displayName) · \(presetLabel(app.colorPreset))")
                .font(.callout).foregroundStyle(PSColor.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(PSColor.panel).overlay(RoundedRectangle(cornerRadius: 10).stroke(PSColor.line)))
    }

    // MARK: - helpers

    private func fitNote(for hoop: HoopProfile) -> some View {
        let fits = hoop.widthMM >= app.physicalWidthMM && hoop.heightMM >= app.physicalHeightMM
        return Label(fits ? "Fits your \(hoop.name) hoop." : "Won't fit your \(hoop.name) hoop — reduce the size or pick a bigger hoop next.",
                     systemImage: fits ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(fits ? PSColor.readyText : PSColor.warnText)
    }

    private var placementName: String {
        if case .preset(let p) = placement { return p.name }
        return "Custom placement"
    }

    private func symbol(for preset: GarmentSizePreset) -> String {
        let n = preset.name.lowercased()
        if n.contains("cap") || n.contains("hat") { return "graduationcap" }
        if n.contains("back") { return "rectangle.portrait" }
        if n.contains("sleeve") { return "rectangle.split.1x2" }
        return "tshirt"
    }

    private func fabricSymbol(_ f: FabricType) -> String {
        switch f {
        case .structuredCap, .unstructuredCap, .beanie: return "graduationcap"
        case .terry: return "cloud"
        case .leatherOrVinyl: return "bag"
        case .stretchKnit: return "figure.run"
        default: return "tshirt"
        }
    }

    private func fabricHint(_ f: FabricType) -> String {
        switch f {
        case .standard: return "not sure — a safe middle"
        case .stableWoven: return "twill, canvas, denim"
        case .knit: return "t-shirt, polo"
        case .stretchKnit: return "athletic, spandex blend"
        case .terry: return "towel, fleece"
        case .leatherOrVinyl: return "firm, no stretch"
        case .structuredCap: return "stiff buckram front"
        case .unstructuredCap: return "soft dad hat, bucket hat"
        case .beanie: return "stretchy knit hat"
        }
    }

    private func presetLabel(_ preset: ColorQuantizationPreset) -> String {
        switch preset {
        case .preserveArtwork: return "Keep every colour"
        case .normalEmbroidery: return "Normal embroidery"
        case .productionEfficient: return "Production efficient"
        case .minimalColors: return "As few as possible"
        }
    }

    private func presetHint(_ preset: ColorQuantizationPreset) -> String {
        switch preset {
        case .preserveArtwork: return "most faithful, most thread changes"
        case .normalEmbroidery: return "a good balance for most designs"
        case .productionEfficient: return "fewer changes, faster sew-out"
        case .minimalColors: return "simplest possible, quickest to sew"
        }
    }

    private func cm(_ mm: Double) -> String {
        let v = mm / 10
        return v.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    private func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.5 }

    private func cmBinding(_ mm: Binding<Double>) -> Binding<Double> {
        Binding(get: { mm.wrappedValue / 10 }, set: { mm.wrappedValue = $0 * 10 })
    }
}

/// A tappable answer card: icon, title, one-line hint, a blue ring when
/// chosen. Grid-friendly (fills its cell), and an amber ring when the
/// option is technically pickable but a bad idea (a hoop the design
/// doesn't fit).
private struct ChoiceButton: View {
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    var warning: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol).foregroundStyle(selected ? PSColor.blue500 : PSColor.muted)
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(PSColor.blue500) }
                }
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(PSColor.navy800).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.caption).foregroundStyle(warning ? PSColor.warnText : PSColor.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? PSColor.blue200.opacity(0.35) : PSColor.panel)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? PSColor.blue500 : (warning ? PSColor.warnBorder : PSColor.line), lineWidth: selected ? 2 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}
