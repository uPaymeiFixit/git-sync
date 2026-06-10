import Foundation

// Events emitted by scripts/_sync.py when GIT_SYNC_EVENTS=1. The `platform`
// field is attached by EventParser based on which child process produced
// the line; the Python side does not include it.
enum SyncEvent: Equatable, Sendable {
    case sessionStart(platform: String, description: String, total: Int)
    case sessionEnd(platform: String, description: String)
    case workerStart(platform: String, rel: String, op: String)
    case workerPhase(platform: String, rel: String, phase: String, pct: Int?)
    case workerFinish(platform: String, rel: String)
    case outcome(platform: String, outcome: Outcome)
}
