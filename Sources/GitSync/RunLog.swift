import AppKit
import Foundation
import os

// The app's running activity log. Replaces the old persisted RunRecord history:
// every full run, individual (one-off) sync, per-repo outcome, and deletion is
// written here as a unified-logging entry. View it in Console.app (filter by
// subsystem "com.uPaymeiFixit.GitSync") or from a terminal:
//
//     log stream  --predicate 'subsystem == "com.uPaymeiFixit.GitSync"' --info
//     log show    --predicate 'subsystem == "com.uPaymeiFixit.GitSync"' --info --last 1h
//
// Unified logging persists entries itself (subject to the system log budget),
// so there's nothing for us to prune or store. Live per-repo state lives in the
// inventory; this is the append-only "what happened, when" record.
//
// Category split lets a viewer narrow further:
//   run     — full-run start/finish + coarse phase labels
//   repo    — per-repo sync outcomes (one line each)
//   delete  — trash actions (moved / skipped, with the reason)
enum RunLog {
    static let subsystem = "com.uPaymeiFixit.GitSync"

    private static let run = Logger(subsystem: subsystem, category: "run")
    private static let repo = Logger(subsystem: subsystem, category: "repo")
    private static let delete = Logger(subsystem: subsystem, category: "delete")

    // ---- Full runs ----------------------------------------------------

    static func runStarted(platforms: String) {
        run.notice("run started — \(platforms, privacy: .public)")
    }

    static func runPhase(_ label: String) {
        run.info("run phase — \(label, privacy: .public)")
    }

    static func runFinished(exitCodes: [String: Int32], outcomes: Int, duration: TimeInterval) {
        let codes = exitCodes.isEmpty
            ? "no platforms"
            : exitCodes.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        run.notice(
            "run finished — \(codes, privacy: .public) · \(outcomes) repo(s) · \(Int(duration))s")
    }

    // ---- Individual (one-off) syncs -----------------------------------

    static func oneOffStarted(_ id: RepoID) {
        run.notice("one-off sync started — \(id.platform, privacy: .public)/\(id.rel, privacy: .public)")
    }

    // ---- Per-repo outcomes --------------------------------------------

    static func outcome(_ o: Outcome) {
        let detail = o.detail.isEmpty ? "" : " — \(o.detail)"
        // Anomalies at .notice so they survive the default log level; routine
        // clean/skip results at .info so they don't flood a casual viewer.
        let line = "\(o.platform)/\(o.rel) [\(o.status.rawValue)]\(detail)"
        if o.status.isAnomaly {
            repo.notice("\(line, privacy: .public)")
        } else {
            repo.info("\(line, privacy: .public)")
        }
    }

    // ---- Deletions ----------------------------------------------------

    static func trashed(_ id: RepoID) {
        delete.notice("moved to Trash — \(id.platform, privacy: .public)/\(id.rel, privacy: .public)")
    }

    static func trashSkipped(_ id: RepoID, reason: String) {
        delete.notice(
            "delete skipped — \(id.platform, privacy: .public)/\(id.rel, privacy: .public): \(reason, privacy: .public)")
    }
}

// Opens the activity log for viewing. There's no public API and no Console.app
// URL scheme to pre-apply a subsystem filter, so we do the next best thing:
// copy a ready-to-paste `log` predicate to the clipboard, then launch Console.
// The user pastes the predicate into Console's search field (or runs it in a
// terminal) to see exactly GitSync's entries.
@MainActor
enum ConsoleLog {
    // A predicate that works both in Console.app's search bar and as the
    // argument to `log stream --predicate '…'` / `log show --predicate '…'`.
    static let predicate = #"subsystem == "com.uPaymeiFixit.GitSync""#

    static func open() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(predicate, forType: .string)
        if let console = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.openApplication(at: console, configuration: .init())
        } else {
            // Console.app missing/renamed — fall back to opening /Applications
            // Utilities so the user can find it manually.
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true))
        }
    }
}
