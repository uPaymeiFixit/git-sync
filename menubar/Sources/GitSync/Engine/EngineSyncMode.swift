import Foundation

// CLI mode to exercise the native SyncEngine end-to-end against the REAL
// configured platforms, without touching the GUI/AppState. The de-risking
// harness: prove discovery + SSH prewarm + clone_or_update + fan-out work
// together before wiring the engine into the app.
//
//   GitSync --engine-sync --only <rel>     one repo (fast path)
//   GitSync --engine-sync --list-only      discover + print, no sync
//   GitSync --engine-sync                  full run
//
// Settings come from the SAME GIT_SYNC_* / GITLAB_HOST / token env the app
// passes, so run it with the user's .envrc sourced (or the app's env).
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
            case .remoteProject(_, let rel, _, _):
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

        // Build settings from the current process env (the GIT_SYNC_* dict).
        var env = ProcessInfo.processInfo.environment
        // Ensure a sync root is present.
        guard env["GIT_SYNC_ROOT"] != nil else {
            FileHandle.standardError.write(Data("GIT_SYNC_ROOT not set\n".utf8))
            return 2
        }
        // Make the bundled glab discoverable if present (dev: Vendor/).
        if let bin = SyncSettings.bundledBinDirectory {
            env["PATH"] = "\(bin.path):" + (env["PATH"] ?? "/usr/bin:/bin")
        }
        let settings = SyncSettings(pythonPath: "/usr/bin/python3",
                                    scriptsDirectory: SyncSettings.bundledScriptsDirectory,
                                    environment: env)

        let sink = ConsoleSink(listOnly: listOnly)
        let engine = SyncEngine(settings: settings, sink: sink)

        Task {
            if let only {
                await engine.syncRepo(RepoID(platform: platformOf(only), rel: only),
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
