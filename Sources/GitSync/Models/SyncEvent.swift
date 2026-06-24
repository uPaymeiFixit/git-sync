import Foundation

// Progress + result events emitted by the sync engine (via BufferSink) and
// consumed by AppState/EventBuffer. The `platform` field identifies the
// originating provider's kind.
enum SyncEvent: Equatable, Sendable {
    case sessionStart(platform: String, description: String, total: Int)
    case sessionEnd(platform: String, description: String)
    case workerStart(platform: String, rel: String, op: String)
    case workerPhase(platform: String, rel: String, phase: String, pct: Int?)
    case workerFinish(platform: String, rel: String)
    case outcome(platform: String, outcome: Outcome)
    // providerID is stamped by the engine so the inventory can key the row by
    // provider. rel is provider-local.
    case remoteProject(providerID: String, platform: String, rel: String, sshURL: String, defaultBranch: String)
    // A coarse "what is the run doing right now" label for the live UI:
    // "Discovering GitLab…", "Warming SSH connections…", "Syncing 2084 repos…".
    // Coalesced in EventBuffer (only the latest matters).
    case phase(label: String)
}
