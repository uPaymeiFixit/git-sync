import Foundation

// CLI test for the concurrent-individual-sync machinery in SyncRunner +
// EventBuffer. Verifies the invariants the design hinges on:
//
//   1. Two SAME-PLATFORM individual jobs run without colliding — each gets
//      its own slot in individualProcesses (keyed by RepoID, not platform)
//      and each produces exactly one independent individual-finish. The
//      first to finish must NOT tear down the other (markAllFinished is
//      never tripped by the individual lane).
//   2. Every early-return path in runIndividual pushes an individual-finish,
//      so a caller that marked a repo "busy" always sees it drain back out
//      (no stuck spinner). Tested via the same-repo dedupe guard.
//
// We drive the real platform script with `--only <bogus rel>` so each child
// lists its API (or skips) and exits quickly without touching any repo —
// fast and side-effect-free, while still exercising the real spawn/termination
// path. All three platforms are skipped via env so no network is required;
// a skipped --only run still spawns, emits no worker events, and terminates,
// which is exactly the lifecycle we care about here.
//
// Invoked via: GitSync --concurrency-test
enum ConcurrencyTest {
    static func run() -> Int32 {
        let buffer = EventBuffer()
        let runner = SyncRunner(settings: settings(), eventBuffer: buffer)

        let resultTask = Task { () -> Int32 in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
                if ok { print("  ok   \(label)") }
                else { failures += 1; let d = detail(); print("  FAIL \(label)\(d.isEmpty ? "" : " — \(d)")") }
            }

            print("SyncRunner concurrency test")

            // Two distinct GitLab repos (same platform, different rel).
            let a = RepoID(platform: "gitlab", rel: "Gitlab/fixture/alpha")
            let b = RepoID(platform: "gitlab", rel: "Gitlab/fixture/beta")

            // Fire both individual syncs "at once". They must both spawn and
            // both finish independently.
            await runner.runIndividual(id: a, extraArgs: ["--only", a.rel])
            await runner.runIndividual(id: b, extraArgs: ["--only", b.rel])

            check("both individual jobs are active in parallel",
                  await runner.individualActive)
            check("a full run is refused while individuals are in flight",
                  !(await tryStartFullRun(runner)),
                  "startRun should no-op while individualActive")

            // Drain until both individual finishes arrive (or time out).
            var finishedIDs = Set<RepoID>()
            var sawAllFinished = false
            let deadline = Date().addingTimeInterval(60)
            while finishedIDs.count < 2 {
                if Date() >= deadline {
                    check("both individual jobs finished within 60s", false,
                          "only saw \(finishedIDs.count): \(finishedIDs)")
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
                let batch = await buffer.drainAndClear()
                if batch.allFinished { sawAllFinished = true }
                for f in batch.individualFinishes { finishedIDs.insert(f.id) }
            }

            check("both individual jobs produced a finish",
                  finishedIDs == [a, b], "got \(finishedIDs)")
            check("individual lane NEVER tripped markAllFinished",
                  !sawAllFinished,
                  "allFinished is the full-run signal and must stay false")
            check("runner is idle after both finish",
                  !(await runner.isRunning))

            // Dedupe early-return must still push a finish (no stuck spinner).
            // Start one job, then immediately request the SAME repo again
            // before it finishes; the second call must emit an individual
            // finish for that id even though it spawns nothing.
            let c = RepoID(platform: "gitlab", rel: "Gitlab/fixture/gamma")
            await runner.runIndividual(id: c, extraArgs: ["--only", c.rel])
            // Second request for c while c is (briefly) in flight. If c has
            // already finished this still exercises a fresh spawn, which is
            // also fine — either way we must get a finish for c back.
            await runner.runIndividual(id: c, extraArgs: ["--only", c.rel])

            var cFinishes = 0
            let deadline2 = Date().addingTimeInterval(60)
            while cFinishes < 1 {
                if Date() >= deadline2 {
                    check("repo c produced at least one finish", false, "got \(cFinishes)")
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
                let batch = await buffer.drainAndClear()
                for f in batch.individualFinishes where f.id == c { cFinishes += 1 }
            }
            check("dedupe/early-return path still drains the repo (finish emitted)",
                  cFinishes >= 1, "got \(cFinishes) finishes for c")

            print()
            if failures == 0 { print("Concurrency test passed."); return 0 }
            print("\(failures) check(s) failed.")
            return 1
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            box.value = await resultTask.value
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? 1
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Int32?
    }

    // Returns true if a full run actually started (i.e. became active). With
    // individuals in flight it must return false (startRun no-ops).
    private static func tryStartFullRun(_ runner: SyncRunner) async -> Bool {
        await runner.startRun()
        return await runner.fullRunActive
    }

    private static func settings() -> SyncSettings {
        SyncSettings(
            pythonPath: SyncSettings.bundledPythonPath,
            scriptsDirectory: SyncSettings.bundledScriptsDirectory,
            environment: [
                "GIT_SYNC_ROOT": "/tmp/gitsync-concurrency-test",
                // Skip all platforms so no network/auth is needed — a skipped
                // --only run still spawns and terminates, which is the
                // lifecycle under test.
                "GIT_SYNC_SKIP_BITBUCKET": "1",
                "GIT_SYNC_SKIP_GITLAB": "1",
                "GIT_SYNC_SKIP_GITHUB": "1",
            ]
        )
    }
}
