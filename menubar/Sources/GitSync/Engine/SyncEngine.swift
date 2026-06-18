import Foundation
import Synchronization

// The native sync engine — replaces SyncRunner. Drives git directly (no
// Python, no subprocess pipe). Owns:
//   - the two-lane mutual-exclusion gate (full run exclusive; individual
//     per-repo syncs run in parallel with each other), identical rules to
//     the SyncRunner two-lane model it replaces
//   - discovery via the PlatformDiscovery clients
//   - fan-out across repos via a bounded TaskGroup (concurrency cap =
//     GIT_SYNC_PARALLEL), wrapped in SSH ControlMaster prewarm/cleanup
//   - the stale-on-disk / non-git-dir scan after a full run
//   - emitting SyncEvents to an EngineSink (the same event vocabulary the
//     EventBuffer/AppState already consume)
//
// Events flow to the sink, which AppState bridges into its existing
// EventBuffer + 10Hz drain timer — so every downstream invariant (the
// two-lane bookkeeping, finalizeRun, @Published coalescing) is preserved.

// The sink mirrors EventBuffer's push surface. AppState provides the concrete
// implementation that hops to MainActor and feeds the buffer.
protocol EngineSink: Sendable {
    func emit(_ event: SyncEvent) async
    func logLine(_ line: String, platform: String) async
    func platformFinished(_ platform: String, exitCode: Int32) async
    func allFinished() async
    func individualFinished(_ id: RepoID, exitCode: Int32) async
}

