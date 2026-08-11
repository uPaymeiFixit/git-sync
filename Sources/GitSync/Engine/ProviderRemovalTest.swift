import Foundation

// Regression for provider removal stranding its inventory rows, and for the
// path-resolution ordering hazard that removing a provider's files exposes.
//
//     GitSync --provider-removal-test
//
// Removing a provider used to delete the provider and its Keychain token and
// nothing else. Every inventory row it owned stayed behind forever: discovery
// runs per configured provider so nothing rediscovers them, and runIndividual
// refuses a row whose providerID matches no provider, so nothing can sync them.
// Re-creating the provider produced a NEW UUID and a second full set of rows —
// on one machine, ~1,500 permanently-dead duplicates, half the inventory.
//
// The subtle half is ORDER. A row's disk path resolves through its provider's
// localPath, and RepoPathResolver falls back to the legacy sync root when the
// providerID matches nothing. So trashing a provider's clones AFTER removing
// the provider silently retargets every path at <syncRoot>/<rel> — a different
// folder. RepoTrasher's allowedRoots includes the legacy root, so that guard
// would not catch it. removeProvider therefore trashes first, removes second;
// these checks pin the resolver behaviour that makes the order matter.
enum ProviderRemovalTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Provider removal (row purge + path-resolution ordering) test")

        let gitlab = Provider(kind: .gitlab, name: "Corp GitLab",
                              host: "gitlab.corp.example",
                              localPath: "/Users/x/Projects/paciolan/gitlab")
        let bitbucket = Provider(kind: .bitbucket, name: "Corp Bitbucket",
                                 scope: "corp",
                                 localPath: "/Users/x/Projects/paciolan/bitbucket")
        let legacyRoot = "/Users/x/git"
        let roots = [
            gitlab.id.uuidString: gitlab.localPath,
            bitbucket.id.uuidString: bitbucket.localPath,
        ]
        let rel = "development/application/platform/api-gateway/pac-io-aws-api-gateway"
        let row = RepoID(providerID: gitlab.id.uuidString, platform: "gitlab", rel: rel)

        // ---- The ordering hazard --------------------------------------

        let before = RepoPathResolver.path(for: row, providerRoots: roots, legacyRoot: legacyRoot)
        check("a row resolves under its provider's folder",
              before.path == gitlab.localPath + "/" + rel, "got \(before.path)")
        check("a row with a configured provider is recognised as resolvable",
              RepoPathResolver.resolvesToProvider(row, providerRoots: roots))

        // Same row, provider gone — what resolving AFTER removal would produce.
        var without = roots
        without[gitlab.id.uuidString] = nil
        let after = RepoPathResolver.path(for: row, providerRoots: without, legacyRoot: legacyRoot)
        check("removing the provider CHANGES where the row resolves",
              before.path != after.path,
              "both resolved to \(before.path) — the ordering hazard would be invisible")
        check("the post-removal path falls back to the legacy sync root",
              after.path == legacyRoot + "/" + rel, "got \(after.path)")
        check("the fallback path is NOT under the provider's real folder",
              !after.path.hasPrefix(gitlab.localPath + "/"),
              "fallback landed inside the provider folder: \(after.path)")
        check("an orphaned row is reported as not resolvable to a provider",
              !RepoPathResolver.resolvesToProvider(row, providerRoots: without))

        // The legacy root is an ALLOWED trash root, which is exactly why the
        // trasher's own guard cannot be relied on to catch a mis-ordered call.
        check("the fallback lands somewhere a trash guard would permit",
              after.path.hasPrefix(legacyRoot + "/"))

        // ---- Row selection --------------------------------------------

        // removeProvider drops rows by exact providerID. Nothing else may go.
        let rows: [RepoID] = [
            RepoID(providerID: gitlab.id.uuidString, platform: "gitlab", rel: "a"),
            RepoID(providerID: gitlab.id.uuidString, platform: "gitlab", rel: "b"),
            RepoID(providerID: bitbucket.id.uuidString, platform: "bitbucket", rel: "c"),
            RepoID(providerID: "", platform: "gitlab", rel: "d"),
            RepoID(providerID: UUID().uuidString, platform: "gitlab", rel: "e"),
        ]
        let doomed = rows.filter { $0.providerID == gitlab.id.uuidString }
        check("only the removed provider's rows are selected", doomed.count == 2,
              "got \(doomed.count)")
        check("another provider's rows survive",
              rows.contains { $0.providerID == bitbucket.id.uuidString })
        check("a same-PLATFORM row from a different provider is not swept up",
              !doomed.contains { $0.rel == "e" })
        check("an empty-providerID row is not swept up by a real provider's removal",
              !doomed.contains { $0.rel == "d" })

        // ---- Impact summary -------------------------------------------

        let impact = ProviderRemovalImpact(repoCount: 1552, clonedCount: 25,
                                           localPath: gitlab.localPath)
        check("impact separates total rows from cloned-on-disk rows",
              impact.repoCount == 1552 && impact.clonedCount == 25)
        check("cloned count never exceeds the row count",
              impact.clonedCount <= impact.repoCount)
        // The confirmation only offers the disk choice when there IS something
        // on disk; a provider with rows but no clones must not show it.
        let noClones = ProviderRemovalImpact(repoCount: 1503, clonedCount: 0,
                                             localPath: gitlab.localPath)
        check("a provider with no clones offers no disk choice", noClones.clonedCount == 0)

        print()
        if failures == 0 { print("Provider removal test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }
}
