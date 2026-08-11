import Foundation

// The data-safety-critical clone-or-update decision tree. DO NOT "improve" the
// branch logic casually — a wrong branch can clobber a user's uncommitted work;
// the rules for when it's safe to fetch/fast-forward vs. report dirty/diverged
// are exact and deliberate.
//
// This is a pure, synchronous function over GitContext so it's trivially
// testable. The engine calls it from a worker task; concurrency, SSH
// multiplexing, and progress reporting live in the caller via the context.

struct GitContext: Sendable {
    var syncRoot: URL
    var depth: Int                       // 0 = full history (omit --depth)
    var timeout: TimeInterval
    // Builds the env for a git child. The engine injects GIT_SSH_COMMAND
    // (with the per-repo ControlMaster shard) here.
    var makeEnv: @Sendable () -> [String: String]
    var isAborted: @Sendable () -> Bool = { false }
    var onProgress: ProgressHandler? = nil

    func depthArgs() -> [String] { depth > 0 ? ["--depth", String(depth)] : [] }
}

// Matches Outcome (Models/Outcome.swift) but built engine-side. We return
// the existing Outcome type so it flows into InventoryStore unchanged.

enum RepoSyncer {
    // Regex equivalents of _NO_MATCHING_HEAD_RE / _BRANCH_MISSING_RE.
    private static func noMatchingHead(_ s: String) -> Bool {
        s.range(of: "no matching remote head", options: .caseInsensitive) != nil
    }
    private static func branchMissing(_ s: String) -> Bool {
        s.range(of: "Remote branch .* not found in upstream origin", options: .regularExpression) != nil
    }

    private static let staleLockNames = ["shallow.lock", "index.lock", "packed-refs.lock"]
    private static let staleLockAgeSecs: TimeInterval = 30

    // The entry point. `platform` and `rel` identify the repo; `dest` is the
    // on-disk path. Returns exactly one Outcome per repo.
    static func cloneOrUpdate(
        platform: String,
        rel: String,
        sshURL: String,
        dest: URL,
        branch: String,
        ctx: GitContext
    ) -> Outcome {
        if ctx.isAborted() {
            return Outcome(platform: platform, rel: rel, status: .error, url: sshURL, detail: "aborted")
        }
        let fm = FileManager.default
        let isExistingClone = fm.fileExists(atPath: dest.appendingPathComponent(".git").path)
        if isExistingClone {
            return update(platform: platform, rel: rel, sshURL: sshURL, dest: dest, branch: branch, ctx: ctx)
        }
        return clone(platform: platform, rel: rel, sshURL: sshURL, dest: dest, branch: branch, ctx: ctx)
    }

    // ---- UPDATE path (dest/.git exists) ----
    private static func update(
        platform: String, rel: String, sshURL: String, dest: URL, branch: String, ctx: GitContext
    ) -> Outcome {
        let path = dest.path
        func out(_ s: SyncStatus, _ detail: String = "", old: String = "", new: String = "", ahead: Int = 0) -> Outcome {
            Outcome(platform: platform, rel: rel, status: s, url: sshURL, detail: detail,
                    oldSha: old, newSha: new, commitsAhead: ahead)
        }

        cleanStaleLocks(dest)
        let oldSha = headSHA(path, ctx)
        let wasEmpty = !hasAnyRef(path, ctx)

        let fetch = GitRunner.runStreamingWithRetry(
            ["-C", path, "fetch", "--progress"] + ctx.depthArgs() + ["--prune", "origin"],
            env: ctx.makeEnv(),
            attempts: wasEmpty ? 1 : 3,
            timeout: ctx.timeout,
            isAborted: ctx.isAborted,
            onProgress: ctx.onProgress
        )
        if !fetch.ok {
            if fetch.aborted { return out(.error, "aborted") }
            // Empty-remote detection, transport-independent: cheap fast-path
            // (empty output + empty local) OR no-matching-head text OR
            // ls-remote confirms zero refs.
            let remoteEmpty = (fetch.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAnyRef(path, ctx))
                || noMatchingHead(fetch.output)
                || remoteHasNoRefs(path, ctx)
            if remoteEmpty {
                if hasAnyRef(path, ctx) {
                    return out(.diverged, "local has commits; remote is empty")
                }
                return out(.upToDate, "empty repository (no commits yet)")
            }
            return out(.error, tail(fetch.output))
        }

        // Fetch OK. Remote totally empty vs has refs but not our branch.
        if !hasRemoteRef(path, branch, ctx) {
            if hasAnyRef(path, ctx) {
                return out(.branchMissing, "remote has no '\(branch)'")
            }
            return out(.upToDate, "empty repository (no commits yet)")
        }

        let wasDirty = isDirty(path, ctx)

        let curBranch = currentBranch(path, ctx)
        if curBranch != branch {
            let ahead = curBranch.isEmpty ? 0 : countCommitsBetween(path, "origin/\(branch)", "HEAD", ctx)
            return out(.diverged, "local on '\(curBranch.isEmpty ? "detached HEAD" : curBranch)', not '\(branch)'", ahead: ahead)
        }

        let ff = GitRunner.runStreamingWithRetry(
            ["-C", path, "merge", "--ff-only", "origin/\(branch)"],
            env: ctx.makeEnv(),
            attempts: 1,
            timeout: ctx.timeout,
            isAborted: ctx.isAborted
        )
        if !ff.ok {
            if ff.aborted { return out(.error, "aborted") }
            if wasDirty {
                return out(.dirty, "uncommitted changes blocked fast-forward")
            }
            let ahead = countCommitsBetween(path, "origin/\(branch)", "HEAD", ctx)
            return out(.diverged, "local '\(branch)' has commits not on origin/\(branch)", ahead: ahead)
        }

        let newSha = headSHA(path, ctx)
        if newSha == oldSha {
            if wasDirty { return out(.dirty, "up-to-date with uncommitted changes") }
            return out(.upToDate)
        }
        let n = countCommitsBetween(path, oldSha, newSha, ctx)
        let status: SyncStatus = wasDirty ? .updatedDirty : .updated
        return out(status, old: String(oldSha.prefix(7)), new: String(newSha.prefix(7)), ahead: n)
    }

