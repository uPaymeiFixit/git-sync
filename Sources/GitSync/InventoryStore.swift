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
    private let backupURL: URL
    private var saveDebounceTimer: Timer?
    // The provider list, for resolving a legacy {platform, "Gitlab/foo"} row to
    // its owning provider during migration and for the disk walk.
    private let providersAtLaunch: [Provider]

    init(providers: [Provider]) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport.appendingPathComponent("GitSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("inventory.json")
        self.backupURL = dir.appendingPathComponent("inventory.json.bak")
        self.providersAtLaunch = providers
        loadFromDisk()
    }

    // ---- Event ingestion ---------------------------------------------

    func apply(remoteProject providerID: String, platform: String, rel: String, sshURL: String, defaultBranch: String) {
        let id = RepoID(providerID: providerID, platform: platform, rel: rel)
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
        let id = RepoID(providerID: outcome.providerID, platform: outcome.platform, rel: outcome.rel)
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
        // Statuses that prove the repo is present on disk → mark it cloned.
        switch outcome.status {
        case .cloned, .updated, .updatedDirty, .upToDate, .emptyRemote,
             .dirty, .diverged, .branchMissing, .untracked, .trackedGone,
             .staleOnDisk, .nonGitDir:
            // .untracked / .trackedGone are emitted for on-disk repos in
            // whitelist mode; .staleOnDisk / .nonGitDir come from the disk-walk
            // stale scan — all of these ARE on disk locally (and so are
            // trashable from the Repositories view).
            repo.isClonedLocally = true
        case .skipped, .error, .notClonedYet, .notSyncedYet:
            break
        }
        repos[id] = repo
        scheduleSave()
    }

    // ---- Whitelist / Track mode --------------------------------------

    func setTracked(_ id: RepoID, _ tracked: Bool) {
        guard var repo = repos[id] else { return }
        guard repo.isTracked != tracked else { return }
        repo.isTracked = tracked
        repos[id] = repo
        scheduleSave()
    }

    func setTracked(_ ids: any Sequence<RepoID>, _ tracked: Bool) {
        var changed = false
        for id in ids {
            guard var repo = repos[id], repo.isTracked != tracked else { continue }
            repo.isTracked = tracked
            repos[id] = repo
            changed = true
        }
        if changed { scheduleSave() }
    }

    // When a platform flips into trackedOnly mode, mark everything currently
    // cloned on disk for that platform as tracked — so nothing the user already
    // has stops updating. New (not-yet-cloned) repos stay untracked.
    func autoTrackClonedRepos(platform: String) {
        var changed = false
        for (id, repo) in repos where id.platform == platform {
            if repo.isClonedLocally && !repo.isTracked {
                var r = repo
                r.isTracked = true
                repos[id] = r
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    // Provider-keyed variant: when a PROVIDER flips into trackedOnly mode,
    // auto-track everything already cloned for that provider.
    func autoTrackClonedRepos(providerID: String) {
        var changed = false
        for (id, repo) in repos where id.providerID == providerID {
            if repo.isClonedLocally && !repo.isTracked {
                var r = repo
                r.isTracked = true
                repos[id] = r
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    // The tracked repos for a provider, as provider-local rels — handed to the
    // engine so it knows which repos to sync in trackedOnly mode.
    func trackedRels(providerID: String) -> [String] {
        repos.values
            .filter { $0.id.providerID == providerID && $0.isTracked }
            .map { $0.id.rel }
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

    // Walk each provider's folder looking for .git directories. Each one
    // becomes a Repo keyed by that provider with a provider-local rel. Doesn't
    // touch ones we already know about (preserves remote-side fields).
    func seedFromDisk(providers: [Provider]) async {
        struct Found: Sendable { let providerID: String; let platform: String; let rel: String }
        let specs = providers.map { (id: $0.id.uuidString, platform: $0.kind.rawValue, root: $0.resolvedLocalPath) }
        let found: [Found] = await Task.detached(priority: .utility) {
            var out: [Found] = []
            for spec in specs {
                for rel in clonedRelsUnder(root: spec.root) {
                    out.append(Found(providerID: spec.id, platform: spec.platform, rel: rel))
                }
            }
            return out
        }.value
        let now = Date()
        for entry in found {
            let id = RepoID(providerID: entry.providerID, platform: entry.platform, rel: entry.rel)
            var repo = repos[id] ?? Repo(id: id)
            repo.isClonedLocally = true
            repo.lastClonedCheckedAt = now
            repos[id] = repo
        }
        if !found.isEmpty { scheduleSave() }
    }

    // Iterate history newest-first, applying any outcome whose repo doesn't
    // already have a `lastStatus`. Outcomes from older runs have providerID ""
    // and a prefixed rel — map them the same way the inventory migration does
    // so history-seeded rows share identity with migrated rows (else ghost
    // duplicates reappear).
    func seedFromHistory(_ history: HistoryStore) {
        for run in history.runs {
            for outcome in run.outcomes where !outcome.platform.isEmpty {
                var o = outcome
                if o.providerID.isEmpty, let prov = providerFor(legacyPlatform: o.platform, rel: o.rel) {
                    o = Outcome(platform: o.platform, rel: Self.stripDirPrefix(o.rel),
                                status: o.status, url: o.url, detail: o.detail,
                                oldSha: o.oldSha, newSha: o.newSha,
                                commitsAhead: o.commitsAhead, providerID: prov.id.uuidString)
                }
                let id = RepoID(providerID: o.providerID, platform: o.platform, rel: o.rel)
                if repos[id]?.lastStatus != nil { continue }
                apply(outcome: o)
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
        migrateToProviders(rawData: data)
        repairClonedFlag()
    }

    // Repair persisted rows whose status proves they're on disk but that were
    // saved with isClonedLocally == false (an earlier apply(outcome:) didn't set
    // the flag for .staleOnDisk / .nonGitDir). Without this they'd be excluded
    // from the Repositories view's "Move N to Trash" count until the next sync
    // re-emitted the outcome. Idempotent; in-memory only (next save persists it).
    private func repairClonedFlag() {
        for (id, repo) in repos where !repo.isClonedLocally {
            if repo.lastStatus == .staleOnDisk || repo.lastStatus == .nonGitDir {
                repos[id]?.isClonedLocally = true
            }
        }
    }

    // One-time migration to provider-keyed identity. Pre-provider rows decode
    // with providerID == "" and rel still carrying the capitalized platform dir
    // ("Gitlab/foo/bar"). We re-key each to its owning provider and strip the
    // prefix so rel becomes provider-local ("foo/bar").
    //
    // Mapping a legacy row → provider: match by kind AND the dir the rel is
    // prefixed with (so a future config with two same-kind providers still maps
    // deterministically by folder), falling back to the first enabled provider
    // of that kind. A row that matches no provider is left as-is (providerID
    // still "") — harmless: it shows in the inventory but won't collide.
    //
    // SAFETY: we back up the raw inventory.json to inventory.json.bak BEFORE
    // rewriting, and only rewrite if something actually changed. The inventory
    // is a rebuildable cache anyway (disk walk + a sync repopulate it), so the
    // worst case is fully recoverable.
    private func migrateToProviders(rawData: Data) {
        let needsMigration = repos.keys.contains { $0.providerID.isEmpty }
        guard needsMigration, !providersAtLaunch.isEmpty else { return }

        // Back up the original before touching anything.
        try? rawData.write(to: backupURL, options: .atomic)

        var migrated: [RepoID: Repo] = [:]
        for (id, repo) in repos {
            let newID: RepoID
            if id.providerID.isEmpty, let prov = providerFor(legacyPlatform: id.platform, rel: id.rel) {
                // Strip the leading "<DefaultDir>/" the legacy rel carried.
                let bareRel = Self.stripDirPrefix(id.rel)
                newID = RepoID(providerID: prov.id.uuidString, platform: id.platform, rel: bareRel)
            } else {
                newID = id   // already migrated, or no matching provider
            }
            if let existing = migrated[newID] {
                migrated[newID] = Self.merge(existing, repo.reKeyed(to: newID))
            } else {
                migrated[newID] = repo.reKeyed(to: newID)
            }
        }
        repos = migrated
        saveNow()
    }

    // Resolve a legacy {platform, prefixed-rel} row to its provider: prefer the
    // provider of that kind whose defaultDirName matches the rel's prefix; else
    // the first provider of that kind.
    private func providerFor(legacyPlatform platform: String, rel: String) -> Provider? {
        let kind = ProviderKind(rawValue: platform)
        let ofKind = providersAtLaunch.filter { kind == nil || $0.kind == kind }
        guard !ofKind.isEmpty else { return nil }
        if let prefix = rel.split(separator: "/").first.map(String.init) {
            if let byDir = ofKind.first(where: { $0.kind.defaultDirName == prefix }) {
                return byDir
            }
        }
        return ofKind.first
    }

    private static func stripDirPrefix(_ rel: String) -> String {
        for prefix in ["Gitlab/", "Github/", "Bitbucket/"] where rel.hasPrefix(prefix) {
            return String(rel.dropFirst(prefix.count))
        }
        return rel
    }

    // Merge two records for the same repo: prefer whichever has actual
    // sync data; union the booleans; keep the latest timestamps and any
    // non-empty remote-side fields.
    private static func merge(_ a: Repo, _ b: Repo) -> Repo {
        let (primary, secondary) = (a.lastStatus == nil && b.lastStatus != nil) ? (b, a) : (a, b)
        var base = primary
        base.isClonedLocally = a.isClonedLocally || b.isClonedLocally
        base.isTracked = a.isTracked || b.isTracked
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

// Returns provider-LOCAL rels for every .git directory under one provider's
// root folder (e.g. "development/foo/bar"). Stops descending once a .git is
// found. The caller pairs these with the provider's id/kind.
private nonisolated func clonedRelsUnder(root: String) -> [String] {
    var out: [String] = []
    let fm = FileManager.default
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    guard fm.fileExists(atPath: rootURL.path) else { return out }
    guard let enumerator = fm.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return out }

    let prefixLen = rootURL.path.count + 1
    for case let url as URL in enumerator {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else { continue }
        if fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
            out.append(String(url.path.dropFirst(prefixLen)))   // provider-local
            enumerator.skipDescendants()
        }
    }
    return out
}
