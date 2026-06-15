import Foundation
import SwiftUI

// Backing store for the Settings window. Non-secrets live in UserDefaults;
// the GitHub PAT and Bitbucket app password live in Keychain via the
// Keychain.swift wrapper.
//
// SettingsStore is the single source of truth for the env vars that get
// passed to the child sync scripts. AppState calls `currentSyncSettings`
// at the start of each run to build the env dict.
//
// Note: the scripts directory and Python interpreter path are NOT user-
// settable — they're baked into the app bundle (and `/usr/bin/python3`
// is required on macOS 14+). Users don't manage their own copy of the
// sync engine, the same way iMovie users don't manage ffmpeg.

@MainActor
final class SettingsStore: ObservableObject {
    // ---- Persistence keys ---------------------------------------------
    private enum DKey {
        static let syncRoot               = "syncRoot"
        static let gitlabHost             = "gitlabHost"
        static let githubOrg              = "githubOrg"
        static let bitbucketWorkspace     = "bitbucketWorkspace"
        static let bitbucketUser          = "bitbucketUser"
        static let skipBitbucket          = "skipBitbucket"
        static let skipGitlab             = "skipGitlab"
        static let skipGithub             = "skipGithub"
        static let includeArchived        = "includeArchived"
        static let skipPatterns           = "skipPatterns"
        static let parallel               = "parallel"
        static let timeout                = "timeout"
        static let depth                  = "depth"
        static let scheduleMode           = "scheduleMode"
        static let scheduleHours          = "scheduleHours"
        static let scheduleDailyHour      = "scheduleDailyHour"
        static let scheduleDailyMinute    = "scheduleDailyMinute"
        static let lastSuccessfulRun      = "lastSuccessfulRun"       // legacy global (migrated)
        static let lastSuccessByPlatform  = "lastSuccessByPlatform"  // [platform rawValue: Date]
        static let filterModeByPlatform   = "filterModeByPlatform"   // [platform rawValue: FilterMode raw]
        static let hasCompletedSetup      = "hasCompletedSetup"      // first-launch onboarding done
    }
    private enum KKey {
        static let githubToken         = "github_token"
        static let gitlabToken         = "gitlab_token"
        static let bitbucketPassword   = "bitbucket_app_password"
    }

    // ---- UserDefaults-backed scalars (auto-publishing) ----------------
    @Published var syncRoot: String {
        didSet { UserDefaults.standard.set(syncRoot, forKey: DKey.syncRoot) }
    }
    @Published var gitlabHost: String {
        didSet { UserDefaults.standard.set(gitlabHost, forKey: DKey.gitlabHost) }
    }
    @Published var githubOrg: String {
        didSet { UserDefaults.standard.set(githubOrg, forKey: DKey.githubOrg) }
    }
    @Published var bitbucketWorkspace: String {
        didSet { UserDefaults.standard.set(bitbucketWorkspace, forKey: DKey.bitbucketWorkspace) }
    }
    @Published var bitbucketUser: String {
        didSet { UserDefaults.standard.set(bitbucketUser, forKey: DKey.bitbucketUser) }
    }
    @Published var skipBitbucket: Bool {
        didSet { UserDefaults.standard.set(skipBitbucket, forKey: DKey.skipBitbucket) }
    }
    @Published var skipGitlab: Bool {
        didSet { UserDefaults.standard.set(skipGitlab, forKey: DKey.skipGitlab) }
    }
    @Published var skipGithub: Bool {
        didSet { UserDefaults.standard.set(skipGithub, forKey: DKey.skipGithub) }
    }
    @Published var includeArchived: Bool {
        didSet { UserDefaults.standard.set(includeArchived, forKey: DKey.includeArchived) }
    }
    @Published var skipPatterns: String {
        didSet { UserDefaults.standard.set(skipPatterns, forKey: DKey.skipPatterns) }
    }
    @Published var parallel: Int {
        didSet { UserDefaults.standard.set(parallel, forKey: DKey.parallel) }
    }
    @Published var timeout: Int {
        didSet { UserDefaults.standard.set(timeout, forKey: DKey.timeout) }
    }
    @Published var depth: Int {
        didSet { UserDefaults.standard.set(depth, forKey: DKey.depth) }
    }

    // ---- Schedule -----------------------------------------------------
    @Published var scheduleMode: ScheduleMode {
        didSet { UserDefaults.standard.set(scheduleMode.rawValue, forKey: DKey.scheduleMode) }
    }
    @Published var scheduleHours: Int {
        didSet { UserDefaults.standard.set(scheduleHours, forKey: DKey.scheduleHours) }
    }
    @Published var scheduleDailyHour: Int {
        didSet { UserDefaults.standard.set(scheduleDailyHour, forKey: DKey.scheduleDailyHour) }
    }
    @Published var scheduleDailyMinute: Int {
        didSet { UserDefaults.standard.set(scheduleDailyMinute, forKey: DKey.scheduleDailyMinute) }
    }

