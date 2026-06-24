import Foundation

// The per-run config the native engine consumes. The environment dict carries
// the GIT_SYNC_* variables from the Settings window (GIT_SYNC_ROOT, depth,
// timeout, parallel) plus the inherited process env (HOME etc.); `providers`
// carries the configured sync sources + their resolved secrets.
struct SyncSettings: Sendable {
    var environment: [String: String]

    // The configured providers + their resolved secrets, snapshotted at run
    // start. The engine iterates THIS — each provider is an independent sync
    // source with its own host/scope/token/folder/skip patterns.
    var providers: [ResolvedProvider] = []
}

// A Provider plus its Keychain-resolved token + tracked set, ready to hand to
// the engine. Sendable so it can cross the actor boundary into SyncEngine.
struct ResolvedProvider: Sendable {
    var provider: Provider
    var token: String          // resolved from Keychain at snapshot time
    var trackedRels: [String]  // tracked rels (whitelist mode), from the inventory
}

// How a platform decides which discovered repos to actually clone/sync.
//   .syncAll      — sync everything except GIT_SYNC_SKIP matches (the default;
//                   the original behavior).
//   .trackedOnly  — whitelist: sync ONLY repos the user has explicitly tracked
//                   (Repo.isTracked). Discovery still lists everything so the
//                   inventory stays browseable, but only tracked repos clone.
enum FilterMode: String, CaseIterable, Sendable, Codable {
    case syncAll
    case trackedOnly

    var displayName: String {
        switch self {
        case .syncAll:     return "Sync all repositories"
        case .trackedOnly: return "Only tracked repositories"
        }
    }
}

enum Platform: String, CaseIterable, Sendable {
    case gitlab, bitbucket, github

    var displayName: String { rawValue }

    // Human-facing, capitalized form for UI labels (e.g. "GitLab"). Kept
    // separate from displayName so nothing that keys off the lowercase
    // rawValue breaks.
    var titleName: String {
        switch self {
        case .gitlab:    return "GitLab"
        case .bitbucket: return "Bitbucket"
        case .github:    return "GitHub"
        }
    }
}
