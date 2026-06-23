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
        static let skipPatterns           = "skipPatterns"   // legacy global; seeds per-provider skip once (migration)
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

    // ---- UserDefaults-backed scalars (auto-publishing) ----------------
    @Published var syncRoot: String {
        didSet { UserDefaults.standard.set(syncRoot, forKey: DKey.syncRoot) }
    }
    // Legacy global skip list. No live UI writes it anymore (skip is per-provider);
    // kept only so migrateGlobalSkipIfNeeded can seed providers from it once.
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
    // Read-only legacy fallback: the per-platform filter mode for un-migrated
    // inventory rows (those with no providerID). Live filter-mode writes go
    // through ProviderStore.setFilterMode(providerID:); nothing writes
    // filterModeByPlatform anymore, so there's no setter here.
    func filterMode(platform: String) -> FilterMode {
        FilterMode(rawValue: filterModeByPlatform[platform] ?? "") ?? .syncAll
    }

    // (Enabled platforms + "is configured?" live on ProviderStore now — the
    // source of truth for what to sync. The Scheduler reads
    // ProviderStore.enabledPlatforms; onboarding reads ProviderStore.isConfigured.)

    // ---- First-launch onboarding -------------------------------------

    // Persisted: the user has been through (or dismissed) first-launch setup.
    @Published var hasCompletedSetup: Bool {
        didSet { UserDefaults.standard.set(hasCompletedSetup, forKey: DKey.hasCompletedSetup) }
    }


    // ---- Init ---------------------------------------------------------
    init() {
        let d = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Paciolan-flavored default for the sync root. Per-provider host/scope/
        // token now live on ProviderStore (seeded once by its legacy migration).
        self.syncRoot           = d.string(forKey: DKey.syncRoot) ?? "\(home)/git/Paciolan"
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
            // One-time migration of the old global last-success into per-platform.
            // Read the legacy enabled-state straight from UserDefaults by raw key
            // (those typed fields are gone; this only runs for pre-provider state).
            var seed: [String: Date] = [:]
            let glHost = d.string(forKey: "gitlabHost") ?? ""
            let ghOrg  = d.string(forKey: "githubOrg") ?? ""
            let bbWs   = d.string(forKey: "bitbucketWorkspace") ?? ""
            if !d.bool(forKey: "skipGitlab"),    !glHost.isEmpty { seed["gitlab"] = legacy }
            if !d.bool(forKey: "skipGithub"),    !ghOrg.isEmpty  { seed["github"] = legacy }
            if !d.bool(forKey: "skipBitbucket"), !bbWs.isEmpty   { seed["bitbucket"] = legacy }
            self.lastSuccessByPlatform = seed
        } else {
            self.lastSuccessByPlatform = [:]
        }
        self.filterModeByPlatform = (d.dictionary(forKey: DKey.filterModeByPlatform) as? [String: String]) ?? [:]
        self.hasCompletedSetup  = d.bool(forKey: DKey.hasCompletedSetup)
    }

    // Build the SyncSettings the engine consumes: the shared run config in the
    // environment dict, with per-provider connection/credentials attached later
    // by AppState.withTrackingEnv (which alone has the provider + inventory
    // stores). The singular GITLAB_HOST / token / skip env vars the Python used
    // are gone — that config now lives on each Provider.
    var currentSyncSettings: SyncSettings {
        // Start from the inherited process environment, then overlay our
        // GIT_SYNC_* config. The git children inherit this env wholesale, so it
        // must carry HOME / PATH / XDG_CONFIG_HOME — without HOME, git can't
        // find ~/.config/git/ignore (which ignores .DS_Store) and clean repos
        // show as "dirty"; credential helpers, hooks, and ssh config break too.
        var env = ProcessInfo.processInfo.environment
        func set(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { env[key] = value } else { env[key] = nil }
        }
        set("GIT_SYNC_ROOT", syncRoot)
        env["GIT_SYNC_PARALLEL"] = String(parallel)
        env["GIT_SYNC_TIMEOUT"] = String(timeout)
        env["GIT_SYNC_DEPTH"] = String(depth)
        return SyncSettings(environment: env)
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
