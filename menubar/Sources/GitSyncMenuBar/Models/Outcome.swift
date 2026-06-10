import Foundation

// Mirrors scripts/_sync.py Outcome dataclass.
struct Outcome: Codable, Hashable, Identifiable, Sendable {
    let rel: String
    let status: SyncStatus
    let url: String
    let detail: String
    let oldSha: String
    let newSha: String
    let commitsAhead: Int

    var id: String { "\(rel)\u{1F}\(status.rawValue)" }
}
