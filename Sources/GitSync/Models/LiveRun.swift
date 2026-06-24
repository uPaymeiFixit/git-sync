import Foundation

// In-memory state for the run currently in flight. There is no persisted run
// history anymore — completed runs, per-repo outcomes, and deletions are
// written to the unified log (see RunLog) and viewed in Console.app. This type
// exists only to drive live UI (the menu's "Running…" label, the icon spin,
// and the active-workers panel) while a full run is active; it is discarded
// when the run finishes. Per-repo state lives in the inventory.
struct LiveRun: Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var outcomes: [Outcome]
    var exitCodes: [String: Int32]
    var phaseLabel: String?

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        outcomes: [Outcome] = [],
        exitCodes: [String: Int32] = [:],
        phaseLabel: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcomes = outcomes
        self.exitCodes = exitCodes
        self.phaseLabel = phaseLabel
    }
}
