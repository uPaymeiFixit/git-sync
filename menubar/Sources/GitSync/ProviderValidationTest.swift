import Foundation

// Tests the provider disk-path collision validation — THE data-safety guard
// for the (in-progress) provider model. Two providers must never resolve to
// the same, nested, or containing folder, or their repos clobber each other
// on disk and in the inventory.
//
//   GitSync --provider-validation-test
//
// Reimplements ProviderStore's normalize/isAncestor/validate logic against
// fixed paths (the real methods are @MainActor + private; this mirrors them
// so the rules are pinned by a test). Kept in sync by intent.
enum ProviderValidationTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Provider path-collision validation test")

        func normalize(_ path: String) -> String {
            var p = (path as NSString).expandingTildeInPath
            p = (p as NSString).standardizingPath
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            return p
        }
        func isAncestor(_ a: String, of b: String) -> Bool {
            guard a != b else { return false }
            return b.hasPrefix(a + "/")
        }
        // Mirror of ProviderStore.validate's path logic: is `p` ok against `others`?
        func pathConflict(_ p: String, _ others: [String]) -> Bool {
            let norm = normalize(p)
            if norm.isEmpty { return true }
            for o in others {
                let on = normalize(o)
                if norm == on { return true }
                if isAncestor(norm, of: on) || isAncestor(on, of: norm) { return true }
            }
            return false
        }

        check("distinct sibling folders OK",
              !pathConflict("/Users/me/git/A", ["/Users/me/git/B"]))
        check("identical folder conflicts",
              pathConflict("/Users/me/git/A", ["/Users/me/git/A"]))
        check("identical modulo trailing slash conflicts",
              pathConflict("/Users/me/git/A/", ["/Users/me/git/A"]))
        check("nested folder conflicts (child under existing)",
              pathConflict("/Users/me/git/A/sub", ["/Users/me/git/A"]))
        check("nested folder conflicts (existing under new)",
              pathConflict("/Users/me/git", ["/Users/me/git/A"]))
        check("sibling prefix is NOT a conflict (/A vs /AB)",
              !pathConflict("/Users/me/git/AB", ["/Users/me/git/A"]))
        check("tilde expands and conflicts with absolute equivalent",
              pathConflict("~/git/A", [(NSHomeDirectory() as NSString).appendingPathComponent("git/A")]))
        check("dot-normalization conflicts (/A/../A vs /A)",
              pathConflict("/Users/me/git/A/../A", ["/Users/me/git/A"]))
        check("empty path is a conflict (must choose a folder)",
              pathConflict("", ["/Users/me/git/A"]))
        check("multiple others, only one overlaps",
              pathConflict("/Users/me/git/A", ["/Users/me/git/B", "/Users/me/git/A", "/Users/me/git/C"]))

        print()
        if failures == 0 { print("Provider validation test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }
}
