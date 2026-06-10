import SwiftUI

@main
struct GitSyncMenuBarApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var history: HistoryStore
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

        // Order matters: settings + history must exist before AppState so the
        // runner picks up the user's stored settings and the history store
        // can record runs as they finish.
        let settingsStore = SettingsStore()
        let historyStore = HistoryStore()
        _settings = StateObject(wrappedValue: settingsStore)
        _history  = StateObject(wrappedValue: historyStore)
        _state    = StateObject(wrappedValue: AppState(settings: settingsStore, history: historyStore))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
                .environmentObject(settings)
                .environmentObject(history)
                .onAppear { _ = state.scheduler }   // ensure scheduler is built
        } label: {
            Label("git-sync", systemImage: state.menuBarIconName)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsWindow()
                .environmentObject(settings)
                .onChange(of: settings.scheduleMode) { _, _ in state.rescheduleIfNeeded() }
                .onChange(of: settings.scheduleHours) { _, _ in state.rescheduleIfNeeded() }
                .onChange(of: settings.scheduleDailyHour) { _, _ in state.rescheduleIfNeeded() }
                .onChange(of: settings.scheduleDailyMinute) { _, _ in state.rescheduleIfNeeded() }
        }

        Window("Run history", id: "history") {
            HistoryWindow()
                .environmentObject(history)
        }
        .windowResizability(.contentSize)
    }
}
