import Foundation
import SwiftUI

// Backing store for the Settings window. Non-secrets live in UserDefaults;
// the GitHub PAT and Bitbucket app password live in Keychain via the
// Keychain.swift wrapper.
//
// SettingsStore is the single source of truth for the env vars that get
// passed to the child sync scripts. AppState calls `currentSyncSettings`
// at the start of each run to build the env dict.

@MainActor
final class SettingsStore: ObservableObject {
    // ---- Persistence keys ---------------------------------------------
    // UserDefaults keys
    private enum DKey {
        static let syncRoot               = "syncRoot"
        static let scriptsDirectory       = "scriptsDirectory"
        static let pythonPath             = "pythonPath"
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
    // Keychain account names
    private enum KKey {
        static let githubToken         = "github_token"
        static let bitbucketPassword   = "bitbucket_app_password"
    }

    // ---- UserDefaults-backed scalars (auto-publishing) ----------------
    @Published var syncRoot: String {
        didSet { UserDefaults.standard.set(syncRoot, forKey: DKey.syncRoot) }
    }
    @Published var scriptsDirectory: String {
        didSet { UserDefaults.standard.set(scriptsDirectory, forKey: DKey.scriptsDirectory) }
    }
    @Published var pythonPath: String {
        didSet { UserDefaults.standard.set(pythonPath, forKey: DKey.pythonPath) }
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
    @Published var bitbucketAppPassword: String {
        didSet { Keychain.set(bitbucketAppPassword, for: KKey.bitbucketPassword) }
    }

    // ---- Init ---------------------------------------------------------
    init() {
        let d = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        self.syncRoot           = d.string(forKey: DKey.syncRoot) ?? "\(home)/git/Paciolan"
        self.scriptsDirectory   = d.string(forKey: DKey.scriptsDirectory)
            ?? "\(home)/git/uPaymeiFixit/git-sync/scripts"
        self.pythonPath         = d.string(forKey: DKey.pythonPath) ?? "/usr/bin/python3"
        self.gitlabHost         = d.string(forKey: DKey.gitlabHost) ?? ""
        self.githubOrg          = d.string(forKey: DKey.githubOrg) ?? ""
        self.bitbucketWorkspace = d.string(forKey: DKey.bitbucketWorkspace) ?? ""
        self.bitbucketUser      = d.string(forKey: DKey.bitbucketUser) ?? ""
        self.skipBitbucket      = d.bool(forKey: DKey.skipBitbucket)
        self.skipGitlab         = d.bool(forKey: DKey.skipGitlab)
        self.skipGithub         = d.bool(forKey: DKey.skipGithub)
        self.includeArchived    = d.bool(forKey: DKey.includeArchived)
        self.skipPatterns       = d.string(forKey: DKey.skipPatterns) ?? ""
        self.parallel           = d.object(forKey: DKey.parallel) as? Int ?? 8
        self.timeout            = d.object(forKey: DKey.timeout) as? Int ?? 1800
        self.depth              = d.object(forKey: DKey.depth) as? Int ?? 100
        self.scheduleMode       = ScheduleMode(rawValue: d.string(forKey: DKey.scheduleMode) ?? "")
            ?? .manualOnly
        self.scheduleHours      = d.object(forKey: DKey.scheduleHours) as? Int ?? 4
        self.scheduleDailyHour  = d.object(forKey: DKey.scheduleDailyHour) as? Int ?? 9
        self.scheduleDailyMinute = d.object(forKey: DKey.scheduleDailyMinute) as? Int ?? 0
        self.githubToken        = Keychain.get(KKey.githubToken) ?? ""
        self.bitbucketAppPassword = Keychain.get(KKey.bitbucketPassword) ?? ""
    }

    // Build the SyncSettings value that SyncRunner consumes.
    var currentSyncSettings: SyncSettings {
        var env: [String: String] = [
            "GIT_SYNC_ROOT": syncRoot,
        ]
        if !gitlabHost.isEmpty            { env["GITLAB_HOST"] = gitlabHost }
        if !githubOrg.isEmpty             { env["GIT_SYNC_GITHUB_ORG"] = githubOrg }
        if !bitbucketWorkspace.isEmpty    { env["GIT_SYNC_BITBUCKET_WORKSPACE"] = bitbucketWorkspace }
        if !bitbucketUser.isEmpty         { env["GIT_SYNC_BITBUCKET_USER"] = bitbucketUser }
        if !bitbucketAppPassword.isEmpty  { env["GIT_SYNC_BITBUCKET_APP_PASSWORD"] = bitbucketAppPassword }
        if !githubToken.isEmpty           { env["GIT_SYNC_GITHUB_TOKEN"] = githubToken }
        if !skipPatterns.isEmpty          { env["GIT_SYNC_SKIP"] = skipPatterns }
        if skipBitbucket                  { env["GIT_SYNC_SKIP_BITBUCKET"] = "1" }
        if skipGitlab                     { env["GIT_SYNC_SKIP_GITLAB"] = "1" }
        if skipGithub                     { env["GIT_SYNC_SKIP_GITHUB"] = "1" }
        if includeArchived                { env["GIT_SYNC_INCLUDE_ARCHIVED"] = "1" }
        env["GIT_SYNC_PARALLEL"] = String(parallel)
        env["GIT_SYNC_TIMEOUT"] = String(timeout)
        env["GIT_SYNC_DEPTH"] = String(depth)
        return SyncSettings(
            pythonPath: pythonPath,
            scriptsDirectory: URL(fileURLWithPath: scriptsDirectory),
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