    // When each platform last synced successfully (exit 0), keyed by platform
    // rawValue. Drives PER-PLATFORM missed-run catch-up: the scheduler asks,
    // for each platform, "have you synced since your expected fire?" — so a
    // VPN-down GitLab stays due and retries cheaply while GitHub/Bitbucket,
    // having succeeded, go idle until their own next fire. Persisted as a
    // [String: Date] dict.
    @Published var lastSuccessByPlatform: [String: Date] {
        didSet { UserDefaults.standard.set(lastSuccessByPlatform, forKey: DKey.lastSuccessByPlatform) }
    }

    func noteSuccess(platform: String, at date: Date) {
        lastSuccessByPlatform[platform] = date
    }
    func lastSuccess(platform: String) -> Date? { lastSuccessByPlatform[platform] }

    // Per-platform filter mode (whitelist vs sync-all). Stored as raw strings
    // so it round-trips through UserDefaults cleanly. Defaults to .syncAll.
    @Published var filterModeByPlatform: [String: String] {
        didSet { UserDefaults.standard.set(filterModeByPlatform, forKey: DKey.filterModeByPlatform) }
    }
    func filterMode(platform: String) -> FilterMode {
        FilterMode(rawValue: filterModeByPlatform[platform] ?? "") ?? .syncAll
    }
    func setFilterMode(_ mode: FilterMode, platform: String) {
        filterModeByPlatform[platform] = mode.rawValue
    }

    // Platforms that are configured AND not skipped — mirrors the engine's
    // enabledPlatforms() gate, but from the settings the scheduler can see.
    var enabledPlatforms: [Platform] {
        var out: [Platform] = []
        if !skipGitlab,    !gitlabHost.isEmpty         { out.append(.gitlab) }
        if !skipGithub,    !githubOrg.isEmpty          { out.append(.github) }
        if !skipBitbucket, !bitbucketWorkspace.isEmpty { out.append(.bitbucket) }
        return out
    }

    // ---- First-launch onboarding -------------------------------------

    // True once at least one platform has its required identity field set —
    // i.e. the app can actually do something. Used to decide whether to show
    // onboarding and as the menu/inventory empty-state trigger.
    var isConfigured: Bool {
        !gitlabHost.isEmpty || !githubOrg.isEmpty || !bitbucketWorkspace.isEmpty
    }

    // Persisted: the user has been through (or dismissed) first-launch setup.
    // Distinct from isConfigured so we don't re-pop onboarding for someone who
    // intentionally left everything blank.
    @Published var hasCompletedSetup: Bool {
        didSet { UserDefaults.standard.set(hasCompletedSetup, forKey: DKey.hasCompletedSetup) }
    }

    // Show the first-launch onboarding window? Only when nothing is configured
    // AND the user hasn't already completed/dismissed setup.
    var shouldShowOnboarding: Bool { !hasCompletedSetup && !isConfigured }

    // ---- Keychain-backed secrets --------------------------------------
    @Published var githubToken: String {
        didSet { Keychain.set(githubToken, for: KKey.githubToken) }
    }
    @Published var gitlabToken: String {
        didSet { Keychain.set(gitlabToken, for: KKey.gitlabToken) }
    }
    @Published var bitbucketAppPassword: String {
        didSet { Keychain.set(bitbucketAppPassword, for: KKey.bitbucketPassword) }
    }

