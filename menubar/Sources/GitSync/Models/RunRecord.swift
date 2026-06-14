import Foundation

struct RunRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var outcomes: [Outcome]
    var logLines: [String]
    var exitCodes: [String: Int32]

    // Transient live-only label ("Discovering GitLab…", "Syncing 2084 repos…").
    // Deliberately excluded from Codable (see CodingKeys): it's meaningless once
    // a run is finished and persisted, and keeping it out preserves on-disk
    // history compatibility.
    var phaseLabel: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, outcomes, logLines, exitCodes
    }

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        outcomes: [Outcome] = [],
        logLines: [String] = [],
        exitCodes: [String: Int32] = [:],
        phaseLabel: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcomes = outcomes
        self.logLines = logLines
        self.exitCodes = exitCodes
        self.phaseLabel = phaseLabel
    }
}
