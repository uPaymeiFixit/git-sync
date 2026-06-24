import Foundation

// Unit test for whitelist / Track-mode classification — the decision the
// engine makes per discovered repo: SYNC, SKIP (blacklist), or EXCLUDE
// (whitelist, not tracked). This is the logic that, if wrong, would either
// clone repos the cautious user didn't want or silently fail to sync ones
// they tracked. The env round-trip (FILTER_MODE / TRACKED vars) is also
// exercised since that's how AppState hands the tracked set to the engine.
//
//   GitSync --whitelist-test
//
// Mirrors the engine's classification (SyncEngine.filterMode/trackedSet + the
// per-repo isSkipped/isExcluded computation) against a synthetic discovered
// set. Kept in sync with SyncEngine by intent.
enum WhitelistTest {
    enum Decision: Equatable { case sync, skip, exclude }

    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Whitelist / Track-mode test")

        // Mirror SyncEngine's env readers.
        func filterMode(_ env: [String: String], _ p: String) -> FilterMode {
            FilterMode(rawValue: env["GIT_SYNC_FILTER_MODE_\(p.uppercased())"] ?? "") ?? .syncAll
        }
        func trackedSet(_ env: [String: String], _ p: String) -> Set<String> {
            Set((env["GIT_SYNC_TRACKED_\(p.uppercased())"] ?? "").split(separator: "\n").map(String.init))
        }
        // Mirror SyncEngine's per-repo classification (skip uses namespacePath,
        // tracked uses canonical rel).
        func classify(env: [String: String], platform: String, rel: String,
                      namespacePath: String, skip: SkipMatcher) -> Decision {
            let mode = filterMode(env, platform)
            let isSkipped = skip.matches(namespacePath)
            if isSkipped { return .skip }
            if mode == .trackedOnly {
                return trackedSet(env, platform).contains(rel) ? .sync : .exclude
            }
            return .sync
        }

        // --- syncAll mode (default): everything syncs except blacklist. ---
        do {
            let env: [String: String] = [:]  // no filter-mode set → syncAll
            let skip = SkipMatcher("archived")
            check("syncAll: normal repo syncs",
                  classify(env: env, platform: "github", rel: "Github/foo", namespacePath: "foo", skip: skip) == .sync)
            check("syncAll: blacklisted repo skips",
                  classify(env: env, platform: "github", rel: "Github/archived/x", namespacePath: "archived/x", skip: skip) == .skip)
        }

        // --- trackedOnly mode: only tracked repos sync; rest EXCLUDED. ---
        do {
            let env: [String: String] = [
                "GIT_SYNC_FILTER_MODE_GITHUB": "trackedOnly",
                "GIT_SYNC_TRACKED_GITHUB": "Github/keep-me\nGithub/team/also-keep",
            ]
            let skip = SkipMatcher("")
            check("trackedOnly: tracked repo syncs",
                  classify(env: env, platform: "github", rel: "Github/keep-me", namespacePath: "keep-me", skip: skip) == .sync)
            check("trackedOnly: tracked nested repo syncs",
                  classify(env: env, platform: "github", rel: "Github/team/also-keep", namespacePath: "team/also-keep", skip: skip) == .sync)
            check("trackedOnly: untracked repo is EXCLUDED (not skipped)",
                  classify(env: env, platform: "github", rel: "Github/whatever", namespacePath: "whatever", skip: skip) == .exclude)
        }

        // --- trackedOnly + blacklist: skip takes precedence over track. ---
        do {
            let env: [String: String] = [
                "GIT_SYNC_FILTER_MODE_GITHUB": "trackedOnly",
                "GIT_SYNC_TRACKED_GITHUB": "Github/secret",
            ]
            let skip = SkipMatcher("secret")
            check("trackedOnly: blacklist beats track (skip wins)",
                  classify(env: env, platform: "github", rel: "Github/secret", namespacePath: "secret", skip: skip) == .skip)
        }

        // --- per-platform isolation: github trackedOnly, gitlab syncAll. ---
        do {
            let env: [String: String] = [
                "GIT_SYNC_FILTER_MODE_GITHUB": "trackedOnly",
                "GIT_SYNC_TRACKED_GITHUB": "Github/only",
                // gitlab unset → syncAll
            ]
            let skip = SkipMatcher("")
            check("isolation: github untracked excluded",
                  classify(env: env, platform: "github", rel: "Github/other", namespacePath: "other", skip: skip) == .exclude)
            check("isolation: gitlab (syncAll) still syncs everything",
                  classify(env: env, platform: "gitlab", rel: "Gitlab/anything", namespacePath: "anything", skip: skip) == .sync)
        }

        // --- empty tracked set in trackedOnly: nothing syncs (all excluded). ---
        do {
            let env: [String: String] = ["GIT_SYNC_FILTER_MODE_GITHUB": "trackedOnly"]  // no TRACKED var
            let skip = SkipMatcher("")
            check("trackedOnly + empty tracked set: everything excluded",
                  classify(env: env, platform: "github", rel: "Github/x", namespacePath: "x", skip: skip) == .exclude)
        }

        print()
        if failures == 0 { print("Whitelist test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }
}
