import Foundation

// Spawns the three sync-{platform}.py scripts in parallel, parses each
// child's event stream (GIT_SYNC_EVENTS=1), and reports events back to a
// delegate (typically AppState). On all three exits, finalizes the
// RunRecord and reports completion.
//
// Design notes:
// - Each platform script is its own Process. stdout/stderr go to separate
//   Pipes — stdout is the event channel (GIT_SYNC_EVENTS protocol), stderr
//   is human-facing log output we capture verbatim.
// - We do NOT shell through sync-all.py: it consumes the events itself to
//   drive its own TUI, so the parent would see nothing useful. Running the
//   three platform scripts directly gives us per-platform attribution for
//   free (one pipe = one platform).
// - macOS Process expects a real, unsandboxed PATH; we set it explicitly
//   plus a passthrough of HOME and a few other essentials so the children
//   can reach git, glab, gh, ssh, etc.

protocol SyncRunnerDelegate: AnyObject, Sendable {
    func runner(_ runner: SyncRunner, didReceive event: SyncEvent) async
    func runner(_ runner: SyncRunner, didReceiveLogLine line: String, platform: String) async
    func runner(_ runner: SyncRunner, didFinishPlatform platform: String, exitCode: Int32) async
    func runnerDidFinishAllPlatforms(_ runner: SyncRunner) async
}

actor SyncRunner {
    private var processes: [String: Process] = [:]
    private var pending = Set<String>()
    private weak var delegate: SyncRunnerDelegate?
    private var settings: SyncSettings

    init(settings: SyncSettings = .default) {
        self.settings = settings
    }

    func updateSettings(_ settings: SyncSettings) {
        self.settings = settings
    }

    var isRunning: Bool { !pending.isEmpty }

    // Kicks off a fresh run across all three platforms. No-op if a run is
    // already in flight — the delegate is expected to keep the menu's
    // Run-now button disabled while isRunning is true.
    func startRun(delegate: SyncRunnerDelegate) async {
        guard !isRunning else { return }
        self.delegate = delegate
        for platform in Platform.allCases {
            do {
                try spawn(platform: platform)
                pending.insert(platform.rawValue)
            } catch {
                await delegate.runner(self, didReceiveLogLine:
                    "failed to spawn \(platform.rawValue): \(error)", platform: platform.rawValue)
                await delegate.runner(self, didFinishPlatform: platform.rawValue, exitCode: -1)
            }
        }
        if pending.isEmpty {
            // Every spawn failed; deliver the all-done callback so AppState
            // doesn't leave the UI stuck in "running" forever.
            await delegate.runnerDidFinishAllPlatforms(self)
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

        // Build the child env. Start from a minimal base PATH so we don't
        // inherit unrelated globals from however the .app was launched,
        // then layer the user's settings on top.
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

        Task.detached { [weak self] in
            await self?.readEvents(from: stdoutPipe, platform: platformName)
        }
        Task.detached { [weak self] in
            await self?.readLog(from: stderrPipe, platform: platformName)
        }
    }

    private func readEvents(from pipe: Pipe, platform: String) async {
        let parser = EventParser(platform: platform)
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                switch parser.parse(line) {
                case .event(let event):
                    await delegate?.runner(self, didReceive: event)
                case .logLine(let log) where !log.isEmpty:
                    // stdout line that isn't an event — surface it as a log
                    // so the user can see anything the child wrote
                    // unexpectedly.
                    await delegate?.runner(self, didReceiveLogLine: log, platform: platform)
                case .logLine:
                    continue
                }
            }
        } catch {
            // Pipe closed unexpectedly — the child likely crashed. Surface
            // it; the termination handler will still fire and finalize.
            await delegate?.runner(self, didReceiveLogLine:
                "event stream error: \(error)", platform: platform)
        }
    }

    private func readLog(from pipe: Pipe, platform: String) async {
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                await delegate?.runner(self, didReceiveLogLine: line, platform: platform)
            }
        } catch {
            // Stderr pipe closed unexpectedly — fine to ignore; termination
            // handler will surface the exit code.
        }
    }

    private func handleTermination(platform: String, exitCode: Int32) async {
        pending.remove(platform)
        processes.removeValue(forKey: platform)
        await delegate?.runner(self, didFinishPlatform: platform, exitCode: exitCode)
        if pending.isEmpty {
            await delegate?.runnerDidFinishAllPlatforms(self)
        }
    }

    private func baseEnvironment() -> [String: String] {
        // .app launches inherit a near-empty environment. Build a sensible
        // base for the child so git/glab/gh/ssh work without the user
        // having to enumerate every var in settings.
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        let user = ProcessInfo.processInfo.environment["USER"]
            ?? NSUserName()
        return [
            "HOME": home,
            "USER": user,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            // Standard search path for Homebrew + system bins. If a user
            // installed glab or gh somewhere else, Settings will add it
            // to the env (PATH override) in a later commit.
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            // SSH agent socket — without this, ssh-based clones fail
            // silently in the app even though they work in the user's
            // shell. macOS doesn't propagate this to GUI children
            // automatically. We pass it through if present at launch.
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
