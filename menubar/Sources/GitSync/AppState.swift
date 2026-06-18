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
    let providers: ProviderStore
    let eventBuffer = EventBuffer()
    private var drainTimer: Timer?
    // Reference count for the shared 10Hz drain timer. The full run and each
    // individual sync each retain it once and release once, so the timer
    // stays alive while ANY job is active and stops only when all are done —
    // the first individual to finish must not stop the timer for the others.
    private var drainRetain = 0
    // The native Swift sync engine. Feeds an EventBuffer via BufferSink, which
    // the 10Hz drain timer / two-lane / finalize logic below consumes.
    private(set) lazy var engine: SyncEngine = SyncEngine(
        settings: settingsStore.currentSyncSettings,
        sink: BufferSink(buffer: eventBuffer)
    )
    private(set) lazy var scheduler: Scheduler = Scheduler(state: self, settings: settingsStore)

    init(settings: SettingsStore, history: HistoryStore, inventory: InventoryStore, providers: ProviderStore) {
        self.settingsStore = settings
        self.history = history
        self.inventory = inventory
        self.providers = providers
    }

    // Called by App.swift whenever a schedule-related setting changes,
    // so the timer reflects the new mode/interval without an app restart.
    func rescheduleIfNeeded() {
        // start() reschedules the heartbeat AND re-checks catch-up, so changing
        // the schedule to a time that's already past today fires promptly
        // rather than waiting for the next heartbeat.
        scheduler.start()
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

    // `only` scopes the run to a subset of platforms (the scheduler passes the
    // platforms that are actually overdue). nil = all enabled platforms (the
    // manual "Run now" button and any full catch-up).
    func startRun(only: Set<Platform>? = nil) {
        // Full run is exclusive: refuse if a full run OR any individual sync
        // is already in flight (rule 1). The engine enforces this again as
        // the authoritative gate; this is the UI-side mirror.
        guard currentRun == nil, syncingRepos.isEmpty else { return }
        currentRun = RunRecord()
        dismissedRunID = nil
        activeWorkers = [:]
        retainDrainTimer()
        let snapshot = withTrackingEnv(settingsStore.currentSyncSettings)
        Task {
            await engine.updateSettings(snapshot)
            await engine.startFullRun(only: only)
        }
    }

    // Build the run snapshot: attach the resolved provider list (each provider
    // + its Keychain token + tracked rels) for the engine to iterate. The
    // filter mode + token live in the provider/settings stores while the
    // tracked set lives in the inventory, so AppState (which has all three) is
    // the only place that can assemble this.
    private func withTrackingEnv(_ settings: SyncSettings) -> SyncSettings {
        var s = settings
        s.providers = providers.enabledProviders.map { p in
            ResolvedProvider(
                provider: p,
                token: providers.token(for: p),
                trackedRels: p.filterMode == .trackedOnly
                    ? inventory.trackedRels(providerID: p.id.uuidString) : [])
        }
        return s
    }

    func cancelRun() {
        Task { await engine.cancel() }
    }

    // Move the local clones of the given repos to the Trash, after the
    // standard safety checks (skip dirty trees and unpushed commits).
    // Inventory rows update to match: stale/disk-only repos disappear
    // entirely; remote-known repos revert to "not cloned yet".
    func deleteLocalRepos(_ ids: Set<RepoID>) async -> TrashReport {
        // Resolve each repo's on-disk path via its provider folder, and bound
        // the trash to the configured provider folders (defense in depth).
        let resolver = diskPathResolver()
        let allowed = allowedRoots()
        let report = await RepoTrasher.trash(
            ids: Array(ids),
            resolve: { resolver($0) },
            allowedRoots: allowed)
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

    // ---- Disk-path resolution (single source of truth) ---------------

    // A repo's on-disk folder = its provider's localPath + provider-local rel.
    // Falls back to syncRoot/<DefaultDir> for rows whose providerID doesn't
    // match a configured provider (pre-migration / legacy / Python path), where
    // rel may still carry the platform-dir prefix.
    func diskPath(for id: RepoID) -> URL? {
        if let p = providers.provider(id: UUID(uuidString: id.providerID) ?? UUID()) {
            return URL(fileURLWithPath: p.resolvedLocalPath, isDirectory: true)
                .appendingPathComponent(id.rel)
        }
        // Legacy fallback: syncRoot + rel (rel here still includes the dir).
        let root = URL(fileURLWithPath: (settingsStore.syncRoot as NSString).expandingTildeInPath)
        return root.appendingPathComponent(id.rel)
    }

    // A Sendable snapshot resolver (provider folders captured now) for handing
    // to RepoTrasher off the main actor.
    private func diskPathResolver() -> @Sendable (RepoID) -> URL? {
        let byID = Dictionary(uniqueKeysWithValues:
            providers.providers.map { ($0.id.uuidString, $0.resolvedLocalPath) })
        let legacyRoot = (settingsStore.syncRoot as NSString).expandingTildeInPath
        return { id in
            if let root = byID[id.providerID] {
                return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(id.rel)
            }
            return URL(fileURLWithPath: legacyRoot, isDirectory: true).appendingPathComponent(id.rel)
        }
    }

    // The folders a trash target must live under (provider folders + the legacy
    // sync root for un-migrated rows).
    private func allowedRoots() -> [URL] {
        var roots = providers.providers.map {
            URL(fileURLWithPath: $0.resolvedLocalPath, isDirectory: true)
        }
        roots.append(URL(fileURLWithPath: (settingsStore.syncRoot as NSString).expandingTildeInPath,
                         isDirectory: true))
        return roots
    }

    // ---- Whitelist / Track mode --------------------------------------

    // Is the repo's PROVIDER in whitelist (trackedOnly) mode? Keyed by the
    // repo's providerID. Falls back to the legacy platform-keyed setting for
    // un-migrated rows (providerID "").
    func isTrackedOnly(repoID id: RepoID) -> Bool {
        if let p = providers.provider(id: UUID(uuidString: id.providerID) ?? UUID()) {
            return p.filterMode == .trackedOnly
        }
        return settingsStore.filterMode(platform: id.platform) == .trackedOnly
    }

    func setTracked(_ ids: Set<RepoID>, _ tracked: Bool) {
        inventory.setTracked(ids, tracked)
    }

    // Save a provider (validate → upsert → token), and if it just flipped into
    // whitelist mode, auto-track everything already cloned for it so nothing
    // the user has stops updating. Returns the validation result.
    @discardableResult
    func saveProvider(_ provider: Provider, token: String) -> ProviderStore.ProviderValidation {
        let wasTrackedOnly = providers.provider(id: provider.id)?.filterMode == .trackedOnly
        let v = providers.upsert(provider)
        guard v.isValid else { return v }
        providers.setToken(token, for: provider)
        if provider.filterMode == .trackedOnly && !wasTrackedOnly {
            inventory.autoTrackClonedRepos(providerID: provider.id.uuidString)
        }
        return v
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
        // engine pushes an individual-finish on every early-return path, so
        // this always drains back out — no stuck spinner.
        syncingRepos.insert(id)
        retainDrainTimer()
        // Attach the resolved provider list so the engine can match this repo's
        // providerID to its folder/token (syncRepo resolves the unit by ID).
        let snapshot = withTrackingEnv(settingsStore.currentSyncSettings)
        // Pass known ssh/branch from the inventory so the engine can skip
        // even the single discoverOne API call when we already have them.
        let repo = inventory.repos[id]
        let ssh = repo?.sshURL
        let branch = repo?.defaultBranch
        Task {
            await engine.updateSettings(snapshot)
            await engine.syncRepo(id, sshURL: ssh, branch: branch)
        }
    }

    // ---- Drain timer --------------------------------------------------
    //
    // Polls the EventBuffer at ~10Hz on the main actor and applies any
    // pending events in a single render cycle. This is the choke point
    // we deliberately introduce so the engine's BufferSink never blocks on
    // UI work — if the UI can't keep up, events coalesce in the buffer
    // rather than backing up in the engine's emit path.

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
        // Record success PER PLATFORM: each platform that exited 0 stamps its
        // own last-success time. A VPN-down run where GitLab exits 1 stamps
        // GitHub + Bitbucket (which succeeded) but NOT GitLab — so the
        // scheduler's per-platform catch-up keeps only GitLab "due" and retries
        // just it (cheaply, via the reachability probe) until the VPN's back.
        // exitCode 2 is EXIT_SKIPPED (list-only / nothing-to-do) — also fine.
        let now = run.endedAt ?? Date()
        for (platform, code) in run.exitCodes where code == 0 || code == 2 {
            settingsStore.noteSuccess(platform: platform, at: now)
        }
        scheduler.noteSuccessfulRun()
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
        case .remoteProject(let providerID, let platform, let rel, let sshURL, let defaultBranch):
            inventory.apply(remoteProject: providerID, platform: platform, rel: rel,
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
