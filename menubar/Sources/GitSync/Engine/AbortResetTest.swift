import Foundation

// Regression test for the HIGH bug found in review: abortBox is a long-lived
// flag on the engine singleton, so a cancel() must NOT poison subsequent
// individual syncs. Before the fix, after a cancel every later individual
// sync returned "aborted" without doing any git work.
//
//   GitSync --abort-reset-test
//
// Builds a local bare repo + clone, cancels the engine, then runs an
// individual sync against that repo and asserts it reports a real status
// (up-to-date), not error/aborted.
enum AbortResetTest {
    final class CapturingSink: EngineSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _outcomes: [Outcome] = []
        let done = DispatchSemaphore(value: 0)
        func emit(_ event: SyncEvent) async {
            if case .outcome(_, let o) = event { append(o) }
        }
        private func append(_ o: Outcome) { lock.lock(); _outcomes.append(o); lock.unlock() }
        func logLine(_ line: String, platform: String) async {}
        func platformFinished(_ platform: String, exitCode: Int32) async {}
        func allFinished() async { done.signal() }
        func individualFinished(_ id: RepoID, exitCode: Int32) async { done.signal() }
        var outcomes: [Outcome] { lock.lock(); defer { lock.unlock() }; return _outcomes }
    }

    static func run() -> Int32 {
        let base = URL(fileURLWithPath: "/tmp/gitsync-abort-reset")
        try? FileManager.default.removeItem(at: base)
        let root = base.appendingPathComponent("root")
        let platformDir = root.appendingPathComponent("Gitlab")
        try? FileManager.default.createDirectory(at: platformDir, withIntermediateDirectories: true)

        // Bare remote with one commit + a clone of it.
        let bare = base.appendingPathComponent("repo.git")
        sh("/usr/bin/git", ["init", "--bare", "-q", "--initial-branch=master", bare.path])
        let seed = base.appendingPathComponent("seed")
        sh("/usr/bin/git", ["clone", "-q", bare.path, seed.path])
        sh("/usr/bin/git", ["-C", seed.path, "-c", "user.email=t@t", "-c", "user.name=T",
                            "commit", "-qm", "init", "--allow-empty"])
        sh("/usr/bin/git", ["-C", seed.path, "push", "-q", "origin", "HEAD:master"])
        let dest = platformDir.appendingPathComponent("repo")
        sh("/usr/bin/git", ["clone", "-q", bare.path, dest.path])

        var env = ProcessInfo.processInfo.environment
        env["GIT_SYNC_ROOT"] = root.path
        env["GIT_SYNC_DEPTH"] = "0"
        env["GIT_SYNC_NO_SSH_MUX"] = "1"   // local file remote, no ssh
        let settings = SyncSettings(pythonPath: "/usr/bin/python3",
                                    scriptsDirectory: SyncSettings.bundledScriptsDirectory,
                                    environment: env)
        let sink = CapturingSink()
        let engine = SyncEngine(settings: settings, sink: sink)
        let id = RepoID(platform: "gitlab", rel: "Gitlab/repo")

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Abort-reset regression test")

        // 1. Cancel the engine FIRST (sets the abort flag), simulating a
        //    cancelled prior run.
        let sem1 = DispatchSemaphore(value: 0)
        Task { await engine.cancel(); sem1.signal() }
        sem1.wait()

        // 2. Now run an individual sync. It must NOT be poisoned by the stale
        //    abort flag — it should actually sync and report up-to-date.
        Task { await engine.syncRepo(id, sshURL: bare.path, branch: "master") }
        let timedOut = sink.done.wait(timeout: .now() + 30) == .timedOut
        check("individual sync completed (not stuck)", !timedOut)

        let outcomes = sink.outcomes
        check("exactly one outcome", outcomes.count == 1, "got \(outcomes.count)")
        if let o = outcomes.first {
            check("status is up-to-date, NOT error/aborted",
                  o.status == .upToDate, "got \(o.status.rawValue): \(o.detail)")
        }

        try? FileManager.default.removeItem(at: base)
        print()
        if failures == 0 { print("Abort-reset test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }

    private static func sh(_ exe: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
