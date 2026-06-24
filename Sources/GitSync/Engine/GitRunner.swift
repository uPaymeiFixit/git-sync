import Foundation
import Synchronization

// Runs `git` subprocesses for the sync engine. The behavior here is exact and
// load-bearing: a fixed env (LC_ALL=C, GIT_TERMINAL_PROMPT=0, GIT_SSH_COMMAND),
// combined stdout+stderr capture, line-splitting on '\n' OR '\r' (git
// --progress rewrites a line in place via carriage return),
// retry/backoff-with-jitter, and the rule that a TIMEOUT does not retry.
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
    // Blocking git call — returns (exitCode, output). Used for the cheap query
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

    private static func runOnce(_ args: [String], env: [String: String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe   // combined stdout+stderr
        do { try p.run() } catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            return (-1, "command not found: \(error.localizedDescription)")
        }
        // Reclaim the pipe FDs (the read-end close below is the load-bearing
        // one — see runStreamingOnce for the full FD-exhaustion → EBADF
        // rationale). The write-end close is a defensive no-op: Foundation
        // already closed the parent's copy on spawn.
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? pipe.fileHandleForReading.close()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // Streaming run with retry/backoff. `args` is the full git argv (e.g. ["-C", repo,
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
                // only burns time. Surface immediately, don't retry.
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
    // the child on timeout or abort.
    // `exe` defaults to git; tests inject a different program (e.g. /bin/sh)
    // to exercise the streaming loop's exit/EOF handling directly.
    static func runStreamingOnce(
        _ args: [String],
        env: [String: String],
        timeout: TimeInterval,
        isAborted: @escaping @Sendable () -> Bool,
        onProgress: ProgressHandler?,
        exe: String = gitPath
    ) -> GitResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        // Did the GIT child itself exit? This is the loop's real "done"
        // signal — NOT pipe EOF. With SSH ControlMaster (ControlPersist=120s)
        // the persistent master process inherits this pipe's write-end, so it
        // stays open after git exits and EOF NEVER arrives. Relying on EOF
        // alone parked every worker in select() until the 1800s timeout — the
        // "stuck at 'starting', 296 [timed out after 1800s]" wedge. We instead
        // check child-exit on every select timeout slice via this flag.
        // terminationHandler fires from Foundation's own child-monitoring queue
        // (not the caller's
        // runloop), so it's reliable on these runloop-less pool threads where
        // p.isRunning is not.
        let exited = Atomic<Bool>(false)
        p.terminationHandler = { _ in exited.store(true, ordering: .releasing) }

        do { try p.run() } catch {
            // run() failed — close both pipe ends so a spawn failure (e.g. FD
            // exhaustion) doesn't itself leak the two FDs we just allocated.
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            return GitResult(ok: false, output: "command not found: \(error.localizedDescription)",
                             timedOut: false, aborted: false)
        }

        // Close the pipe ends to reclaim FDs. The read-end close (defer) is the
        // load-bearing one: without it we leaked 1 FD/call, and against
        // launchd's 256 soft limit × thousands of repos that exhausted the
        // table → Process.run() failed with EBADF "Bad file descriptor" (the
        // 919-error storm). The write-end close is defensive: Foundation's
        // Process.run() already closes the parent's copy on spawn, so this is
        // an idempotent no-op on the happy path (NOT the EOF mechanism — that's
        // the `exited` flag above). The defer covers every return path.
        try? pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }

        let readFD = pipe.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var captured: [String] = []
        var buf = Data()
        var timedOut = false
        var aborted = false

        // Non-blocking fd + select() with a bounded slice. We end on EITHER pipe
        // EOF (read==0) OR the git child exiting (`exited` flag). EOF alone is
        // NOT sufficient: a persistent SSH ControlMaster keeps the pipe
        // write-end open long after git is gone, so we'd block forever. Process
        // exit is the authoritative signal.
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
            // If git has already exited, drain the rest and stop NOW — don't
            // enter another select slice. Checked at the TOP of each iteration
            // so a fast child that exits between slices doesn't cost us a full
            // slice of latency per call. (Real
            // clones stream output so this rarely fires mid-loop, but a
            // sub-100ms fetch on an up-to-date repo would otherwise pay a
            // slice.)
            if exited.load(ordering: .acquiring) {
                _ = readAvailable()
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
            // 0.1s slice: bounds how long we sleep past git's exit when it
            // happens DURING a select (the top-of-loop check catches exits
            // BETWEEN slices), and makes abort/timeout checks 10x/s. Negligible
            // CPU — select sleeps, it doesn't spin.
            let waitSecs = min(0.1, remaining)
            tv.tv_sec = Int(waitSecs)
            tv.tv_usec = __darwin_suseconds_t((waitSecs - Double(tv.tv_sec)) * 1_000_000)
            let sel = select(readFD + 1, &readSet, nil, nil, &tv)
            if sel > 0 {
                if readAvailable() { break readLoop }   // EOF → done
            } else if exited.load(ordering: .acquiring) {
                // sel == 0 (no data this slice) AND git has exited.
                // Drain whatever git flushed just before exiting, then stop —
                // do NOT wait for pipe EOF (a persistent ssh master may hold
                // the write-end open indefinitely).
                _ = readAvailable()
                break readLoop
            }
            // sel == 0 with git still running, or sel < 0 (EINTR): loop; the
            // deadline/abort/exit checks bound the wait.
        }
        // We left the loop because: git exited (EOF or `exited`), we hit the
        // deadline, or we were aborted. Reap before reading terminationStatus
        // — reading it on a live Process traps. We deliberately do NOT call
        // waitUntilExit() unconditionally: on these runloop-less pool threads
        // it can block when the pipe write-end is still held by a persistent
        // ssh master (the very bug we're fixing). Instead spin on the `exited`
        // flag (set by terminationHandler from Foundation's own dispatch
        // queue, runloop-independent), with a bounded fallback so a
        // pathological child can't wedge the worker. The handler fires within
        // ~1ms of FD close / SIGTERM, so the common EOF case spins once or
        // twice; the 10s ceiling only matters if the handler never fires, in
        // which case we degrade to a retryable soft failure below.
        let reapDeadline = Date().addingTimeInterval(10)
        while !exited.load(ordering: .acquiring) && Date() < reapDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let reaped = exited.load(ordering: .acquiring)

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
        // If we somehow couldn't confirm exit within the reap window, don't
        // touch terminationStatus (it would trap) — treat as a soft failure so
        // so the retry layer can decide. In practice `reaped` is always true here.
        guard reaped else {
            return GitResult(ok: false, output: output + "\n[exit not observed]",
                             timedOut: false, aborted: false)
        }
        return GitResult(ok: p.terminationStatus == 0, output: output, timedOut: false, aborted: false)
    }

    // Pull complete lines out of buf, splitting on '\n' OR '\r' (git
    // --progress rewrites in place with '\r').
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

// Parses git's --progress lines ("Receiving objects: 45% (...)") into a phase
// name + percentage for the live UI.
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
