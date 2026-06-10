import Foundation

// Persists completed RunRecords to disk and loads the most recent N back
// into memory on launch. One file per run, named by the run's startedAt
// in ISO format so the directory sorts chronologically.
//
// Storage: ~/Library/Application Support/GitSyncMenuBar/history/
// Cap: 100 newest kept; older files pruned on each save.

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var runs: [RunRecord] = []

    private let directory: URL
    private let maxRuns = 100
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        directory = appSupport
            .appendingPathComponent("GitSyncMenuBar", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadFromDisk()
    }

    func record(_ run: RunRecord) {
        runs.insert(run, at: 0)
        if runs.count > maxRuns {
            runs = Array(runs.prefix(maxRuns))
        }
        persistAndPrune(run)
    }

    private func loadFromDisk() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [RunRecord] = []
        for url in entries where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let run = try? decoder.decode(RunRecord.self, from: data) {
                loaded.append(run)
            }
        }
        runs = loaded
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(maxRuns)
            .map { $0 }
    }

    private func persistAndPrune(_ run: RunRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let stamp = isoFormatter.string(from: run.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(stamp)_\(run.id.uuidString.prefix(8)).json"
        let url = directory.appendingPathComponent(filename)
        do {
            let data = try encoder.encode(run)
            try data.write(to: url, options: .atomic)
        } catch {
            // History persistence is best-effort. A failed write shouldn't
            // disturb the run; surface to stderr in case the user is
            // watching console output.
            print("history: failed to write \(url.path): \(error)")
        }
        prune()
    }

    private func prune() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let jsonEntries = entries
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return lDate > rDate
            }
        for old in jsonEntries.dropFirst(maxRuns) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
