import Foundation

// Where a repo row lives on disk: its provider's folder + the provider-local
// rel. Pure and Sendable so both the main-actor UI and the off-actor trasher
// resolve paths the same way, and so the fallback below can be tested.
//
// ORDERING HAZARD, and the reason this is its own type: the fallback for a
// providerID that matches no configured provider is the legacy sync root, which
// is a DIFFERENT folder from wherever that provider's repos actually were. So
// anything that acts on a provider's files must resolve the paths while the
// provider is still configured. Removing the provider first and resolving
// afterwards silently retargets every path at ~/git/<rel> — a folder that
// belongs to something else, or to nothing. See RepoTrasher's allowedRoots,
// which permits the legacy root and so would NOT catch the mistake.
// What removing a provider would affect. Shown in the confirmation sheet so the
// two consequences are stated separately: the inventory rows always go, the
// cloned folders only if the user asks.
struct ProviderRemovalImpact: Equatable {
    let repoCount: Int
    let clonedCount: Int
    let localPath: String
}

enum RepoPathResolver {
    static func path(for id: RepoID,
                     providerRoots: [String: String],
                     legacyRoot: String) -> URL {
        if let root = providerRoots[id.providerID] {
            return URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(id.rel)
        }
        // Legacy fallback: syncRoot + rel (rel here may still include the
        // platform dir, for rows that predate the provider model).
        return URL(fileURLWithPath: legacyRoot, isDirectory: true)
            .appendingPathComponent(id.rel)
    }

    // Does this row resolve through a configured provider, or only through the
    // legacy fallback? Callers that are about to touch files use this to refuse
    // rather than act on a guessed path.
    static func resolvesToProvider(_ id: RepoID, providerRoots: [String: String]) -> Bool {
        providerRoots[id.providerID] != nil
    }
}
