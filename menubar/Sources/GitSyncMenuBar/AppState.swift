import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var currentRun: RunRecord?
    @Published var lastRun: RunRecord?
    @Published var dismissedRunID: UUID?
    // Per-platform live worker state during a run. Keyed by platform name;
    // each value maps `rel` (repo path under the platform root) to its
    // current phase + percentage. Empty between runs.
    @Published var activeWorkers: [String: [String: WorkerView]] = [:]

    private let settingsStore: SettingsStore
    private let history: HistoryStore
    private(set) lazy var runner: SyncRunner = SyncRunner(settings: settingsStore.currentSyncSettings)
    private(set) lazy var scheduler: Scheduler = Scheduler(state: self, settings: settingsStore)

    init(settings: SettingsStore, history: HistoryStore) {
        self.settingsStore = settings
        self.history = history
    }

    // Called by App.swift whenever a schedule-related setting changes,
    // so the timer reflects the new mode/interval without an app restart.
    func rescheduleIfNeeded() {
        scheduler.reschedule()
    }

    var isRunning: Bool { currentRun != nil }

    var anomalyCount: Int {
        (lastRun?.outcomes ?? []).filter(\.status.isAnomaly).count
    }

    var showsAttention: Bool {
        guard let lastRun, anomalyCount > 0 else { return false }
        return dismissedRunID != lastRun.id
    }

    var menuBarIconName: String {
        if isRunning { return "arrow.triangle.2.circlepath" }
        if showsAttention { return "exclamationmark.triangle" }
        return "arrow.triangle.2.circlepath"
    }

    func dismissCurrentNotification() {
        dismissedRunID = lastRun?.id
    }

    func startRun() {
        guard !isRunning else { return }
        currentRun = RunRecord()
        // Fresh run starts; clear the dismissal so a new attention badge
        // can appear at the end if this run finds anomalies.
        dismissedRunID = nil
        activeWorkers = [:]
        // Pick up any settings edits the user made since the last run.
        let snapshot = settingsStore.currentSyncSettings
        Task {
            await runner.updateSettings(snapshot)
            await runner.startRun(delegate: self)
        }
    }

    func cancelRun() {
        Task { await runner.cancel() }
    }
}

struct WorkerView: Hashable, Sendable {
    var op: String
    var phase: String
    var pct: Int?
    var startedAt: Date
}

extension AppState: SyncRunnerDelegate {
    nonisolated func runner(_ runner: SyncRunner, didReceive event: SyncEvent) async {
        await MainActor.run { self.apply(event) }
    }

    nonisolated func runner(_ runner: SyncRunner, didReceiveLogLine line: String, platform: String) async {
        await MainActor.run {
            self.currentRun?.logLines.append("[\(platform)] \(line)")
        }
    }

    nonisolated func runner(_ runner: SyncRunner, didFinishPlatform platform: String, exitCode: Int32) async {
        await MainActor.run {
            self.currentRun?.exitCodes[platform] = exitCode
            self.activeWorkers[platform] = nil
        }
    }

    nonisolated func runnerDidFinishAllPlatforms(_ runner: SyncRunner) async {
        await MainActor.run {
            guard var run = self.currentRun else { return }
            run.endedAt = Date()
            self.lastRun = run
            self.currentRun = nil
            self.activeWorkers = [:]
            self.history.record(run)
        }
    }

    private func apply(_ event: SyncEvent) {
        switch event {
        case .sessionStart, .sessionEnd:
            break
        case .workerStart(let platform, let rel, let op):
            activeWorkers[platform, default: [:]][rel] = WorkerView(
                op: op, phase: "starting", pct: nil, startedAt: Date()
            )
        case .workerPhase(let platform, let rel, let phase, let pct):
            if var w = activeWorkers[platform]?[rel] {
                w.phase = phase
                w.pct = pct
                activeWorkers[platform, default: [:]][rel] = w
            }
        case .workerFinish(let platform, let rel):
            activeWorkers[platform]?[rel] = nil
            if activeWorkers[platform]?.isEmpty == true {
                activeWorkers[platform] = nil
            }
        case .outcome(_, let outcome):
            currentRun?.outcomes.append(outcome)
        }
    }
}
