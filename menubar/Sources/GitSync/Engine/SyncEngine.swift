import Foundation

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
    private var parallel: Int { Int(env["GIT_SYNC_PARALLEL"] ?? "8") ?? 8 }
    private var skip: SkipMatcher { SkipMatcher(env["GIT_SYNC_SKIP"] ?? "") }

    // ---- Full run: all enabled platforms, exclusive ----
    // listOnly = discover + emit remote_project events, then stop without
    // cloning/fetching anything (inventory refresh; also the safe way to
    // exercise discovery in tests).
    func startFullRun(listOnly: Bool = false) {
        guard !isRunning else { return }   // rule 1: exclusive against everything
        fullRunActive = true
        aborted = false
        abortBox.reset()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runFull(listOnly: listOnly)
        }
        fullRunTask = task
    }

    // ---- Individual per-repo sync: parallel with other individuals,
    //      refused while a full run is active ----
    func syncRepo(_ id: RepoID, sshURL: String?, branch: String?) {
        guard !fullRunActive else { return }            // rule 1
        guard !individualRepos.contains(id) else { return }  // rule 3 dedupe
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
                includeArchived: env["GIT_SYNC_INCLUDE_ARCHIVED"] != nil,
                syncRoot: syncRoot, env: env)
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

    // Build a GitContext whose makeEnv injects the SSH-multiplexed
    // GIT_SSH_COMMAND for this repo's shard.
    private func gitContext(mux: SSHMultiplexer, rel: String) -> GitContext {
        let shard = mux.shard(for: rel)
        let baseEnv = env
        let sshCmd = mux.sshCommand(shard: shard)
        let root = syncRoot
        let d = depth
        let to = timeout
        return GitContext(
            syncRoot: root,
            depth: d,
            timeout: to,
            makeEnv: {
                var e = baseEnv
                e["LC_ALL"] = "C"
                e["GIT_TERMINAL_PROMPT"] = "0"
                e["GIT_SSH_COMMAND"] = sshCmd
                return e
            }
        )
    }

    private func runFull(listOnly: Bool = false) async {
        let platforms = enabledPlatforms()
        let mux = SSHMultiplexer(parallel: parallel,
                                 pid: ProcessInfo.processInfo.processIdentifier,
                                 uid: getuid(),
                                 enabled: env["GIT_SYNC_NO_SSH_MUX"] != "1")

        // Discover all platforms, emit remote_project events, collect jobs.
        var jobs: [(platform: Platform, repo: DiscoveredRepo, skipped: Bool)] = []
        var perPlatformComplete: [Platform: Bool] = [:]
        for platform in platforms {
            if aborted { break }
            let client = makeClient(platform)
            let result = client.discoverAll(skip: skip)
            perPlatformComplete[platform] = (result.fatalError == nil)
            if let fatal = result.fatalError {
                await sink.logLine("discovery failed: \(fatal)", platform: platform.rawValue)
                await sink.platformFinished(platform.rawValue, exitCode: 1)
                continue
            }
            for repo in result.repos {
                await sink.emit(.remoteProject(platform: platform.rawValue, rel: repo.rel,
                                               sshURL: repo.sshURL, defaultBranch: repo.defaultBranch))
                jobs.append((platform, repo, skip.matches(repo.namespacePath)))
            }
        }

        // list-only: discovery is done and remote_project events emitted —
        // stop here without touching any repo.
        if listOnly {
            for platform in platforms where perPlatformComplete[platform] == true {
                await sink.platformFinished(platform.rawValue, exitCode: 2)  // EXIT_SKIPPED
            }
            await sink.allFinished()
            clearFullRun()
            return
        }

        // Prewarm SSH masters before fan-out (the 20x speedup).
        let hosts = SSHMultiplexer.uniqueHosts(jobs.filter { !$0.skipped }.map { $0.repo.sshURL })
        let warmed = mux.prewarm(hosts: hosts)
        defer { mux.cleanup(pairs: warmed) }

        // Emit skipped outcomes; collect the jobs to actually sync.
        let toSync = jobs.filter { !$0.skipped }
        for job in jobs where job.skipped {
            await sink.emit(.outcome(platform: job.platform.rawValue,
                                     outcome: Outcome(platform: job.platform.rawValue, rel: job.repo.rel,
                                                      status: .skipped, url: job.repo.sshURL)))
        }

        // Fan out across all repos with a bounded concurrency cap.
        await fanOut(toSync, mux: mux)

        // Stale-on-disk / non-git-dir scan per platform, only when that
        // platform's discovery was complete (mirrors finish_run gating).
        for platform in platforms {
            guard perPlatformComplete[platform] == true else { continue }
            let platformRoot = syncRoot.appendingPathComponent(platformDir(platform))
            var expected = Set(jobs.filter { $0.platform == platform }
                .map { syncRoot.appendingPathComponent($0.repo.rel).standardizedFileURL.path })
            // (skipped dests are already in `jobs`, so they're in expected)
            _ = expected  // (kept explicit for parity with finish_run)
            let extras = StaleScan.discoverExtras(
                platformRoot: platformRoot, platform: platform.rawValue,
                expected: expected, rel: { self.rel($0) })
            for o in extras { await sink.emit(.outcome(platform: platform.rawValue, outcome: o)) }
        }

        // Per-platform finish (exit 0 for those that completed).
        for platform in platforms where perPlatformComplete[platform] == true {
            await sink.platformFinished(platform.rawValue, exitCode: 0)
        }
        await sink.allFinished()
        clearFullRun()
    }

    private func runIndividual(id: RepoID, knownSSH: String?, knownBranch: String?) async {
        defer { Task { await self.clearIndividual(id) } }
        guard let platform = Platform(rawValue: id.platform) else {
            await sink.individualFinished(id, exitCode: -1)
            return
        }
        let mux = SSHMultiplexer(parallel: 1,
                                 pid: ProcessInfo.processInfo.processIdentifier,
                                 uid: getuid(),
                                 enabled: env["GIT_SYNC_NO_SSH_MUX"] != "1")

        // Resolve ssh/branch: use known values if present, else discoverOne
        // (the fast path — one API call, not a full listing).
        var sshURL = knownSSH ?? ""
        var branch = knownBranch ?? ""
        if sshURL.isEmpty || branch.isEmpty {
            let client = makeClient(platform)
            guard let repo = client.discoverOne(rel: id.rel) else {
                await sink.logLine("--only \(id.rel): not found in remote listing", platform: id.platform)
                await sink.individualFinished(id, exitCode: 1)
                return
            }
            sshURL = repo.sshURL
            branch = repo.defaultBranch
            await sink.emit(.remoteProject(platform: id.platform, rel: repo.rel,
                                           sshURL: repo.sshURL, defaultBranch: repo.defaultBranch))
            // honor skip even on an individual sync
            if skip.matches(repo.namespacePath) {
                await sink.individualFinished(id, exitCode: 0)
                return
            }
        }

        let warmed = mux.prewarm(hosts: SSHMultiplexer.uniqueHosts([sshURL]))
        defer { mux.cleanup(pairs: warmed) }

        let dest = syncRoot.appendingPathComponent(id.rel)
        await sink.emit(.workerStart(platform: id.platform, rel: id.rel,
                                     op: FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path) ? "fetch" : "clone"))
        let outcome = await runSync(platform: id.platform, rel: id.rel, sshURL: sshURL,
                                    dest: dest, branch: branch, mux: mux)
        await sink.emit(.workerFinish(platform: id.platform, rel: id.rel))
        await sink.emit(.outcome(platform: id.platform, outcome: outcome))
        await sink.individualFinished(id, exitCode: 0)
    }

    // Bounded fan-out: at most `parallel` repos syncing at once.
    private func fanOut(_ jobs: [(platform: Platform, repo: DiscoveredRepo, skipped: Bool)],
                        mux: SSHMultiplexer) async {
        let cap = max(1, parallel)
        var index = 0
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            func startNext() {
                guard index < jobs.count else { return }
                let job = jobs[index]; index += 1
                running += 1
                group.addTask { [weak self] in
                    guard let self else { return }
                    let dest = await self.syncRoot.appendingPathComponent(job.repo.rel)
                    await self.sink.emit(.workerStart(platform: job.platform.rawValue, rel: job.repo.rel,
                        op: FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path) ? "fetch" : "clone"))
                    let outcome = await self.runSync(platform: job.platform.rawValue, rel: job.repo.rel,
                        sshURL: job.repo.sshURL, dest: dest, branch: job.repo.defaultBranch, mux: mux)
                    await self.sink.emit(.workerFinish(platform: job.platform.rawValue, rel: job.repo.rel))
                    await self.sink.emit(.outcome(platform: job.platform.rawValue, outcome: outcome))
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

    // Run one repo's clone_or_update with progress events wired to the sink.
    private func runSync(platform: String, rel: String, sshURL: String, dest: URL,
                         branch: String, mux: SSHMultiplexer) async -> Outcome {
        let sink = self.sink
        var ctx = gitContext(mux: mux, rel: rel)
        ctx.isAborted = { [weak self] in
            // Non-actor read; aborted is only ever set true, so a stale false
            // read just means one more git op runs before we notice — safe.
            self?.abortedUnsafe ?? false
        }
        ctx.onProgress = { phase, pct in
            Task { await sink.emit(.workerPhase(platform: platform, rel: rel, phase: phase, pct: pct)) }
        }
        return RepoSyncer.cloneOrUpdate(platform: platform, rel: rel, sshURL: sshURL,
                                        dest: dest, branch: branch, ctx: ctx)
    }

    // nonisolated read of the abort flag for the @Sendable isAborted closure.
    nonisolated var abortedUnsafe: Bool {
        // Reading actor state nonisolated isn't allowed directly; we mirror
        // the flag into an atomic-ish box.
        abortBox.value
    }
    private let abortBox = AbortBox()

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
final class AbortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
    func reset() { lock.lock(); _value = false; lock.unlock() }
}
