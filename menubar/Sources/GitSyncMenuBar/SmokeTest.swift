import Foundation

// CLI smoke test for SyncRunner. Spawns the three platform scripts with
// every platform skipped (so they exit quickly with EXIT_SKIPPED=2 and
// emit no real events), then reports what it observed. Catches:
// - Wrong scripts directory (the SyncSettings.default path)
// - Python interpreter unreachable
// - Pipe / process plumbing broken
// - Termination handler not firing
//
// Invoked via:
//   .build/debug/GitSyncMenuBar.app/Contents/MacOS/GitSyncMenuBar --smoke-test
enum SmokeTest {
    static func run() -> Int32 {
        let runner = SyncRunner(settings: settingsForSmokeTest())
        let collector = Collector()

        let resultTask = Task { () -> Int32 in
            await runner.startRun(delegate: collector)
            // 30s ceiling — skipped runs complete in well under 1s.
            let timeout = Task {
                try? await Task.sleep(for: .seconds(30))
                await collector.timeoutTrip()
            }
            await collector.waitForAllPlatforms()
            timeout.cancel()
            return await collector.printReport()
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

    // Threadsafe holder so we can move the result out of the async closure.
    private final class ResultBox: @unchecked Sendable {
        var value: Int32?
    }

    private static func settingsForSmokeTest() -> SyncSettings {
        var s = SyncSettings.default
        s.environment = [
            "GIT_SYNC_ROOT": "/tmp/gitsync-smoketest",
            "GIT_SYNC_SKIP_BITBUCKET": "1",
            "GIT_SYNC_SKIP_GITLAB": "1",
            "GIT_SYNC_SKIP_GITHUB": "1",
        ]
        return s
    }
}

private actor Collector: SyncRunnerDelegate {
    private var events: [SyncEvent] = []
    private var logLines: [String] = []
    private var exitCodes: [String: Int32] = [:]
    private var doneContinuation: CheckedContinuation<Void, Never>?
    private var isDone = false

    nonisolated func runner(_ runner: SyncRunner, didReceive event: SyncEvent) async {
        await self.appendEvent(event)
    }

    nonisolated func runner(_ runner: SyncRunner, didReceiveLogLine line: String, platform: String) async {
        await self.appendLog("[\(platform)] \(line)")
    }

    nonisolated func runner(_ runner: SyncRunner, didFinishPlatform platform: String, exitCode: Int32) async {
        await self.recordExit(platform: platform, exitCode: exitCode)
    }

    nonisolated func runnerDidFinishAllPlatforms(_ runner: SyncRunner) async {
        await self.markDone()
    }

    private func appendEvent(_ e: SyncEvent) { events.append(e) }
    private func appendLog(_ s: String) { logLines.append(s) }
    private func recordExit(platform: String, exitCode: Int32) {
        exitCodes[platform] = exitCode
    }
    private func markDone() {
        isDone = true
        doneContinuation?.resume()
        doneContinuation = nil
    }

    func waitForAllPlatforms() async {
        if isDone { return }
        await withCheckedContinuation { cont in
            doneContinuation = cont
        }
    }

    func timeoutTrip() {
        guard !isDone else { return }
        logLines.append("[smoke-test] timed out waiting for platforms")
        isDone = true
        doneContinuation?.resume()
        doneContinuation = nil
    }

    func printReport() -> Int32 {
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
              exitCodes.count == 3,
              "got \(exitCodes.keys.sorted())")
        check("all exit codes are EXIT_SKIPPED (2)",
              exitCodes.values.allSatisfy { $0 == 2 },
              "exit codes: \(exitCodes)")
        check("no GIT_SYNC_EVENTS were emitted (skipped runs short-circuit run_jobs)",
              events.isEmpty,
              "got \(events.count) events")

        if !logLines.isEmpty {
            print("\n  Captured log lines (\(logLines.count)):")
            for line in logLines.prefix(10) {
                print("    \(line)")
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
