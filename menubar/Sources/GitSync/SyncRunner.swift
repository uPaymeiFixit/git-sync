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
    // Full-run lane: the three platform scripts, keyed by platform name.
    // markAllFinished()/allFinished and the RunRecord belong to this lane
    // ONLY.
    private var processes: [String: Process] = [:]
    private var pending = Set<String>()
    // Individual lane: per-repo --only syncs, keyed by RepoID so any number
    // run in parallel without colliding (different repos = disjoint .git
    // dirs = safe). Keying by RepoID rather than platform is what lets two
    // same-platform individual syncs coexist.
    private var individualProcesses: [RepoID: Process] = [:]
    private var settings: SyncSettings
    private let buffer: EventBuffer

    init(settings: SyncSettings, eventBuffer: EventBuffer) {
        self.settings = settings
        self.buffer = eventBuffer
    }

    func updateSettings(_ settings: SyncSettings) {
        self.settings = settings
    }

    // True while a full run OR any individual sync is in flight. Retained
    // as the catch-all; the two lanes also expose their own predicates.
    var isRunning: Bool { !pending.isEmpty || !individualProcesses.isEmpty }
    var fullRunActive: Bool { !pending.isEmpty }
    var individualActive: Bool { !individualProcesses.isEmpty }

    // Kicks off a fresh run across all three platforms. No-op if a full run
    // OR any individual sync is already in flight — this is the authoritative
    // gate for full-run exclusivity (rule 1). Checking individualProcesses
    // here (not just pending) closes the TOCTOU where a scheduler-fired full
    // run could otherwise race an in-flight individual onto the same repo.
    func startRun() async {
        guard !isRunning else { return }
        for platform in Platform.allCases {
            do {
                try spawn(platform: platform, extraArgs: [])
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

    // Kicks off a single-repo --only sync (from the Repositories view).
    // Runs in parallel with other individual syncs; refused only if a full
    // run is active (rule 1) or this exact repo is already syncing (rule 3).
    //
    // CRITICAL: every early-return path pushes an individual-finish for `id`.
    // AppState inserts `id` into syncingRepos synchronously before awaiting
    // this call, so a bare `return` would leave the row (and the menu-bar
    // icon) spinning forever and permanently block the next full run. The
    // finish event is what drains syncingRepos.
    func runIndividual(id: RepoID, extraArgs: [String]) async {
        func bail(_ reason: String) async {
            await buffer.pushLogLine(reason, platform: id.platform)
            await buffer.pushIndividualFinish(id, exitCode: -1)
        }
        guard pending.isEmpty else {
            return await bail("skipped \(id.rel): a full sync is running")
        }
        guard individualProcesses[id] == nil else {
            return await bail("skipped \(id.rel): already syncing")
        }
        guard let platform = Platform(rawValue: id.platform) else {
            return await bail("skipped \(id.rel): unknown platform \(id.platform)")
        }
        do {
            try spawn(platform: platform, extraArgs: extraArgs, individual: id)
        } catch {
            await bail("failed to spawn \(id.rel): \(error)")
        }
    }

    // Best-effort cancel of everything in flight (both lanes). SIGTERM gives
    // the scripts a chance to clean up; a follow-up SIGKILL after 5s ensures
    // we don't leak processes if a child is stuck in a syscall.
    func cancel() {
        for p in allProcesses() where p.isRunning {
            p.terminate()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let snapshot = await self?.allProcesses() else { return }
            for p in snapshot where p.isRunning {
                kill(p.processIdentifier, SIGKILL)
            }
        }
    }

    private func allProcesses() -> [Process] {
        Array(processes.values) + Array(individualProcesses.values)
    }

    private func spawn(platform: Platform, extraArgs: [String], individual: RepoID? = nil) throws {
        let script = settings.scriptsDirectory.appendingPathComponent(platform.scriptName)
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            throw RunnerError.scriptNotFound(script.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.pythonPath)
        process.arguments = [script.path] + extraArgs
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
            let code = proc.terminationStatus
            Task {
                if let id = individual {
                    await self.handleIndividualTermination(id: id, exitCode: code)
                } else {
                    await self.handleTermination(platform: platformName, exitCode: code)
                }
            }
        }

        try process.run()
        if let id = individual {
            individualProcesses[id] = process
        } else {
            processes[platformName] = process
        }

        // Drain stdout and stderr via readabilityHandler. We deliberately
        // avoid FileHandle.AsyncBytes / .lines here: that path stalled on
        // real high-throughput runs (1500+ repos), apparently because of
        // a known issue with AsyncBytes' suspend/resume around full kernel
        // pipe buffers. readabilityHandler is the time-tested callback
        // API — it fires on a background queue whenever the kernel has
        // data, and never deadlocks against a full pipe.
        attach(reader: stdoutPipe.fileHandleForReading,
               role: .events,
               platform: platformName)
        attach(reader: stderrPipe.fileHandleForReading,
               role: .log,
               platform: platformName)
    }

    private enum ReaderRole {
        case events     // parse GIT_SYNC_EVENTS lines
        case log        // append free-form stderr lines
    }

    // Wires a FileHandle's readabilityHandler into a LineSplitter buffer
    // and hands completed lines to the EventBuffer. Captures the platform
    // name and buffer reference; no `self` so the closures can outlive
    // the runner safely (Process.terminationHandler still finalizes).
    private nonisolated func attach(reader handle: FileHandle, role: ReaderRole, platform: String) {
        let splitter = LineSplitter()
        let buffer = self.buffer
        let parser = role == .events ? EventParser(platform: platform) : nil

        handle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                // EOF — child closed this end. Tear down the handler so
                // it doesn't keep firing with empty data.
                fh.readabilityHandler = nil
                // Flush any trailing fragment that didn't end in \n.
                if let tail = splitter.flushRemainder() {
                    Task.detached { @Sendable in
                        await Self.dispatch(line: tail, role: role, platform: platform,
                                            buffer: buffer, parser: parser)
                    }
                }
                return
            }
            let lines = splitter.append(data)
            guard !lines.isEmpty else { return }
            Task.detached { @Sendable in
                for line in lines {
                    await Self.dispatch(line: line, role: role, platform: platform,
                                        buffer: buffer, parser: parser)
                }
            }
        }
    }

    private static func dispatch(
        line: String,
        role: ReaderRole,
        platform: String,
        buffer: EventBuffer,
        parser: EventParser?
    ) async {
        switch role {
        case .events:
            guard let parser else { return }
            switch parser.parse(line) {
            case .event(let event):
                await buffer.push(event)
            case .logLine(let log) where !log.isEmpty:
                await buffer.pushLogLine(log, platform: platform)
            case .logLine:
                break
            }
        case .log:
            await buffer.pushLogLine(line, platform: platform)
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

    // Per-job teardown for the individual lane. Crucially it does NOT call
    // markAllFinished() — that flag is the full run's completion signal, and
    // tripping it here would tear down any other in-flight individual jobs.
    // Each individual finishes independently via its own pushIndividualFinish.
    private func handleIndividualTermination(id: RepoID, exitCode: Int32) async {
        individualProcesses.removeValue(forKey: id)
        await buffer.pushIndividualFinish(id, exitCode: exitCode)
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
