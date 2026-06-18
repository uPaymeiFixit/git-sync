import Foundation

// Events emitted by scripts/_sync.py when GIT_SYNC_EVENTS=1. The `platform`
// field is attached by EventParser based on which child process produced
// the line; the Python side does not include it (except on outcome and
// remote_project events, which carry it natively).
enum SyncEvent: Equatable, Sendable {
    case sessionStart(platform: String, description: String, total: Int)
    case sessionEnd(platform: String, description: String)
    case workerStart(platform: String, rel: String, op: String)
    case workerPhase(platform: String, rel: String, phase: String, pct: Int?)
    case workerFinish(platform: String, rel: String)
    case outcome(platform: String, outcome: Outcome)
    // providerID is stamped by the native engine (empty on the Python path) so
    // the inventory can key the row by provider. rel is provider-local.
    case remoteProject(providerID: String, platform: String, rel: String, sshURL: String, defaultBranch: String)
    // A coarse "what is the run doing right now" label for the live UI:
    // "Discovering GitLab…", "Warming SSH connections…", "Syncing 2084 repos…".
    // Coalesced in EventBuffer (only the latest matters). Emitted by the
    // native engine only; the Python path never produces it.
    case phase(label: String)
}
