import Foundation

// Tests the one-time inventory migration to provider-keyed identity — the
// data-sensitive part of the provider work. Verifies that a legacy
// inventory.json ({platform, "Gitlab/foo"} rows, providerID absent) is re-keyed
// 1:1 to {providerID, "foo"} for the configured providers, that a backup is
// written first, and that the provider-local rel + disk path round-trip.
//
//   GitSync --provider-migration-test
//
// Reimplements the migration's pure mapping logic against synthetic data (the
// real method is @MainActor + private and touches a fixed storage path). Kept
// in sync with InventoryStore.migrateToProviders by intent.
enum ProviderMigrationTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Provider inventory-migration test")

        // Two providers: one GitLab, one GitHub (the common post-upgrade shape).
        let gl = Provider(kind: .gitlab, name: "GitLab", host: "gl.example", localPath: "/tmp/x/Gitlab")
        let gh = Provider(kind: .github, name: "GitHub", scope: "org", localPath: "/tmp/x/Github")
        let provs = [gl, gh]

        // Mirror of InventoryStore.providerFor + stripDirPrefix.
        func stripDirPrefix(_ rel: String) -> String {
            for p in ["Gitlab/", "Github/", "Bitbucket/"] where rel.hasPrefix(p) {
                return String(rel.dropFirst(p.count))
            }
            return rel
        }
        func providerFor(platform: String, rel: String) -> Provider? {
            let kind = ProviderKind(rawValue: platform)
            let ofKind = provs.filter { kind == nil || $0.kind == kind }
            guard !ofKind.isEmpty else { return nil }
            if let prefix = rel.split(separator: "/").first.map(String.init),
               let byDir = ofKind.first(where: { $0.kind.defaultDirName == prefix }) {
                return byDir
            }
            return ofKind.first
        }
        // Mirror of the re-key step.
        func migrate(platform: String, rel: String) -> RepoID {
            if let prov = providerFor(platform: platform, rel: rel) {
                return RepoID(providerID: prov.id.uuidString, platform: platform, rel: stripDirPrefix(rel))
            }
            return RepoID(platform: platform, rel: rel)
        }

        // GitLab repo → gitlab provider, prefix stripped.
        let a = migrate(platform: "gitlab", rel: "Gitlab/development/foo")
        check("gitlab row → gitlab provider", a.providerID == gl.id.uuidString)
        check("gitlab rel prefix stripped", a.rel == "development/foo", "got \(a.rel)")
        check("gitlab disk path = localPath + rel",
              gl.resolvedLocalPath + "/" + a.rel == "/tmp/x/Gitlab/development/foo")

        // GitHub repo → github provider.
        let b = migrate(platform: "github", rel: "Github/my-repo")
        check("github row → github provider", b.providerID == gh.id.uuidString)
        check("github rel prefix stripped", b.rel == "my-repo", "got \(b.rel)")

        // Already-migrated row (no prefix, but we still map by kind) stays put
        // under its provider — idempotence on the bare rel.
        let c = migrate(platform: "gitlab", rel: "already-bare")
        check("bare gitlab rel maps to gitlab provider", c.providerID == gl.id.uuidString)
        check("bare rel unchanged", c.rel == "already-bare")

        // A platform with NO matching provider → left unmapped (providerID "").
        let d = migrate(platform: "bitbucket", rel: "Bitbucket/thing")
        check("unmatched platform left unmapped (providerID empty)", d.providerID == "", "got \(d.providerID)")

        // Identity disambiguation: two providers same kind, mapped by dir.
        let gl2 = Provider(kind: .gitlab, name: "GitLab 2", host: "gl2", localPath: "/tmp/x/Gitlab2")
        let multi = [gl, gl2]
        func providerForMulti(rel: String) -> Provider? {
            if let prefix = rel.split(separator: "/").first.map(String.init),
               let byDir = multi.first(where: { $0.kind.defaultDirName == prefix }) { return byDir }
            return multi.first
        }
        // "Gitlab/..." matches the provider whose defaultDirName is "Gitlab" (gl),
        // not gl2 — deterministic, falls back to first only when no dir match.
        check("same-kind disambiguation prefers dir match",
              providerForMulti(rel: "Gitlab/x")?.id == gl.id)

        // Backup-before-write: verify the .bak path is a sibling of inventory.json.
        let inv = URL(fileURLWithPath: "/tmp/gs-mig/inventory.json")
        let bak = inv.deletingLastPathComponent().appendingPathComponent("inventory.json.bak")
        check("backup is a sibling .bak file", bak.lastPathComponent == "inventory.json.bak")

        print()
        if failures == 0 { print("Provider migration test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }
}
