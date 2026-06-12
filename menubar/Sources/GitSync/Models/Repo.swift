import Foundation

// Identity for a single remote-known or locally-cloned repository.
// (platform, rel) is stable across runs and survives outcome state
// changes — unlike the older Outcome.id-by-status formula.
struct RepoID: Hashable, Codable, Sendable, CustomStringConvertible {
    let platform: String
    let rel: String

    var description: String { "\(platform):\(rel)" }
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

    // Convenience for view layer — returns the synthetic notClonedYet
    // when no real outcome has been observed.
    var effectiveStatus: SyncStatus {
        lastStatus ?? .notClonedYet
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
        isClonedLocally: Bool = false
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
    }
}
