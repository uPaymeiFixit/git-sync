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

    // Free-form engine diagnostics (the `sink.logLine` channel): discovery
    // failures ("discovery failed: HTTP 401 unauthorized…"), host-unreachable
    // notices, etc. These are the lines that explain a platform exiting 1 with
    // zero repos — without them, a failed run looks like "nothing happened."
    // Logged at .notice so they survive the default log level.
    static func engine(_ message: String, platform: String) {
        run.notice("\(platform, privacy: .public): \(message, privacy: .public)")
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

// Opens the activity log for viewing.
//
// Console.app is a dead end for this: it opens to "No messages" until you click
// Start Streaming, and even then it shows the FIREHOSE (everything on the
// system) with no way to pre-apply our subsystem filter — there's no public API
// or URL scheme to drive it. So instead we open Terminal running the `log
// stream` command from the README: a live, correctly-filtered tail of exactly
// GitSync's entries, scrolling as runs happen. One click, no setup.
@MainActor
enum ConsoleLog {
    // The predicate that scopes the stream to just GitSync's entries. Also
    // valid in Console.app's search bar / `log show --predicate '…'` if a user
    // prefers those.
    static let predicate = #"subsystem == "com.uPaymeiFixit.GitSync""#

    // The full command we run. `--info` includes the .info-level routine
    // outcomes (clean/skipped), not just the .notice-level anomalies; `--style
    // compact` keeps each entry on a readable single line. An initial `log
    // show … --last 1h` prints recent history first so the window isn't empty
    // until the next event, then `log stream` tails live.
    static var streamCommand: String {
        let p = "'\(predicate)'"
        return "log show --predicate \(p) --info --style compact --last 1h; "
             + "echo '— streaming live (Ctrl-C to stop) —'; "
             + "log stream --predicate \(p) --info --style compact"
    }

    static func open() {
        // Always put the command on the clipboard as a fallback: if driving
        // Terminal fails (automation permission denied, Terminal missing), the
        // user can paste it into any shell.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(streamCommand, forType: .string)

        guard runInTerminal(streamCommand) else {
            // Couldn't drive Terminal — open it (or fall back to Utilities) so
            // the user has somewhere to paste the command we just copied.
            if let term = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.openApplication(at: term, configuration: .init())
            } else {
                NSWorkspace.shared.open(
                    URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true))
            }
            return
        }
    }

    // Launch Terminal and run `command` in a new window via AppleScript.
    // Returns false if osascript couldn't be run or reported an error.
    private static func runInTerminal(_ command: String) -> Bool {
        // Escape for an AppleScript string literal: backslash then double-quote.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
