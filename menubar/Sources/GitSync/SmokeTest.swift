import Foundation

// CLI smoke test for SyncRunner. Spawns the three platform scripts with
// every platform skipped (so they exit quickly with EXIT_SKIPPED=2 and
// emit no real events), then reports what it observed by polling the
// EventBuffer.
//
// Invoked via:
//   .build/<config>/GitSync.app/Contents/MacOS/GitSync --smoke-test
enum SmokeTest {
    static func run() -> Int32 {
        let buffer = EventBuffer()
        let runner = SyncRunner(settings: settingsForSmokeTest(), eventBuffer: buffer)

        let resultTask = Task { () -> Int32 in
            await runner.startRun()

            // Poll the buffer with a 30s ceiling. Skipped runs complete
            // in well under 1s, but the timeout gives us a hard stop in
            // case the runner deadlocks.
            let deadline = Date().addingTimeInterval(30)
            var events: [SyncEvent] = []
            var logLines: [(String, String)] = []
            var exitCodes: [String: Int32] = [:]
            var allFinished = false

            while !allFinished {
                if Date() >= deadline {
                    print("FAIL: timeout waiting for platforms to finish")
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

    private static func settingsForSmokeTest() -> SyncSettings {
        SyncSettings(
            pythonPath: SyncSettings.bundledPythonPath,
            scriptsDirectory: SyncSettings.bundledScriptsDirectory,
            environment: [
                "GIT_SYNC_ROOT": "/tmp/gitsync-smoketest",
                "GIT_SYNC_SKIP_BITBUCKET": "1",
                "GIT_SYNC_SKIP_GITLAB": "1",
                "GIT_SYNC_SKIP_GITHUB": "1",
            ]
        )
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

        print("SyncRunner smoke test (all platforms skipped)")
        check("all three platforms reported termination",
              exitCodes.count == 3, "got \(exitCodes.keys.sorted())")
        check("all exit codes are EXIT_SKIPPED (2)",
              exitCodes.values.allSatisfy { $0 == 2 },
              "exit codes: \(exitCodes)")
        check("no GIT_SYNC_EVENTS were emitted (skipped runs short-circuit run_jobs)",
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