actor SyncEngine {
    private let sink: EngineSink
    private var settings: SyncSettings

    // Two-lane state, mirroring SyncRunner: a full run is exclusive; any
    // number of individual per-repo syncs run in parallel.
    private var fullRunActive = false
    private var individualRepos = Set<RepoID>()
    private var fullRunTask: Task<Void, Never>?
    private var individualTasks: [RepoID: Task<Void, Never>] = [:]
    private var aborted = false

    init(settings: SyncSettings, sink: EngineSink) {
        self.settings = settings
        self.sink = sink
    }

    func updateSettings(_ s: SyncSettings) { settings = s }

    var isRunning: Bool { fullRunActive || !individualRepos.isEmpty }
    var fullRunActiveNow: Bool { fullRunActive }
    var individualActiveNow: Bool { !individualRepos.isEmpty }

    // ---- Config derived from settings env (the GIT_SYNC_* dict) ----
    private var env: [String: String] { settings.environment }
    private var syncRoot: URL {
        URL(fileURLWithPath: (env["GIT_SYNC_ROOT"]! as NSString).expandingTildeInPath)
    }
    private var depth: Int { Int(env["GIT_SYNC_DEPTH"] ?? "100") ?? 100 }
    private var timeout: TimeInterval { TimeInterval(Int(env["GIT_SYNC_TIMEOUT"] ?? "1800") ?? 1800) }
    private var parallel: Int { Int(env["GIT_SYNC_PARALLEL"] ?? "128") ?? 128 }
    private var skip: SkipMatcher { SkipMatcher(env["GIT_SYNC_SKIP"] ?? "") }

    // Per-platform whitelist config (set by AppState.withTrackingEnv).
    private func filterMode(_ p: Platform) -> FilterMode {
        FilterMode(rawValue: env["GIT_SYNC_FILTER_MODE_\(p.rawValue.uppercased())"] ?? "") ?? .syncAll
    }
    // The tracked canonical rels for a platform, as a set for O(1) membership.
    private func trackedSet(_ p: Platform) -> Set<String> {
        let raw = env["GIT_SYNC_TRACKED_\(p.rawValue.uppercased())"] ?? ""
        return Set(raw.split(separator: "\n").map(String.init))
    }

    // ---- Full run: enabled platforms, exclusive ----
    // listOnly = discover + emit remote_project events, then stop without
    // cloning/fetching anything (inventory refresh; also the safe way to
    // exercise discovery in tests).
    // `only` scopes the run to a subset of platforms (used by the scheduler's
    // per-platform catch-up so a VPN-down GitLab retry doesn't drag GitHub /
    // Bitbucket along). nil = all enabled platforms (the manual "Run now").
    func startFullRun(listOnly: Bool = false, only: Set<Platform>? = nil) {
        guard !isRunning else { return }   // rule 1: exclusive against everything
        fullRunActive = true
        aborted = false
        abortBox.reset()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runFull(listOnly: listOnly, only: only)
        }
        fullRunTask = task
    }

    // ---- Individual per-repo sync: parallel with other individuals,
    //      refused while a full run is active ----
    func syncRepo(_ id: RepoID, sshURL: String?, branch: String?) {
        guard !fullRunActive else { return }            // rule 1
        guard !individualRepos.contains(id) else { return }  // rule 3 dedupe
        // Clear a stale abort flag from a PREVIOUS cancelled run before
        // starting fresh work. abortBox lives on the long-lived engine
        // singleton, so without this a cancel would poison every later
        // individual sync (they'd all return "aborted" without doing any
        // git work). Only safe to reset when nothing else is in flight.
        if individualRepos.isEmpty {
            aborted = false
            abortBox.reset()
        }
        individualRepos.insert(id)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runIndividual(id: id, knownSSH: sshURL, knownBranch: branch)
        }
        individualTasks[id] = task
    }

    func cancel() {
        aborted = true
        abortBox.set()      // visible to the @Sendable isAborted closures
        fullRunTask?.cancel()
        for (_, t) in individualTasks { t.cancel() }
    }

    // ---- internals ----

    private func clearIndividual(_ id: RepoID) {
        individualRepos.remove(id)
        individualTasks[id] = nil
    }

    private func clearFullRun() {
        fullRunActive = false
        fullRunTask = nil
    }

    private func enabledPlatforms() -> [Platform] {
        var out: [Platform] = []
        if env["GIT_SYNC_SKIP_GITLAB"] == nil, env["GITLAB_HOST"] != nil { out.append(.gitlab) }
        if env["GIT_SYNC_SKIP_GITHUB"] == nil, env["GIT_SYNC_GITHUB_ORG"] != nil { out.append(.github) }
        if env["GIT_SYNC_SKIP_BITBUCKET"] == nil, env["GIT_SYNC_BITBUCKET_WORKSPACE"] != nil { out.append(.bitbucket) }
        return out
    }

    private func makeClient(_ platform: Platform) -> PlatformDiscovery {
        switch platform {
        case .gitlab:
            return GitLabClient(
                host: env["GITLAB_HOST"] ?? "",
                token: env["GITLAB_TOKEN"] ?? "",
                includeArchived: env["GIT_SYNC_INCLUDE_ARCHIVED"] != nil,
                syncRoot: syncRoot)
        case .github:
            return GitHubClient(
                org: env["GIT_SYNC_GITHUB_ORG"] ?? "",
                token: env["GIT_SYNC_GITHUB_TOKEN"] ?? "",
                includeArchived: env["GIT_SYNC_INCLUDE_ARCHIVED"] != nil,
                syncRoot: syncRoot)
        case .bitbucket:
            return BitbucketClient(
                workspace: env["GIT_SYNC_BITBUCKET_WORKSPACE"] ?? "",
                user: env["GIT_SYNC_BITBUCKET_USER"] ?? "",
                appPassword: env["GIT_SYNC_BITBUCKET_APP_PASSWORD"] ?? "",
                syncRoot: syncRoot)
        }
    }

    // One provider's per-run context. Everything downstream (discovery,
    // filtering, fan-out, stale-scan) keys off this so the run loop is
    // provider-uniform — no special-casing per platform.
    private struct RunUnit {
        let providerID: String          // "" for the synthesized legacy units
        let kind: Platform
        let title: String
        let client: PlatformDiscovery
        let destRoot: URL               // where this provider's repos clone
        let filterMode: FilterMode
        let trackedSet: Set<String>     // provider-local rels, when trackedOnly
    }

    // Build the run units. Native path: one per enabled ResolvedProvider.
    // Legacy path (no providers in the snapshot — Python fallback or pre-
    // population): synthesize from the env-driven enabledPlatforms() so behavior
    // is unchanged.
    private func runUnits(only: Set<Platform>?) -> [RunUnit] {
        if !providersSnapshot.isEmpty {
            return providersSnapshot.compactMap { rp -> RunUnit? in
                let p = rp.provider
                let kind = Platform(rawValue: p.kind.rawValue) ?? .gitlab
                if let only, !only.contains(kind) { return nil }
                let root = URL(fileURLWithPath: p.resolvedLocalPath, isDirectory: true)
                let client: PlatformDiscovery
                switch p.kind {
                case .gitlab:
                    client = GitLabClient(host: p.host, token: rp.token,
                                          includeArchived: p.includeArchived,
                                          syncRoot: syncRoot, localRoot: root)
                case .github:
                    client = GitHubClient(org: p.scope, token: rp.token,
                                          includeArchived: p.includeArchived,
                                          syncRoot: syncRoot, localRoot: root)
                case .bitbucket:
                    client = BitbucketClient(workspace: p.scope, user: p.bitbucketUser,
                                             appPassword: rp.token,
                                             syncRoot: syncRoot, localRoot: root)
                }
                return RunUnit(providerID: p.id.uuidString, kind: kind, title: p.name,
                               client: client, destRoot: root, filterMode: p.filterMode,
                               trackedSet: Set(rp.trackedRels))
            }
        }
        // Legacy fallback.
        var platforms = enabledPlatforms()
        if let only { platforms = platforms.filter { only.contains($0) } }
        return platforms.map { kind in
            RunUnit(providerID: "", kind: kind, title: kind.titleName,
                    client: makeClient(kind),
                    destRoot: syncRoot.appendingPathComponent(platformDir(kind)),
                    filterMode: filterMode(kind),
                    trackedSet: filterMode(kind) == .trackedOnly ? trackedSet(kind) : [])
        }
    }

    private var providersSnapshot: [ResolvedProvider] { settings.providers }

    // Immutable, Sendable snapshot of the actor config the per-repo git work
    // needs. Captured ONCE on the actor before fan-out, then handed to the
    // nonisolated worker so each repo's clone/fetch runs OFF the actor — that
    // is what makes the TaskGroup actually parallel. (Previously runSync was
    // actor-isolated and ran the blocking git work synchronously on the
    // actor, so all N "parallel" tasks serialized through the single actor —
    // they ticked down one at a time, never truly concurrent.)
    struct WorkConfig: Sendable {
        let baseEnv: [String: String]
        let syncRoot: URL
        let depth: Int
        let timeout: TimeInterval
    }
    private func workConfig() -> WorkConfig {
        WorkConfig(baseEnv: env, syncRoot: syncRoot, depth: depth, timeout: timeout)
    }

    // Build a GitContext for one repo. nonisolated + static: no actor state,
    // so callers run it (and the git work) off the actor concurrently.
    nonisolated static func gitContext(_ cfg: WorkConfig, mux: SSHMultiplexer, rel: String,
                                       abort: AbortBox, sink: EngineSink,
                                       platform: String) -> GitContext {
        let shard = mux.shard(for: rel)
        let sshCmd = mux.sshCommand(shard: shard)
        let baseEnv = cfg.baseEnv
        var ctx = GitContext(
            syncRoot: cfg.syncRoot,
            depth: cfg.depth,
            timeout: cfg.timeout,
            makeEnv: {
                var e = baseEnv
                e["LC_ALL"] = "C"
                e["GIT_TERMINAL_PROMPT"] = "0"
                e["GIT_SSH_COMMAND"] = sshCmd
                return e
            }
        )
        ctx.isAborted = { abort.value }
        ctx.onProgress = { phase, pct in
            Task { await sink.emit(.workerPhase(platform: platform, rel: rel, phase: phase, pct: pct)) }
        }
        return ctx
    }

    // Runs one repo's clone_or_update OFF the actor (nonisolated static).
    // This is the unit the TaskGroup parallelizes.
    // `destRoot` is the folder the repo clones into (the provider's localPath,
    // or syncRoot/<Dir> on the legacy path); `rel` is provider-local. The
    // emitted outcome carries `providerID` so the inventory keys it correctly.
    nonisolated static func syncOne(
        cfg: WorkConfig, mux: SSHMultiplexer, providerID: String, platform: String,
        rel: String, destRoot: URL, sshURL: String, branch: String,
        abort: AbortBox, sink: EngineSink, pool: GitWorkPool
    ) async -> Outcome {
        let dest = destRoot.appendingPathComponent(rel)
        await sink.emit(.workerStart(platform: platform, rel: rel,
            op: FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path) ? "fetch" : "clone"))
        let ctx = gitContext(cfg, mux: mux, rel: rel, abort: abort, sink: sink, platform: platform)
        // RepoSyncer.cloneOrUpdate BLOCKS on subprocess I/O — run it on the
        // OS-thread work pool (not the cooperative pool), so N of them can sit
        // blocked on network/disk at once. The pool's semaphore bounds width.
        var outcome = await pool.run {
            RepoSyncer.cloneOrUpdate(platform: platform, rel: rel, sshURL: sshURL,
                                     dest: dest, branch: branch, ctx: ctx)
        }
        // Stamp providerID onto the outcome (RepoSyncer is provider-agnostic).
        outcome = outcome.withProviderID(providerID)
        await sink.emit(.workerFinish(platform: platform, rel: rel))
        await sink.emit(.outcome(platform: platform, outcome: outcome))
        return outcome
    }

    private func runFull(listOnly: Bool = false, only: Set<Platform>? = nil) async {
        let units = runUnits(only: only)
        // Nothing to run (empty filter / nothing configured): finish cleanly
        // rather than dangling with fullRunActive=true.
        if units.isEmpty {
            await sink.allFinished()
            clearFullRun()
            return
        }
        let mux = SSHMultiplexer(parallel: parallel,
                                 pid: ProcessInfo.processInfo.processIdentifier,
                                 uid: getuid(),
                                 enabled: env["GIT_SYNC_NO_SSH_MUX"] != "1")

        // A job carries its provider context so fan-out can clone into the right
        // folder and stamp the right providerID.
        struct Job {
            let unit: RunUnit
            let repo: DiscoveredRepo
            let skipped: Bool    // blacklist (GIT_SYNC_SKIP) → emits .skipped
            let excluded: Bool   // whitelist miss → silently omitted, no outcome
        }
        var jobs: [Job] = []
        // Keyed by providerID (or "platform#" for legacy units, which have "").
        var complete: [String: Bool] = [:]
        func key(_ u: RunUnit) -> String { u.providerID.isEmpty ? "p:" + u.kind.rawValue : u.providerID }

        for unit in units {
            if aborted { break }
            // Fast reachability probe before the expensive discovery (VPN-down
            // fails in ~8s, not ~5min). Isolated per provider.
            if let probe = unit.client.probeURL {
                await sink.emit(.phase(label: "Checking \(unit.title)…"))
                if !hostReachable(probe) {
                    complete[key(unit)] = false
                    await sink.logLine("\(unit.title) unreachable (host did not respond — VPN down?)",
                                       platform: unit.kind.rawValue)
                    await sink.platformFinished(unit.kind.rawValue, exitCode: 1)
                    continue
                }
            }
            await sink.emit(.phase(label: "Discovering \(unit.title)…"))
            let result = unit.client.discoverAll(skip: skip)
            complete[key(unit)] = (result.fatalError == nil)
            if let fatal = result.fatalError {
                await sink.logLine("discovery failed: \(fatal)", platform: unit.kind.rawValue)
                await sink.platformFinished(unit.kind.rawValue, exitCode: 1)
                continue
            }
            for repo in result.repos {
                await sink.emit(.remoteProject(providerID: unit.providerID, platform: unit.kind.rawValue,
                                               rel: repo.rel, sshURL: repo.sshURL,
                                               defaultBranch: repo.defaultBranch))
                let isSkipped = skip.matches(repo.namespacePath)
                let isExcluded = unit.filterMode == .trackedOnly && !isSkipped && !unit.trackedSet.contains(repo.rel)
                jobs.append(Job(unit: unit, repo: repo, skipped: isSkipped, excluded: isExcluded))
            }
        }

        // list-only: discovery done, remote_project events emitted — stop.
        if listOnly {
            for unit in units where complete[key(unit)] == true {
                await sink.platformFinished(unit.kind.rawValue, exitCode: 2)  // EXIT_SKIPPED
            }
            await sink.allFinished()
            clearFullRun()
            return
        }

        let toSync = jobs.filter { !$0.skipped && !$0.excluded }

        // Prewarm SSH masters for the hosts we'll actually contact.
        let hosts = SSHMultiplexer.uniqueHosts(toSync.map { $0.repo.sshURL })
        if !hosts.isEmpty {
            await sink.emit(.phase(label: "Warming \(hosts.count) SSH connection\(hosts.count == 1 ? "" : "s")…"))
        }
        let warmed = mux.prewarm(hosts: hosts)
        defer { mux.cleanup(pairs: warmed) }

        // .skipped outcomes for blacklist matches only (whitelist-excluded get
        // no outcome — they keep their prior inventory status).
        for job in jobs where job.skipped {
            await sink.emit(.outcome(platform: job.unit.kind.rawValue,
                                     outcome: Outcome(platform: job.unit.kind.rawValue, rel: job.repo.rel,
                                                      status: .skipped, url: job.repo.sshURL,
                                                      providerID: job.unit.providerID)))
        }

        // Fan out. Each job clones into its provider's destRoot.
        await sink.emit(.phase(label: "Syncing \(toSync.count) repo\(toSync.count == 1 ? "" : "s")…"))
        await fanOut(toSync.map {
            FanJob(providerID: $0.unit.providerID, kind: $0.unit.kind, rel: $0.repo.rel,
                   destRoot: $0.unit.destRoot, sshURL: $0.repo.sshURL, branch: $0.repo.defaultBranch)
        }, mux: mux)
        await sink.emit(.phase(label: "Scanning for stale local checkouts…"))

        // Tracked-but-gone (whitelist mode): a tracked repo discovery no longer
        // returned. Advisory only; never deleted. Keyed per provider.
        var trackedGoneDests: [String: Set<String>] = [:]
        for unit in units where complete[key(unit)] == true && unit.filterMode == .trackedOnly {
            let discovered = Set(jobs.filter { key($0.unit) == key(unit) }.map { $0.repo.rel })
            for rel in unit.trackedSet where !discovered.contains(rel) {
                let dest = unit.destRoot.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path) else { continue }
                trackedGoneDests[key(unit), default: []].insert(dest.standardizedFileURL.path)
                await sink.emit(.outcome(platform: unit.kind.rawValue,
                    outcome: Outcome(platform: unit.kind.rawValue, rel: rel, status: .trackedGone,
                                     providerID: unit.providerID)))
            }
        }

        // Stale-on-disk / non-git scan per provider folder (only when complete).
        for unit in units where complete[key(unit)] == true {
            var expected = Set(jobs.filter { key($0.unit) == key(unit) }
                .map { unit.destRoot.appendingPathComponent($0.repo.rel).standardizedFileURL.path })
            expected.formUnion(trackedGoneDests[key(unit)] ?? [])
            let staleStatus: SyncStatus = unit.filterMode == .trackedOnly ? .untracked : .staleOnDisk
            let pid = unit.providerID
            let kindRaw = unit.kind.rawValue
            let root = unit.destRoot
            let extras = StaleScan.discoverExtras(
                platformRoot: root, platform: kindRaw,
                expected: expected,
                rel: { dest in
                    let r = root.standardizedFileURL.path
                    let d = dest.standardizedFileURL.path
                    return d.hasPrefix(r + "/") ? String(d.dropFirst(r.count + 1)) : d
                },
                staleStatus: staleStatus)
            for o in extras {
                await sink.emit(.outcome(platform: kindRaw, outcome: o.withProviderID(pid)))
            }
        }

        for unit in units where complete[key(unit)] == true {
            await sink.platformFinished(unit.kind.rawValue, exitCode: 0)
        }
        await sink.allFinished()
        clearFullRun()
    }

    // The Sendable per-repo work item handed to fanOut.
    struct FanJob: Sendable {
        let providerID: String
        let kind: Platform
        let rel: String
        let destRoot: URL
        let sshURL: String
        let branch: String
    }

    private func runIndividual(id: RepoID, knownSSH: String?, knownBranch: String?) async {
        defer { Task { await self.clearIndividual(id) } }
        guard let platform = Platform(rawValue: id.platform) else {
            await sink.individualFinished(id, exitCode: -1)
            return
        }
        // Resolve the provider this repo belongs to (its client + dest folder).
        // Falls back to the legacy syncRoot/<Dir> when there's no provider match
        // (e.g. providerID "" on the Python path).
        let unit = runUnits(only: nil).first { $0.providerID == id.providerID }
            ?? runUnits(only: [platform]).first
        let destRoot = unit?.destRoot ?? syncRoot.appendingPathComponent(platformDir(platform))
        let client = unit?.client ?? makeClient(platform)

        let mux = SSHMultiplexer(parallel: 1,
                                 pid: ProcessInfo.processInfo.processIdentifier,
                                 uid: getuid(),
                                 enabled: env["GIT_SYNC_NO_SSH_MUX"] != "1")

        // Resolve ssh/branch: use known values if present, else discoverOne
        // (the fast path — one API call, not a full listing).
        var sshURL = knownSSH ?? ""
        var branch = knownBranch ?? ""
        if sshURL.isEmpty || branch.isEmpty {
            guard let repo = client.discoverOne(rel: id.rel) else {
                await sink.logLine("--only \(id.rel): not found in remote listing", platform: id.platform)
                await sink.individualFinished(id, exitCode: 1)
                return
            }
            sshURL = repo.sshURL
            branch = repo.defaultBranch
            await sink.emit(.remoteProject(providerID: id.providerID, platform: id.platform, rel: repo.rel,
                                           sshURL: repo.sshURL, defaultBranch: repo.defaultBranch))
            // honor skip even on an individual sync
            if skip.matches(repo.namespacePath) {
                await sink.individualFinished(id, exitCode: 0)
                return
            }
        }

        let warmed = mux.prewarm(hosts: SSHMultiplexer.uniqueHosts([sshURL]))
        defer { mux.cleanup(pairs: warmed) }

        _ = await SyncEngine.syncOne(
            cfg: workConfig(), mux: mux, providerID: id.providerID, platform: id.platform,
            rel: id.rel, destRoot: destRoot, sshURL: sshURL, branch: branch,
            abort: abortBox, sink: sink, pool: GitWorkPool(width: 1))
        await sink.individualFinished(id, exitCode: 0)
    }

    // Bounded fan-out: at most `parallel` repos syncing at once, each running
    // OFF the actor via the nonisolated syncOne. The TaskGroup tasks no longer
    // hop back onto the actor for the git work, so they genuinely overlap.
    private func fanOut(_ jobs: [FanJob], mux: SSHMultiplexer) async {
        let cap = max(1, parallel)
        let cfg = workConfig()
        let sink = self.sink
        let abort = self.abortBox
        let pool = GitWorkPool(width: cap)
        var index = 0
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            func startNext() {
                guard index < jobs.count else { return }
                let job = jobs[index]; index += 1
                running += 1
                group.addTask {
                    _ = await SyncEngine.syncOne(
                        cfg: cfg, mux: mux, providerID: job.providerID, platform: job.kind.rawValue,
                        rel: job.rel, destRoot: job.destRoot,
                        sshURL: job.sshURL, branch: job.branch,
                        abort: abort, sink: sink, pool: pool)
                }
            }
            for _ in 0..<min(cap, jobs.count) { startNext() }
            while running > 0 {
                await group.next()
                running -= 1
                startNext()
            }
        }
    }

    // The abort flag, readable from the nonisolated worker without hopping
    // onto the actor.
    let abortBox = AbortBox()

    private func platformDir(_ p: Platform) -> String {
        switch p { case .gitlab: return "Gitlab"; case .github: return "Github"; case .bitbucket: return "Bitbucket" }
    }
    private func rel(_ dest: URL) -> String {
        let root = syncRoot.standardizedFileURL.path
        let d = dest.standardizedFileURL.path
        return d.hasPrefix(root + "/") ? String(d.dropFirst(root.count + 1)) : d
    }
}

// Thread-safe abort flag readable from the @Sendable progress/abort closures
// without hopping back onto the actor.
// A one-shot abort flag polled in tight per-chunk loops by every git worker.
// MUST be lock-free: an NSLock here convoys all N pool threads on a single
// pthread_mutex (every clone emits thousands of progress chunks, each taking
// the lock), collapsing 128-way parallelism to crawling single-file lock
// handoff. `Atomic<Bool>` reads compile to a plain load + acquire barrier —
// no kernel call, no contention.
final class AbortBox: @unchecked Sendable {
    private let _value = Atomic<Bool>(false)
    var value: Bool { _value.load(ordering: .acquiring) }
    func set() { _value.store(true, ordering: .releasing) }
    func reset() { _value.store(false, ordering: .releasing) }
}
