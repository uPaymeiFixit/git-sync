import Foundation

// Moves local repo directories to the Trash, with the same pre-flight
// safety checks we'd do by hand before deleting a clone:
//   1. `git status --porcelain` — any output means uncommitted changes
//   2. `git for-each-ref '%(upstream:track)' refs/heads` — "[ahead N]"
//      means commits that were never pushed
// Repos failing either check are skipped with a reason instead of
// trashed. Everything that does get removed goes to the macOS Trash
// (FileManager.trashItem), so even a mistake is recoverable.
//
// Known limitation, accepted for v1: a local branch with NO upstream at
// all reports no "[ahead]" marker, so purely-local branches don't block
// deletion. The Trash is the backstop for that case.

struct TrashReport: Sendable {
    var trashed: [RepoID] = []
    var skipped: [(id: RepoID, reason: String)] = []

    var summary: String {
        var lines: [String] = []
        lines.append("Moved \(trashed.count) repo(s) to Trash.")
        if !skipped.isEmpty {
            lines.append("")
            lines.append("Skipped \(skipped.count):")
            for entry in skipped.prefix(12) {
                lines.append("• \(entry.id.rel) — \(entry.reason)")
            }
            if skipped.count > 12 {
                lines.append("…and \(skipped.count - 12) more.")
            }
        }
        return lines.joined(separator: "\n")
    }
}

enum RepoTrasher {
    // Runs off the caller's actor; sequential per repo (deletes are rare
    // and small batches; git status is ~20ms each).
    // `resolve` maps each RepoID to its absolute on-disk path (provider.localPath
    // + provider-local rel). `allowedRoots` are the provider folders a target
    // must live under — defense-in-depth so a malformed rel can never escape a
    // configured provider folder and trash something unrelated.
    static func trash(ids: [RepoID],
                      resolve: @escaping @Sendable (RepoID) -> URL?,
                      allowedRoots: [URL]) async -> TrashReport {
        await Task.detached(priority: .userInitiated) {
            trashSync(ids: ids, resolve: resolve, allowedRoots: allowedRoots)
        }.value
    }

    private static func trashSync(ids: [RepoID],
                                  resolve: (RepoID) -> URL?,
                                  allowedRoots: [URL]) -> TrashReport {
        var report = TrashReport()
        let fm = FileManager.default
        let rootPaths = allowedRoots.map { $0.standardizedFileURL.path }

        for id in ids {
            guard let target = resolve(id)?.standardizedFileURL else {
                report.skipped.append((id, "no provider folder for this repo"))
                continue
            }

            // Defense in depth: the target must live under one of the
            // configured provider folders, even if a malformed rel sneaks in.
            guard rootPaths.contains(where: { target.path.hasPrefix($0 + "/") }) else {
                report.skipped.append((id, "path escapes provider folder"))
                continue
            }
            guard fm.fileExists(atPath: target.path) else {
                report.skipped.append((id, "not on disk"))
                continue
            }

            // Safety checks only apply to git repos; a non-git dir has no
            // git state to lose and the Trash is the backstop.
            if fm.fileExists(atPath: target.appendingPathComponent(".git").path) {
                if let dirty = isDirty(target.path) {
                    if dirty {
                        report.skipped.append((id, "uncommitted changes"))
                        continue
                    }
                } else {
                    report.skipped.append((id, "git status failed — not touching it"))
                    continue
                }
                if let unpushed = hasUnpushedCommits(target.path) {
                    if unpushed {
                        report.skipped.append((id, "unpushed commits"))
                        continue
                    }
                } else {
                    report.skipped.append((id, "git ref check failed — not touching it"))
                    continue
                }
            }

            do {
                try fm.trashItem(at: target, resultingItemURL: nil)
                report.trashed.append(id)
            } catch {
                report.skipped.append((id, "trash failed: \(error.localizedDescription)"))
            }
        }
        return report
    }

    // nil = the git invocation itself failed (treat as unsafe).
    private static func isDirty(_ repoPath: String) -> Bool? {
        guard let out = runGit(["-C", repoPath, "status", "--porcelain"]) else { return nil }
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasUnpushedCommits(_ repoPath: String) -> Bool? {
        guard let out = runGit([
            "-C", repoPath,
            "for-each-ref", "--format=%(refname:short) %(upstream:track)", "refs/heads",
        ]) else { return nil }
        return out.contains("[ahead")
    }

    private static func runGit(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            return nil
        }
        // Reclaim the pipe FDs (see GitRunner for the FD-exhaustion rationale).
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? pipe.fileHandleForReading.close()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
