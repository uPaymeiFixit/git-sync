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
    // Repos with an individual (--only) sync in flight. Drives the per-row
    // spinner and the per-row button disable. Many can be present at once;
    // they run in parallel. A full run and individual syncs are mutually
    // exclusive (see startRun / syncRepo guards), so this is empty whenever
    // currentRun != nil and vice versa.
    @Published var syncingRepos: Set<RepoID> = []

    private let settingsStore: SettingsStore
    private let history: HistoryStore
    let inventory: InventoryStore
    let eventBuffer = EventBuffer()
    private var drainTimer: Timer?
    // Reference count for the shared 10Hz drain timer. The full run and each
    // individual sync each retain it once and release once, so the timer
    // stays alive while ANY job is active and stops only when all are done —
    // the first individual to finish must not stop the timer for the others.
    private var drainRetain = 0
    private(set) lazy var runner: SyncRunner = SyncRunner(
        settings: settingsStore.currentSyncSettings,
        eventBuffer: eventBuffer
    )
    // Native Swift sync engine — replaces the Python+pipe. Feeds the SAME
    // EventBuffer via BufferSink, so the drain timer / two-lane / finalize
    // logic below is unchanged. The engine is the default; set
    // GIT_SYNC_USE_PYTHON=1 in the environment to fall back to the legacy
    // SyncRunner during the transition.
    private(set) lazy var engine: SyncEngine = SyncEngine(
        settings: settingsStore.currentSyncSettings,
        sink: BufferSink(buffer: eventBuffer)
    )
    private let useNativeEngine =
        ProcessInfo.processInfo.environment["GIT_SYNC_USE_PYTHON"] != "1"
    private(set) lazy var scheduler: Scheduler = Scheduler(state: self, settings: settingsStore)

    init(settings: SettingsStore, history: HistoryStore, inventory: InventoryStore) {
        self.settingsStore = settings
        self.history = history
        self.inventory = inventory
    }

    // Called by App.swift whenever a schedule-related setting changes,
    // so the timer reflects the new mode/interval without an app restart.
    func rescheduleIfNeeded() {
        scheduler.reschedule()
    }

    // isRunning means specifically "a full run is active" — it drives the
    // Running…/last-run summary and the Cancel-run item, which are full-run
    // concepts. Individual syncs deliberately don't show there (rule 5).
    var isRunning: Bool { currentRun != nil }

    // True while a full run OR any individual sync is in flight. Drives the
    // menu-bar icon (so it spins for per-repo syncs too) and the drain timer.
    var anyActivity: Bool { currentRun != nil || !syncingRepos.isEmpty }

    func isSyncing(_ id: RepoID) -> Bool { syncingRepos.contains(id) }

    var anomalyCount: Int {
        (lastRun?.outcomes ?? []).filter(\.status.isAnomaly).count
    }

    var showsAttention: Bool {
        guard let lastRun, anomalyCount > 0 else { return false }
        return dismissedRunID != lastRun.id
    }

    var menuBarIconName: String {
        if anyActivity    { return "arrow.triangle.2.circlepath" }
        if showsAttention { return "exclamationmark.triangle.fill" }
        return "arrow.triangle.2.circlepath"
    }

    func dismissCurrentNotification() {
        dismissedRunID = lastRun?.id
    }

    func startRun() {
        // Full run is exclusive: refuse if a full run OR any individual sync
        // is already in flight (rule 1). The runner enforces this again as
        // the authoritative gate; this is the UI-side mirror.
        guard currentRun == nil, syncingRepos.isEmpty else { return }
        currentRun = RunRecord()
        dismissedRunID = nil
        activeWorkers = [:]
        retainDrainTimer()
        let snapshot = settingsStore.currentSyncSettings
        if useNativeEngine {
            Task {
                await engine.updateSettings(snapshot)
                await engine.startFullRun()
            }
        } else {
            Task {
                await runner.updateSettings(snapshot)
                await runner.startRun()
            }
        }
    }

    func cancelRun() {
        if useNativeEngine {
            Task { await engine.cancel() }
        } else {
            Task { await runner.cancel() }
        }
    }

    // Move the local clones of the given repos to the Trash, after the
    // standard safety checks (skip dirty trees and unpushed commits).
    // Inventory rows update to match: stale/disk-only repos disappear
    // entirely; remote-known repos revert to "not cloned yet".
    func deleteLocalRepos(_ ids: Set<RepoID>) async -> TrashReport {
        let root = URL(fileURLWithPath:
            (settingsStore.syncRoot as NSString).expandingTildeInPath)
        let report = await RepoTrasher.trash(ids: Array(ids), under: root)
        for id in report.trashed {
            let repo = inventory.repos[id]
            let remoteStillHasIt = repo?.lastSeenRemoteAt != nil
                && repo?.lastStatus != .staleOnDisk
            if remoteStillHasIt {
                inventory.markNotCloned(id)
            } else {
                inventory.remove(id)
            }
        }
        return report
    }

    // Per-repo sync triggered from the Repositories view's "Sync this repo"
    // action. Runs in parallel with other individual syncs (different repos
    // = disjoint .git dirs = safe). Refused only if a full run is active
    // (rule 1) or this exact repo is already syncing (rule 3). Does NOT
    // create a RunRecord or touch history/last-run — individual results land
    // in the inventory only (rule 5).
    func syncRepo(_ id: RepoID) {
        guard currentRun == nil else { return }
        guard !syncingRepos.contains(id) else { return }
        guard Platform(rawValue: id.platform) != nil else { return }
        // Mark busy synchronously (before the await) so the row spins on the
        // very next render and a second click is rejected immediately. The
        // runner pushes an individual-finish on every early-return path, so
        // this always drains back out — no stuck spinner.
        syncingRepos.insert(id)
        retainDrainTimer()
        let snapshot = settingsStore.currentSyncSettings
        if useNativeEngine {
            // Pass known ssh/branch from the inventory so the engine can skip
            // even the single discoverOne API call when we already have them.
            let repo = inventory.repos[id]
            let ssh = repo?.sshURL
            let branch = repo?.defaultBranch
            Task {
                await engine.updateSettings(snapshot)
                await engine.syncRepo(id, sshURL: ssh, branch: branch)
            }
        } else {
            Task {
                await runner.updateSettings(snapshot)
                await runner.runIndividual(id: id, extraArgs: ["--only", id.rel])
            }
        }
    }

    // ---- Drain timer --------------------------------------------------
    //
    // Polls the EventBuffer at ~10Hz on the main actor and applies any
    // pending events in a single render cycle. This is the choke point
    // we deliberately introduce so the SyncRunner's pipe reader never
    // blocks on UI work — if the UI can't keep up, events coalesce in
    // the buffer rather than backing up in the Python's stdout pipe.

    // Ref-counted so a full run and N individual syncs share ONE timer.
    // Retain when a job starts, release when it finishes; the timer lives
    // while the count is positive and stops only at zero. Never invalidates
    // a live timer (which would steal it from a concurrent job).
    private func retainDrainTimer() {
        drainRetain += 1
        guard drainTimer == nil else { return }
        // .common run-loop mode, not .default: menu tracking pauses
        // .default-mode timers, which would freeze the live progress shown
        // in the open menu (and back events up) for as long as it's open.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.drainOnce() }
        }
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
    }

    private func releaseDrainTimer() {
        drainRetain = max(0, drainRetain - 1)
        guard drainRetain == 0 else { return }
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
        // Captured stderr lines + the coarse run-phase label. Folded into one
        // working-copy mutation so @Published republishes once per drain.
        if currentRun != nil, !batch.logs.isEmpty || batch.runPhase != nil {
            var run = currentRun!
            for entry in batch.logs {
                run.logLines.append("[\(entry.platform)] \(entry.line)")
            }
            if let label = batch.runPhase { run.phaseLabel = label }
            currentRun = run
        }
        // Per-platform terminations + activeWorkers cleanup (full-run lane).
        for finish in batch.finishes {
            currentRun?.exitCodes[finish.platform] = finish.exitCode
            activeWorkers[finish.platform] = nil
        }
        // All-platforms-done finalizer (full-run lane).
        if batch.allFinished {
            finalizeRun()
        }
        // Individual-lane terminations. Each finishing repo drops out of the
        // busy set (stopping its row's spinner) and releases the timer it
        // retained. Its outcome already updated the inventory via .outcome
        // above; no RunRecord/history is involved (rule 5).
        for finish in batch.individualFinishes {
            if syncingRepos.remove(finish.id) != nil {
                releaseDrainTimer()
            }
        }
    }

    private func finalizeRun() {
        guard var run = currentRun else { return }
        run.endedAt = Date()
        lastRun = run
        currentRun = nil
        activeWorkers = [:]
        history.record(run)
        releaseDrainTimer()
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
            inventory.apply(outcome: outcome)
        case .remoteProject(let platform, let rel, let sshURL, let defaultBranch):
            inventory.apply(remoteProject: platform, rel: rel,
                            sshURL: sshURL, defaultBranch: defaultBranch)
        case .phase(let label):
            // Normally coalesced into batch.runPhase; handled here too for
            // exhaustiveness (and so a stray un-coalesced .phase still lands).
            currentRun?.phaseLabel = label
        }
    }
}

struct WorkerView: Hashable, Sendable {
    var op: String
    var phase: String
    var pct: Int?
    var startedAt: Date
}
