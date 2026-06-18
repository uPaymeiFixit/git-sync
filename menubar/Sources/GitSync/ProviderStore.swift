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

    init() {
        load()
        migrateFromLegacyIfNeeded()
        migrateGlobalSkipIfNeeded()
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

    var enabledProviders: [Provider] { providers.filter { $0.enabled && $0.isConfigured } }

    var isConfigured: Bool { !enabledProviders.isEmpty }

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
        // Even if the initial migration already ran, BACKFILL any provider
        // whose per-provider token is empty from the (correctly-named) legacy
        // key — repairs the wrong-key bug for users already migrated.
        backfillMissingTokens()

        // Already migrated, or the user already has providers → nothing to do.
        guard !d.bool(forKey: migratedKey) else { return }
        guard providers.isEmpty else { d.set(true, forKey: migratedKey); return }

        let syncRoot = d.string(forKey: "syncRoot") ?? "\(NSHomeDirectory())/git/Paciolan"
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
        backfillMissingTokens()   // copy tokens into the just-created providers
    }

    // Skip patterns used to be one global GIT_SYNC_SKIP list shared by every
    // platform; they're now per-provider. Seed each provider's skipPatterns
    // from that global list ONCE so existing users keep their skips. Runs after
    // the provider migration (so providers exist) and only if a provider hasn't
    // already got its own patterns. The global key stays in UserDefaults for
    // the legacy Python/no-providers fallback.
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

    // For each provider with an empty per-provider token, copy from the legacy
    // single-per-kind Keychain key. Idempotent + safe to run every launch:
    // does nothing once a provider has its own token. This is what repairs the
    // already-migrated user whose tokens didn't copy due to the wrong-key bug.
    private func backfillMissingTokens() {
        for p in providers where token(for: p).isEmpty {
            if let tok = Keychain.get(LegacyKeychainKey.forKind(p.kind)), !tok.isEmpty {
                Keychain.set(tok, for: p.tokenKeychainKey)
            }
        }
    }
}
