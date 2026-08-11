import Foundation

// Regression for the "stuck at 'starting', 296 × [timed out after 1800s]"
// wedge. GitRunner.runStreamingOnce ended its read loop ONLY on pipe EOF
// (read==0). But with SSH ControlMaster (ControlPersist=120s) the persistent
// master process inherits the git child's stdout/stderr pipe write-end and
// keeps it open after git exits — so EOF never arrives and every worker
// blocked in select() until the 1800s timeout.
//
//   GitSync --stream-eof-test
//
// We reproduce the FD inheritance exactly without any network: a shell that
// backgrounds a long `sleep` (which inherits the stdout pipe and holds the
// write-end open) and then exits immediately. With the bug, the reader hangs
// on the sleep; with the fix (break when the main process exits, don't wait
// for EOF) it returns in well under a second. We assert it returns promptly
// AND that the output captured before exit is intact.
enum StreamEofTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Stream EOF-vs-exit test")

        let env = ProcessInfo.processInfo.environment

        // CASE 1: child exits immediately but a backgrounded grandchild holds
        // the pipe write-end open for 60s. This is the ControlMaster leak,
        // reproduced. Must return in ~0s, NOT ~60s, and certainly not block
        // until any large timeout.
        let start = Date()
        let r1 = GitRunner.runStreamingOnce(
            ["-c", "echo hello-from-git; (sleep 3 &) ; exit 0"],
            env: env, timeout: 1800, isAborted: { false }, onProgress: nil,
            exe: "/bin/sh")
        let elapsed1 = Date().timeIntervalSince(start)
        print(String(format: "  case 1 returned in %.3fs", elapsed1))
        check("leaked-FD child does not block the reader (< 5s)", elapsed1 < 5.0,
              String(format: "took %.1fs", elapsed1))
        check("output captured before exit is intact",
              r1.output.contains("hello-from-git"), "got: \(r1.output)")
        check("not a timeout", !r1.timedOut)
        check("reports success (exit 0)", r1.ok, "ok=\(r1.ok) out=\(r1.output)")

        // CASE 2: normal fast child, no leak — still works, returns promptly,
        // captures output, correct exit status.
        let r2 = GitRunner.runStreamingOnce(
            ["-c", "echo line1; echo line2; exit 0"],
            env: env, timeout: 30, isAborted: { false }, onProgress: nil,
            exe: "/bin/sh")
        check("clean child: captures all output",
              r2.output.contains("line1") && r2.output.contains("line2"), "got: \(r2.output)")
        check("clean child: success", r2.ok)

        // CASE 3: non-zero exit is reported as failure (and still doesn't hang
        // despite a leaked grandchild).
        let r3 = GitRunner.runStreamingOnce(
            ["-c", "echo boom; (sleep 3 &) ; exit 7"],
            env: env, timeout: 1800, isAborted: { false }, onProgress: nil,
            exe: "/bin/sh")
        check("non-zero exit reported as failure", !r3.ok, "ok=\(r3.ok)")
        check("non-zero exit not a timeout", !r3.timedOut)

        // CASE 4: timeout path still works (a child that truly never exits and
        // produces no output is killed at the deadline, not left forever).
        let start4 = Date()
        let r4 = GitRunner.runStreamingOnce(
            ["-c", "sleep 5"],
            env: env, timeout: 1, isAborted: { false }, onProgress: nil,
            exe: "/bin/sh")
        let elapsed4 = Date().timeIntervalSince(start4)
        check("genuine hang times out near the deadline (< 5s for a 1s timeout)",
              elapsed4 < 5.0, String(format: "took %.1fs", elapsed4))
        check("genuine hang reports timedOut", r4.timedOut, "timedOut=\(r4.timedOut)")

        // CASE 5: real git through the streaming runner, for the empty-remote
        // probe (RepoSyncer.remoteHasNoRefs). That query used to run on the
        // read-to-EOF one-shot runner; it now runs here, and its whole meaning
        // rests on "exit 0 with EMPTY captured output" vs "exit 0 with output".
        // So exercise both against real bare repos rather than trusting that the
        // reader preserves tab-separated ls-remote lines.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gitsync-lsremote-\(getpid())")
        defer { try? fm.removeItem(at: tmp) }
        func git(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        // An EMPTY bare remote, cloned. ls-remote must report zero refs.
        let emptyBare = tmp.appendingPathComponent("empty.git")
        let emptyClone = tmp.appendingPathComponent("empty-clone")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        git(["init", "--bare", "-q", "--initial-branch=master", emptyBare.path])
        git(["clone", "-q", emptyBare.path, emptyClone.path])
        // A POPULATED bare remote, cloned. ls-remote must report refs.
        let fullBare = tmp.appendingPathComponent("full.git")
        let fullClone = tmp.appendingPathComponent("full-clone")
        let seed = tmp.appendingPathComponent("seed")
        git(["init", "--bare", "-q", "--initial-branch=master", fullBare.path])
        git(["init", "-q", "--initial-branch=master", seed.path])
        try? "hello".write(to: seed.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        git(["-C", seed.path, "add", "."])
        git(["-C", seed.path, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "seed"])
        git(["-C", seed.path, "remote", "add", "origin", fullBare.path])
        git(["-C", seed.path, "push", "-q", "origin", "master"])
        git(["clone", "-q", fullBare.path, fullClone.path])

        func lsRemote(_ repo: String) -> GitResult {
            GitRunner.runStreamingWithRetry(
                ["-C", repo, "ls-remote", "--quiet", "origin"],
                env: env, attempts: 1, timeout: 60)
        }
        if fm.fileExists(atPath: emptyClone.path) && fm.fileExists(atPath: fullClone.path) {
            let rEmpty = lsRemote(emptyClone.path)
            let empties = rEmpty.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            check("ls-remote on an EMPTY remote succeeds", rEmpty.ok,
                  "ok=\(rEmpty.ok) out=\(rEmpty.output)")
            check("ls-remote on an EMPTY remote captures no refs", empties,
                  "got: \(rEmpty.output)")

            let rFull = lsRemote(fullClone.path)
            let fulls = rFull.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            check("ls-remote on a POPULATED remote succeeds", rFull.ok,
                  "ok=\(rFull.ok) out=\(rFull.output)")
            check("ls-remote on a POPULATED remote captures refs (not mistaken for empty)",
                  !fulls, "output was empty — empty-remote detection would misfire")
            check("captured ls-remote output keeps its ref names",
                  rFull.output.contains("master"), "got: \(rFull.output)")
        } else {
            check("bare-repo fixtures were created", false, "clone failed; skipped ls-remote checks")
        }

        print()
        if failures == 0 { print("Stream EOF-vs-exit test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }
}
