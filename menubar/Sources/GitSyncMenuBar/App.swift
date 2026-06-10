import SwiftUI

@main
struct GitSyncMenuBarApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var state: AppState

    init() {
        // CLI-mode entry points. Detected at startup so we don't spin up a
        // GUI for tooling commands.
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--verify-parser") {
            exit(VerifyParser.run())
        }
        if args.contains("--smoke-test") {
            exit(SmokeTest.run())
        }

        // Settings has to exist before AppState so the runner picks up the
        // user's stored sync settings on first event-loop tick.
        let settingsStore = SettingsStore()
        _settings = StateObject(wrappedValue: settingsStore)
        _state = StateObject(wrappedValue: AppState(settings: settingsStore))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
                .environmentObject(settings)
        } label: {
            Label("git-sync", systemImage: state.menuBarIconName)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsWindow()
                .environmentObject(settings)
        }
    }
}
