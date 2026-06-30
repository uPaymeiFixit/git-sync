import SwiftUI

struct MenuContent: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var providers: ProviderStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !providers.isConfigured {
            Text("Not set up yet")
            Button("Set Up GitSync…") {
                openWindow(id: "onboarding")
                bringAppWindowsToFront()
            }
            Divider()
        }
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
            LastRunSummary(run: last, anomalyCount: state.anomalyCount)
        } else {
            Text("No runs yet")
        }

        Divider()

        Button("Run now") {
            state.startRun()
        }
        // A full run can't start while a full run OR any individual sync is
        // in flight (rule 1).
        .disabled(state.anyActivity)
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

        Button("Show repositories…") {
            openWindow(id: "repositories")
            bringAppWindowsToFront()
        }
        .keyboardShortcut("h", modifiers: .command)

        Button("Open activity log…") {
            ConsoleLog.open()
        }
        .keyboardShortcut("l", modifiers: .command)
        .help("Open a live, filtered tail of the sync/deletion log in Terminal")

        if providers.isConfigured {
            // Re-runnable setup for the already-configured (the unconfigured
            // case shows a more prominent "Set Up GitSync…" at the top).
            Button("Set Up GitSync…") {
                openWindow(id: "onboarding")
                bringAppWindowsToFront()
            }
        }

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)
        .simultaneousGesture(TapGesture().onEnded {
            // Nudge focus to the freshly-opened Settings window. SettingsLink
            // itself doesn't activate the app, so the window opens behind
            // whatever the user previously had in front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                bringAppWindowsToFront()
            }
        })

        Button("Check for updates…") {
            Task { await UpdateChecker.check() }
        }

        Divider()

        Button("Quit GitSync") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

// Pulled out so the dispatcher can return ONE View — SwiftUI ViewBuilders
// don't compose if/else-if/else chains nicely as inline @ViewBuilder
// computed properties inside a parent body that has other siblings.
private struct LastRunSummary: View {
    let run: LiveRun
    let anomalyCount: Int

    var body: some View {
        let when = run.startedAt.formatted(.relative(presentation: .named))
        let exits = Array(run.exitCodes.values)
        let spawnFailures = exits.filter { $0 < 0 }.count
        let nonZero = exits.filter { $0 != 0 && $0 != 2 }.count
        let allSkipped = !exits.isEmpty && exits.allSatisfy { $0 == 2 }

        if spawnFailures > 0 {
            Text("Last run \(when) — \(spawnFailures) platform(s) failed to start")
            Text("Check that the bundled scripts are present.")
                .foregroundStyle(.secondary)
        } else if anomalyCount > 0 {
            Text("Last run \(when) — \(anomalyCount) anomaly/anomalies")
            Divider()
            AnomaliesSubmenu(outcomes: run.outcomes)
        } else if nonZero > 0 && run.outcomes.isEmpty {
            // Some platforms exited non-zero with no outcomes — almost
            // always missing config (no host / org / workspace).
            Text("Last run \(when) — \(nonZero) platform(s) errored")
            Text("Configure credentials in Settings → Platforms.")
                .foregroundStyle(.secondary)
        } else if allSkipped {
            Text("Last run \(when) — all platforms skipped")
            Text("Configure credentials in Settings → Platforms.")
                .foregroundStyle(.secondary)
        } else {
            Text("Last run \(when) — all clean")
        }
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
            NSWorkspace.shared.open(root)
        }
    }
}

