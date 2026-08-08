import Foundation

// Regression for the Repositories filter chips being keyed by platform KIND
// instead of by provider.
//
//     GitSync --provider-filter-test
//
// The list filtered on `repo.id.platform` — a fixed three-case enum — and drew
// one chip per Platform.allCases. So two providers of the same kind (two GitHub
// orgs, corporate GitLab + gitlab.com) shared a single "github"/"gitlab" chip
// and could not be told apart or filtered separately. The row badge had the
// same defect: it rendered the kind, and `rel` is provider-local, so two rows
// for the same repo path under different providers were pixel-identical.
//
// Identity is now the provider. What that has to guarantee:
//
//   - two providers of the SAME kind produce two distinct chips
//   - chips are labelled with the provider's name, not its kind
//   - a row whose providerID matches no configured provider lands in the
//     `.unknown` bucket rather than vanishing from the list
//   - the orphan chip appears ONLY when such rows exist
//   - a provider with zero rows still gets a chip
//
// The last one matters because the filter state is stored as the HIDDEN set,
// not the shown set: a provider added while the window is open must default to
// visible. Seeding a "shown" set once (what the kind-based filter did) left any
// later-added provider silently filtered out.
enum ProviderFilterTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Provider filter (chips keyed by provider, not kind) test")

        // Two GitHub providers — the exact shape the old kind-based filter
        // collapsed into one chip — plus a GitLab so ordering is observable.
        let ghWork = Provider(kind: .github, name: "Work GitHub",
                              scope: "acme", localPath: "~/git/work")
        let ghPersonal = Provider(kind: .github, name: "Personal GitHub",
                                  scope: "me", localPath: "~/git/personal")
        let gitlab = Provider(kind: .gitlab, name: "Corp GitLab",
                              host: "gitlab.corp.example", localPath: "~/git/corp")
        let all = [ghWork, ghPersonal, gitlab]
        let configured = Set(all.map(\.id.uuidString))

        // ---- Classification ------------------------------------------

        check("a row maps to its own provider",
              ProviderFilter.key(forProviderID: ghWork.id.uuidString, configured: configured)
                == .provider(ghWork.id.uuidString))
        check("two same-kind providers classify SEPARATELY",
              ProviderFilter.key(forProviderID: ghWork.id.uuidString, configured: configured)
                != ProviderFilter.key(forProviderID: ghPersonal.id.uuidString, configured: configured))

        // The duplicate-row report: a provider that was deleted leaves rows
        // behind whose providerID resolves to nothing.
        let deleted = UUID().uuidString
        check("a row from a deleted provider is .unknown, not dropped",
              ProviderFilter.key(forProviderID: deleted, configured: configured) == .unknown)
        check("a pre-provider-model row (empty providerID) is .unknown",
              ProviderFilter.key(forProviderID: "", configured: configured) == .unknown)
        check("all orphans share ONE bucket",
              ProviderFilter.key(forProviderID: deleted, configured: configured)
                == ProviderFilter.key(forProviderID: UUID().uuidString, configured: configured))

        // ---- Chip construction ---------------------------------------

        let counts: [ProviderFilterKey: Int] = [
            .provider(ghWork.id.uuidString): 12,
            .provider(ghPersonal.id.uuidString): 3,
            // gitlab deliberately absent → a configured provider with no rows
        ]
        let chips = ProviderFilter.chips(providers: all, counts: counts)

        check("one chip per configured provider", chips.count == 3, "got \(chips.count)")
        check("a provider with zero rows still gets a chip",
              chips.contains { $0.key == .provider(gitlab.id.uuidString) && $0.count == 0 })
        check("chips are labelled by NAME, not kind",
              chips.map(\.label) == ["Work GitHub", "Personal GitHub", "Corp GitLab"],
              "got \(chips.map(\.label))")
        check("two same-kind providers yield two distinctly-labelled chips",
              Set(chips.map(\.label)).count == chips.count)
        check("chip order follows configured order",
              chips.first?.key == .provider(ghWork.id.uuidString))
        check("counts land on the right chip",
              chips.first(where: { $0.key == .provider(ghWork.id.uuidString) })?.count == 12)
        check("no orphan chip when no orphan rows exist",
              !chips.contains { $0.isOrphanBucket })

        // ---- Orphan bucket -------------------------------------------

        var withOrphans = counts
        withOrphans[.unknown] = 47
        let orphanChips = ProviderFilter.chips(providers: all, counts: withOrphans)
        check("orphan rows get their own chip", orphanChips.contains { $0.isOrphanBucket })
        check("orphan chip carries the orphan count",
              orphanChips.first(where: { $0.isOrphanBucket })?.count == 47)
        check("orphan chip sorts last (after the real providers)",
              orphanChips.last?.isOrphanBucket == true)
        check("orphan chip doesn't disturb the provider chips",
              orphanChips.filter { !$0.isOrphanBucket }.map(\.label) == chips.map(\.label))
        check("a zero orphan count still shows no chip",
              !ProviderFilter.chips(providers: all, counts: withOrphans.merging([.unknown: 0]) { _, b in b })
                  .contains { $0.isOrphanBucket })

        // ---- No providers configured ----------------------------------

        // Everything is orphaned when nothing is configured — the rows must
        // still be reachable through the unknown bucket.
        check("with no providers, every row is .unknown",
              ProviderFilter.key(forProviderID: ghWork.id.uuidString, configured: []) == .unknown)
        let onlyOrphans = ProviderFilter.chips(providers: [], counts: [.unknown: 5])
        check("with no providers, only the orphan chip shows",
              onlyOrphans.count == 1 && onlyOrphans[0].isOrphanBucket)

        // ---- Chip identity is stable ----------------------------------

        // ForEach keys off `id`; two chips must never collide or SwiftUI drops
        // rows. Same-kind providers are the case that used to collide.
        check("chip ids are unique", Set(orphanChips.map(\.id)).count == orphanChips.count)

        print()
        if failures == 0 { print("Provider filter test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }
}
