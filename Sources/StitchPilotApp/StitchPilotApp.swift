import SwiftUI
import AppKit

@main
struct StitchPilotApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        // A fresh window (first launch, or "New Window") opens at 80% of
        // the current display rather than an arbitrary fixed size, so it
        // scales sensibly across a small laptop screen and a large
        // external monitor alike. `visibleFrame` (not `frame`) excludes
        // the menu bar/Dock, matching what's actually available to size
        // into. Only affects a window with no saved frame to restore --
        // macOS's own window-state restoration still takes over on a
        // normal relaunch, this isn't fighting that.
        let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)

        WindowGroup("OneClickStitch") {
            ContentView()
                .environmentObject(appState)
                // Must clear the three panels' own minimum widths (176 +
                // 504 + 300, plus dividers -- see ContentView's HStack) or
                // this constraint silently loses to theirs.
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: screenSize.width * 0.8, height: screenSize.height * 0.8)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Artwork...") { appState.openArtworkWithPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open Project...") { appState.openProjectWithPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Save Project...") { appState.saveProject() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(appState.document == nil)
            }
            CommandGroup(after: .saveItem) {
                Divider()
                Button("Export DST...") { appState.exportDST() }
                    .disabled(appState.stitchPlan == nil)
                Button("Export PES...") { appState.exportPES() }
                    .disabled(appState.stitchPlan == nil)
                Button("Export EXP...") { appState.exportEXP() }
                    .disabled(appState.stitchPlan == nil)
                Button("Export JEF...") { appState.exportJEF() }
                    .disabled(appState.stitchPlan == nil)
            }
        }
    }
}
