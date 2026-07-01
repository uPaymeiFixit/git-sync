import Foundation

// Pins the ONE-TIME legacy-Keychain cleanup logic that fixed the "three
// password prompts on every relaunch" bug (see ProviderStore.cleanUpLegacyKeychainIfNeeded).
// The real method is @MainActor + private and touches the login Keychain (which
// would prompt), so this mirrors its algorithm against an in-memory fake store
// and pins the behavior:
//   1. empty per-provider tokens are backfilled from the matching legacy key
//   2. ALL legacy keys are deleted afterward (so they can never prompt again)
//   3. it runs at most ONCE (flag-guarded) — the every-launch sweep is gone
//   4. a provider left with no recoverable token is simply empty (not fatal)
//
//   GitSync --legacy-keychain-cleanup-test
enum LegacyKeychainCleanupTest {
    // An in-memory stand-in for Keychain: account key → secret. A "read" and a
    // "delete" are recorded so we can assert the cleanup doesn't re-read on a
    // second run (the whole point — reads are what prompt).
    final class FakeKeychain {
        var store: [String: String] = [:]
        private(set) var reads = 0
        private(set) var deletes = 0
        func get(_ key: String) -> String? { reads += 1; return store[key] }
        func set(_ value: String?, for key: String) {
            if let value, !value.isEmpty { store[key] = value }
            else { if store[key] != nil { deletes += 1 }; store[key] = nil }
        }
    }

    // Mirror of ProviderStore.cleanUpLegacyKeychainIfNeeded, parameterized over a
    // fake store + a fake "done" flag box so the test can drive it deterministically.
    // `kinds` are the provider kinds present (each with its per-provider key).
    static func cleanup(
        kc: FakeKeychain,
        providerKeyByKind: [(kind: ProviderKind, perProviderKey: String)],
        doneFlag: inout Bool
    ) {
        guard !doneFlag else { return }
        // 1. Backfill empty per-provider tokens from the matching legacy key.
        for entry in providerKeyByKind where (kc.get(entry.perProviderKey) ?? "").isEmpty {
            if let tok = kc.get(LegacyKeychainKey.forKind(entry.kind)), !tok.isEmpty {
                kc.set(tok, for: entry.perProviderKey)
            }
        }
        // 2. Delete ALL legacy keys.
        for key in [LegacyKeychainKey.gitlabToken,
                    LegacyKeychainKey.githubToken,
                    LegacyKeychainKey.bitbucketPassword] {
            kc.set(nil, for: key)
        }
        doneFlag = true
    }

    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Legacy-Keychain one-time cleanup test")

        let glKey = "provider.GL.token"
        let ghKey = "provider.GH.token"
        let entries: [(ProviderKind, String)] = [(.gitlab, glKey), (.github, ghKey)]

        // ---- Scenario A: friend's case — per-provider tokens EMPTY, legacy keys present.
        do {
            let kc = FakeKeychain()
            kc.store[LegacyKeychainKey.gitlabToken] = "gl-secret"
            kc.store[LegacyKeychainKey.githubToken] = "gh-secret"
            kc.store[LegacyKeychainKey.bitbucketPassword] = "bb-secret"  // orphan (no bitbucket provider)
            var done = false
            cleanup(kc: kc, providerKeyByKind: entries.map { ($0.0, $0.1) }, doneFlag: &done)

            check("A: gitlab per-provider token backfilled", kc.store[glKey] == "gl-secret", kc.store[glKey] ?? "nil")
            check("A: github per-provider token backfilled", kc.store[ghKey] == "gh-secret")
            check("A: legacy gitlab_token deleted", kc.store[LegacyKeychainKey.gitlabToken] == nil)
            check("A: legacy github_token deleted", kc.store[LegacyKeychainKey.githubToken] == nil)
            check("A: orphan legacy bitbucket key deleted", kc.store[LegacyKeychainKey.bitbucketPassword] == nil)
            check("A: flag set after one run", done)

            // Second run must NOT read anything (reads are what prompt).
            let readsBefore = kc.reads
            cleanup(kc: kc, providerKeyByKind: entries.map { ($0.0, $0.1) }, doneFlag: &done)
            check("A: second run is a no-op (no Keychain reads)", kc.reads == readsBefore,
                  "reads went \(readsBefore) → \(kc.reads)")
        }

        // ---- Scenario B: already-healthy — per-provider tokens present, no legacy keys.
        do {
            let kc = FakeKeychain()
            kc.store[glKey] = "gl-live"
            kc.store[ghKey] = "gh-live"
            var done = false
            cleanup(kc: kc, providerKeyByKind: entries.map { ($0.0, $0.1) }, doneFlag: &done)
            check("B: existing tokens untouched (gitlab)", kc.store[glKey] == "gl-live")
            check("B: existing tokens untouched (github)", kc.store[ghKey] == "gh-live")
            check("B: no deletes when no legacy keys exist", kc.deletes == 0)
            check("B: flag still set", done)
        }

        // ---- Scenario C: unrecoverable — token empty AND no legacy key. Not fatal.
        do {
            let kc = FakeKeychain()
            var done = false
            cleanup(kc: kc, providerKeyByKind: [(.gitlab, glKey)], doneFlag: &done)
            check("C: provider left with empty token (no crash, no phantom value)", (kc.store[glKey] ?? "").isEmpty)
            check("C: flag set even when nothing to recover (no perpetual re-prompt)", done)
        }

        // ---- Scenario D: legacy key deletion is unconditional even if backfill is skipped.
        do {
            let kc = FakeKeychain()
            kc.store[glKey] = "gl-live"                                  // token already present → backfill skipped
            kc.store[LegacyKeychainKey.gitlabToken] = "gl-stale-legacy"  // but stale legacy lingers
            var done = false
            cleanup(kc: kc, providerKeyByKind: [(.gitlab, glKey)], doneFlag: &done)
            check("D: stale legacy key deleted even when per-provider token already set",
                  kc.store[LegacyKeychainKey.gitlabToken] == nil)
            check("D: live per-provider token preserved", kc.store[glKey] == "gl-live")
        }

        print()
        if failures == 0 { print("Legacy-Keychain cleanup test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }
}
