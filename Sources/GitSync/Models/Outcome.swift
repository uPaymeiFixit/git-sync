import Foundation

// The result of syncing one repo, produced by the engine (RepoSyncer / StaleScan).
// Feeds the inventory (one row per repo) and the activity log. Codable with
// snake_case wire keys (see CodingKeys) so older inventory JSON still decodes;
// `platform`/`providerID` default to empty for back-compat with rows that
// predate those fields.
struct Outcome: Codable, Hashable, Identifiable, Sendable {
    let platform: String
    let rel: String
    let status: SyncStatus
    let url: String
    let detail: String
    let oldSha: String
    let newSha: String
    let commitsAhead: Int
    // Which provider produced this; the engine stamps it so the inventory can
    // key the row by provider. Empty for old history rows that predate it.
    let providerID: String

    var id: String { "\(providerID)\u{1F}\(platform)\u{1F}\(rel)" }

    init(
        platform: String = "",
        rel: String,
        status: SyncStatus,
        url: String = "",
        detail: String = "",
        oldSha: String = "",
        newSha: String = "",
        commitsAhead: Int = 0,
        providerID: String = ""
    ) {
        self.platform = platform
        self.rel = rel
        self.status = status
        self.url = url
        self.detail = detail
        self.oldSha = oldSha
        self.newSha = newSha
        self.commitsAhead = commitsAhead
        self.providerID = providerID
    }

    // Same outcome with providerID set — the engine stamps this after
    // RepoSyncer (which is provider-agnostic) returns.
    func withProviderID(_ pid: String) -> Outcome {
        Outcome(platform: platform, rel: rel, status: status, url: url, detail: detail,
                oldSha: oldSha, newSha: newSha, commitsAhead: commitsAhead, providerID: pid)
    }

    enum CodingKeys: String, CodingKey {
        case platform, rel, status, url, detail
        case oldSha = "old_sha"
        case newSha = "new_sha"
        case commitsAhead = "commits_ahead"
        case providerID = "provider_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.platform = (try? c.decode(String.self, forKey: .platform)) ?? ""
        self.rel = try c.decode(String.self, forKey: .rel)
        self.status = try c.decode(SyncStatus.self, forKey: .status)
        self.url = (try? c.decode(String.self, forKey: .url)) ?? ""
        self.detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
        self.oldSha = (try? c.decode(String.self, forKey: .oldSha)) ?? ""
        self.newSha = (try? c.decode(String.self, forKey: .newSha)) ?? ""
        self.commitsAhead = (try? c.decode(Int.self, forKey: .commitsAhead)) ?? 0
        self.providerID = (try? c.decode(String.self, forKey: .providerID)) ?? ""
    }
}
