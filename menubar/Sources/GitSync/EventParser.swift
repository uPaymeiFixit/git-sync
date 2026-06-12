import Foundation

// Parses lines from a sync-{platform}.py child process (run with
// GIT_SYNC_EVENTS=1) into SyncEvent values. Event lines start with the
// EVENTS_PREFIX from scripts/_sync.py:165 — ASCII record separator + "GSE ".
// Anything else is treated as free-form log output and returned as nil.
//
// Defensive: if the prefix is present but the JSON fails to decode, we
// return .logLine instead of throwing — the script controls all call sites
// so this should never happen in practice, but a corrupt event line should
// not break the app.

enum ParsedLine: Equatable, Sendable {
    case event(SyncEvent)
    case logLine(String)
}

struct EventParser {
    // Matches EVENTS_PREFIX in scripts/_sync.py: \x1e + "GSE " (with the
    // trailing space). The Python uses `"\x1eGSE "` exactly.
    static let prefix = "\u{1E}GSE "

    let platform: String

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    func parse(_ rawLine: String) -> ParsedLine {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard line.hasPrefix(Self.prefix) else {
            return .logLine(rawLine)
        }
        let jsonPart = String(line.dropFirst(Self.prefix.count))
        guard let data = jsonPart.data(using: .utf8) else {
            return .logLine(rawLine)
        }
        do {
            let envelope = try decoder.decode(EventEnvelope.self, from: data)
            if let event = try envelope.materialize(platform: platform, data: data, decoder: decoder) {
                return .event(event)
            }
            // Unknown kind: surface the raw JSON so the user can see something
            // weird happened, but don't crash.
            return .logLine(rawLine)
        } catch {
            return .logLine(rawLine)
        }
    }
}

// Two-pass decoding: read `kind` first, then re-decode into the right
// payload. Keeps the per-event payload types small and avoids one huge
// optional-fields struct.
private struct EventEnvelope: Decodable {
    let kind: String

    func materialize(
        platform: String,
        data: Data,
        decoder: JSONDecoder
    ) throws -> SyncEvent? {
        switch kind {
        case "session_start":
            let p = try decoder.decode(SessionStartPayload.self, from: data)
            return .sessionStart(platform: platform, description: p.description, total: p.total)
        case "session_end":
            let p = try decoder.decode(SessionEndPayload.self, from: data)
            return .sessionEnd(platform: platform, description: p.description)
        case "worker_start":
            let p = try decoder.decode(WorkerStartPayload.self, from: data)
            return .workerStart(platform: platform, rel: p.rel, op: p.op)
        case "worker_phase":
            let p = try decoder.decode(WorkerPhasePayload.self, from: data)
            return .workerPhase(platform: platform, rel: p.rel, phase: p.phase, pct: p.pct)
        case "worker_finish":
            let p = try decoder.decode(WorkerFinishPayload.self, from: data)
            return .workerFinish(platform: platform, rel: p.rel)
        case "outcome":
            let o = try decoder.decode(Outcome.self, from: data)
            // Outcome's wire envelope carries platform natively (Python's
            // _emit_outcome_event added the field). Trust that over the
            // pipe-attribution fallback when present.
            return .outcome(platform: o.platform.isEmpty ? platform : o.platform,
                            outcome: o)
        case "remote_project":
            let p = try decoder.decode(RemoteProjectPayload.self, from: data)
            return .remoteProject(
                platform: p.platform.isEmpty ? platform : p.platform,
                rel: p.rel,
                sshURL: p.sshURL,
                defaultBranch: p.defaultBranch)
        default:
            return nil
        }
    }
}

private struct SessionStartPayload: Decodable { let description: String; let total: Int }
private struct SessionEndPayload: Decodable { let description: String }
private struct WorkerStartPayload: Decodable { let rel: String; let op: String }
private struct WorkerPhasePayload: Decodable {
    let rel: String
    let phase: String
    let pct: Int?
}
private struct WorkerFinishPayload: Decodable { let rel: String }
private struct RemoteProjectPayload: Decodable {
    let platform: String
    let rel: String
    let sshURL: String
    let defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case platform, rel
        case sshURL = "ssh_url"
        case defaultBranch = "default_branch"
    }
}
