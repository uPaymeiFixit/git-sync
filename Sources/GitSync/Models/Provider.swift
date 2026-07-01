import Foundation

// The legacy (pre-provider) single-per-kind Keychain account names. The single
// source of truth shared by SettingsStore (which wrote them) and ProviderStore
// (which migrates from them). Keeping them here prevents the wrong-key drift
// that silently dropped tokens during the first provider migration.
enum LegacyKeychainKey {
    static let githubToken       = "github_token"
    static let gitlabToken       = "gitlab_token"
    static let bitbucketPassword = "bitbucket_app_password"

    static func forKind(_ kind: ProviderKind) -> String {
        switch kind {
        case .gitlab:    return gitlabToken
        case .github:    return githubToken
        case .bitbucket: return bitbucketPassword
        }
    }
}

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

    // The scope field's user-facing label, which differs per dialect. GitLab
    // has no scope field in the UI (discovery can't be narrowed to a group),
    // so its label is unused — kept only for switch exhaustiveness.
    var scopeLabel: String {
        switch self {
        case .gitlab: return "Group"
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

    // ---- Credential guidance -----------------------------------------
    // What kind of secret each platform actually wants, where to create it,
    // and which scopes to grant. The old UI labelled every secret the same
    // ("App password") which steered Bitbucket users toward their account
    // password (which the API has never accepted) and is being sunset anyway
    // in favour of API tokens.

    // The label for the secret field (what the user is pasting in).
    var credentialLabel: String {
        switch self {
        case .gitlab:    return "Personal access token"
        case .github:    return "Personal access token"
        case .bitbucket: return "API token"
        }
    }

    // One-line guidance shown under the secret field: what to use and the
    // scopes it needs. Bitbucket explicitly warns off the account password.
    var credentialHelp: String {
        switch self {
        case .gitlab:
            return "A GitLab personal access token with the read_api and read_repository scopes. Not your account password."
        case .github:
            return "A GitHub token. Classic: the repo scope. Fine-grained: Contents → Read and Metadata → Read. Not your account password."
        case .bitbucket:
            return "An Atlassian API token created with “Create API token with scopes” (NOT the plain “Create API token” — that one has no scopes and 401s). Select Bitbucket and grant read:repository:bitbucket + read:workspace:bitbucket. Not your account password."
        }
    }

    // Where to create the credential. Opened by the link button next to the
    // secret field. nil = host-specific (GitLab), filled in by the view.
    var credentialURL: URL? {
        switch self {
        case .gitlab:    return nil   // https://<host>/-/user_settings/personal_access_tokens
        case .github:    return URL(string: "https://github.com/settings/tokens")
        case .bitbucket: return URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")
        }
    }
}

struct Provider: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var kind: ProviderKind
    var name: String           // user label, e.g. "Work GitLab"
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

    // Comma-separated repo names / path-prefixes to skip, matched against this
    // provider's platform-native namespace path (case-insensitive). Per-provider
    // so a pattern meant for one source can't accidentally match another's repos.
    var skipPatterns: String

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
        filterMode: FilterMode = .syncAll,
        skipPatterns: String = ""
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
        self.skipPatterns = skipPatterns
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, enabled, host, scope, bitbucketUser
        case includeArchived, localPath, filterMode, skipPatterns
    }

    // Custom decode so providers persisted before `skipPatterns` existed still
    // load (synthesized Codable would reject the missing key). Everything else
    // is required — those keys have always been written. `encode` stays
    // synthesized (writes all keys including skipPatterns).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        kind            = try c.decode(ProviderKind.self, forKey: .kind)
        name            = try c.decode(String.self, forKey: .name)
        enabled         = try c.decode(Bool.self, forKey: .enabled)
        host            = try c.decode(String.self, forKey: .host)
        scope           = try c.decode(String.self, forKey: .scope)
        bitbucketUser   = try c.decode(String.self, forKey: .bitbucketUser)
        includeArchived = try c.decode(Bool.self, forKey: .includeArchived)
        localPath       = try c.decode(String.self, forKey: .localPath)
        filterMode      = try c.decode(FilterMode.self, forKey: .filterMode)
        skipPatterns    = try c.decodeIfPresent(String.self, forKey: .skipPatterns) ?? ""
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
