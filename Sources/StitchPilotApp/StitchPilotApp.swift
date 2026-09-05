import SwiftUI

@main
struct StitchPilotApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("StitchPilot") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
