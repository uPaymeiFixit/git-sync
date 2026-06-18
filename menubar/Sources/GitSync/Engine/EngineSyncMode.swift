import Foundation

// CLI mode to exercise the SyncEngine end-to-end without touching the
// GUI/AppState — a shell-level debugging harness for discovery + SSH prewarm
// + clone_or_update + fan-out.
//
//   GitSync --engine-sync --only <rel>     one repo (fast path)
//   GitSync --engine-sync --list-only      discover + print, no sync
//   GitSync --engine-sync                  full run
//
// It builds a Provider per platform from env vars (GITLAB_HOST/GITLAB_TOKEN,
// GIT_SYNC_GITHUB_ORG/GIT_SYNC_GITHUB_TOKEN, GIT_SYNC_BITBUCKET_*), so it runs
// through the SAME provider path the app uses. Run it with the user's .envrc
// sourced (or the app's env), with GIT_SYNC_ROOT set.
enum EngineSyncMode {
    // A sink that prints events to stderr and tallies outcomes, then signals
    // completion. Thread-safe; @unchecked Sendable with a lock.
    final class ConsoleSink: EngineSink, @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [Outcome] = []
        let done = DispatchSemaphore(value: 0)
        let listOnly: Bool
        init(listOnly: Bool) { self.listOnly = listOnly }

        func emit(_ event: SyncEvent) async {
            switch event {
            case .remoteProject(_, _, let rel, _, _):
                if listOnly { FileHandle.standardError.write(Data("  remote: \(rel)\n".utf8)) }
            case .outcome(_, let o):
                appendOutcome(o)
                FileHandle.standardError.write(Data("  \(o.status.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(o.rel) \(o.detail)\n".utf8))
            case .workerStart(_, let rel, let op):
                FileHandle.standardError.write(Data("  [\(op)] \(rel)…\n".utf8))
            default: break
            }
        }
        func logLine(_ line: String, platform: String) async {
            FileHandle.standardError.write(Data("  [\(platform)] \(line)\n".utf8))
        }
        func platformFinished(_ platform: String, exitCode: Int32) async {
            FileHandle.standardError.write(Data("  platform \(platform) finished (exit \(exitCode))\n".utf8))
        }
        func allFinished() async { done.signal() }
        func individualFinished(_ id: RepoID, exitCode: Int32) async { done.signal() }

        private func appendOutcome(_ o: Outcome) { lock.lock(); outcomes.append(o); lock.unlock() }
        func summary() -> [Outcome] { lock.lock(); defer { lock.unlock() }; return outcomes }
    }

    static func run(args: [String]) -> Int32 {
        let only = value(after: "--only", in: args)
        let listOnly = args.contains("--list-only")

        let env = ProcessInfo.processInfo.environment
        guard let root = env["GIT_SYNC_ROOT"] else {
            FileHandle.standardError.write(Data("GIT_SYNC_ROOT not set\n".utf8))
            return 2
        }
        // Synthesize a Provider per platform whose env credentials are present,
        // so the engine runs through the real provider path (no legacy fallback).
        let providers = buildProviders(env: env, syncRoot: root)
        guard !providers.isEmpty else {
            FileHandle.standardError.write(Data("no platform env configured (set GITLAB_HOST / GIT_SYNC_GITHUB_ORG / GIT_SYNC_BITBUCKET_WORKSPACE)\n".utf8))
            return 2
        }
        let settings = SyncSettings(environment: env, providers: providers)

        let sink = ConsoleSink(listOnly: listOnly)
        let engine = SyncEngine(settings: settings, sink: sink)

        Task {
            if let only {
                // Match the rel's platform to a provider so syncRepo can resolve
                // the unit by providerID.
                let plat = platformOf(only)
                let pid = providers.first { $0.provider.kind.rawValue == plat }?.provider.id.uuidString ?? ""
                await engine.syncRepo(RepoID(providerID: pid, platform: plat, rel: only),
                                      sshURL: nil, branch: nil)
            } else {
                await engine.startFullRun(listOnly: listOnly)
            }
        }
        // Wait for completion (allFinished or individualFinished).
        let timeout = DispatchTime.now() + .seconds(only != nil ? 120 : 3600)
        if sink.done.wait(timeout: timeout) == .timedOut {
            FileHandle.standardError.write(Data("TIMEOUT\n".utf8))
            return 1
        }
        let outcomes = sink.summary()
        FileHandle.standardError.write(Data("\n\(outcomes.count) outcome(s).\n".utf8))
        return 0
    }

    // Build a ResolvedProvider per platform whose required env credentials are
    // present. Mirrors the old env→client mapping, but as real Providers so the
    // engine's single provider path drives everything.
    private static func buildProviders(env: [String: String], syncRoot: String) -> [ResolvedProvider] {
        func dir(_ name: String) -> String { (syncRoot as NSString).appendingPathComponent(name) }
        var out: [ResolvedProvider] = []

        if let host = env["GITLAB_HOST"], !host.isEmpty {
            let p = Provider(kind: .gitlab, name: "GitLab", host: host,
                             includeArchived: env["GIT_SYNC_INCLUDE_ARCHIVED"] != nil,
                             localPath: dir("Gitlab"), skipPatterns: env["GIT_SYNC_SKIP"] ?? "")
            out.append(ResolvedProvider(provider: p, token: env["GITLAB_TOKEN"] ?? "", trackedRels: []))
        }
        if let org = env["GIT_SYNC_GITHUB_ORG"], !org.isEmpty {
            let p = Provider(kind: .github, name: "GitHub", host: "github.com", scope: org,
                             includeArchived: env["GIT_SYNC_INCLUDE_ARCHIVED"] != nil,
                             localPath: dir("Github"), skipPatterns: env["GIT_SYNC_SKIP"] ?? "")
            out.append(ResolvedProvider(provider: p, token: env["GIT_SYNC_GITHUB_TOKEN"] ?? "", trackedRels: []))
        }
        if let ws = env["GIT_SYNC_BITBUCKET_WORKSPACE"], !ws.isEmpty {
            let p = Provider(kind: .bitbucket, name: "Bitbucket", host: "bitbucket.org", scope: ws,
                             bitbucketUser: env["GIT_SYNC_BITBUCKET_USER"] ?? "",
                             localPath: dir("Bitbucket"), skipPatterns: env["GIT_SYNC_SKIP"] ?? "")
            out.append(ResolvedProvider(provider: p, token: env["GIT_SYNC_BITBUCKET_APP_PASSWORD"] ?? "", trackedRels: []))
        }
        return out
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    // Infer platform from the rel's leading dir (Gitlab/Github/Bitbucket).
    private static func platformOf(_ rel: String) -> String {
        let head = rel.split(separator: "/").first.map(String.init) ?? ""
        switch head { case "Github": return "github"; case "Bitbucket": return "bitbucket"; default: return "gitlab" }
    }
}
