import Foundation

// Mirrors scripts/_sync.py Outcome dataclass. Wire format uses snake_case
// keys (see _emit_outcome_event in scripts/_sync.py:444).
struct Outcome: Codable, Hashable, Identifiable, Sendable {
    let rel: String
    let status: SyncStatus
    let url: String
    let detail: String
    let oldSha: String
    let newSha: String
    let commitsAhead: Int

    var id: String { "\(rel)\u{1F}\(status.rawValue)" }

    enum CodingKeys: String, CodingKey {
        case rel, status, url, detail
        case oldSha = "old_sha"
        case newSha = "new_sha"
        case commitsAhead = "commits_ahead"
    }
}
