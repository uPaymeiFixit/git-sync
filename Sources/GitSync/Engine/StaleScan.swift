import Foundation

// Port of scripts/_sync.py discover_extras — a single-pass walk of a
// platform root that finds:
//   - stale-on-disk: a git repo whose path isn't in the expected set
//   - non-git-dir:  a subtree with NO .git anywhere, reported at the
//                   TOPMOST offending directory only
// Each on-disk directory is visited exactly once.
//
// Only run when discovery was COMPLETE and we synced the full set — a
// partial listing (or an --only subset) would flag every un-enumerated
// repo as deleted. The engine gates this exactly like finish_run does.

enum StaleScan {
    // `expected` is the set of dest paths we expect to exist (synced + skipped).
    // Returns outcomes for stale/non-git dirs. `rel` maps a dir to its
    // sync-root-relative path.
    // `staleStatus` is what an on-disk git repo NOT in `expected` is labelled.
    // Normally .staleOnDisk (an anomaly: "remote dropped it"). In whitelist
    // (trackedOnly) mode the engine passes .untracked instead, because an
    // on-disk repo the user simply hasn't tracked isn't an anomaly.
    static func discoverExtras(
        platformRoot: URL,
        platform: String,
        expected: Set<String>,          // standardized paths
        rel: (URL) -> String,
        staleStatus: SyncStatus = .staleOnDisk
    ) -> [Outcome] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: platformRoot.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        // Returns (hasRepoInSubtree, outcomesToEmit). When hasRepo is false
        // the caller collapses to a single non-git-dir for the parent.
        func walk(_ dir: URL) -> (Bool, [Outcome]) {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path, isDirectory: &isDir), isDir.boolValue {
                var oc: [Outcome] = []
                if !expected.contains(dir.standardizedFileURL.path) {
                    oc.append(Outcome(platform: platform, rel: rel(dir), status: staleStatus))
                }
                return (true, oc)
            }
            let children = childDirs(dir, fm: fm)
            var hasRepo = false
            var repoBranch: [Outcome] = []
            var nonGitSubtree: [Outcome] = []
            for child in children {
                let (childHasRepo, childOC) = walk(child)
                if childHasRepo { hasRepo = true; repoBranch.append(contentsOf: childOC) }
                else { nonGitSubtree.append(contentsOf: childOC) }
            }
            if hasRepo {
                return (true, repoBranch + nonGitSubtree)
            }
            // No repos anywhere — collapse to one non-git-dir for this dir.
            return (false, [Outcome(platform: platform, rel: rel(dir), status: .nonGitDir)])
        }

        var results: [Outcome] = []
        for child in childDirs(platformRoot, fm: fm) {
            let (_, oc) = walk(child)
            results.append(contentsOf: oc)
        }
        return results
    }

    // Sorted immediate subdirectories, excluding symlinks and .git. Mirrors
    // the Python's `sorted(p for p in dir.iterdir() if p.is_dir() and not
    // p.is_symlink() and p.name != ".git")`.
    private static func childDirs(_ dir: URL, fm: FileManager) -> [URL] {
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []) else { return [] }
        return entries.filter { url in
            guard url.lastPathComponent != ".git" else { return false }
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return (vals?.isDirectory ?? false) && !(vals?.isSymbolicLink ?? false)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
