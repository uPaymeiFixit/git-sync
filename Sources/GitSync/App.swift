import SwiftUI

@main
struct GitSyncApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var inventory: InventoryStore
    @StateObject private var providers: ProviderStore
    @StateObject private var state: AppState
    @StateObject private var updater = SparkleUpdater()

    init() {
        // Raise the open-file-descriptor soft limit FIRST. A GUI app launched
        // by launchd inherits maxfiles=256, which is far too low for 128
        // concurrent git+ssh workers — even without a leak, a big run brushes
        // against it and Process.run() starts failing with EBADF ("Bad file
        // descriptor"). Bump toward the hard limit. Belt to the FD-close fixes
        // in GitRunner (suspenders).
        GitSyncApp.raiseFDLimit()

        // CLI-mode entry points. Detected at startup so we don't spin up a
        // GUI for tooling commands.
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--verify-parser") {
            exit(VerifyParser.run())
        }
        if args.contains("--smoke-test") {
            exit(SmokeTest.run())
        }
        if args.contains("--load-test") {
            exit(LoadTest.run())
        }
        if args.contains("--trash-test") {
            exit(TrashTest.run())
        }
        if args.contains("--abort-reset-test") {
            exit(AbortResetTest.run())
        }
        if args.contains("--parallelism-test") {
            exit(ParallelismTest.run())
        }
        if args.contains("--abort-contention-test") {
            exit(AbortContentionTest.run())
        }
        if args.contains("--stream-eof-test") {
            exit(StreamEofTest.run())
        }
        if args.contains("--fd-leak-test") {
            exit(FDLeakTest.run())
        }
        if args.contains("--scheduler-test") {
            exit(SchedulerTest.run())
        }
        if args.contains("--whitelist-test") {
            exit(WhitelistTest.run())
        }
        if args.contains("--provider-validation-test") {
            exit(ProviderValidationTest.run())
        }
        if args.contains("--provider-migration-test") {
            exit(ProviderMigrationTest.run())
        }
        if args.contains("--connection-test") {
            exit(ConnectionTest.run())
        }
        if args.contains("--legacy-keychain-cleanup-test") {
            exit(LegacyKeychainCleanupTest.run())
        }

        // Order matters: settings + inventory must exist before AppState so the
        // engine picks up the user's stored settings and the inventory store can
        // absorb remote_project + outcome events as they stream in.
        let settingsStore = SettingsStore()
        let providerStore = ProviderStore()   // migrates legacy config on first run
        let inventoryStore = InventoryStore(providers: providerStore.providers)
        _settings  = StateObject(wrappedValue: settingsStore)
        _providers = StateObject(wrappedValue: providerStore)
        _inventory = StateObject(wrappedValue: inventoryStore)
        _state     = StateObject(wrappedValue: AppState(
            settings: settingsStore,
            inventory: inventoryStore,
            providers: providerStore
        ))

        // Seed the inventory on first launch (best-effort, async). The disk
        // walk needs the provider list (each provider has its own folder).
        let provs = providerStore.providers
        Task { @MainActor in
            await inventoryStore.seedFromDisk(providers: provs)
        }
    }

    // Raise RLIMIT_NOFILE toward the hard cap. launchd hands GUI apps a soft
    // limit of 256; 128 parallel git+ssh workers need far more headroom.
    static func raiseFDLimit() {
        // RLIM_INFINITY is a C macro (a cast expression) Swift can't import;
        // inline its value: (1<<63)-1.
        let rlimInfinity = rlim_t(bitPattern: Int64.max)
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return }
        // OPEN_MAX (10240) is the practical per-process ceiling on macOS even
        // when rlim_max reports "unlimited"; asking for more fails the call.
        let target = rlim_t(OPEN_MAX)
        let want = min(target, lim.rlim_max == rlimInfinity ? target : lim.rlim_max)
        if lim.rlim_cur < want {
            lim.rlim_cur = want
            _ = setrlimit(RLIMIT_NOFILE, &lim)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
                .environmentObject(settings)
                .environmentObject(inventory)
                .environmentObject(providers)
                .environmentObject(updater)
                .onAppear {
                    _ = state.scheduler   // ensure scheduler is built
                    installTerminationGuard()
                }
        } label: {
            MenuBarIcon(state: state, settings: settings)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsWindow()
                .environmentObject(settings)
                .environmentObject(state)
                .environmentObject(inventory)
                .environmentObject(providers)
                .environmentObject(updater)
                .onChange(of: settings.scheduleMode) { _, _ in state.rescheduleIfNeeded() }
                .onChange(of: settings.scheduleHours) { _, _ in state.rescheduleIfNeeded() }
        }

        Window("Set Up GitSync", id: "onboarding") {
            OnboardingView()
                .environmentObject(settings)
                .environmentObject(state)
                .environmentObject(providers)
        }
        .windowResizability(.contentSize)

        Window("Repositories", id: "repositories") {
            RepositoriesView()
                .environmentObject(state)
                .environmentObject(settings)
                .environmentObject(inventory)
                .environmentObject(providers)
        }
        .windowResizability(.contentSize)
    }

    // Animating the menu-bar icon is harder than it looks. A MenuBarExtra
    // with .menu style renders its label into the NSStatusItem button as a
    // flattened bitmap. AppKit re-rasterizes that bitmap on discrete,
    // *meaningful* changes — the glyph name flipping, the tint changing —
    // but NOT for a continuous stream of tiny rotationEffect deltas: from
    // its side that's "same glyph, same color, just nudged," and the
    // status-item snapshot cache skips it. That's why both symbolEffect
    // (.rotate) and a manual rotationEffect timer drew nothing.
    //
    // So we animate the one way AppKit reliably honors: by swapping the
    // glyph *name* on a cadence. Each frame is a distinct SF Symbol, so
    // each tick is a real state change AppKit re-snapshots. isRunning
    // covers every trigger — manual Run now, scheduled runs, per-repo
    // syncs — so no extra wiring per source.
    private struct MenuBarIcon: View {
        @ObservedObject var state: AppState
        @ObservedObject var settings: SettingsStore
        @Environment(\.openWindow) private var openWindow

        @StateObject private var spin = SpinDriver()

        var body: some View {
            // anyActivity, not isRunning: the icon must animate for individual
            // per-repo syncs too, not only full runs.
            Image(systemName: state.anyActivity
                  ? SpinDriver.frames[spin.frame]
                  : state.menuBarIconName)
                .foregroundStyle(state.showsAttention ? Color.orange : Color.primary)
                .onAppear {
                    spin.setRunning(state.anyActivity)
                    // First-launch onboarding. The menu-bar label renders at
                    // launch (the MENU content's .onAppear only fires when the
                    // menu is opened), so this is where we catch a fresh,
                    // unconfigured install and pop the setup window once.
                    // "Configured" now means "has a provider" (post-migration).
                    if !settings.hasCompletedSetup && !state.providers.isConfigured {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            openWindow(id: "onboarding")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                }
                .onChange(of: state.anyActivity) { _, running in
                    spin.setRunning(running)
                }
        }
    }

    @MainActor
    private final class SpinDriver: ObservableObject {
        // Four "clock" SF Symbols whose fill sweeps around the dial. Cycled
        // in order they read as a rotating indicator. These are distinct
        // glyph names, so each step is a snapshot AppKit honors (a smooth
        // rotationEffect is not — see MenuBarIcon's note).
        static let frames = [
            "circle.bottomhalf.filled",
            "circle.lefthalf.filled",
            "circle.tophalf.filled",
            "circle.righthalf.filled",
        ]

        @Published var frame: Int = 0
        private var timer: Timer?

        func setRunning(_ running: Bool) {
            timer?.invalidate()
            timer = nil
            frame = 0
            guard running else { return }
            // ~0.22s/frame → one full sweep every ~0.9s. Added in .common
            // mode so the animation keeps going while the menu is open
            // (menu tracking pauses .default-mode timers).
            let t = Timer(timeInterval: 0.22, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.frame = (self.frame + 1) % SpinDriver.frames.count
                }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    // Quit-while-running cleanup: cancel the in-process sync engine on app
    // termination (engine.cancel() via cancelRun()) so a git op interrupted by
    // quit doesn't leave a .git/*.lock behind for the next run to trip over.
    private func installTerminationGuard() {
        let appState = state
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in appState.cancelRun() }
        }
    }
}
