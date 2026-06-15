import Foundation

// Regression for the FD-exhaustion storm: GitRunner allocated a Pipe (2 FDs)
// per subprocess but never explicitly closed its ends, relying on Foundation
// dealloc timing. Against launchd's 256-FD soft limit, a few hundred repos
// exhausted the table and Process.run() began failing with EBADF — surfaced
// to the user as "command not found: …Bad file descriptor (NSPOSIXErrorDomain
// error 9)" on ~919 repos.
//
//   GitSync --fd-leak-test
//
// Runs many subprocess invocations through BOTH the streaming and one-shot
// paths and asserts the process's open-FD count does not grow with iteration
// count. A leak of even 1 FD/call shows up immediately as a steadily climbing
// count; the fixed code stays flat.
enum FDLeakTest {
    // Count open file descriptors for this process by probing fcntl(F_GETFD).
    static func openFDCount() -> Int {
        let rlimInfinity = rlim_t(bitPattern: Int64.max)
        var lim = rlimit()
        _ = getrlimit(RLIMIT_NOFILE, &lim)
        let cap = Int(min(lim.rlim_cur == rlimInfinity ? 10240 : lim.rlim_cur, 10240))
        var count = 0
        for fd in 0..<cap where fcntl(Int32(fd), F_GETFD) != -1 { count += 1 }
        return count
    }

    static func run() -> Int32 {
        var failures = 0
        func say(_ s: String) { print(s); fflush(stdout) }
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { say("  ok   \(label)") }
            else { failures += 1; say("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        say("FD-leak test")

        let env = ProcessInfo.processInfo.environment
        // N is comfortably past the 256 soft limit so a 1-FD/call leak would
        // run the table dry and surface as EBADF. We DON'T need hundreds of
        // leaked-grandchild children (that just hammers Foundation's process
        // monitor and piles up background sleeps); the EOF/exit-detection path
        // is covered separately by --stream-eof-test. Here we use clean,
        // instant-exit children to isolate the FD-accounting question.
        let N = 300

        // --- One-shot path (runOnce, via the public git wrapper). This is the
        // hottest path: every status/rev-parse/show-ref goes through it. ---
        say("  [one-shot] starting \(N) gitRaw --version calls…")
        let before1 = openFDCount()
        for _ in 0..<N {
            _ = GitRunner.gitRaw(["--version"], env: env)
        }
        let after1 = openFDCount()
        say("  one-shot: FDs \(before1) → \(after1) over \(N) calls")
        check("one-shot path does not leak FDs (Δ ≤ 8)", after1 - before1 <= 8,
              "leaked \(after1 - before1)")

        // --- Streaming path (runStreamingOnce), clean instant-exit children:
        // proves the read-end/defer close reclaims FDs on the normal path. ---
        say("  [streaming] starting \(N) runStreamingOnce calls…")
        let before2 = openFDCount()
        for _ in 0..<N {
            _ = GitRunner.runStreamingOnce(
                ["-c", "echo x; exit 0"],
                env: env, timeout: 60, isAborted: { false }, onProgress: nil,
                exe: "/bin/sh")
        }
        let after2 = openFDCount()
        say("  streaming: FDs \(before2) → \(after2) over \(N) calls")
        check("streaming path does not leak FDs (Δ ≤ 8)", after2 - before2 <= 8,
              "leaked \(after2 - before2)")

        // --- A handful of leaked-grandchild children too, to prove the FD
        // cleanup holds even when the pipe write-end outlives git (the
        // ControlMaster shape). Few iterations: each leaves a short-lived
        // background sleep, and we only need to confirm no FD growth. ---
        say("  [streaming/leaked-fd] 20 calls with a lingering pipe holder…")
        let before3 = openFDCount()
        for _ in 0..<20 {
            _ = GitRunner.runStreamingOnce(
                ["-c", "echo x; (sleep 1 &) ; exit 0"],
                env: env, timeout: 60, isAborted: { false }, onProgress: nil,
                exe: "/bin/sh")
        }
        let after3 = openFDCount()
        say("  leaked-fd: FDs \(before3) → \(after3) over 20 calls")
        check("leaked-grandchild path does not leak FDs (Δ ≤ 8)", after3 - before3 <= 8,
              "leaked \(after3 - before3)")

        // --- Sanity: after all that churn, a fresh spawn STILL succeeds (i.e.
        // we never hit EBADF). With the leak this returned the Bad-file-
        // descriptor error instead. ---
        say("  [sanity] one more spawn after churn…")
        let r = GitRunner.runStreamingOnce(
            ["-c", "echo still-alive; exit 0"],
            env: env, timeout: 30, isAborted: { false }, onProgress: nil,
            exe: "/bin/sh")
        check("spawn still works after churn (no EBADF)",
              r.ok && r.output.contains("still-alive"),
              "ok=\(r.ok) out=\(r.output)")

        say("")
        if failures == 0 { say("FD-leak test passed."); return 0 }
        say("\(failures) check(s) failed."); return 1
    }
}
