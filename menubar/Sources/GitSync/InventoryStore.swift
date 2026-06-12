import Foundation
import SwiftUI

// Persistent inventory of every repo GitSync knows about, indexed by
// (platform, rel). Survives across runs and across app restarts.
//
// State sources:
// - `remote_project` events during discovery: tell us "this repo exists
//   on the remote." First time we see one, we create a Repo row.
// - `outcome` events during sync: tell us "this repo's last sync ended
//   with status X." Updates an existing row or creates one.
// - Disk walk at launch (`seedFromDisk`): finds .git directories under
//   GIT_SYNC_ROOT so the inventory isn't empty before the first run.
// - History replay (`seedFromHistory`): iterates persisted run records
//   newest-first and fills in `lastStatus` for any row not yet touched.
//
// Persistence: a single JSON file at
// ~/Library/Application Support/GitSync/inventory.json. Saved on every
// mutation with a 1s debounce, plus a synchronous flush at app quit.

@MainActor
final class InventoryStore: ObservableObject {
    @Published private(set) var repos: [RepoID: Repo] = [:]

    private let storageURL: URL
    private var saveDebounceTimer: Timer?

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport.appendingPathComponent("GitSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("inventory.json")
        loadFromDisk()
    }

    // ---- Event ingestion ---------------------------------------------

    func apply(remoteProject platform: String, rel: String, sshURL: String, defaultBranch: String) {
        let id = RepoID(platform: platform, rel: rel)
        var repo = repos[id] ?? Repo(id: id)
        repo.sshURL = sshURL
        if !defaultBranch.isEmpty {
            repo.defaultBranch = defaultBranch
        }
        repo.lastSeenRemoteAt = Date()
        repos[id] = repo
        scheduleSave()
    }

    func apply(outcome: Outcome) {
        // Outcome carries platform now (see Outcome.platform). If empty
        // (very old fixture data), we can't key it — drop.
        guard !outcome.platform.isEmpty else { return }
        let id = RepoID(platform: outcome.platform, rel: outcome.rel)
        var repo = repos[id] ?? Repo(id: id)
        if !outcome.url.isEmpty {
            repo.sshURL = outcome.url
        }
        repo.lastStatus = outcome.status
        repo.lastDetail = outcome.detail
        repo.lastOldSha = outcome.oldSha
        repo.lastNewSha = outcome.newSha
        repo.lastCommitsAhead = outcome.commitsAhead
        repo.lastUpdatedAt = Date()
        // Any non-stale, non-skipped status implies we have it locally.
        switch outcome.status {
        case .cloned, .updated, .updatedDirty, .upToDate, .emptyRemote,
             .dirty, .diverged, .branchMissing:
            repo.isClonedLocally = true
        case .staleOnDisk, .nonGitDir, .skipped, .error, .notClonedYet,
             .notSyncedYet:
            break
        }
        repos[id] = repo
        scheduleSave()
    }

    // ---- Local-delete bookkeeping -------------------------------------

    // The repo's local clone was trashed and the remote doesn't know it
    // either — drop the row entirely.
    func remove(_ id: RepoID) {
        guard repos[id] != nil else { return }
        repos[id] = nil
        scheduleSave()
    }

    // The repo's local clone was trashed but the remote still lists it —
    // it reverts to a plain "not cloned yet" row.
    func markNotCloned(_ id: RepoID) {
        guard var repo = repos[id] else { return }
        repo.isClonedLocally = false
        repo.lastStatus = nil
        repo.lastDetail = ""
        repo.lastOldSha = ""
        repo.lastNewSha = ""
        repo.lastCommitsAhead = 0
        repo.lastClonedCheckedAt = Date()
        repos[id] = repo
        scheduleSave()
    }

    // ---- Seeding (launch-time fill) ----------------------------------

    // Walk GIT_SYNC_ROOT looking for .git directories. Each one becomes
    // a Repo with isClonedLocally = true. Doesn't touch ones we already
    // know about (preserves any remote-side fields from a prior session).
    func seedFromDisk(syncRoot: URL) async {
        let found: [(platform: String, rel: String)] = await Task.detached(priority: .utility) {
            findClonedRepos(under: syncRoot)
        }.value
        let now = Date()
        for entry in found {
            let id = RepoID(platform: entry.platform, rel: entry.rel)
            var repo = repos[id] ?? Repo(id: id)
            repo.isClonedLocally = true
            repo.lastClonedCheckedAt = now
            repos[id] = repo
        }
        if !found.isEmpty { scheduleSave() }
    }

    // Iterate history newest-first, applying any outcome whose repo
    // doesn't already have a `lastStatus`. This gives the inventory a
    // reasonable initial state even if no sync has run since the app
    // gained inventory support.
    func seedFromHistory(_ history: HistoryStore) {
        for run in history.runs {
            for outcome in run.outcomes where !outcome.platform.isEmpty {
                let id = RepoID(platform: outcome.platform, rel: outcome.rel)
                if repos[id]?.lastStatus != nil { continue }
                apply(outcome: outcome)
            }
        }
    }

