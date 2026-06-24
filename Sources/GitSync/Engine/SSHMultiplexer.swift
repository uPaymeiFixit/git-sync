import Foundation

// Faithful port of the SSH ControlMaster machinery in scripts/_sync.py.
// This is NOT optional: prewarming N masters per host before the worker
// pool fans out takes a full run from ~40min to ~2min. Without prewarming,
// the first burst of parallel workers all race to open the master at once,
// which defeats multiplexing AND trips sshd's MaxStartups/MaxSessions
// limits — the 40-minute pathology.
//
// Each worker is assigned a stable shard for the life of its clone_or_update
// so retries hit the already-authenticated master. The GIT_SSH_COMMAND the
// worker uses carries that shard's ControlPath.

struct SSHMultiplexer: Sendable {
    let enabled: Bool
    let parallel: Int
    let controlDir: URL          // per-process socket dir, e.g. /tmp/git-sync-cm-<uid>-<pid>
    let mastersPerHost: Int

    // Mirrors _SSH_TIMEOUT_OPTS.
    static let timeoutOpts = "-o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"

    init(parallel: Int, pid: Int32, uid: UInt32, enabled: Bool = true) {
        self.enabled = enabled
        self.parallel = max(1, parallel)
        self.controlDir = URL(fileURLWithPath: "/tmp/git-sync-cm-\(uid)-\(pid)")
        // ceil(PARALLEL/8), like MASTERS_PER_HOST. ~8 channels per master at
        // peak leaves headroom under sshd's MaxSessions=10.
        self.mastersPerHost = enabled ? max(1, Int((Double(self.parallel) / 8.0).rounded(.up))) : 1
    }

    // Stable shard for a repo path → the master that retries reuse. Port of
    // _shard_for. Uses a stable FNV-1a hash (Swift's Hasher is seeded per
    // process and would still be stable within a run, but FNV keeps it
    // deterministic and dependency-free).
    func shard(for rel: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in rel.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(mastersPerHost))
    }

    // ControlPath for a shard. Port of _control_path: collapse the s<N>-
    // prefix when there's only one master so layouts are easy to eyeball.
    func controlPath(shard: Int) -> String {
        if mastersPerHost <= 1 { return "\(controlDir.path)/%C" }
        return "\(controlDir.path)/s\(shard)-%C"
    }

    // The GIT_SSH_COMMAND a worker uses. Port of _ssh_command for a fixed
    // shard (the engine pins each worker to its shard, rather than the
    // Python's thread-local).
    func sshCommand(shard: Int) -> String {
        var parts = ["ssh", Self.timeoutOpts]
        if enabled {
            parts.append("-o ControlMaster=auto -o ControlPath=\(controlPath(shard: shard)) -o ControlPersist=120s")
        }
        return parts.joined(separator: " ")
    }

    // Pull the set of user@host pairs out of the job SSH URLs. Port of
    // _unique_ssh_hosts. Matches scp-style "user@host:path".
    static func uniqueHosts(_ sshURLs: [String]) -> Set<String> {
        var hosts = Set<String>()
        let re = try! NSRegularExpression(pattern: #"^(?:([^@:/]+)@)?([^:/]+):"#)
        for url in sshURLs {
            let ns = url as NSString
            guard let m = re.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)) else { continue }
            let userRange = m.range(at: 1)
            let user = userRange.location == NSNotFound ? "git" : ns.substring(with: userRange)
            let host = ns.substring(with: m.range(at: 2))
            hosts.insert("\(user)@\(host)")
        }
        return hosts
    }

    // Prewarm MASTERS_PER_HOST connections for each host, in parallel,
    // BEFORE the worker pool fires. Port of prewarm_ssh_masters. Returns the
    // (host, shard) pairs actually attempted so cleanup can close them.
    @discardableResult
    func prewarm(hosts: Set<String>) -> [(host: String, shard: Int)] {
        guard enabled, !hosts.isEmpty else { return [] }
        try? FileManager.default.createDirectory(
            at: controlDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let pairs = hosts.flatMap { h in (0..<mastersPerHost).map { (host: h, shard: $0) } }
        guard !pairs.isEmpty else { return [] }

        // Parallel prewarm — serially this is ~1s per (host,shard).
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ssh-prewarm", attributes: .concurrent)
        let sem = DispatchSemaphore(value: min(pairs.count, 16))
        for pair in pairs {
            group.enter()
            sem.wait()
            queue.async {
                defer { sem.signal(); group.leave() }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = [
                    "-o", "BatchMode=yes",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=\(self.controlPath(shard: pair.shard))",
                    "-o", "ControlPersist=120s",
                    "-o", "ConnectTimeout=15",
                    pair.host, "true",
                ]
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                // Best-effort: workers still try directly if this fails.
                try? p.run()
                // Bound the wait so a hung host can't stall startup forever.
                let deadline = DispatchTime.now() + 30
                let waiter = DispatchQueue.global()
                let done = DispatchSemaphore(value: 0)
                waiter.async { p.waitUntilExit(); done.signal() }
                if done.wait(timeout: deadline) == .timedOut, p.isRunning {
                    p.terminate()
                }
            }
        }
        group.wait()
        return pairs
    }

    // Close every master we opened and remove the socket dir. Port of
    // _cleanup_ssh_masters. Without this the master ssh processes linger
    // until ControlPersist (120s) expires.
    func cleanup(pairs: [(host: String, shard: Int)]) {
        guard enabled else { return }
        for pair in pairs {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-O", "exit", "-o", "ControlPath=\(controlPath(shard: pair.shard))", pair.host]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { continue }
            // Bound the wait (Python uses timeout=5): a wedged control socket
            // must not stall run completion, since cleanup runs in a defer on
            // the run-finish path.
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
            if done.wait(timeout: .now() + 5) == .timedOut, p.isRunning {
                p.terminate()
            }
        }
        try? FileManager.default.removeItem(at: controlDir)
    }
}
