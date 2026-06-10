import Foundation

struct RunRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var outcomes: [Outcome]
    var logLines: [String]
    var exitCodes: [String: Int32]

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        outcomes: [Outcome] = [],
        logLines: [String] = [],
        exitCodes: [String: Int32] = [:]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcomes = outcomes
        self.logLines = logLines
        self.exitCodes = exitCodes
    }
}
