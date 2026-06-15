import Foundation

// Unit test for the scheduler's PER-PLATFORM catch-up math — the logic that
// decides which platforms are overdue. This is where the correctness lives
// (the NSBackgroundActivityScheduler / wake-notification plumbing can't be
// tested headless). Covers the two headline behaviors:
//   - "Mac asleep at midnight" → the daily run catches up on wake.
//   - "VPN down" → only GitLab stays due and retries; GitHub/Bitbucket, having
//     synced, drop out until their own next fire (no wasteful re-sync).
//
//   GitSync --scheduler-test
//
// Reimplements mostRecentExpectedFire + duePlatforms against a fixed "now" and
// a per-platform last-success map. Kept in sync with Scheduler.swift by intent.
enum SchedulerTest {
    enum Mode { case manual, everyN(Int), dailyAt(Int, Int) }
    // platforms enabled in the test; last success per platform (nil = never).
    typealias Successes = [String: Date]

    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Scheduler per-platform catch-up test")

        let cal = Calendar.current
        func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            var c = DateComponents(); c.year=y; c.month=mo; c.day=d; c.hour=h; c.minute=mi; c.second=0
            return cal.date(from: c)!
        }

        // Mirror of Scheduler.mostRecentExpectedFire(asOf:).
        func mostRecentExpectedFire(_ mode: Mode, enabled: [String], succ: Successes, now: Date) -> Date? {
            switch mode {
            case .manual: return nil
            case .everyN(let hrs):
                let successes = enabled.compactMap { succ[$0] }
                guard successes.count == enabled.count, let oldest = successes.min() else { return now }
                let next = oldest.addingTimeInterval(TimeInterval(max(1, hrs) * 3600))
                return next <= now ? next : nil
            case .dailyAt(let h, let mi):
                var comps = cal.dateComponents([.year,.month,.day], from: now)
                comps.hour = h; comps.minute = mi; comps.second = 0
                guard let todayFire = cal.date(from: comps) else { return nil }
                if todayFire <= now { return todayFire }
                return cal.date(byAdding: .day, value: -1, to: todayFire)
            }
        }
        // Mirror of Scheduler.duePlatforms(asOf:).
        func duePlatforms(_ mode: Mode, enabled: [String], succ: Successes, now: Date) -> Set<String> {
            guard let due = mostRecentExpectedFire(mode, enabled: enabled, succ: succ, now: now) else { return [] }
            var out = Set<String>()
            for p in enabled {
                let last = succ[p]
                if last == nil || last! < due { out.insert(p) }
            }
            return out
        }

        let all = ["gitlab", "github", "bitbucket"]

        // ---- HEADLINE 1: daily@midnight, asleep through midnight, open 8am.
        // All three last synced yesterday morning → all three due. ----
        let now0800 = date(2026, 6, 16, 8, 0)
        let yMorning = date(2026, 6, 15, 7, 30)
        let allYesterday: Successes = ["gitlab": yMorning, "github": yMorning, "bitbucket": yMorning]
        check("daily@midnight: all 3 due when opened at 8am after sleeping through",
              duePlatforms(.dailyAt(0,0), enabled: all, succ: allYesterday, now: now0800) == Set(all))

        // ---- HEADLINE 2 (the VPN-down core): after the 8am catch-up run,
        // GitHub+Bitbucket succeeded at 08:01 but GitLab failed (still yesterday).
        // On the next heartbeat, ONLY gitlab should be due. ----
        let now0830 = date(2026, 6, 16, 8, 30)
        let ghbbOK: Successes = [
            "gitlab": yMorning,                  // VPN down → never updated
            "github": date(2026, 6, 16, 8, 1),
            "bitbucket": date(2026, 6, 16, 8, 1),
        ]
        check("VPN-down: only GitLab due after GitHub/Bitbucket succeeded",
              duePlatforms(.dailyAt(0,0), enabled: all, succ: ghbbOK, now: now0830) == ["gitlab"])

        // ---- After VPN returns and GitLab finally syncs, nobody is due. ----
        let allOKToday: Successes = [
            "gitlab": date(2026, 6, 16, 9, 0),
            "github": date(2026, 6, 16, 8, 1),
            "bitbucket": date(2026, 6, 16, 8, 1),
        ]
        let now1000 = date(2026, 6, 16, 10, 0)
        check("nothing due once all 3 synced after today's midnight fire",
              duePlatforms(.dailyAt(0,0), enabled: all, succ: allOKToday, now: now1000).isEmpty)

        // ---- every-4h, only GitLab stale (synced 5h ago), others 1h ago.
        // Most-recent fire anchors on the OLDEST (gitlab, 5h) → fire is in the
        // past → gitlab due; github/bitbucket synced after it → not due. ----
        let now = date(2026, 6, 16, 12, 0)
        let mixed: Successes = [
            "gitlab": now.addingTimeInterval(-5*3600),
            "github": now.addingTimeInterval(-1*3600),
            "bitbucket": now.addingTimeInterval(-1*3600),
        ]
        check("every-4h: only the stale platform (gitlab 5h) is due",
              duePlatforms(.everyN(4), enabled: all, succ: mixed, now: now) == ["gitlab"])

        // ---- every-4h, all fresh (1h ago) → none due. ----
        let allFresh: Successes = Dictionary(uniqueKeysWithValues: all.map { ($0, now.addingTimeInterval(-3600)) })
        check("every-4h: none due when all synced 1h ago",
              duePlatforms(.everyN(4), enabled: all, succ: allFresh, now: now).isEmpty)

        // ---- never-run platform is due immediately. ----
        let neverGitlab: Successes = ["github": now.addingTimeInterval(-600), "bitbucket": now.addingTimeInterval(-600)]
        check("every-4h: a never-synced platform is due now",
              duePlatforms(.everyN(4), enabled: all, succ: neverGitlab, now: now).contains("gitlab"))

        // ---- manual: nothing ever due. ----
        check("manual: nothing due",
              duePlatforms(.manual, enabled: all, succ: allYesterday, now: now0800).isEmpty)

        // ---- a disabled platform (not in `enabled`) is never due even if
        // it has no success record. ----
        let twoOnly = ["github", "bitbucket"]
        check("disabled platform not considered (bitbucket-less enabled set)",
              !duePlatforms(.dailyAt(0,0), enabled: twoOnly, succ: ghbbOK, now: now0830).contains("gitlab"))

        print()
        if failures == 0 { print("Scheduler per-platform catch-up test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }
}
