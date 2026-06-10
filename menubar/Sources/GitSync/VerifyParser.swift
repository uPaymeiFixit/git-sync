import Foundation

// Runtime parser smoke test. Reads the bundled fixture, runs every line
// through EventParser, and asserts the result matches expectations. Used
// in place of XCTest because this project builds with the Command Line
// Tools toolchain, which doesn't ship XCTest or swift-testing.
//
// Invoked via `./build.sh debug && .build/debug/GitSyncMenuBar --verify-parser`
// or by passing --verify-parser to the .app's executable.
enum VerifyParser {
    // exit codes: 0 ok, 1 a check failed, 2 the fixture wasn't found
    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok {
                print("  ok   \(label)")
            } else {
                let d = detail()
                print("  FAIL \(label)\(d.isEmpty ? "" : " — \(d)")")
                failures += 1
            }
        }

        let parser = EventParser(platform: "gitlab")
        let lines = Self.embeddedFixture.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var events: [SyncEvent] = []
        var unexpectedLogLines: [String] = []
        for line in lines {
            switch parser.parse(line) {
            case .event(let e): events.append(e)
            case .logLine(let l): unexpectedLogLines.append(l)
            }
        }

        print("Parser fixture verification")
        check("all 9 fixture lines parse as events",
              events.count == 9 && unexpectedLogLines.isEmpty,
              "got \(events.count) events + \(unexpectedLogLines.count) log lines")

        if case .sessionStart(let p, let desc, let total) = events.first {
            check("first event is session_start(GitLab sync, total=3)",
                  p == "gitlab" && desc == "GitLab sync" && total == 3,
                  "got platform=\(p) desc=\(desc) total=\(total)")
        } else {
            check("first event is session_start", false, "got \(events.first.map(String.init(describing:)) ?? "nil")")
        }

        let statuses: [SyncStatus] = events.compactMap {
            if case .outcome(_, let o) = $0 { return o.status } else { return nil }
        }
        check("outcomes are [cloned, dirty, diverged]",
              statuses == [.cloned, .dirty, .diverged],
              "got \(statuses)")

        if case .sessionEnd = events.last {
            check("last event is session_end", true)
        } else {
            check("last event is session_end", false)
        }

        // Free-form log lines should pass through unchanged.
        let logLine = "[14:45:53] some random log output"
        check("free-form log lines pass through",
              parser.parse(logLine) == .logLine(logLine))

        // worker_phase with null pct decodes pct as nil.
        let nullPctLine = "\u{1E}GSE {\"kind\":\"worker_phase\",\"rel\":\"x\",\"phase\":\"starting\",\"pct\":null}"
        if case .event(.workerPhase(_, _, _, let pct)) = parser.parse(nullPctLine) {
            check("worker_phase with null pct decodes to nil", pct == nil)
        } else {
            check("worker_phase with null pct decodes to nil", false)
        }

        // Corrupt event line should fall back to .logLine, not crash.
        let corrupt = "\u{1E}GSE {\"kind\":\"outcome\",\"rel\":"
        check("corrupt JSON falls back to .logLine",
              parser.parse(corrupt) == .logLine(corrupt))

        print()
        if failures == 0 {
            print("All checks passed.")
            return 0
        } else {
            print("\(failures) check(s) failed.")
            return 1
        }
    }

    // Mirror of Sources/GitSyncMenuBar/Resources/all-events.txt — embedded
    // directly so the parser check works without shipping the fixture as a
    // resource (avoids SPM bundle path issues inside the .app). To refresh:
    //   python3 synthesize_fixture.py > Sources/GitSyncMenuBar/Resources/all-events.txt
    // then paste the contents here (the .txt file remains the source of truth
    // and is what tests under Xcode would read directly).
    private static let embeddedFixture = """
    \u{1E}GSE {"kind":"session_start","description":"GitLab sync","total":3}
    \u{1E}GSE {"kind":"worker_start","rel":"group/project-a","op":"clone"}
    \u{1E}GSE {"kind":"worker_phase","rel":"group/project-a","phase":"receiving","pct":42}
    \u{1E}GSE {"kind":"worker_phase","rel":"group/project-a","phase":"resolving","pct":100}
    \u{1E}GSE {"kind":"worker_finish","rel":"group/project-a"}
    \u{1E}GSE {"kind":"outcome","rel":"group/project-a","status":"cloned","url":"git@gitlab.example.com:group/project-a.git","detail":"","old_sha":"","new_sha":"abc1234","commits_ahead":0}
    \u{1E}GSE {"kind":"outcome","rel":"group/project-b","status":"dirty","url":"git@gitlab.example.com:group/project-b.git","detail":"uncommitted changes blocked fast-forward","old_sha":"def5678","new_sha":"def5678","commits_ahead":0}
    \u{1E}GSE {"kind":"outcome","rel":"group/project-c","status":"diverged","url":"git@gitlab.example.com:group/project-c.git","detail":"local has 2 commits not on remote","old_sha":"aaa1111","new_sha":"bbb2222","commits_ahead":2}
    \u{1E}GSE {"kind":"session_end","description":"GitLab sync"}
    """
}
