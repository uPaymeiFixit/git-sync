import Foundation

// End-to-end stress test for the SyncRunner pipe-reading path. The
// LoadTest exercises the EventBuffer in isolation; this test goes one
// layer down and verifies the readabilityHandler-based pipe reader
// keeps up with a real subprocess writing events at high rate.
//
// Failure mode this protects against: with a previous AsyncBytes-based
// reader, the Swift side stalled when the stdout pipe filled, hanging
// real 1500+ repo runs indefinitely. This test spawns a Python that
// emits a synthetic event stream as fast as it can write — if the
// reader stalls, the producer will block on write() and the test
// times out.
//
// Invoked via:
//   .build/<config>/GitSync.app/Contents/MacOS/GitSync --pipe-stress-test
enum PipeStressTest {
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

    // Number of synthetic outcomes the Python child will emit. Big enough
    // to overflow the 64KB pipe buffer many times over (each event is
    // ~150 bytes, so 5000 events ≈ 750KB).
    private static let totalRepos = 5000

    private static func runAsync() async -> Int32 {
        let buffer = EventBuffer()

        // Spawn a Python -c inline script that emits totalRepos worth of
        // events as fast as possible to stdout, using the same EVENTS_PREFIX
        // tag the real scripts use.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SyncSettings.bundledPythonPath)
        process.arguments = ["-c", inlinePython(repos: totalRepos)]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let splitter = LineSplitter()
        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            let parser = EventParser(platform: "stress")
            for line in splitter.append(data) {
                if case .event(let ev) = parser.parse(line) {
                    Task.detached { @Sendable [buffer] in
                        await buffer.push(ev)
                    }
                }
            }
        }

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            print("FAIL: could not spawn python3: \(error)")
            return 2
        }

        // Drain the buffer while the producer runs, then wait for it.
        var startsSeen = 0
        var finishesSeen = 0
        var outcomesSeen = 0
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            let batch = await buffer.drainAndClear()
            for e in batch.events {
                switch e {
                case .workerStart:  startsSeen += 1
                case .workerFinish: finishesSeen += 1
                case .outcome:      outcomesSeen += 1
                default: break
                }
            }
        }

        // One final drain after the producer exits.
        try? await Task.sleep(for: .milliseconds(200))
        let final = await buffer.drainAndClear()
        for e in final.events {
            switch e {
            case .workerStart:  startsSeen += 1
            case .workerFinish: finishesSeen += 1
            case .outcome:      outcomesSeen += 1
            default: break
            }
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { print("  ok   \(label)") }
            else  { print("  FAIL \(label) — \(detail())"); failures += 1 }
        }

        check("python3 child terminated",
              !process.isRunning,
              "still alive after \(elapsed)s")
        if process.isRunning {
            process.terminate()
        }
        check("exit code 0",
              process.terminationStatus == 0,
              "got \(process.terminationStatus)")
        check("all \(totalRepos) worker_start events seen",
              startsSeen == totalRepos, "got \(startsSeen)")
        check("all \(totalRepos) worker_finish events seen",
              finishesSeen == totalRepos, "got \(finishesSeen)")
        check("all \(totalRepos) outcome events seen",
              outcomesSeen == totalRepos, "got \(outcomesSeen)")
        check("completed within 60s deadline",
              elapsed < 60.0, "took \(String(format: "%.2f", elapsed))s")

        print()
        print("Wall time: \(String(format: "%.2f", elapsed))s for \(totalRepos) round-trip events through the pipe")
        if failures == 0 {
            print("Pipe stress test passed.")
            return 0
        } else {
            print("\(failures) check(s) failed.")
            return 1
        }
    }

    // Generates a Python -c payload that mimics the scripts/_sync.py event
    // protocol: ASCII RS (\x1e) + "GSE " prefix + JSON. Emits N repos
    // worth of worker_start/worker_phase/worker_finish/outcome to stdout.
    private static func inlinePython(repos: Int) -> String {
        return """
        import sys, json
        N = \(repos)
        PREFIX = '\\x1eGSE '
        def emit(kind, **fields):
            line = PREFIX + json.dumps({'kind': kind, **fields}, separators=(',', ':'))
            sys.stdout.write(line + '\\n')
        for i in range(N):
            rel = 'group/repo-' + str(i)
            emit('worker_start', rel=rel, op='clone')
            for p in (10, 30, 50, 70, 90):
                emit('worker_phase', rel=rel, phase='receiving', pct=p)
            emit('worker_finish', rel=rel)
            emit('outcome', rel=rel, status='updated',
                 url='git@example:'+rel+'.git', detail='',
                 old_sha='aaaaaaa', new_sha='bbbbbbb', commits_ahead=1)
        sys.stdout.flush()
        """
    }
}
