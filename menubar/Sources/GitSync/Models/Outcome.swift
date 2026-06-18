import Foundation

// Mirrors scripts/_sync.py Outcome dataclass. Wire format uses snake_case
// keys (see _emit_outcome_event in scripts/_sync.py:444).
//
// `platform` is added by the Python side (OutcomeCollector now carries
// the platform name) so the menu-bar app can key by (platform, rel)
// without needing pipe-attribution. Default empty for back-compat with
// older history JSON that predates the field.
struct Outcome: Codable, Hashable, Identifiable, Sendable {
    let platform: String
    let rel: String
    let status: SyncStatus
    let url: String
    let detail: String
    let oldSha: String
    let newSha: String
    let commitsAhead: Int
    // Which provider produced this. Native-engine-only (the Python path leaves
    // it ""); the engine stamps it so the inventory can key the row by provider.
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
