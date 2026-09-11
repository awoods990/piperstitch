import SwiftUI

/// The app's visual identity -- navy/thread-blue from the wordmark, a
/// caramel accent from the sandpiper, and a warm linen ground. Exact same
/// palette and component shapes as `website/styles.css`'s `:root` tokens
/// and its `.mock-*` app-window mockup, so the real app reads as the same
/// product as its own marketing site rather than a generic default-SwiftUI
/// look next to a designed one. Kept as a single source of truth here
/// rather than scattered literal colors so the two never drift apart again.
enum PSColor {
    static let navy900 = Color(red: 0x08 / 255, green: 0x1a / 255, blue: 0x33 / 255)
    static let navy800 = Color(red: 0x0f / 255, green: 0x2a / 255, blue: 0x4d / 255)
    static let navy700 = Color(red: 0x14 / 255, green: 0x3a / 255, blue: 0x6b / 255)
    static let navy600 = Color(red: 0x1a / 255, green: 0x4f / 255, blue: 0x8f / 255)
    static let blue500 = Color(red: 0x1a / 255, green: 0x6f / 255, blue: 0xd1 / 255)
    static let blue400 = Color(red: 0x3b / 255, green: 0x8e / 255, blue: 0xe6 / 255)
    static let blue200 = Color(red: 0xb9 / 255, green: 0xd4 / 255, blue: 0xf3 / 255)
    static let caramel600 = Color(red: 0xa8 / 255, green: 0x62 / 255, blue: 0x1f / 255)
    static let caramel500 = Color(red: 0xc0 / 255, green: 0x72 / 255, blue: 0x2a / 255)

    static let paper = Color(red: 0xf7 / 255, green: 0xf3 / 255, blue: 0xec / 255)
    static let panel = Color(red: 0xff / 255, green: 0xff / 255, blue: 0xfe / 255)
    static let ink = Color(red: 0x12 / 255, green: 0x16 / 255, blue: 0x1c / 255)
    static let ink2 = Color(red: 0x3a / 255, green: 0x42 / 255, blue: 0x4e / 255)
    static let muted = Color(red: 0x5d / 255, green: 0x64 / 255, blue: 0x72 / 255)
    static let label = Color(red: 0x8b / 255, green: 0x90 / 255, blue: 0x99 / 255)
    static let line = Color(red: 0xe6 / 255, green: 0xe0 / 255, blue: 0xd4 / 255)
    static let line2 = Color(red: 0xea / 255, green: 0xe7 / 255, blue: 0xe0 / 255)
    static let rowLine = Color(red: 0xf0 / 255, green: 0xed / 255, blue: 0xe6 / 255)

    static let readyBG = Color(red: 0xe9 / 255, green: 0xf3 / 255, blue: 0xec / 255)
    static let readyBorder = Color(red: 0xcf / 255, green: 0xe5 / 255, blue: 0xd5 / 255)
    static let readyText = Color(red: 0x2f / 255, green: 0x6b / 255, blue: 0x41 / 255)
    static let warnBG = Color(red: 0xfa / 255, green: 0xef / 255, blue: 0xe3 / 255)
    static let warnBorder = Color(red: 0xef / 255, green: 0xd9 / 255, blue: 0xb7 / 255)
    static let warnText = Color(red: 0x8a / 255, green: 0x5a / 255, blue: 0x1a / 255)
}

/// A section's small uppercase label -- "OBJECTS", "FINISHED SIZE" --
/// matching `.mock-side h5`/`.mock-insp h5` (10.5px, tracked, uppercase,
/// `#8b9099`). Used both as a plain header above a hand-laid-out block and
/// as a `Form` `Section`'s header, which is why it takes no parameters
/// beyond the text itself.
struct PSSectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(PSColor.label)
    }
}

/// A flat, hairline-divided settings section -- the Inspector's own
/// replacement for a `Form` `Section`, since a `Form`'s automatic grouped-
/// box chrome on macOS is exactly the "default SwiftUI" look this is
/// moving away from. Every native control (`Picker`, `TextField`,
/// `Toggle`, `Slider`) still works fine directly inside a plain
/// `VStack` -- this just supplies the header and the bottom-border
/// separator between sections, matching `.mock-side`/`.mock-insp`'s
/// hairline dividers.
struct PSSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PSSectionLabel(title)
            content
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(PSColor.line2).frame(height: 1) }
    }
}

/// One label/value line inside an inspector-style panel -- matching
/// `.mock-row` (space-between, a hairline bottom border, muted label,
/// bold navy value).
struct PSRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack {
            Text(label).foregroundStyle(PSColor.ink2)
            Spacer()
            Text(value).fontWeight(.semibold).foregroundStyle(PSColor.navy800)
        }
        .font(.system(size: 12))
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(PSColor.rowLine).frame(height: 1) }
    }
}

/// The readiness/status card -- matching `.mock-score`: a tinted rounded
/// card, green when ready, a warmer tone when review is recommended (the
/// mockup only ever shows the green "ready" state, so the not-ready
/// palette here is this app's own extension of the same language, not
/// copied from a CSS rule).
struct PSStatusCard: View {
    let title: String
    let detail: String
    let isPositive: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).lineSpacing(2)
        }
        .foregroundStyle(isPositive ? PSColor.readyText : PSColor.warnText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(isPositive ? PSColor.readyBG : PSColor.warnBG, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(isPositive ? PSColor.readyBorder : PSColor.warnBorder, lineWidth: 1))
    }
}

/// A toolbar action -- matching `.mock-toolbar u`: a small bordered pill,
/// `#4c5361` text on white, no fill until hovered/pressed. This is every
/// secondary toolbar button's style; the one primary action per row
/// (`PSPrimaryButtonStyle`) stays visually distinct from these.
///
/// `isHighlighted`/`accent` replace the old `.tint(...)`-based "this
/// toggle is currently on" styling (active Paint/Erase mode, an always-
/// relevant Detected Text callout) -- a custom `ButtonStyle` doesn't
/// automatically pick up an ancestor's `.tint()` the way `.borderless`
/// did, so that state has to be passed in explicitly instead.
struct PSPillButtonStyle: ButtonStyle {
    var accent: Color = PSColor.blue500
    var isHighlighted: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let color = isHighlighted ? accent : PSColor.ink2
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(isHighlighted ? accent.opacity(0.12) : (configuration.isPressed ? PSColor.line2 : PSColor.panel),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(isHighlighted ? accent : PSColor.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The one prominent action per toolbar row -- matching `.mock-toolbar
/// u.go`: solid `blue-500`, white bold text, same pill shape as the
/// secondary buttons so it reads as "the same kind of control, just the
/// important one" rather than a completely different control type.
struct PSPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(PSColor.blue500.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 7))
    }
}

extension View {
    /// Applies `PSSectionLabel`'s styling to a `Form` `Section`'s own
    /// header, so a native `Section("Title")` and a hand-laid-out block
    /// both carry identical header typography.
    func psSectionHeader() -> some View {
        self.font(.system(size: 10.5, weight: .semibold)).tracking(1.1).foregroundStyle(PSColor.label)
    }
}
