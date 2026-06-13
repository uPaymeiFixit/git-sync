import Foundation

// Runs `git` subprocesses for the native sync engine. This is the Swift
// port of scripts/_sync.py's _git / _run_streaming / run_with_retry, kept
// deliberately faithful: same env (LC_ALL=C, GIT_TERMINAL_PROMPT=0,
// GIT_SSH_COMMAND), same combined stdout+stderr capture, same line-splitting
// on '\n' OR '\r' (git --progress rewrites a line in place via carriage
// return), same retry/backoff-with-jitter semantics, and the same rule that
// a TIMEOUT does not retry.
//
// Not an actor: it holds no mutable shared state. Each call spawns its own
// Process and returns a value. Callers run it from whatever actor/task they
// like; concurrency is bounded by the engine's TaskGroup, not here.

struct GitResult: Sendable {
    let ok: Bool
    let output: String      // combined stdout+stderr, lines joined by '\n'
    let timedOut: Bool
    let aborted: Bool
}

// Sendable progress callback: (phase, percent) parsed from git --progress.
typealias ProgressHandler = @Sendable (_ phase: String, _ percent: Int) -> Void

enum GitRunner {
    static let gitPath = "/usr/bin/git"

    // One git invocation, combined output, no streaming/retry. Mirrors
    // _sync.py:_git — returns (exitCode, output). Used for the cheap query
    // commands (rev-parse, status, show-ref, ls-remote, …).
    @discardableResult
    static func git(_ repo: String, _ args: String..., env: [String: String]) -> (code: Int32, out: String) {
        runOnce(["-C", repo] + args, env: env)
    }

    static func git(_ repo: String, _ args: [String], env: [String: String]) -> (code: Int32, out: String) {
        runOnce(["-C", repo] + args, env: env)
    }

    // Bare invocation with no -C (e.g. `git clone <url> <dest>`).
    static func gitRaw(_ args: [String], env: [String: String]) -> (code: Int32, out: String) {
        runOnce(args, env: env)
    }

