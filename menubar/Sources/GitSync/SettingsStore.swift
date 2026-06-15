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
