import Foundation

// CLI smoke test for the sync engine's plumbing. Runs the engine with NO
// providers configured (nothing to discover or clone), then asserts it
// finishes promptly through the BufferSink → EventBuffer path without
// deadlocking and without emitting spurious events. This is the cheapest
// end-to-end check that the engine → sink → buffer → drain wiring is intact.
//
// Invoked via:
//   .build/<config>/GitSync.app/Contents/MacOS/GitSync --smoke-test
enum SmokeTest {
    static func run() -> Int32 {
        let buffer = EventBuffer()
        let settings = SyncSettings(
            environment: ["GIT_SYNC_ROOT": "/tmp/gitsync-smoketest"],
            providers: [])   // no providers → no platforms → finishes immediately
        let engine = SyncEngine(settings: settings, sink: BufferSink(buffer: buffer))

        let resultTask = Task { () -> Int32 in
            await engine.startFullRun()

            // Poll the buffer with a 30s ceiling. A no-provider run finishes in
            // well under 1s; the timeout is a hard stop in case it deadlocks.
            let deadline = Date().addingTimeInterval(30)
            var events: [SyncEvent] = []
            var logLines: [(String, String)] = []
            var exitCodes: [String: Int32] = [:]
            var allFinished = false

            while !allFinished {
                if Date() >= deadline {
                    print("FAIL: timeout waiting for the run to finish")
                    return 1
                }
                try? await Task.sleep(for: .milliseconds(50))
                let batch = await buffer.drainAndClear()
                events.append(contentsOf: batch.events)
                for log in batch.logs { logLines.append((log.platform, log.line)) }
                for f in batch.finishes { exitCodes[f.platform] = f.exitCode }
                allFinished = batch.allFinished
            }

            return printReport(events: events, logLines: logLines, exitCodes: exitCodes)
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

    private static func printReport(
        events: [SyncEvent],
        logLines: [(String, String)],
        exitCodes: [String: Int32]
    ) -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok {
                print("  ok   \(label)")
            } else {
                let d = detail()
                print("  FAIL \(label)\(d.isEmpty ? "" : " — \(d)")")
                failures += 1
            }
        }

        print("Engine smoke test (no providers configured)")
        check("run finished (allFinished arrived, no deadlock)", true)
        check("no platforms reported (nothing to sync)",
              exitCodes.isEmpty, "got \(exitCodes.keys.sorted())")
        check("no events emitted (no discovery/clone work)",
              events.isEmpty, "got \(events.count) events")

        if !logLines.isEmpty {
            print("\n  Captured log lines (\(logLines.count)):")
            for (platform, line) in logLines.prefix(10) {
                print("    [\(platform)] \(line)")
            }
        }

        print()
        if failures == 0 {
            print("Smoke test passed.")
            return 0
        } else {
            print("\(failures) check(s) failed.")
            return 1
        }
    }
}
