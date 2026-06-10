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
                .onAppear {
                    _ = state.scheduler   // ensure scheduler is built
                    installTerminationGuard()
                }
        } label: {
            Image(systemName: state.menuBarIconName)
                .symbolEffect(.pulse, options: .repeating, isActive: state.isRunning)
                .foregroundStyle(state.showsAttention ? Color.orange : Color.primary)
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

    // Quit-while-running cleanup. Without this, the .app's process exits
    // and macOS reaps the Python children with SIGTERM — usually fine, but
    // a child mid-clone can leave a .git/*.lock behind. We send a polite
    // SIGTERM ourselves so the scripts' own SIGINT handler runs first.
    private func installTerminationGuard() {
        let appState = state
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in appState.cancelRun() }
        }
    }
}
