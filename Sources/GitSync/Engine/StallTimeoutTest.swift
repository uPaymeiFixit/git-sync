import Foundation

// Regression for the connect-vs-transfer timeout conflation.
//
// GIT_SYNC_TIMEOUT (1800s) was ONE number serving two jobs: the ceiling for
// cloning a genuinely large repo, and — accidentally — the ceiling for "the TCP
// connect never completed". Against a half-up VPN tunnel on wake, git produced
// zero bytes and sat for the full 30 minutes with no progress events, so the UI
// showed "starting" forever. That is the reported "goes infinitely".
//
//   GitSync --stall-timeout-test
//
// The fix adds a separate stall deadline: how long a child may produce NO
// output. Any output resets it, so a slow-but-live transfer is bounded only by
// the total `timeout` as before. We reproduce both shapes with /bin/sh — no
// network needed:
//
//   - silent child        → must die at the stall deadline, not the total one
//   - chatty slow child   → must NOT be killed by the stall deadline
//
// The retryability distinction is load-bearing and asserted here too: a total
// timeout must NOT retry (runStreamingWithRetry short-circuits on timedOut,
// since a genuine 30-min transfer won't get faster), but a stall MUST retry
// (the tunnel often finishes coming up moments later).
enum StallTimeoutTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Stall-timeout (connect vs transfer) test")

        let env = ProcessInfo.processInfo.environment

        // CASE 1: the wedge itself. A child that produces NOTHING and never
        // exits, with a LARGE total timeout and a small stall timeout. Before
        // the fix this ran for the full `timeout`; now it dies at the stall
        // deadline. We use timeout=600 to prove the total ceiling is not what
        // saved us.
        let start1 = Date()
        let r1 = GitRunner.runStreamingOnce(
            ["-c", "sleep 600"],
            env: env, timeout: 600, isAborted: { false }, onProgress: nil,
            exe: "/bin/sh", stallTimeout: 1.0)
        let e1 = Date().timeIntervalSince(start1)
        print(String(format: "  case 1 returned in %.2fs (total timeout was 600s)", e1))
        check("silent child dies at the stall deadline, not the total timeout",
              e1 < 10, String(format: "took %.1fs", e1))
        check("stalled child is a failure", !r1.ok)
        check("stall is NOT reported as timedOut (so it stays retryable)",
              !r1.timedOut, "timedOut=\(r1.timedOut)")
        check("stall output explains itself",
              r1.output.contains("stalled"), "got: \(r1.output)")

        // CASE 2: the false-positive guard. A child that IS making progress,
        // slowly — output every 0.2s for ~2s, with a 1s stall timeout. Each
        // write must reset the deadline, so this must run to completion. If the
        // stall check ignored output, this would be killed at 1s.
        let start2 = Date()
        let r2 = GitRunner.runStreamingOnce(
            ["-c", "for i in 1 2 3 4 5 6 7 8 9 10; do echo chunk-$i; sleep 0.2; done; echo done-ok"],
            env: env, timeout: 600, isAborted: { false }, onProgress: nil,
            exe: "/bin/sh", stallTimeout: 1.0)
        let e2 = Date().timeIntervalSince(start2)
        print(String(format: "  case 2 returned in %.2fs", e2))
        check("chatty slow child is NOT killed by the stall deadline", r2.ok,
              "ok=\(r2.ok) out=\(r2.output)")
        check("chatty slow child ran to completion",
              r2.output.contains("done-ok"), "got: \(r2.output)")
        check("chatty slow child not marked stalled",
              !r2.output.contains("stalled"), "got: \(r2.output)")
        check("chatty child took longer than the stall window (proves resets)",
              e2 > 1.0, String(format: "took %.2fs", e2))

        // CASE 3: a child that talks, then goes silent mid-transfer. This is a
        // dropped tunnel partway through a clone. Must trip the stall deadline
        // AFTER the last output, keeping what it captured.
        let start3 = Date()
        let r3 = GitRunner.runStreamingOnce(
            ["-c", "echo receiving-objects; sleep 600"],
            env: env, timeout: 600, isAborted: { false }, onProgress: nil,
            exe: "/bin/sh", stallTimeout: 1.0)
        let e3 = Date().timeIntervalSince(start3)
        check("mid-transfer stall is caught", e3 < 10,
              String(format: "took %.1fs", e3))
        check("output captured before the stall is kept",
              r3.output.contains("receiving-objects"), "got: \(r3.output)")
        check("mid-transfer stall stays retryable", !r3.timedOut)

        // CASE 4: the total timeout still works and still does NOT retry. A
        // child that chatters forever can't be killed by the stall deadline, so
        // only the total ceiling stops it.
        let start4 = Date()
        let r4 = GitRunner.runStreamingOnce(
            ["-c", "while true; do echo tick; sleep 0.1; done"],
            env: env, timeout: 1.0, isAborted: { false }, onProgress: nil,
            exe: "/bin/sh", stallTimeout: 30)
        let e4 = Date().timeIntervalSince(start4)
        check("chattering child is stopped by the TOTAL timeout", e4 < 10,
              String(format: "took %.1fs", e4))
        check("total timeout still reports timedOut (non-retryable)",
              r4.timedOut, "timedOut=\(r4.timedOut)")

        // CASE 5: retryability, end to end through the retry wrapper.
        // A stall must be retried; a total timeout must not. We count attempts
        // via onRetry (called before each re-attempt).
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }

        let stallRetries = Counter()
        let rStall = GitRunner.runStreamingWithRetry(
            ["-c", "sleep 600"],
            env: env, attempts: 3, timeout: 600, backoff: 0.01,
            onRetry: { stallRetries.bump() },
            stallTimeout: 0.5, exe: "/bin/sh")
        check("a stall IS retried (tunnel may come up next attempt)",
              stallRetries.value == 2, "retries=\(stallRetries.value)")
        check("a stall exhausts attempts and reports failure", !rStall.ok)

        let timeoutRetries = Counter()
        let rTimeout = GitRunner.runStreamingWithRetry(
            ["-c", "while true; do echo tick; sleep 0.05; done"],
            env: env, attempts: 3, timeout: 0.5, backoff: 0.01,
            onRetry: { timeoutRetries.bump() },
            stallTimeout: 30, exe: "/bin/sh")
        check("a total timeout is NOT retried",
              timeoutRetries.value == 0, "retries=\(timeoutRetries.value)")
        // A child producing output continuously must still be classified as a
        // TIMEOUT (not a plain failure) when it hits the total ceiling —
        // otherwise the retry layer would re-run a genuine 30-minute transfer
        // `attempts` times.
        check("a continuously-chattering child is classified as timedOut",
              rTimeout.timedOut, "timedOut=\(rTimeout.timedOut)")

        // CASE 6: stallTimeout=0 disables the check (escape hatch for a caller
        // that genuinely expects long silence).
        let start6 = Date()
        let r6 = GitRunner.runStreamingOnce(
            ["-c", "sleep 600"],
            env: env, timeout: 1.0, isAborted: { false }, onProgress: nil,
            exe: "/bin/sh", stallTimeout: 0)
        let e6 = Date().timeIntervalSince(start6)
        check("stallTimeout=0 disables the stall check", r6.timedOut,
              "timedOut=\(r6.timedOut)")
        check("with the stall check off, the total timeout applies", e6 < 10,
              String(format: "took %.1fs", e6))

        // CASE 7: the default is sane — well above a plausible quiet phase,
        // well below the 1800s that made this look like a hang.
        check("default stall timeout is shorter than a typical total timeout",
              GitRunner.defaultStallTimeout < 1800)
        check("default stall timeout tolerates a long quiet enumeration phase",
              GitRunner.defaultStallTimeout >= 60,
              "\(GitRunner.defaultStallTimeout)")

        print()
        if failures == 0 { print("Stall-timeout test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }
}
