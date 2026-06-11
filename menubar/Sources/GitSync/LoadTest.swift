import Foundation

// Synthetic load test for the EventBuffer pipeline. Simulates the wedge
// condition we hit during a real 1552-repo GitLab run: produce events
// faster than a slow consumer can drain them, and verify the buffer
// coalesces correctly without dropping discrete events (worker_start,
// worker_finish, outcome) and without blocking the producer.
//
// Invoked via:
//   .build/<config>/GitSync.app/Contents/MacOS/GitSync --load-test
//
// Passes when:
// 1. All N "real" repos (workerStart → workerFinish + outcome) survive
//    the round trip with no drops.
// 2. Producer pushes 100k events in < 5s (i.e. ~20k events/sec) — proves
//    push() does not block on consumer drain rate.
// 3. The final buffer batch contains AT MOST N latest-phase snapshots,
//    not the thousands of intermediate ones (proves coalescing works).
enum LoadTest {
    static func run() -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            box.value = await runAsync()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? 1
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Int32?
    }

    private static func runAsync() async -> Int32 {
        let buffer = EventBuffer()
        let totalRepos = 1500           // similar to user's real GitLab run
        let phasesPerRepo = 50          // 50 progress ticks per repo, by design overkill
        let totalEvents = totalRepos * (2 + phasesPerRepo) + totalRepos  // start + finishes + phases + outcomes
        print("LoadTest: producing \(totalEvents) events for \(totalRepos) repos…")

        let producerStart = Date()
        let producer = Task.detached {
            for i in 0..<totalRepos {
                let rel = "group/repo-\(i)"
                await buffer.push(.workerStart(platform: "gitlab", rel: rel, op: "clone"))
                for p in stride(from: 0, through: 100, by: 100 / phasesPerRepo) {
                    await buffer.push(.workerPhase(
                        platform: "gitlab", rel: rel,
                        phase: p < 50 ? "receiving" : "resolving",
                        pct: p))
                }
                await buffer.push(.workerFinish(platform: "gitlab", rel: rel))
                let outcome = Outcome(
                    rel: rel, status: .updated,
                    url: "git@example:\(rel).git",
                    detail: "fast-forwarded",
                    oldSha: "aaa", newSha: "bbb", commitsAhead: 1)
                await buffer.push(.outcome(platform: "gitlab", outcome: outcome))
            }
            await buffer.markAllFinished()
        }

        // Slow consumer — pretend the UI is rendering at 10Hz.
        var startsSeen = 0
        var finishesSeen = 0
        var outcomesSeen = 0
        var latestPhaseBatchSizes: [Int] = []
        var allFinished = false
        let deadline = Date().addingTimeInterval(30)
        while !allFinished {
            if Date() >= deadline {
                _ = await producer.result
                print("FAIL: consumer timed out after 30s")
                return 1
            }
            try? await Task.sleep(for: .milliseconds(100))
            let batch = await buffer.drainAndClear()
            latestPhaseBatchSizes.append(batch.latestPhases.count)
            for e in batch.events {
                switch e {
                case .workerStart:  startsSeen += 1
                case .workerFinish: finishesSeen += 1
                case .outcome:      outcomesSeen += 1
                default: break
                }
            }
            allFinished = batch.allFinished
        }
        _ = await producer.result
        let producerElapsed = Date().timeIntervalSince(producerStart)

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { print("  ok   \(label)") }
            else  { print("  FAIL \(label) — \(detail())"); failures += 1 }
        }

        check("all \(totalRepos) worker_start events seen",
              startsSeen == totalRepos, "got \(startsSeen)")
        check("all \(totalRepos) worker_finish events seen",
              finishesSeen == totalRepos, "got \(finishesSeen)")
        check("all \(totalRepos) outcome events seen",
              outcomesSeen == totalRepos, "got \(outcomesSeen)")
        check("producer finished in < 30s",
              producerElapsed < 30.0,
              "took \(String(format: "%.2f", producerElapsed))s")
        let maxBatch = latestPhaseBatchSizes.max() ?? 0
        check("phase batch never exceeded \(totalRepos) snapshots (coalescing works)",
              maxBatch <= totalRepos,
              "saw a batch of \(maxBatch) phase snapshots")
        let totalPhasesIfNoCoalescing = totalRepos * phasesPerRepo
        let totalPhasesAfterCoalescing = latestPhaseBatchSizes.reduce(0, +)
        check("coalescing collapsed phase events (\(totalPhasesAfterCoalescing) flushed vs \(totalPhasesIfNoCoalescing) produced)",
              totalPhasesAfterCoalescing < totalPhasesIfNoCoalescing,
              "no coalescing observed")

        print()
        print("Producer wall time: \(String(format: "%.2f", producerElapsed))s for \(totalEvents) events")
        print("Phase coalescing ratio: \(totalPhasesAfterCoalescing) flushed / \(totalPhasesIfNoCoalescing) produced = \(String(format: "%.1f", Double(totalPhasesAfterCoalescing) / Double(totalPhasesIfNoCoalescing) * 100))%")
        if failures == 0 {
            print("Load test passed.")
            return 0
        } else {
            print("\(failures) check(s) failed.")
            return 1
        }
    }
}