    // Run an arbitrary program resolved via the env's PATH (e.g. `glab`),
    // combined stdout+stderr. Used by the GitLab discovery client to shell
    // glab the same way the Python did. Mirrors _glab_api_single's
    // subprocess.run (read to EOF; glab is a single process with no
    // pipe-inheriting helpers, so readDataToEndOfFile is safe here).
    static func gitRawProgram(_ program: String, _ args: [String], env: [String: String]) -> (code: Int32, out: String) {
        let p = Process()
        // Resolve via /usr/bin/env so PATH (with the bundled bin dir) applies.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [program] + args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return (-1, "command not found: \(program): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func runOnce(_ args: [String], env: [String: String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe   // combined, like _git's stderr=STDOUT
        do { try p.run() } catch {
            return (-1, "command not found: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // Streaming run with retry/backoff — the port of run_with_retry +
    // _run_streaming. `args` is the full git argv (e.g. ["-C", repo,
    // "fetch", …] or ["clone", …]). `isAborted` lets the caller cancel a
    // run cooperatively (checked before each attempt and during backoff).
    // `onRetry` cleans up partial state before a re-attempt (e.g. rmtree a
    // half-made clone). `onProgress` receives parsed (phase, pct) lines.
    static func runStreamingWithRetry(
        _ args: [String],
        env: [String: String],
        attempts: Int,
        timeout: TimeInterval,
        backoff: TimeInterval = 2.0,
        isAborted: @escaping @Sendable () -> Bool = { false },
        onRetry: (() -> Void)? = nil,
        onProgress: ProgressHandler? = nil
    ) -> GitResult {
        var delay = backoff
        var lastOutput = ""
        var attempt = 0
        while attempt < attempts {
            attempt += 1
            if isAborted() {
                return GitResult(ok: false, output: lastOutput + "\n[aborted]", timedOut: false, aborted: true)
            }
            if attempt > 1, let onRetry { onRetry() }

            let r = runStreamingOnce(args, env: env, timeout: timeout,
                                     isAborted: isAborted, onProgress: onProgress)
            lastOutput = r.output
            if r.timedOut {
                // A timeout means "takes longer than `timeout`" — retrying
                // only burns time. Surface immediately (matches Python).
                return r
            }
            if r.ok || r.aborted {
                return r
            }
            if attempt < attempts {
                // ±50% jitter so a herd of workers hit by the same transient
                // failure (sshd MaxStartups, throttling) don't retry in
                // lockstep and recreate the condition.
                let jitter = Double.random(in: 0.5...1.5)
                let sleepFor = delay * jitter
                if interruptibleSleep(sleepFor, isAborted: isAborted) {
                    return GitResult(ok: false, output: lastOutput + "\n[aborted]", timedOut: false, aborted: true)
                }
                delay *= 2
            }
        }
        return GitResult(ok: false, output: lastOutput, timedOut: false, aborted: false)
    }

    // Returns true if aborted during the sleep.
    private static func interruptibleSleep(_ seconds: TimeInterval, isAborted: @Sendable () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isAborted() { return true }
            Thread.sleep(forTimeInterval: min(0.1, deadline.timeIntervalSinceNow))
        }
        return isAborted()
    }

    // One streaming attempt. Enforces `timeout` manually (Process has no
    // built-in deadline), splits output on '\n'/'\r' for progress, and kills
    // the child on timeout or abort. Port of _run_streaming.
    private static func runStreamingOnce(
        _ args: [String],
        env: [String: String],
        timeout: TimeInterval,
        isAborted: @escaping @Sendable () -> Bool,
        onProgress: ProgressHandler?
    ) -> GitResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return GitResult(ok: false, output: "command not found: \(error.localizedDescription)",
                             timedOut: false, aborted: false)
        }

        let readFD = pipe.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var captured: [String] = []
        var buf = Data()
        var timedOut = false
        var aborted = false

        // Mirror Python's _run_streaming: non-blocking fd + select() with a
        // bounded slice. The AUTHORITATIVE end-of-stream signal is read()
        // returning 0 (EOF) — i.e. git AND every helper child that inherited
        // the pipe write-end have closed it. We do NOT rely on p.isRunning to
        // end the loop: on a thread with no run loop, Foundation may not reap
        // the child promptly, so isRunning can stay true long after exit (the
        // bug that made this look like a hang). EOF is reliable; isRunning is
        // not.
        let flags = fcntl(readFD, F_GETFL, 0)
        _ = fcntl(readFD, F_SETFL, flags | O_NONBLOCK)

        var readBuffer = [UInt8](repeating: 0, count: 65536)
        // Returns true on EOF (read == 0).
        func readAvailable() -> Bool {
            while true {
                let n = readBuffer.withUnsafeMutableBytes { ptr -> Int in
                    read(readFD, ptr.baseAddress, ptr.count)
                }
                if n > 0 {
                    buf.append(contentsOf: readBuffer[0..<n])
                    drainLines(&buf, into: &captured, onProgress: onProgress)
                } else if n == 0 {
                    return true   // EOF — stream fully closed
                } else {
                    return false  // -1/EAGAIN — no more data right now
                }
            }
        }

        readLoop: while true {
            if isAborted() {
                aborted = true
                if p.isRunning { p.terminate() }
                break
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                timedOut = true
                if p.isRunning { p.terminate() }
                break
            }
            var readSet = fd_set()
            __darwin_fd_set(readFD, &readSet)
            var tv = timeval(tv_sec: 0, tv_usec: 0)
            let waitSecs = min(0.5, remaining)
            tv.tv_sec = Int(waitSecs)
            tv.tv_usec = __darwin_suseconds_t((waitSecs - Double(tv.tv_sec)) * 1_000_000)
            let sel = select(readFD + 1, &readSet, nil, nil, &tv)
            if sel > 0 {
                if readAvailable() { break readLoop }   // EOF → done
            }
            // sel == 0 (timeout slice) or sel < 0 (EINTR): just loop; the
            // deadline/abort checks at the top bound the wait.
        }
        p.waitUntilExit()

        // Flush trailing partial line (no terminator).
        if !buf.isEmpty {
            captured.append(String(decoding: buf, as: UTF8.self))
            buf.removeAll()
        }

        var output = captured.joined(separator: "\n")
        if timedOut {
            output += "\n[timed out after \(Int(timeout))s]"
            return GitResult(ok: false, output: output, timedOut: true, aborted: false)
        }
        if aborted {
            return GitResult(ok: false, output: output + "\n[aborted]", timedOut: false, aborted: true)
        }
        return GitResult(ok: p.terminationStatus == 0, output: output, timedOut: false, aborted: false)
    }

    // Pull complete lines out of buf, splitting on '\n' OR '\r' (git
    // --progress rewrites in place with '\r'). Port of _drain_lines.
    private static func drainLines(_ buf: inout Data, into captured: inout [String], onProgress: ProgressHandler?) {
        while true {
            guard let idx = buf.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return }
            let lineData = buf[buf.startIndex..<idx]
            buf.removeSubrange(buf.startIndex...idx)
            if lineData.isEmpty { continue }
            let line = String(decoding: lineData, as: UTF8.self)
            captured.append(line)
            if let onProgress, let (phase, pct) = GitProgress.parse(line) {
                onProgress(phase, pct)
            }
        }
    }
}

// Port of _GIT_PROGRESS_RE / _parse_git_progress.
enum GitProgress {
    // "Receiving objects:  45% (...)" or "remote: Compressing objects:  43% (...)"
    private static let phases: [(token: String, display: String)] = [
        ("Enumerating", "enumerating"),
        ("Counting", "counting"),
        ("Compressing", "compressing"),
        ("Receiving", "receiving"),
        ("Resolving", "resolving"),
        ("Updating", "updating"),
    ]

    // Faithful to _GIT_PROGRESS_RE:
    //   ^(?:remote:\s+)?(Enumerating|…|Updating)[^:]*:\s+(\d+)%
    private static let regex = try! NSRegularExpression(
        pattern: #"^(?:remote:\s+)?(Enumerating|Counting|Compressing|Receiving|Resolving|Updating)[^:]*:\s+(\d+)%"#
    )
    private static let displayFor: [String: String] =
        Dictionary(uniqueKeysWithValues: phases.map { ($0.token, $0.display) })

    static func parse(_ line: String) -> (String, Int)? {
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 3 else { return nil }
        let token = ns.substring(with: m.range(at: 1))
        guard let display = displayFor[token],
              let pct = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        return (display, pct)
    }
}
