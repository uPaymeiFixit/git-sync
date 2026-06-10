import SwiftUI

struct MenuContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    var body: some View {
        if state.isRunning {
            Text("Running…")
            if !state.activeWorkers.isEmpty {
                Divider()
                ForEach(Platform.allCases, id: \.rawValue) { platform in
                    if let workers = state.activeWorkers[platform.rawValue], !workers.isEmpty {
                        Text("\(platform.displayName): \(workers.count) worker(s)")
                    }
                }
            }
        } else if let last = state.lastRun {
            Text("Last run: \(last.startedAt.formatted(.relative(presentation: .named)))")
            if state.anomalyCount > 0 {
                Divider()
                AnomaliesSubmenu(outcomes: last.outcomes)
            }
        } else {
            Text("No runs yet")
        }

        Divider()

        Button("Run now") {
            state.startRun()
        }
        .disabled(state.isRunning)
        .keyboardShortcut("r", modifiers: .command)

        Button("Dismiss notification") {
            state.dismissCurrentNotification()
        }
        .disabled(!state.showsAttention)
        .keyboardShortcut("d", modifiers: .command)

        if state.isRunning {
            Button("Cancel run") {
                state.cancelRun()
            }
        }

        Divider()

        Button("Show history…") {
            openWindow(id: "history")
        }
        .keyboardShortcut("h", modifiers: .command)

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Check for updates…") {
            Task { await UpdateChecker.check() }
        }

        Toggle("Launch at login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, newValue in
                _ = LaunchAtLogin.setEnabled(newValue)
                // Re-read the system state in case registration failed.
                launchAtLogin = LaunchAtLogin.isEnabled
            }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

}

// One submenu per non-optimal status, each containing the actual repos
// that hit that status. Clicking a repo opens the platform root in
// Finder with that subdirectory selected (so the user sees it in context
// rather than having Finder open the leaf directory in isolation).
private struct AnomaliesSubmenu: View {
    @EnvironmentObject private var settings: SettingsStore
    let outcomes: [Outcome]

    var body: some View {
        let anomalies = outcomes.filter(\.status.isAnomaly)
        let grouped = Dictionary(grouping: anomalies, by: \.status)
        let sortedStatuses = grouped.keys.sorted { $0.rawValue < $1.rawValue }

        Text("Anomalies (\(anomalies.count))")
        ForEach(sortedStatuses, id: \.self) { status in
            let group = grouped[status] ?? []
            Menu("\(status.displayName) (\(group.count))") {
                ForEach(group, id: \.id) { outcome in
                    Button(outcome.rel) { reveal(outcome) }
                }
            }
        }
    }

    private func reveal(_ outcome: Outcome) {
        let root = URL(fileURLWithPath: settings.syncRoot)
        let target = root.appendingPathComponent(outcome.rel)
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            // Stale-on-disk repos may have been deleted between scans;
            // fall back to opening the platform root.
            NSWorkspace.shared.open(root)
        }
    }
}
