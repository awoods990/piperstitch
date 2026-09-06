import SwiftUI

@main
struct StitchPilotApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("OneClickStitch") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
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
            }
        }
    }
}
