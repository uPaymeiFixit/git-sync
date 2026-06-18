import Foundation

// Identity for a single remote-known or locally-cloned repository.
// (platform, rel) is stable across runs and survives outcome state
// changes — unlike the older Outcome.id-by-status formula.
//
// NOTE (provider work, in progress): the provider abstraction will move
// identity to (providerID, provider-local rel). That change is intentionally
// NOT yet wired — see memory `roadmap-whitelist-providers-onboarding` and the
// `provider-model-scaffolding` note. RepoID stays (platform, rel) until the
// inventory migration is built + verified against real data with the user.
struct RepoID: Hashable, Codable, Sendable, CustomStringConvertible {
    let platform: String
    let rel: String

    var description: String { "\(platform):\(rel)" }

    // The repo path as the platform knows it — rel minus the leading
    // platform directory. This is the format GIT_SYNC_SKIP patterns use
    // (the Python matches them against path_with_namespace / name / slug,
    // never against the on-disk platform-dir-prefixed path).
    var namespacePath: String {
        for prefix in ["Gitlab/", "Github/", "Bitbucket/"] where rel.hasPrefix(prefix) {
            return String(rel.dropFirst(prefix.count))
        }
        return rel
    }
}

// One row in the Repositories inventory. The view layer derives all
// presentation off of this; InventoryStore handles persistence and
// applies remote_project + outcome events.
struct Repo: Codable, Sendable, Identifiable, Hashable {
    let id: RepoID
    var sshURL: String
    var defaultBranch: String

    // Most recent observed sync result. `nil` means we know the repo
    // exists remotely but haven't synced it yet — the view treats that
    // as `SyncStatus.notClonedYet` for display.
    var lastStatus: SyncStatus?
    var lastDetail: String
    var lastOldSha: String
    var lastNewSha: String
    var lastCommitsAhead: Int

    // When the most recent outcome / API-listing / disk check happened.
    var lastUpdatedAt: Date?       // when lastStatus / lastDetail changed
    var lastSeenRemoteAt: Date?    // when the platform API last returned it
    var lastClonedCheckedAt: Date? // when we last verified .git on disk

    var isClonedLocally: Bool

    // Whitelist / "Track" mode: when a platform is in trackedOnly filter mode,
    // ONLY repos with isTracked == true are cloned/synced. Ignored in syncAll
    // mode (the default). Persisted with the inventory; decodes to false for
    // older inventory.json that predates this field (see init(from:)).
    var isTracked: Bool

    // Convenience for view layer. When no real outcome has been observed:
    // a repo found on disk is "not synced yet" (we have it, no sync data),
    // a repo only known from the remote listing is "not cloned yet".
    var effectiveStatus: SyncStatus {
        if let lastStatus { return lastStatus }
        return isClonedLocally ? .notSyncedYet : .notClonedYet
    }

    // Same record under a different identity — used by the inventory's
    // legacy-key migration.
    func reKeyed(to newID: RepoID) -> Repo {
        Repo(
            id: newID,
            sshURL: sshURL,
            defaultBranch: defaultBranch,
            lastStatus: lastStatus,
            lastDetail: lastDetail,
            lastOldSha: lastOldSha,
            lastNewSha: lastNewSha,
            lastCommitsAhead: lastCommitsAhead,
            lastUpdatedAt: lastUpdatedAt,
            lastSeenRemoteAt: lastSeenRemoteAt,
            lastClonedCheckedAt: lastClonedCheckedAt,
            isClonedLocally: isClonedLocally,
            isTracked: isTracked
        )
    }

    init(
        id: RepoID,
        sshURL: String = "",
        defaultBranch: String = "",
        lastStatus: SyncStatus? = nil,
        lastDetail: String = "",
        lastOldSha: String = "",
        lastNewSha: String = "",
        lastCommitsAhead: Int = 0,
        lastUpdatedAt: Date? = nil,
        lastSeenRemoteAt: Date? = nil,
        lastClonedCheckedAt: Date? = nil,
        isClonedLocally: Bool = false,
        isTracked: Bool = false
    ) {
        self.id = id
        self.sshURL = sshURL
        self.defaultBranch = defaultBranch
        self.lastStatus = lastStatus
        self.lastDetail = lastDetail
        self.lastOldSha = lastOldSha
        self.lastNewSha = lastNewSha
        self.lastCommitsAhead = lastCommitsAhead
        self.lastUpdatedAt = lastUpdatedAt
        self.lastSeenRemoteAt = lastSeenRemoteAt
        self.lastClonedCheckedAt = lastClonedCheckedAt
        self.isClonedLocally = isClonedLocally
        self.isTracked = isTracked
    }

    // Custom decoder so inventory.json written before isTracked existed still
    // loads (the key is simply absent → false). All other keys decode as
    // synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(RepoID.self, forKey: .id)
        sshURL = try c.decodeIfPresent(String.self, forKey: .sshURL) ?? ""
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch) ?? ""
        lastStatus = try c.decodeIfPresent(SyncStatus.self, forKey: .lastStatus)
        lastDetail = try c.decodeIfPresent(String.self, forKey: .lastDetail) ?? ""
        lastOldSha = try c.decodeIfPresent(String.self, forKey: .lastOldSha) ?? ""
        lastNewSha = try c.decodeIfPresent(String.self, forKey: .lastNewSha) ?? ""
        lastCommitsAhead = try c.decodeIfPresent(Int.self, forKey: .lastCommitsAhead) ?? 0
        lastUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        lastSeenRemoteAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenRemoteAt)
        lastClonedCheckedAt = try c.decodeIfPresent(Date.self, forKey: .lastClonedCheckedAt)
        isClonedLocally = try c.decodeIfPresent(Bool.self, forKey: .isClonedLocally) ?? false
        isTracked = try c.decodeIfPresent(Bool.self, forKey: .isTracked) ?? false
    }
}