    // ---- Init ---------------------------------------------------------
    init() {
        let d = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Paciolan-flavored defaults. The app is primarily for the
        // Paciolan team's use, so pre-fill what we know.
        self.syncRoot           = d.string(forKey: DKey.syncRoot) ?? "\(home)/git/Paciolan"
        self.gitlabHost         = d.string(forKey: DKey.gitlabHost) ?? "gitlabdev.paciolan.info"
        self.githubOrg          = d.string(forKey: DKey.githubOrg) ?? "Paciolan"
        self.bitbucketWorkspace = d.string(forKey: DKey.bitbucketWorkspace) ?? "paciolan"
        self.bitbucketUser      = d.string(forKey: DKey.bitbucketUser) ?? ""
        self.skipBitbucket      = d.bool(forKey: DKey.skipBitbucket)
        self.skipGitlab         = d.bool(forKey: DKey.skipGitlab)
        self.skipGithub         = d.bool(forKey: DKey.skipGithub)
        self.includeArchived    = d.bool(forKey: DKey.includeArchived)
        self.skipPatterns       = d.string(forKey: DKey.skipPatterns) ?? ""
        self.parallel           = d.object(forKey: DKey.parallel) as? Int ?? 128
        self.timeout            = d.object(forKey: DKey.timeout) as? Int ?? 1800
        self.depth              = d.object(forKey: DKey.depth) as? Int ?? 100
        self.scheduleMode       = ScheduleMode(rawValue: d.string(forKey: DKey.scheduleMode) ?? "")
            ?? .manualOnly
        self.scheduleHours      = d.object(forKey: DKey.scheduleHours) as? Int ?? 4
        self.scheduleDailyHour  = d.object(forKey: DKey.scheduleDailyHour) as? Int ?? 9
        self.scheduleDailyMinute = d.object(forKey: DKey.scheduleDailyMinute) as? Int ?? 0
        // Per-platform last-success, migrating a legacy global value if present
        // (seed the ENABLED platforms with it so the first post-upgrade run
        // doesn't think everything is overdue — disabled platforms are left out
        // since their timestamp would just be dead weight).
        if let dict = d.dictionary(forKey: DKey.lastSuccessByPlatform) as? [String: Date] {
            self.lastSuccessByPlatform = dict
        } else if let legacy = d.object(forKey: DKey.lastSuccessfulRun) as? Date {
            // Read the enabled-state straight from UserDefaults (can't touch
            // self.* here — still mid-init). Mirror the same gates the host/
            // skip fields were just loaded from above.
            var seed: [String: Date] = [:]
            let glHost = d.string(forKey: DKey.gitlabHost) ?? "gitlabdev.paciolan.info"
            let ghOrg  = d.string(forKey: DKey.githubOrg) ?? "Paciolan"
            let bbWs   = d.string(forKey: DKey.bitbucketWorkspace) ?? "paciolan"
            if !d.bool(forKey: DKey.skipGitlab),    !glHost.isEmpty { seed["gitlab"] = legacy }
            if !d.bool(forKey: DKey.skipGithub),    !ghOrg.isEmpty  { seed["github"] = legacy }
            if !d.bool(forKey: DKey.skipBitbucket), !bbWs.isEmpty   { seed["bitbucket"] = legacy }
            self.lastSuccessByPlatform = seed
        } else {
            self.lastSuccessByPlatform = [:]
        }
        self.filterModeByPlatform = (d.dictionary(forKey: DKey.filterModeByPlatform) as? [String: String]) ?? [:]
        self.hasCompletedSetup  = d.bool(forKey: DKey.hasCompletedSetup)
        self.githubToken        = Keychain.get(KKey.githubToken) ?? ""
        self.gitlabToken        = Keychain.get(KKey.gitlabToken) ?? ""
        self.bitbucketAppPassword = Keychain.get(KKey.bitbucketPassword) ?? ""
    }

    // Build the SyncSettings value that SyncRunner consumes. Scripts
    // directory + Python interpreter are app-bundle-relative and not
    // user-controllable.
    var currentSyncSettings: SyncSettings {
        // Start from the inherited process environment, then overlay our
        // GIT_SYNC_* config. Process.environment REPLACES the child's env
        // wholesale, so if we built this dict from scratch the git children
        // would run with NO HOME / PATH / XDG_CONFIG_HOME. The visible symptom
        // was repos that have a .DS_Store showing as "dirty": without HOME,
        // git can't find ~/.config/git/ignore (which ignores .DS_Store), so it
        // reports the file as untracked. The same stripping would also break
        // git's credential helpers, hooks, and user ssh config — inherit the
        // real environment so git behaves exactly as it does in a shell.
        var env = ProcessInfo.processInfo.environment
        // The Settings UI is authoritative: explicitly set keys when the
        // setting is present and REMOVE them when it isn't, so a GIT_SYNC_*
        // var inherited from the launching shell (e.g. a sourced .envrc) can't
        // silently override the UI. set(_:_:) writes or clears accordingly.
        func set(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { env[key] = value } else { env[key] = nil }
        }
        set("GIT_SYNC_ROOT", syncRoot)
        set("GITLAB_HOST", gitlabHost)
        set("GIT_SYNC_GITHUB_ORG", githubOrg)
        set("GIT_SYNC_BITBUCKET_WORKSPACE", bitbucketWorkspace)
        set("GIT_SYNC_BITBUCKET_USER", bitbucketUser)
        set("GIT_SYNC_BITBUCKET_APP_PASSWORD", bitbucketAppPassword)
        set("GIT_SYNC_GITHUB_TOKEN", githubToken)
        // glab reads GITLAB_TOKEN from env when no glab-cli config exists, so
        // passing this through lets the bundled glab authenticate without the
        // user running `glab auth login`.
        set("GITLAB_TOKEN", gitlabToken)
        set("GIT_SYNC_SKIP", skipPatterns)
        set("GIT_SYNC_SKIP_BITBUCKET", skipBitbucket ? "1" : nil)
        set("GIT_SYNC_SKIP_GITLAB", skipGitlab ? "1" : nil)
        set("GIT_SYNC_SKIP_GITHUB", skipGithub ? "1" : nil)
        set("GIT_SYNC_INCLUDE_ARCHIVED", includeArchived ? "1" : nil)
        env["GIT_SYNC_PARALLEL"] = String(parallel)
        env["GIT_SYNC_TIMEOUT"] = String(timeout)
        env["GIT_SYNC_DEPTH"] = String(depth)
        return SyncSettings(
            pythonPath: SyncSettings.bundledPythonPath,
            scriptsDirectory: SyncSettings.bundledScriptsDirectory,
            environment: env
        )
    }
}

enum ScheduleMode: String, CaseIterable, Identifiable {
    case manualOnly = "manual"
    case everyNHours = "everyN"
    case dailyAt = "daily"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .manualOnly:  return "Manual only"
        case .everyNHours: return "Every N hours"
        case .dailyAt:     return "Daily at time"
        }
    }
}