    // ---- CLONE path (dest/.git does not exist) ----
    private static func clone(
        platform: String, rel: String, sshURL: String, dest: URL, branch: String, ctx: GitContext
    ) -> Outcome {
        let fm = FileManager.default
        func out(_ s: SyncStatus, _ detail: String = "") -> Outcome {
            Outcome(platform: platform, rel: rel, status: s, url: sshURL, detail: detail)
        }

        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        let destExistedBefore = fm.fileExists(atPath: dest.path)
        let syncRootForCleanup = ctx.syncRoot
        let cleanupPartial: @Sendable () -> Void = {
            // Only remove what WE created, and only if safely under the root.
            // Use FileManager.default inside (FileManager isn't Sendable, so
            // we can't capture the outer `fm` in this @Sendable closure).
            if destExistedBefore { return }
            guard safeUnderRoot(dest, syncRootForCleanup) else { return }
            let m = FileManager.default
            if m.fileExists(atPath: dest.path) { try? m.removeItem(at: dest) }
        }

        let first = GitRunner.runStreamingWithRetry(
            ["clone", "--progress"] + ctx.depthArgs() + ["--no-single-branch", "--branch", branch, sshURL, dest.path],
            env: ctx.makeEnv(),
            attempts: 3,
            timeout: ctx.timeout,
            isAborted: ctx.isAborted,
            onRetry: cleanupPartial,
            onProgress: ctx.onProgress
        )
        if first.ok { return out(.cloned) }
        if first.aborted { return out(.error, "aborted") }

        // Branch-pinned clone failed for no-usable-HEAD or missing-branch:
        // retry unpinned. Empty repo clones fine without -b (valid .git,
        // zero refs); a different real default branch clones its actual HEAD.
        if noMatchingHead(first.output) || branchMissing(first.output) {
            if !safeUnderRoot(dest, ctx.syncRoot) {
                return out(.error, "dest outside SYNC_ROOT")
            }
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            let second = GitRunner.runStreamingWithRetry(
                ["clone", "--progress"] + ctx.depthArgs() + ["--no-single-branch", sshURL, dest.path],
                env: ctx.makeEnv(),
                attempts: 3,
                timeout: ctx.timeout,
                isAborted: ctx.isAborted,
                onRetry: cleanupPartial,
                onProgress: ctx.onProgress
            )
            if second.ok {
                if hasAnyRef(dest.path, ctx) {
                    return out(.cloned, "default branch differs from API")
                }
                return out(.cloned, "empty repository (no commits yet)")
            }
            if second.aborted { return out(.error, "aborted") }
            if noMatchingHead(second.output) {
                return out(.emptyRemote)   // legacy server-quirk path
            }
            return out(.error, tail(second.output))
        }

        return out(.error, tail(first.output))
    }

    // ---- git plumbing (ports of the _git helpers) ----

