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
    let eventBuffer = EventBuffer()
    private var drainTimer: Timer?
    private(set) lazy var runner: SyncRunner = SyncRunner(
        settings: settingsStore.currentSyncSettings,
        eventBuffer: eventBuffer
    )
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
        if isRunning      { return "arrow.triangle.2.circlepath" }
        if showsAttention { return "exclamationmark.triangle.fill" }
        return "arrow.triangle.2.circlepath"
    }

    func dismissCurrentNotification() {
        dismissedRunID = lastRun?.id
    }

    func startRun() {
        guard !isRunning else { return }
        currentRun = RunRecord()
        dismissedRunID = nil
        activeWorkers = [:]
        startDrainTimer()
        let snapshot = settingsStore.currentSyncSettings
        Task {
            await runner.updateSettings(snapshot)
            await runner.startRun()
        }
    }

    func cancelRun() {
        Task { await runner.cancel() }
    }

    // ---- Drain timer --------------------------------------------------
    //
    // Polls the EventBuffer at ~10Hz on the main actor and applies any
    // pending events in a single render cycle. This is the choke point
    // we deliberately introduce so the SyncRunner's pipe reader never
    // blocks on UI work — if the UI can't keep up, events coalesce in
    // the buffer rather than backing up in the Python's stdout pipe.

    private func startDrainTimer() {
        drainTimer?.invalidate()
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.drainOnce() }
        }
    }

    private func stopDrainTimer() {
        drainTimer?.invalidate()
        drainTimer = nil
    }

    private func drainOnce() async {
        let batch = await eventBuffer.drainAndClear()
        guard !batch.isEmpty else { return }
        apply(batch)
    }

    private func apply(_ batch: EventBuffer.Batch) {
        // Structural events first: workerStart / workerFinish / outcome /
        // session_*. These are always discrete and order-sensitive.
        for event in batch.events {
            apply(event)
        }
        // Latest-phase snapshots (already coalesced by the buffer).
        for snap in batch.latestPhases {
            if var w = activeWorkers[snap.platform]?[snap.rel] {
                w.phase = snap.phase
                w.pct = snap.pct
                activeWorkers[snap.platform, default: [:]][snap.rel] = w
            }
        }
        // Captured stderr lines, prefixed by platform.
        if !batch.logs.isEmpty, currentRun != nil {
            // Mutate via a working copy to limit @Published republishes to
            // one per drain instead of N per drain.
            var run = currentRun!
            for entry in batch.logs {
                run.logLines.append("[\(entry.platform)] \(entry.line)")
            }
            currentRun = run
        }
        // Per-platform terminations + activeWorkers cleanup.
        for finish in batch.finishes {
            currentRun?.exitCodes[finish.platform] = finish.exitCode
            activeWorkers[finish.platform] = nil
        }
        // All-platforms-done finalizer.
        if batch.allFinished {
            finalizeRun()
        }
    }

    private func finalizeRun() {
        guard var run = currentRun else { return }
        run.endedAt = Date()
        lastRun = run
        currentRun = nil
        activeWorkers = [:]
        history.record(run)
        stopDrainTimer()
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
            // Buffer normally coalesces these into batch.latestPhases, but
            // applying defensively here too is cheap.
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
        case .remoteProject:
            // No-op until the InventoryStore lands; the event is plumbed
            // through but nothing consumes it yet.
            break
        }
    }
}

struct WorkerView: Hashable, Sendable {
    var op: String
    var phase: String
    var pct: Int?
    var startedAt: Date
}
