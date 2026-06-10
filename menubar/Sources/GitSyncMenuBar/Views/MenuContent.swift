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
                let counts = anomalyCounts(in: last.outcomes)
                Divider()
                Text("Anomalies (\(state.anomalyCount))")
                ForEach(counts, id: \.status) { entry in
                    Text("\(entry.status.displayName): \(entry.count)")
                }
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

    private struct AnomalyEntry: Hashable {
        let status: SyncStatus
        let count: Int
    }

    private func anomalyCounts(in outcomes: [Outcome]) -> [AnomalyEntry] {
        let anomalies = outcomes.filter(\.status.isAnomaly)
        let grouped = Dictionary(grouping: anomalies, by: \.status)
        return grouped
            .map { AnomalyEntry(status: $0.key, count: $0.value.count) }
            .sorted { $0.status.rawValue < $1.status.rawValue }
    }
}
