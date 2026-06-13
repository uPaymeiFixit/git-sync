import SwiftUI

@main
struct GitSyncApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var history: HistoryStore
    @StateObject private var inventory: InventoryStore
    @StateObject private var state: AppState

    init() {
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
        if args.contains("--pipe-stress-test") {
            exit(PipeStressTest.run())
        }
        if args.contains("--trash-test") {
            exit(TrashTest.run())
        }
        if args.contains("--concurrency-test") {
            exit(ConcurrencyTest.run())
        }
        if let i = args.firstIndex(of: "--diff-engine") {
            let dir = args.index(after: i) < args.endIndex ? args[args.index(after: i)] : ""
            exit(DiffEngineMode.run(dir: dir))
        }
        if args.contains("--engine-sync") {
            exit(EngineSyncMode.run(args: Array(args)))
        }

        // Order matters: settings + history + inventory must exist before
        // AppState so the runner picks up the user's stored settings, the
        // history store can record completed runs, and the inventory store
        // can absorb remote_project + outcome events as they stream in.
        let settingsStore = SettingsStore()
        let historyStore = HistoryStore()
        let inventoryStore = InventoryStore()
        _settings  = StateObject(wrappedValue: settingsStore)
        _history   = StateObject(wrappedValue: historyStore)
        _inventory = StateObject(wrappedValue: inventoryStore)
        _state     = StateObject(wrappedValue: AppState(
            settings: settingsStore,
            history: historyStore,
            inventory: inventoryStore
        ))

        // Seed the inventory on first launch (best-effort, async).
        Task { @MainActor in
            inventoryStore.seedFromHistory(historyStore)
            let syncRoot = URL(fileURLWithPath:
                (settingsStore.syncRoot as NSString).expandingTildeInPath)
            await inventoryStore.seedFromDisk(syncRoot: syncRoot)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
                .environmentObject(settings)
                .environmentObject(history)
                .environmentObject(inventory)
                .onAppear {
                    _ = state.scheduler   // ensure scheduler is built
                    installTerminationGuard()
                }
        } label: {
            MenuBarIcon(state: state)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsWindow()
                .environmentObject(settings)
                .onChange(of: settings.scheduleMode) { _, _ in state.rescheduleIfNeeded() }
                .onChange(of: settings.scheduleHours) { _, _ in state.rescheduleIfNeeded() }
                .onChange(of: settings.scheduleDailyHour) { _, _ in state.rescheduleIfNeeded() }
                .onChange(of: settings.scheduleDailyMinute) { _, _ in state.rescheduleIfNeeded() }
        }

        Window("Repositories", id: "repositories") {
            RepositoriesView()
                .environmentObject(state)
                .environmentObject(settings)
                .environmentObject(inventory)
        }
        .windowResizability(.contentSize)

        Window("Run history", id: "history") {
            HistoryWindow()
                .environmentObject(history)
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
        @StateObject private var spin = SpinDriver()

        var body: some View {
            // anyActivity, not isRunning: the icon must animate for individual
            // per-repo syncs too, not only full runs.
            Image(systemName: state.anyActivity
                  ? SpinDriver.frames[spin.frame]
                  : state.menuBarIconName)
                .foregroundStyle(state.showsAttention ? Color.orange : Color.primary)
                .onAppear { spin.setRunning(state.anyActivity) }
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

    // Quit-while-running cleanup. Without this, the .app's process exits
    // and macOS reaps the Python children with SIGTERM — usually fine, but
    // a child mid-clone can leave a .git/*.lock behind. We send a polite
    // SIGTERM ourselves so the scripts' own SIGINT handler runs first.
    private func installTerminationGuard() {
        let appState = state
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in appState.cancelRun() }
        }
    }
}
