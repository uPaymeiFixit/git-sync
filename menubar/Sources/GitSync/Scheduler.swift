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
// fireIfDue() is wall-clock based: it computes the schedule's most recent
// expected fire time and compares it to settings.lastSuccessfulRun. If we
// haven't had a clean run since that expected fire, we're overdue → run now.
// Because it keys off persisted lastSuccessfulRun (not a volatile in-memory
// fire date), it survives quit/sleep/off: whenever the app is next alive, the
// first trigger notices the miss and catches up.
//
// Nothing runs while the Mac is fully OFF — no userspace scheduler can — but
// the run fires on the next launch/wake instead of being lost forever.

@MainActor
final class Scheduler {
    private weak var state: AppState?
    private let settings: SettingsStore
    private var activity: NSBackgroundActivityScheduler?
    private var wakeObserver: NSObjectProtocol?

    // How often the background heartbeat re-checks "are we due?". This is NOT
    // the sync cadence — it's just the polling granularity for catch-up. 30
    // min keeps a daily/every-N-hours schedule punctual without busy-work.
    private static let heartbeat: TimeInterval = 30 * 60

    init(state: AppState, settings: SettingsStore) {
        self.state = state
        self.settings = settings
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
        // Catch a run that came due while we were quit.
        fireIfDue()
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

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.fireIfDue() }
        }
    }

    func noteSuccessfulRun() {
        // lastSuccessfulRun is persisted by AppState; nothing else to do here —
        // the next fireIfDue() will see it and stay quiet until next due.
    }

    // The heart of catch-up: is a scheduled run overdue right now?
    func fireIfDue() {
        guard let state else { return }
        guard settings.scheduleMode != .manualOnly else { return }
        // Don't stack a makeup run on top of one already going.
        guard !state.isRunning else { return }
        guard let due = mostRecentExpectedFire(asOf: Date()) else { return }

        let last = settings.lastSuccessfulRun
        if last == nil || last! < due {
            state.startRun()
        }
    }

    // For the current schedule, the most recent moment a run "should have"
    // happened on or before `now`. Catch-up fires if we haven't had a clean
    // run since this instant. Returns nil for manualOnly.
    func mostRecentExpectedFire(asOf now: Date) -> Date? {
        let cal = Calendar.current
        switch settings.scheduleMode {
        case .manualOnly:
            return nil
        case .everyNHours:
            // Anchor every-N-hours to the last successful run if we have one
            // (so "every 4h" means 4h after the last sync), else treat as
            // immediately due.
            let hours = TimeInterval(max(1, settings.scheduleHours) * 3600)
            guard let last = settings.lastSuccessfulRun else { return now }
            let next = last.addingTimeInterval(hours)
            return next <= now ? next : nil  // not yet due → nil
        case .dailyAt:
            // The most recent occurrence of HH:MM at or before now.
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
            let base = settings.lastSuccessfulRun ?? now
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