    private static func headSHA(_ path: String, _ ctx: GitContext) -> String {
        let r = GitRunner.git(path, "rev-parse", "HEAD", env: ctx.makeEnv())
        return r.code == 0 ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
    private static func hasAnyRef(_ path: String, _ ctx: GitContext) -> Bool {
        GitRunner.git(path, "show-ref", env: ctx.makeEnv()).code == 0
    }
    private static func hasRemoteRef(_ path: String, _ branch: String, _ ctx: GitContext) -> Bool {
        GitRunner.git(path, "rev-parse", "--verify", "refs/remotes/origin/\(branch)", env: ctx.makeEnv()).code == 0
    }
    private static func remoteHasNoRefs(_ path: String, _ ctx: GitContext) -> Bool {
        // The only NETWORK query outside clone/fetch, so it uses the STREAMING
        // runner rather than the read-to-EOF one-shot (GitRunner.git). That
        // one-shot has no deadline and no abort check of its own: it was safe
        // here only because GIT_SSH_COMMAND happens to carry ConnectTimeout,
        // which is a ceiling set in another file that nothing here enforces.
        // Streaming brings its own timeout, stall deadline, and abort check, so
        // this can no longer outlive a cancelled run.
        //
        // attempts: 1 — this is a yes/no probe on a fetch that ALREADY failed.
        // Retrying would just re-pay the timeout to learn the same thing.
        //
        // Using the streaming runner is also why no ControlMaster=no override is
        // needed. The one-shot reads to EOF, and an ssh master holds the pipe's
        // write-end open for ControlPersist seconds after the git child exits,
        // which blocked that read forever. The streaming reader ends on the
        // CHILD'S EXIT instead (runStreamingOnce's `exited` flag, guarded by
        // --stream-eof-test), so the master can stay alive — which is also the
        // 40min→2min multiplexing win the fetch path depends on.
        let r = GitRunner.runStreamingWithRetry(
            ["-C", path, "ls-remote", "--quiet", "origin"],
            env: ctx.makeEnv(),
            attempts: 1,
            timeout: ctx.timeout,
            isAborted: ctx.isAborted
        )
        return r.ok && r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private static func isDirty(_ path: String, _ ctx: GitContext) -> Bool {
        let env = ctx.makeEnv()
        let r = GitRunner.git(path, "status", "--porcelain", env: env)
        guard r.code == 0 else { return false }
        if r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }

        // Non-empty status. Before trusting it, refresh the stat cache and
        // re-check, to rule out a "racy index" false positive (a tracked file
        // whose mtime can't disambiguate it from the index — e.g. just written
        // by the fetch we ran moments ago — gets reported as possibly-modified
        // by the stat-only check, then clears on the next status). This is what
        // a second `git status` does on its own. `update-index --refresh` exits
        // non-zero when it finds real modifications, so we can't gate on its
        // exit code — re-run porcelain as the authority.
        //
        // NOTE: the original "14 GitHub repos always dirty" report was NOT this
        // — it was untracked .DS_Store files the git children couldn't ignore
        // because they ran with no HOME (so ~/.config/git/ignore was invisible).
        // That's fixed at the source in SettingsStore.currentSyncSettings (the
        // env now inherits HOME). This refresh stays as cheap defense for the
        // genuine racy-stat case.
        _ = GitRunner.git(path, "update-index", "-q", "--refresh", env: env)
        let r2 = GitRunner.git(path, "status", "--porcelain", env: env)
        guard r2.code == 0 else { return false }
        return !r2.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private static func currentBranch(_ path: String, _ ctx: GitContext) -> String {
        let r = GitRunner.git(path, "symbolic-ref", "--quiet", "--short", "HEAD", env: ctx.makeEnv())
        return r.code == 0 ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
    private static func countCommitsBetween(_ path: String, _ base: String, _ tip: String, _ ctx: GitContext) -> Int {
        let r = GitRunner.git(path, "rev-list", "--count", "\(base)..\(tip)", env: ctx.makeEnv())
        guard r.code == 0 else { return 0 }
        return Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func cleanStaleLocks(_ dest: URL) {
        let gitDir = dest.appendingPathComponent(".git")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitDir.path, isDirectory: &isDir), isDir.boolValue else { return }
        let now = Date()
        for name in staleLockNames {
            let lock = gitDir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: lock.path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(mtime) < staleLockAgeSecs { continue }
            try? fm.removeItem(at: lock)
        }
    }

    private static func safeUnderRoot(_ dest: URL, _ root: URL) -> Bool {
        // dest may not exist yet (clone path), so resolvingSymlinksInPath on
        // it is unreliable. Resolve the deepest EXISTING ancestor for symlink
        // safety, then re-append the non-existent tail, and check containment.
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        let d = resolvedExistingPrefix(dest).path
        return d == r || d.hasPrefix(r + "/")
    }

    // Resolve symlinks on the deepest existing ancestor of `url`, then append
    // the remaining (non-existent) path components.
    private static func resolvedExistingPrefix(_ url: URL) -> URL {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !fm.fileExists(atPath: existing.path) {
            tail.insert(existing.lastPathComponent, at: 0)
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }  // reached root
            existing = parent
        }
        var resolved = existing.resolvingSymlinksInPath()
        for comp in tail { resolved.appendPathComponent(comp) }
        return resolved.standardizedFileURL
    }

    private static func tail(_ s: String, _ n: Int = 20) -> String {
        // Split on both \n and \r (captured output is \n-joined, but split on
        // both so a residual \r can't merge lines).
        let lines = s.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }
        return lines.suffix(n).joined(separator: "\n")
    }
}
