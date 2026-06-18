import Foundation

// A configured sync source. Decouples the platform TYPE (which API dialect
// to speak — `kind`) from a specific INSTANCE (this host + this token + this
// scope + this disk folder). That's what lets a user have, say, two GitLab
// providers (corporate + gitlab.com), or GitHub Enterprise alongside
// github.com — each an independent Provider with its own identity, folder,
// schedule, and filter mode.
//
// Replaces the old fixed 3-platform model. On upgrade, the user's existing
// gitlab/github/bitbucket config migrates to three default Provider instances
// (see ProviderStore.migrateFromLegacyIfNeeded).

enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case gitlab, github, bitbucket

    var titleName: String {
        switch self {
        case .gitlab: return "GitLab"
        case .github: return "GitHub"
        case .bitbucket: return "Bitbucket"
        }
    }

    // The scope field's user-facing label, which differs per dialect.
    var scopeLabel: String {
        switch self {
        case .gitlab: return "Group (optional)"   // empty = all accessible projects
        case .github: return "Organization"
        case .bitbucket: return "Workspace"
        }
    }

    // The conventional folder name a fresh provider of this kind defaults to.
    var defaultDirName: String {
        switch self {
        case .gitlab: return "Gitlab"
        case .github: return "Github"
        case .bitbucket: return "Bitbucket"
        }
    }
}

struct Provider: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var kind: ProviderKind
    var name: String           // user label, e.g. "Paciolan GitLab"
    var enabled: Bool

    // Connection. `host` is meaningful for GitLab (the instance host) and is
    // also kept for GitHub/Bitbucket where the API host is fixed but a future
    // Enterprise/self-hosted variant could use it.
    var host: String
    var scope: String          // gitlab group (optional) / github org / bitbucket workspace
    var bitbucketUser: String  // bitbucket only (basic-auth username)
    var includeArchived: Bool

    // Where this provider's repos are cloned. ABSOLUTE or ~-relative. Each
    // provider MUST resolve to a non-overlapping path (validated in
    // ProviderStore) — overlapping paths would let two providers clobber each
    // other on disk and in the inventory.
    var localPath: String

    var filterMode: FilterMode

    // Keychain account for this provider's secret token/app-password.
    var tokenKeychainKey: String { "provider.\(id.uuidString).token" }

    var resolvedLocalPath: String {
        (localPath as NSString).expandingTildeInPath
    }

    init(
        id: UUID = UUID(),
        kind: ProviderKind,
        name: String,
        enabled: Bool = true,
        host: String = "",
        scope: String = "",
        bitbucketUser: String = "",
        includeArchived: Bool = false,
        localPath: String,
        filterMode: FilterMode = .syncAll
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.enabled = enabled
        self.host = host
        self.scope = scope
        self.bitbucketUser = bitbucketUser
        self.includeArchived = includeArchived
        self.localPath = localPath
        self.filterMode = filterMode
    }

    // "Configured enough to attempt discovery." Per-kind required field.
    var isConfigured: Bool {
        switch kind {
        case .gitlab:    return !host.isEmpty
        case .github:    return !scope.isEmpty
        case .bitbucket: return !scope.isEmpty
        }
    }
}
