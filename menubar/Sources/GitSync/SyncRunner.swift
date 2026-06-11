import Foundation

// Spawns the three sync-{platform}.py scripts in parallel, parses each
// child's event stream (GIT_SYNC_EVENTS=1), and pushes events into an
// EventBuffer. Consumers (AppState in production, SmokeTest in tests)
// drain the buffer on their own cadence.
//
// Design notes:
// - Each platform script is its own Process. stdout/stderr go to separate
//   Pipes — stdout is the event channel (GIT_SYNC_EVENTS protocol), stderr
//   is human-facing log output we capture verbatim.
// - We do NOT shell through sync-all.py: it consumes the events itself to
//   drive its own TUI, so the parent would see nothing useful.
// - Critical: the pipe-reader tasks MUST drain into the EventBuffer with
//   minimal blocking. Earlier prototypes did a MainActor hop per event,
//   which under load (1000+ repos) backed up the Python's stdout pipe
//   and wedged the entire run. The buffer absorbs bursts and the UI
//   drains in batches.

actor SyncRunner {
    private var processes: [String: Process] = [:]
    private var pending = Set<String>()
    private var settings: SyncSettings
    private let buffer: EventBuffer

    init(settings: SyncSettings, eventBuffer: EventBuffer) {
        self.settings = settings
        self.buffer = eventBuffer
    }

    func updateSettings(_ settings: SyncSettings) {
        self.settings = settings
    }

    var isRunning: Bool { !pending.isEmpty }

    // Kicks off a fresh run across all three platforms. No-op if a run is
    // already in flight.
    func startRun() async {
        guard !isRunning else { return }
        for platform in Platform.allCases {
            do {
                try spawn(platform: platform)
                pending.insert(platform.rawValue)
            } catch {
                await buffer.pushLogLine(
                    "failed to spawn \(platform.rawValue): \(error)",
                    platform: platform.rawValue
                )
                await buffer.pushPlatformFinish(platform.rawValue, exitCode: -1)
            }
        }
        if pending.isEmpty {
            // Every spawn failed; tell the consumer we're done so the UI
            // doesn't get stuck in "running" forever.
            await buffer.markAllFinished()
        }
    }

    // Best-effort cancel. SIGTERM gives the scripts a chance to clean up;
    // a follow-up SIGKILL after 5s ensures we don't leak processes if a
    // child is stuck in a syscall.
    func cancel() {
        for (_, process) in processes where process.isRunning {
            process.terminate()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let snapshot = await self?.snapshotProcesses() else { return }
            for (_, process) in snapshot where process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func snapshotProcesses() -> [String: Process] { processes }

    private func spawn(platform: Platform) throws {
        let script = settings.scriptsDirectory.appendingPathComponent(platform.scriptName)
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            throw RunnerError.scriptNotFound(script.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.pythonPath)
        process.arguments = [script.path]
        process.currentDirectoryURL = settings.scriptsDirectory

        var env = baseEnvironment()
        env["GIT_SYNC_EVENTS"] = "1"
        for (k, v) in settings.environment {
            env[k] = v
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let platformName = platform.rawValue
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task {
                await self.handleTermination(platform: platformName, exitCode: proc.terminationStatus)
            }
        }

        try process.run()
        processes[platformName] = process

        let buffer = self.buffer
        Task.detached {
            await Self.readEvents(from: stdoutPipe, platform: platformName, into: buffer)
        }
        Task.detached {
            await Self.readLog(from: stderrPipe, platform: platformName, into: buffer)
        }
    }

    // Drains the platform child's stdout into the buffer. Critical that
    // this never blocks on UI: each push() only touches the buffer actor.
    // Coalescing of worker_phase events happens inside the buffer.
    private static func readEvents(from pipe: Pipe, platform: String, into buffer: EventBuffer) async {
        let parser = EventParser(platform: platform)
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                switch parser.parse(line) {
                case .event(let event):
                    await buffer.push(event)
                case .logLine(let log) where !log.isEmpty:
                    await buffer.pushLogLine(log, platform: platform)
                case .logLine:
                    continue
                }
            }
        } catch {
            await buffer.pushLogLine(
                "event stream error: \(error)", platform: platform)
        }
    }

    private static func readLog(from pipe: Pipe, platform: String, into buffer: EventBuffer) async {
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                await buffer.pushLogLine(line, platform: platform)
            }
        } catch {
            // stderr pipe closed unexpectedly — fine to ignore.
        }
    }

    private func handleTermination(platform: String, exitCode: Int32) async {
        pending.remove(platform)
        processes.removeValue(forKey: platform)
        await buffer.pushPlatformFinish(platform, exitCode: exitCode)
        if pending.isEmpty {
            await buffer.markAllFinished()
        }
    }

    private func baseEnvironment() -> [String: String] {
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        let user = ProcessInfo.processInfo.environment["USER"]
            ?? NSUserName()
        // Prepend the bundled bin directory so sync-gitlab.py's hardcoded
        // `glab` resolves to our bundled copy.
        var path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let bin = SyncSettings.bundledBinDirectory {
            path = "\(bin.path):\(path)"
        }
        return [
            "HOME": home,
            "USER": user,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": path,
            // SSH agent socket — without this, ssh-based clones fail
            // silently in the app even though they work in the user's
            // shell.
            "SSH_AUTH_SOCK": ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? "",
        ]
    }
}

enum RunnerError: Error, CustomStringConvertible {
    case scriptNotFound(String)
    var description: String {
        switch self {
        case .scriptNotFound(let path): return "script not found: \(path)"
        }
    }
}
