import Foundation
import AppKit

// Sleep-aware scheduler with missed-run catch-up.
//
// The old implementation was a one-shot Timer that fired only if the app was
// running AND the Mac was awake at the exact fire instant. A daily-at-midnight
// schedule on a Mac asleep at midnight would simply never run — the fire was
// lost with no makeup. This rewrite fixes that with three triggers, all
// funneled through fireIfDue():
//
//   1. NSBackgroundActivityScheduler heartbeat — a low-frequency, sleep-aware
//      tick (the system coalesces ticks missed during sleep into one on wake,
//      unlike a RunLoop Timer which just drops them). This is the steady
//      cadence even if the user never touches the machine.
//   2. NSWorkspace.didWakeNotification — re-check the moment the Mac wakes, so
//      an overdue run starts promptly on lid-open rather than waiting for the
//      next heartbeat.
//   3. Launch (start()) — catch a run that came due while the app was quit.
//
// fireIfDue() is wall-clock based AND per-platform: it computes the schedule's
// most recent expected fire time, then asks each enabled platform "have you
// synced since then?" (settings.lastSuccess(platform:), persisted). It runs
// ONLY the platforms that haven't — so a VPN-down GitLab stays due and retries
// (cheaply, via the reachability probe) while GitHub/Bitbucket, having synced,
// drop out until their own next fire. Because it keys off persisted per-
// platform success (not a volatile in-memory fire date), it survives
// quit/sleep/off: whenever the app is next alive, the first trigger catches up.
//
// Nothing runs while the Mac is fully OFF — no userspace scheduler can — but
// the run fires on the next launch/wake instead of being lost forever.

@MainActor
final class Scheduler {
    private weak var state: AppState?
    private let settings: SettingsStore
    private let providers: ProviderStore
    private var activity: NSBackgroundActivityScheduler?
    private var wakeObserver: NSObjectProtocol?

    // How often the background heartbeat re-checks "are we due?". This is NOT
    // the sync cadence — it's just the polling granularity for catch-up. 30
    // min keeps a daily/every-N-hours schedule punctual without busy-work.
    private static let heartbeat: TimeInterval = 30 * 60

    init(state: AppState, settings: SettingsStore, providers: ProviderStore) {
        self.state = state
        self.settings = settings
        self.providers = providers
        start()
    }

    // No deinit cleanup: the Scheduler is owned by AppState for the entire app
    // lifetime, so the heartbeat + wake observer live until the process exits
    // (which tears them down anyway). A @MainActor deinit is nonisolated under
    // Swift 6 and can't touch these non-Sendable properties, and there's no
    // real lifecycle reason to — so we don't.

    // Build (or rebuild) the heartbeat + wake observer, then do an immediate
    // catch-up check. Safe to call repeatedly (settings changes, relaunch).
    func start() {
        reschedule()
        observeWake()
        observeNetworkPath()
        // Catch a run that came due while we were quit.
        fireIfDue()
    }

    // The fourth trigger: the network path changed.
    //
    // This is what makes a VPN reconnect actionable. Previously a VPN-down
    // GitLab stayed permanently "due" and got re-probed on every 30-min
    // heartbeat and every wake, forever — but when the tunnel actually came
    // back, nothing noticed for up to 30 minutes. Now the path change itself
    // invalidates cached reachability and re-checks catch-up immediately.
    private func observeNetworkPath() {
        guard let state else { return }
        let health = state.providerHealth
        state.pathMonitor.onChange = { [weak self] _ in
            // Whatever we knew about reachability was learned on a DIFFERENT
            // network. Drop it so the next gate re-probes instead of serving a
            // cached "unreachable" through its backoff window.
            health.invalidateAll()
            Task { @MainActor in self?.fireIfDue() }
        }
        state.pathMonitor.start()
    }

    // Called by AppState whenever a schedule setting changes.
    func reschedule() {
        activity?.invalidate()
        activity = nil
        guard settings.scheduleMode != .manualOnly else { return }

        let a = NSBackgroundActivityScheduler(identifier: "com.uPaymeiFixit.GitSync.scheduledSync")
        a.repeats = true
        a.interval = Self.heartbeat
        // tolerance lets the system batch our wake-up with other maintenance,
        // saving power; punctuality to ~the heartbeat is plenty for a sync.
        a.tolerance = Self.heartbeat / 2
        a.qualityOfService = .utility
        a.schedule { [weak self] completion in
            // The scheduler may invoke us on a background queue; hop to main.
            Task { @MainActor in
                self?.fireIfDue()
                completion(.finished)
            }
        }
        activity = a
    }

