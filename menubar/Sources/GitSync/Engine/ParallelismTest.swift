import Foundation

// Proves the fan-out actually runs repos CONCURRENTLY, not serialized on the
// SyncEngine actor. Regression test for the bug where runSync was
// actor-isolated and ran the blocking git work synchronously on the actor,
// so N "parallel" workers ticked down one at a time.
//
//   GitSync --parallelism-test
//
// Builds M local bare repos + empty dests, then runs M syncOne operations
// concurrently via a TaskGroup (same shape as fanOut) and records each
// worker's start/end wall-clock. If they truly overlap, the max concurrent
// count reaches ~M and total wall-time << sum of individual times. If they
// serialize, concurrency peaks at 1.
enum ParallelismTest {
    final class Recorder: EngineSink, @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var peakConcurrency = 0
        private(set) var starts = 0
        let total: Int
        let allDone = DispatchSemaphore(value: 0)
        init(total: Int) { self.total = total }

        func emit(_ event: SyncEvent) async {
            switch event {
            case .workerStart: onStart()
            case .workerFinish: onFinish()
            default: break
            }
        }
        private func onStart() {
            lock.lock(); active += 1; starts += 1
            peakConcurrency = max(peakConcurrency, active); lock.unlock()
        }
        private func onFinish() { lock.lock(); active -= 1; lock.unlock() }
        func logLine(_ line: String, platform: String) async {}
        func platformFinished(_ platform: String, exitCode: Int32) async {}
        func allFinished() async { allDone.signal() }
        func individualFinished(_ id: RepoID, exitCode: Int32) async {}
    }

    static func run() -> Int32 {
        let M = 12
        let base = URL(fileURLWithPath: "/tmp/gitsync-parallel-test")
        try? FileManager.default.removeItem(at: base)
        let root = base.appendingPathComponent("root")
        let gitlab = root.appendingPathComponent("Gitlab")
        try? FileManager.default.createDirectory(at: gitlab, withIntermediateDirectories: true)

        // M bare remotes each with a commit, so each sync does a real clone.
        for i in 0..<M {
            let bare = base.appendingPathComponent("r\(i).git")
            sh("/usr/bin/git", ["init", "--bare", "-q", "--initial-branch=master", bare.path])
            let seed = base.appendingPathComponent("seed\(i)")
            sh("/usr/bin/git", ["clone", "-q", bare.path, seed.path])
            // a few files so the clone isn't instant
            for f in 0..<5 { try? "x\(f)".write(to: seed.appendingPathComponent("f\(f).txt"), atomically: true, encoding: .utf8) }
            sh("/usr/bin/git", ["-C", seed.path, "add", "."])
            sh("/usr/bin/git", ["-C", seed.path, "commit", "-qm", "seed"])
            sh("/usr/bin/git", ["-C", seed.path, "push", "-q", "origin", "HEAD:master"])
        }

        var env = ProcessInfo.processInfo.environment
        env["GIT_SYNC_ROOT"] = root.path
        env["GIT_SYNC_DEPTH"] = "0"
        env["GIT_SYNC_NO_SSH_MUX"] = "1"
        env["GIT_SYNC_PARALLEL"] = String(M)
        let cfg = SyncEngine.WorkConfig(baseEnv: env, syncRoot: root, depth: 0, timeout: 120)
        let mux = SSHMultiplexer(parallel: M, pid: ProcessInfo.processInfo.processIdentifier,
                                 uid: getuid(), enabled: false)
        let rec = Recorder(total: M)
        let abort = AbortBox()

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Parallelism test (\(M) concurrent clones)")

        // Drive the same bounded TaskGroup shape fanOut uses, calling the
        // nonisolated syncOne directly.
        let pool = GitWorkPool(width: M)
        let group = DispatchGroup()
        group.enter()
        Task {
            await withTaskGroup(of: Void.self) { g in
                for i in 0..<M {
                    let bare = base.appendingPathComponent("r\(i).git").path
                    g.addTask {
                        _ = await SyncEngine.syncOne(
                            cfg: cfg, mux: mux, providerID: "", platform: "gitlab", rel: "r\(i)",
                            destRoot: gitlab, sshURL: bare, branch: "master",
                            abort: abort, sink: rec, pool: pool)
                    }
                }
                await g.waitForAll()
            }
            group.leave()
        }
        group.wait()

        check("all \(M) workers started", rec.starts == M, "got \(rec.starts)")
        // The crux: with real parallelism, peak concurrency should be well
        // above 1 (ideally ~M). Serialized-on-actor would peak at 1.
        check("workers ran concurrently (peak > 1)", rec.peakConcurrency > 1,
              "peak concurrency was \(rec.peakConcurrency)")
        check("peak concurrency reached most of the pool (>= M/2)",
              rec.peakConcurrency >= M / 2, "peak was \(rec.peakConcurrency)/\(M)")

        try? FileManager.default.removeItem(at: base)
        print()
        if failures == 0 { print("Parallelism test passed (peak \(rec.peakConcurrency)/\(M) concurrent)."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }

    private static func sh(_ exe: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        let ov = [("commit.gpgsign", "false"), ("tag.gpgsign", "false"),
                  ("user.email", "fixture@example.invalid"), ("user.name", "GitSync Fixture")]
        for (i, kv) in ov.enumerated() { e["GIT_CONFIG_KEY_\(i)"] = kv.0; e["GIT_CONFIG_VALUE_\(i)"] = kv.1 }
        e["GIT_CONFIG_COUNT"] = String(ov.count)
        p.environment = e
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