    // ---- Persistence -------------------------------------------------

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let stored = try? decoder.decode([Repo].self, from: data) {
            for repo in stored { repos[repo.id] = repo }
        }
        migrateLegacyKeys()
    }

    // The canonical rel format matches the Python's _rel(): relative to
    // GIT_SYNC_ROOT, INCLUDING the platform directory ("Gitlab/foo/bar").
    // An early version of the disk walk produced platform-root-relative
    // rels ("foo/bar"), creating orphan duplicates that never matched
    // incoming outcomes and showed as eternally not-cloned-yet. Re-key
    // those and merge into the canonical entry.
    private func migrateLegacyKeys() {
        var migrated: [RepoID: Repo] = [:]
        var changed = false
        for (id, repo) in repos {
            let canonical = RepoID(
                platform: id.platform,
                rel: Self.canonicalRel(platform: id.platform, rel: id.rel)
            )
            if canonical != id { changed = true }
            if let existing = migrated[canonical] {
                migrated[canonical] = Self.merge(existing, repo.reKeyed(to: canonical))
            } else {
                migrated[canonical] = repo.reKeyed(to: canonical)
            }
        }
        if changed {
            repos = migrated
            saveNow()
        }
    }

    static func canonicalRel(platform: String, rel: String) -> String {
        let prefix: String
        switch platform {
        case "gitlab":    prefix = "Gitlab/"
        case "github":    prefix = "Github/"
        case "bitbucket": prefix = "Bitbucket/"
        default:          return rel
        }
        return rel.hasPrefix(prefix) ? rel : prefix + rel
    }

    // Merge two records for the same repo: prefer whichever has actual
    // sync data; union the booleans; keep the latest timestamps and any
    // non-empty remote-side fields.
    private static func merge(_ a: Repo, _ b: Repo) -> Repo {
        let (primary, secondary) = (a.lastStatus == nil && b.lastStatus != nil) ? (b, a) : (a, b)
        var base = primary
        base.isClonedLocally = a.isClonedLocally || b.isClonedLocally
        if base.sshURL.isEmpty { base.sshURL = secondary.sshURL }
        if base.defaultBranch.isEmpty { base.defaultBranch = secondary.defaultBranch }
        base.lastSeenRemoteAt = maxDate(a.lastSeenRemoteAt, b.lastSeenRemoteAt)
        base.lastClonedCheckedAt = maxDate(a.lastClonedCheckedAt, b.lastClonedCheckedAt)
        return base
    }

    private static func maxDate(_ x: Date?, _ y: Date?) -> Date? {
        switch (x, y) {
        case (nil, nil):            return nil
        case (let d?, nil):         return d
        case (nil, let d?):         return d
        case (let d1?, let d2?):    return max(d1, d2)
        }
    }

    private func scheduleSave() {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.saveNow() }
        }
    }

    func saveNow() {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let snapshot = Array(repos.values)
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}

// MARK: - Disk walk helper

// Returns (platform, rel) pairs for every .git directory under syncRoot.
// Bounded depth: looks for repos like syncRoot/<Platform>/<a>/<b>/.../.git,
// stops descending into a directory once a .git is found inside it.
// Tolerant of missing platform subdirectories.
private nonisolated func findClonedRepos(under syncRoot: URL) -> [(platform: String, rel: String)] {
    var out: [(platform: String, rel: String)] = []
    let fm = FileManager.default
    // Platform subdirectories are capitalized (Bitbucket/, Gitlab/, Github/)
    // per scripts/_sync.py:PLATFORM_ROOT conventions. We lower-case the
    // platform when storing.
    let platformNames = ["Gitlab": "gitlab", "Github": "github", "Bitbucket": "bitbucket"]
    for (dirName, platform) in platformNames {
        let platformRoot = syncRoot.appendingPathComponent(dirName, isDirectory: true)
        guard fm.fileExists(atPath: platformRoot.path) else { continue }
        guard let enumerator = fm.enumerator(
            at: platformRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { continue }

        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let gitDir = url.appendingPathComponent(".git")
            if fm.fileExists(atPath: gitDir.path) {
                // Canonical rel format: relative to syncRoot INCLUDING the
                // platform directory ("Gitlab/foo/bar"), matching the
                // Python's _rel() so disk-seeded entries share identity
                // with event-driven ones.
                let sub = url.path.dropFirst(platformRoot.path.count + 1)
                out.append((platform: platform, rel: "\(dirName)/\(sub)"))
                enumerator.skipDescendants()
            }
        }
    }
    return out
}