    // How long a wake-triggered run waits for the network to come up before
    // giving up on this trigger. didWakeNotification fires when the machine
    // wakes, which is BEFORE Wi-Fi associates and well before a VPN finishes
    // reconnecting — starting a run in that window is what produced the
    // "syncs go infinitely on first wake" report. If the network isn't up
    // within this window we simply don't fire: the path-change observer will
    // fire the moment it does come up, and the heartbeat remains a backstop.
    private static let wakeNetworkGrace: TimeInterval = 20

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.fireIfDueAfterWake() }
        }
    }

    // Wake path: reachability learned before sleep is worthless (different
    // network, or none), so drop it, then hold briefly for the interfaces to
    // settle before deciding anything.
    private func fireIfDueAfterWake() async {
        guard let state else { return }
        state.providerHealth.invalidateAll()
        // Cheap exit: nothing is due, so don't even wait on the network.
        guard settings.scheduleMode != .manualOnly, !duePlatforms(asOf: Date()).isEmpty else { return }
        let up = await state.pathMonitor.waitForPath(timeout: Self.wakeNetworkGrace)
        guard up else {
            RunLog.runDeferred(reason: "no network path \(Int(Self.wakeNetworkGrace))s after wake")
            return
        }
        fireIfDue()
    }

    func noteSuccessfulRun() {
        // lastSuccessfulRun is persisted by AppState; nothing else to do here —
        // the next fireIfDue() will see it and stay quiet until next due.
    }

    // The heart of catch-up: which platforms are overdue right now? Runs only
    // those. A VPN-down GitLab stays due (cheap probe each retry) while
    // GitHub/Bitbucket, having synced, drop out until their own next fire.
    func fireIfDue() {
        guard let state else { return }
        guard settings.scheduleMode != .manualOnly else { return }
        // Don't stack a makeup run on top of one already going.
        guard !state.isRunning else { return }

        let due = duePlatforms(asOf: Date())
        guard !due.isEmpty else { return }
        // Don't launch a run with no usable network path. The per-provider
        // reachability gate would refuse every provider anyway, but doing it
        // here keeps the log readable (one "deferred" line instead of a run
        // that starts, fails every platform, and finishes with zero repos) and
        // leaves the platforms "due" so the path-change observer retries the
        // moment connectivity returns.
        guard state.pathMonitor.isSatisfied else {
            RunLog.runDeferred(reason: "no usable network path")
            return
        }
        state.startRun(only: due)
    }

    // The set of enabled platforms whose most-recent expected fire has passed
    // without a successful sync since.
    func duePlatforms(asOf now: Date) -> Set<Platform> {
        guard let due = mostRecentExpectedFire(asOf: now) else { return [] }
        var out = Set<Platform>()
        for p in providers.enabledPlatforms {
            let last = settings.lastSuccess(platform: p.rawValue)
            if last == nil || last! < due { out.insert(p) }
        }
        return out
    }

    // For the current schedule, the most recent moment a run "should have"
    // happened on or before `now`. Returns nil for manualOnly.
    //
    // NOTE on every-N-hours anchoring: we anchor to the EARLIEST platform
    // success (min across platforms) so the interval reflects "it's been N
    // hours since the oldest platform synced". Per-platform due-ness is then
    // decided in duePlatforms by comparing each platform's own last-success to
    // this fire instant — so a platform that synced recently isn't dragged in.
    func mostRecentExpectedFire(asOf now: Date) -> Date? {
        let cal = Calendar.current
        switch settings.scheduleMode {
        case .manualOnly:
            return nil
        case .everyNHours:
            let hours = TimeInterval(max(1, settings.scheduleHours) * 3600)
            let enabled = providers.enabledPlatforms
            let successes = enabled.compactMap { settings.lastSuccess(platform: $0.rawValue) }
            // If any enabled platform has never synced, something is due now.
            guard successes.count == enabled.count, let oldest = successes.min() else {
                return now
            }
            let next = oldest.addingTimeInterval(hours)
            return next <= now ? next : nil  // nothing due yet
        case .dailyAt:
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = settings.scheduleDailyHour
            comps.minute = settings.scheduleDailyMinute
            comps.second = 0
            guard let todayFire = cal.date(from: comps) else { return nil }
            if todayFire <= now { return todayFire }
            return cal.date(byAdding: .day, value: -1, to: todayFire)
        }
    }

    // The NEXT scheduled fire, for display in the menu. Best-effort.
    var nextScheduledFire: Date? {
        let cal = Calendar.current
        let now = Date()
        switch settings.scheduleMode {
        case .manualOnly:
            return nil
        case .everyNHours:
            let hours = TimeInterval(max(1, settings.scheduleHours) * 3600)
            let successes = providers.enabledPlatforms.compactMap { settings.lastSuccess(platform: $0.rawValue) }
            let base = successes.min() ?? now
            let next = base.addingTimeInterval(hours)
            return next > now ? next : now
        case .dailyAt:
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = settings.scheduleDailyHour
            comps.minute = settings.scheduleDailyMinute
            comps.second = 0
            guard let todayFire = cal.date(from: comps) else { return nil }
            if todayFire > now { return todayFire }
            return cal.date(byAdding: .day, value: 1, to: todayFire)
        }
    }
}
