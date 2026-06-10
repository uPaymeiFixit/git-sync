import Foundation
import SwiftUI

// Timer-based scheduler. Reads ScheduleMode + interval from SettingsStore
// and fires AppState.startRun() at the right times.
//
// Lifecycle: created at app launch; observes SettingsStore via the
// onChange callback in App.swift. Cancels any in-flight timer when the
// mode changes. Fires only while the app is running — combined with
// "Launch at Login" this is enough to cover the user's actual constraint
// (they keep the app open across reboots).
//
// We use Timer (DispatchSource would be more precise) because:
// - Timer integrates with the run loop in App.swift's @main thread without
//   needing a dispatch queue.
// - The longest interval is hours; sub-second precision isn't needed.
// - Timers in macOS can drift but for a sync scheduler that's fine.

@MainActor
final class Scheduler {
    private weak var state: AppState?
    private var settings: SettingsStore
    private var timer: Timer?
    private var nextFireDate: Date?

    init(state: AppState, settings: SettingsStore) {
        self.state = state
        self.settings = settings
        reschedule()
    }

    var nextScheduledFire: Date? { nextFireDate }

    func reschedule() {
        timer?.invalidate()
        timer = nil
        nextFireDate = nil

        guard let state else { return }
        switch settings.scheduleMode {
        case .manualOnly:
            return
        case .everyNHours:
            let interval = TimeInterval(max(1, settings.scheduleHours) * 3600)
            scheduleOneShot(after: interval) { [weak self] in
                state.startRun()
                self?.reschedule()
            }
        case .dailyAt:
            let next = nextDailyDate(hour: settings.scheduleDailyHour,
                                     minute: settings.scheduleDailyMinute)
            let interval = next.timeIntervalSinceNow
            nextFireDate = next
            scheduleOneShot(after: max(60, interval)) { [weak self] in
                state.startRun()
                self?.reschedule()
            }
        }
    }

    private func scheduleOneShot(after interval: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        nextFireDate = Date(timeIntervalSinceNow: interval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor in block() }
        }
    }

    private func nextDailyDate(hour: Int, minute: Int) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let today = cal.date(from: comps) ?? Date().addingTimeInterval(3600)
        if today.timeIntervalSinceNow > 60 {
            return today
        }
        return cal.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
    }
}
