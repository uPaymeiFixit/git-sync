import Foundation

// EventBuffer sits between the engine's BufferSink (the event producer) and
// AppState (the event consumer). It exists because hopping to MainActor for
// every event during a large run (1000+ repos, many concurrent workers) would
// back up the emit path and stutter the UI.
//
// Producer: the engine via BufferSink. push() never blocks on the UI; it
// only touches the buffer's actor.
// Consumer: AppState. drainAndClear() runs on a Timer at ~10Hz from the
// MainActor and applies a batch in one render cycle.
//
// Coalescing: worker_phase events for the same (platform, rel) are
// deduplicated — only the latest phase/pct survives. This drops thousands
// of intermediate "receiving 47%" -> "receiving 48%" updates that the UI
// can't render fast enough anyway. workerStart/Finish and outcome events
// are NEVER dropped because they're discrete state transitions.
//
// Log lines (free-form stderr) get batched the same way.

actor EventBuffer {
    // Order-preserving buffer of structural events. workerStart, workerFinish,
    // outcome, sessionStart, sessionEnd. Coalesced worker_phase events go
    // separately so they don't bloat this list.
    private var events: [SyncEvent] = []

    // Coalesced phase state: latest (phase, pct) per (platform, rel).
    private var latestPhase: [String: WorkerPhaseSnapshot] = [:]

    // Coalesced log lines, accumulated per platform.
    private var logLines: [(platform: String, line: String)] = []

    // Termination signals queued during the run.
    private var platformFinishes: [(platform: String, exitCode: Int32)] = []
    private var allFinished: Bool = false
    // Per-job finishes for the individual (per-repo --only) lane. Kept
    // separate from allFinished so one individual finishing never signals
    // "the whole run is done" and tears down the others.
    private var individualFinishes: [(id: RepoID, exitCode: Int32)] = []

    // Latest coarse run-phase label ("Discovering GitLab…", etc.). Coalesced:
    // only the most recent matters. nil until the first .phase event.
    private var latestRunPhase: String?

    struct WorkerPhaseSnapshot: Sendable {
        let platform: String
        let rel: String
        let phase: String
        let pct: Int?
    }

    struct Batch: Sendable {
        let events: [SyncEvent]
        let latestPhases: [WorkerPhaseSnapshot]
        let logs: [(platform: String, line: String)]
        let finishes: [(platform: String, exitCode: Int32)]
        let allFinished: Bool
        let individualFinishes: [(id: RepoID, exitCode: Int32)]
        let runPhase: String?

        var isEmpty: Bool {
            events.isEmpty && latestPhases.isEmpty && logs.isEmpty
                && finishes.isEmpty && !allFinished && individualFinishes.isEmpty
                && runPhase == nil
        }
    }

    func push(_ event: SyncEvent) {
        switch event {
        case .workerPhase(let platform, let rel, let phase, let pct):
            // Coalesce by (platform, rel) — only the latest phase matters
            // for the UI.
            let key = platform + "\u{1F}" + rel
            latestPhase[key] = WorkerPhaseSnapshot(
                platform: platform, rel: rel, phase: phase, pct: pct)
        case .phase(let label):
            // Coalesce: only the most recent run-phase label survives a drain.
            latestRunPhase = label
        case .workerStart, .workerFinish, .outcome, .sessionStart, .sessionEnd,
             .remoteProject:
            events.append(event)
        }
    }

    func pushLogLine(_ line: String, platform: String) {
        logLines.append((platform: platform, line: line))
    }

    func pushPlatformFinish(_ platform: String, exitCode: Int32) {
        platformFinishes.append((platform: platform, exitCode: exitCode))
    }

    func markAllFinished() {
        allFinished = true
    }

    func pushIndividualFinish(_ id: RepoID, exitCode: Int32) {
        individualFinishes.append((id: id, exitCode: exitCode))
    }

    func drainAndClear() -> Batch {
        let snapshot = Batch(
            events: events,
            latestPhases: Array(latestPhase.values),
            logs: logLines,
            finishes: platformFinishes,
            allFinished: allFinished,
            individualFinishes: individualFinishes,
            runPhase: latestRunPhase
        )
        events.removeAll(keepingCapacity: true)
        latestPhase.removeAll(keepingCapacity: true)
        logLines.removeAll(keepingCapacity: true)
        platformFinishes.removeAll(keepingCapacity: true)
        allFinished = false
        individualFinishes.removeAll(keepingCapacity: true)
        latestRunPhase = nil
        return snapshot
    }
}
