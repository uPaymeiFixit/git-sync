import Foundation
import SwiftUI

// The configured providers, persisted as JSON in UserDefaults. Replaces the
// old fixed gitlab/github/bitbucket fields on SettingsStore as the source of
// truth for "what to sync." Tokens live in Keychain (per-provider key).
//
// On first run after upgrade, migrateFromLegacyIfNeeded() turns the user's
// existing single-provider-per-kind config into Provider instances so nothing
// changes for them.

@MainActor
final class ProviderStore: ObservableObject {
    @Published private(set) var providers: [Provider] = []

    private let defaultsKey = "providersV1"
    private let migratedKey = "providersMigratedFromLegacy"
    private let skipMigratedKey = "providersSkipMigratedFromGlobal"
    private let legacyCleanupKey = "providersLegacyKeychainCleanedUp"

    init() {
        load()
        migrateFromLegacyIfNeeded()
        migrateGlobalSkipIfNeeded()
        cleanUpLegacyKeychainIfNeeded()
    }

    // ---- CRUD --------------------------------------------------------

    func provider(id: UUID) -> Provider? { providers.first { $0.id == id } }

    @discardableResult
    func upsert(_ provider: Provider) -> ProviderValidation {
        let validation = validate(provider, existing: providers.filter { $0.id != provider.id })
        guard validation.isValid else { return validation }
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx] = provider
        } else {
            providers.append(provider)
        }
        save()
        return validation
    }

    func setToken(_ token: String, for provider: Provider) {
        Keychain.set(token, for: provider.tokenKeychainKey)
    }
    func token(for provider: Provider) -> String {
        Keychain.get(provider.tokenKeychainKey) ?? ""
    }

    func remove(id: UUID) {
        guard let p = providers.first(where: { $0.id == id }) else { return }
        Keychain.set(nil, for: p.tokenKeychainKey)   // clear the secret too
        providers.removeAll { $0.id == id }
        save()
    }

    func setFilterMode(_ mode: FilterMode, providerID: UUID) {
        guard let idx = providers.firstIndex(where: { $0.id == providerID }) else { return }
        providers[idx].filterMode = mode
        save()
    }

    // Append a skip pattern (case-insensitive, comma-separated) to the provider
    // the repo belongs to — the engine reads THIS (per-provider) list, so this
    // is what actually affects sync behavior. No-op if the pattern is already
    // present or the provider can't be found (e.g. an un-migrated row).
    func addSkipPattern(_ pattern: String, providerID: UUID) {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, let idx = providers.firstIndex(where: { $0.id == providerID }) else { return }
        guard !skipEntries(providers[idx].skipPatterns).contains(p.lowercased()) else { return }
        let existing = providers[idx].skipPatterns.trimmingCharacters(in: .whitespacesAndNewlines)
        providers[idx].skipPatterns = existing.isEmpty ? p : existing + ", " + p
        save()
    }

    // Is `namespacePath` already skipped by its provider's patterns? Mirrors the
    // engine's SkipMatcher (case-insensitive prefix match).
    func isSkipped(namespacePath: String, providerID: UUID) -> Bool {
        guard let p = providers.first(where: { $0.id == providerID }) else { return false }
        let path = namespacePath.lowercased()
        return skipEntries(p.skipPatterns).contains { path.hasPrefix($0) }
    }

    private func skipEntries(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    var enabledProviders: [Provider] { providers.filter { $0.enabled && $0.isConfigured } }

    var isConfigured: Bool { !enabledProviders.isEmpty }

    // The distinct platform kinds among enabled, configured providers. The
    // scheduler dedup-keys per Platform (lastSuccessByPlatform, startRun(only:)),
    // so two enabled providers of the same kind collapse to one platform here.
    var enabledPlatforms: [Platform] {
        var seen = Set<Platform>()
        var out: [Platform] = []
        for p in enabledProviders {
            guard let plat = Platform(rawValue: p.kind.rawValue) else { continue }
            if seen.insert(plat).inserted { out.append(plat) }
        }
        return out
    }

    // ---- Validation (the dangerous-corner guard) ---------------------

    struct ProviderValidation {
        var pathError: String?
        var nameError: String?
        var isValid: Bool { pathError == nil && nameError == nil }
        static let ok = ProviderValidation()
    }

    // A provider's localPath must not be empty, must not equal, contain, or be
    // contained by another provider's path — overlapping paths let two
    // providers clobber each other on disk and in the inventory. This is THE
    // data-safety check for the provider model.
    func validate(_ p: Provider, existing: [Provider]? = nil) -> ProviderValidation {
        var v = ProviderValidation()
        let others = existing ?? providers.filter { $0.id != p.id }

        let path = p.resolvedLocalPath.trimmingCharacters(in: .whitespaces)
        if path.isEmpty {
            v.pathError = "Choose a folder for this provider's repos."
        } else {
            let norm = Self.normalize(path)
            for other in others {
                let otherNorm = Self.normalize(other.resolvedLocalPath)
                if norm == otherNorm {
                    v.pathError = "Same folder as \"\(other.name)\". Each provider needs its own folder."
                    break
                }
                if Self.isAncestor(norm, of: otherNorm) || Self.isAncestor(otherNorm, of: norm) {
                    v.pathError = "Folder overlaps \"\(other.name)\" (\(other.localPath)). Pick a non-nested folder."
                    break
                }
            }
        }
        if p.name.trimmingCharacters(in: .whitespaces).isEmpty {
            v.nameError = "Give this provider a name."
        }
        return v
    }

    private static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = (p as NSString).standardizingPath
        // Resolve symlinks too, so two providers pointing at the same physical
        // folder through a symlink are caught as a collision (best-effort:
        // resolvingSymlinksInPath only resolves components that exist on disk).
        p = (p as NSString).resolvingSymlinksInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
    // Is `a` an ancestor directory of `b`? (Path-segment aware so /a/b is NOT
    // an ancestor of /a/bc.)
    private static func isAncestor(_ a: String, of b: String) -> Bool {
        guard a != b else { return false }
        return b.hasPrefix(a + "/")
    }

    // ---- Persistence -------------------------------------------------

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        if let decoded = try? JSONDecoder().decode([Provider].self, from: data) {
            providers = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // ---- Legacy migration --------------------------------------------

    // Turn the user's existing fixed gitlab/github/bitbucket config (the old
    // SettingsStore fields, still in UserDefaults + Keychain) into Provider
    // instances. Runs once. A 1:1 map for the single-provider-per-kind world
    // that existed before this feature, so nothing changes for existing users.
    private func migrateFromLegacyIfNeeded() {
        let d = UserDefaults.standard
        // NOTE: the every-launch backfill call that used to live here was the
        // cause of the "three password prompts on every relaunch" bug — it read
        // the legacy Keychain keys on every launch, and each rebuild's new code
        // signature re-triggered the login-keychain ACL prompt. The backfill +
        // legacy-key repair is now a ONE-TIME, gated step in
        // cleanUpLegacyKeychainIfNeeded() (called once, flag-guarded), which
        // also DELETES the legacy keys so they can never prompt again.

        // Already migrated, or the user already has providers → nothing to do.
        guard !d.bool(forKey: migratedKey) else { return }
        guard providers.isEmpty else { d.set(true, forKey: migratedKey); return }

        let syncRoot = d.string(forKey: "syncRoot") ?? "\(NSHomeDirectory())/git"
        func path(_ dir: String) -> String { (syncRoot as NSString).appendingPathComponent(dir) }
        func mode(_ key: String) -> FilterMode {
            FilterMode(rawValue: (d.dictionary(forKey: "filterModeByPlatform") as? [String: String])?[key] ?? "") ?? .syncAll
        }

        var migrated: [Provider] = []

        let glHost = d.string(forKey: "gitlabHost") ?? ""
        if !glHost.isEmpty {
            let p = Provider(kind: .gitlab, name: "GitLab",
                             enabled: !d.bool(forKey: "skipGitlab"),
                             host: glHost, scope: "",
                             includeArchived: d.bool(forKey: "includeArchived"),
                             localPath: path("Gitlab"), filterMode: mode("gitlab"))
            if let tok = Keychain.get(LegacyKeychainKey.gitlabToken), !tok.isEmpty { Keychain.set(tok, for: p.tokenKeychainKey) }
            migrated.append(p)
        }
        let ghOrg = d.string(forKey: "githubOrg") ?? ""
        if !ghOrg.isEmpty {
            let p = Provider(kind: .github, name: "GitHub",
                             enabled: !d.bool(forKey: "skipGithub"),
                             host: "github.com", scope: ghOrg,
                             includeArchived: d.bool(forKey: "includeArchived"),
                             localPath: path("Github"), filterMode: mode("github"))
            if let tok = Keychain.get(LegacyKeychainKey.githubToken), !tok.isEmpty { Keychain.set(tok, for: p.tokenKeychainKey) }
            migrated.append(p)
        }
        let bbWs = d.string(forKey: "bitbucketWorkspace") ?? ""
        if !bbWs.isEmpty {
            let p = Provider(kind: .bitbucket, name: "Bitbucket",
                             enabled: !d.bool(forKey: "skipBitbucket"),
                             host: "bitbucket.org", scope: bbWs,
                             bitbucketUser: d.string(forKey: "bitbucketUser") ?? "",
                             localPath: path("Bitbucket"), filterMode: mode("bitbucket"))
            if let tok = Keychain.get(LegacyKeychainKey.bitbucketPassword), !tok.isEmpty { Keychain.set(tok, for: p.tokenKeychainKey) }
            migrated.append(p)
        }

        providers = migrated
        save()
        d.set(true, forKey: migratedKey)
        // Tokens are copied into the just-created providers (and the legacy keys
        // then deleted) by cleanUpLegacyKeychainIfNeeded(), which init() calls
        // right after this — no separate backfill needed here.
    }

    // Skip patterns used to be one global GIT_SYNC_SKIP list shared by every
    // platform; they're now per-provider. Seed each provider's skipPatterns
    // from that global list ONCE so existing users keep their skips. Runs after
    // the provider migration (so providers exist) and only if a provider hasn't
    // already got its own patterns. The global key stays in UserDefaults only
    // as the migration source.
    private func migrateGlobalSkipIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: skipMigratedKey) else { return }
        let global = (d.string(forKey: "skipPatterns") ?? "").trimmingCharacters(in: .whitespaces)
        if !global.isEmpty {
            for i in providers.indices where providers[i].skipPatterns.trimmingCharacters(in: .whitespaces).isEmpty {
                providers[i].skipPatterns = global
            }
            save()
        }
        d.set(true, forKey: skipMigratedKey)
    }

    // ONE-TIME legacy-Keychain cleanup. This replaces the old every-launch
    // backfillMissingTokens(), which caused THREE password prompts on every
    // relaunch: it read the legacy single-per-kind keys (gitlab_token /
    // github_token / bitbucket_app_password) on each launch, and every rebuild's
    // new code signature re-triggered the login-keychain ACL prompt for each.
    //
    // This runs once (flag-guarded), and does two things:
    //   1. BACKFILL: for any provider whose per-provider token is empty, copy the
    //      value from its legacy key — the repair for users whose migration
    //      didn't copy tokens due to the old wrong-key bug.
    //   2. DELETE the legacy keys afterward, so they can never be read (or
    //      prompted for) again. The per-provider items are the sole source of
    //      truth after this.
    //
    // Setting the flag unconditionally after one sweep is correct: any legacy key
    // that still holds a value we couldn't place (no matching provider) is
    // deleted too — it's dead data from a pre-provider config, and keeping it
    // around only risks another prompt. A provider left with an empty token after
    // this simply has no credential and the user re-enters it in Settings (the
    // Test Connection flow now makes that obvious).
    private func cleanUpLegacyKeychainIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: legacyCleanupKey) else { return }

        // 1. Backfill empty per-provider tokens from the matching legacy key.
        for p in providers where token(for: p).isEmpty {
            if let tok = Keychain.get(LegacyKeychainKey.forKind(p.kind)), !tok.isEmpty {
                Keychain.set(tok, for: p.tokenKeychainKey)
            }
        }

        // 2. Delete ALL legacy keys — their values are now either copied into a
        //    per-provider item or genuinely orphaned. Either way they must not
        //    linger and prompt. Keychain.set(nil,) deletes.
        for key in [LegacyKeychainKey.gitlabToken,
                    LegacyKeychainKey.githubToken,
                    LegacyKeychainKey.bitbucketPassword] {
            Keychain.set(nil, for: key)
        }

        d.set(true, forKey: legacyCleanupKey)
    }
}
