import Foundation

// Unit test for the scheduler's catch-up math — the part that decides whether
// a scheduled run is OVERDUE (the fix for "Mac asleep at midnight never syncs").
// The trigger plumbing (NSBackgroundActivityScheduler, wake notification) can't
// be tested headless, but the overdue DECISION is pure date math and is where
// the correctness lives, so we test that directly.
//
//   GitSync --scheduler-test
//
// We reimplement the exact mostRecentExpectedFire/overdue logic here against a
// fixed "now" and assert the missed-run cases catch up and the up-to-date
// cases stay quiet. (Kept in sync with Scheduler.swift by intent; if that
// logic changes, update both.)
enum SchedulerTest {
    enum Mode { case manual, everyN(Int), dailyAt(Int, Int) }

    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Scheduler catch-up test")

        let cal = Calendar.current
        func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            var c = DateComponents(); c.year=y; c.month=mo; c.day=d; c.hour=h; c.minute=mi; c.second=0
            return cal.date(from: c)!
        }

        // Mirror of Scheduler.mostRecentExpectedFire(asOf:).
        func mostRecentExpectedFire(_ mode: Mode, lastSuccessful: Date?, now: Date) -> Date? {
            switch mode {
            case .manual: return nil
            case .everyN(let hrs):
                guard let last = lastSuccessful else { return now }
                let next = last.addingTimeInterval(TimeInterval(max(1, hrs) * 3600))
                return next <= now ? next : nil
            case .dailyAt(let h, let mi):
                var comps = cal.dateComponents([.year,.month,.day], from: now)
                comps.hour = h; comps.minute = mi; comps.second = 0
                guard let todayFire = cal.date(from: comps) else { return nil }
                if todayFire <= now { return todayFire }
                return cal.date(byAdding: .day, value: -1, to: todayFire)
            }
        }
        // Mirror of fireIfDue()'s decision.
        func isDue(_ mode: Mode, lastSuccessful: Date?, now: Date) -> Bool {
            guard let due = mostRecentExpectedFire(mode, lastSuccessful: lastSuccessful, now: now) else { return false }
            return lastSuccessful == nil || lastSuccessful! < due
        }

        // ---- THE headline scenario: daily at 00:00, Mac asleep at midnight,
        // user opens laptop at 08:00. Last good run was yesterday morning. ----
        let now0800 = date(2026, 6, 16, 8, 0)
        let yesterdayMorning = date(2026, 6, 15, 7, 30)
        check("daily@midnight: overdue when opened at 8am (asleep through midnight)",
              isDue(.dailyAt(0, 0), lastSuccessful: yesterdayMorning, now: now0800))

        // Already ran AFTER today's midnight fire → NOT due.
        let ranAt0030 = date(2026, 6, 16, 0, 30)
        check("daily@midnight: not due if already ran after midnight today",
              !isDue(.dailyAt(0, 0), lastSuccessful: ranAt0030, now: now0800))

        // Daily at 09:00 but it's only 08:00 → today's fire hasn't come; the
        // relevant fire is YESTERDAY 09:00; last run was yesterday 07:30
        // (before it) → still due (yesterday's 9am run was also missed).
        check("daily@9am: due at 8am if last run predates yesterday's 9am",
              isDue(.dailyAt(9, 0), lastSuccessful: yesterdayMorning, now: now0800))

        // Daily at 09:00, last run was yesterday 10:00 (after yesterday's 9am),
        // now 08:00 today (before today's 9am) → most-recent fire is yest 9am,
        // last run (yest 10am) is after it → NOT due yet.
        let yest1000 = date(2026, 6, 15, 10, 0)
        check("daily@9am: not due before today's fire if last run was after yesterday's",
              !isDue(.dailyAt(9, 0), lastSuccessful: yest1000, now: now0800))

        // ---- every-N-hours ----
        let now = date(2026, 6, 16, 12, 0)
        check("every-4h: due when last run was 5h ago",
              isDue(.everyN(4), lastSuccessful: now.addingTimeInterval(-5*3600), now: now))
        check("every-4h: NOT due when last run was 1h ago",
              !isDue(.everyN(4), lastSuccessful: now.addingTimeInterval(-1*3600), now: now))
        check("every-4h: due immediately when never run before",
              isDue(.everyN(4), lastSuccessful: nil, now: now))

        // ---- manual ----
        check("manual: never due",
              !isDue(.manual, lastSuccessful: nil, now: now))

        // ---- never-run daily ----
        check("daily: due if never run (lastSuccessful nil)",
              isDue(.dailyAt(0, 0), lastSuccessful: nil, now: now0800))

        print()
        if failures == 0 { print("Scheduler catch-up test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }
}
