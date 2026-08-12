import Foundation

// Regression for the 24-hour-fuse thread leak that froze every repo row on
// "starting" with the clock ticking up, zero CPU, and no git child process.
//
//   GitSync --pool-leak-test
//
// GitWorkPool's worker threads captured the pool as `[weak self] in
// self?.workerLoop()`. The optional chain upgrades the weak reference to a
// strong one for the duration of the call, and that call is an infinite loop
// that only exits when `shuttingDown` is set — which only `deinit` did. So the
// workers kept their own pool alive, deinit never ran, and the threads never
// exited: each full sync run leaked 128 OS threads permanently.
//
// macOS caps a process at kern.num_taskthreads (6144). At the 30-minute
// scheduler heartbeat that is 48 runs ≈ 24h of uptime, after which
// pthread_create fails and no work can be dispatched at all. The wedged process
// this was diagnosed from held exactly 6144 threads: 48 pools × 128, with the
// newest pool's last 6 workers missing because they could not be created.
//
// So the assertion that matters is not "does the pool run work" (it always did)
// but "do its threads GO AWAY when the pool is released". We measure real OS
// threads via task_threads(), not a counter the pool maintains, because the
// leak was invisible to every counter in the program.
enum PoolLeakTest {

    // Live OS thread count for this process, straight from the kernel.
    private static func liveThreads() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS,
              let list else { return -1 }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        return Int(count)
    }

    // Threads exit asynchronously after shutdown, so settle rather than sample.
    private static func waitForThreads(atMost ceiling: Int, timeout: TimeInterval) -> Int {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var n = liveThreads()
        while n > ceiling && Date() < deadline {
            usleep(20_000)
            n = liveThreads()
        }
        return n
    }

    // Run an async body from this synchronous test entry point.
    private static func sync(_ body: @escaping @Sendable () async -> Void) {
        let g = DispatchGroup()
        g.enter()
        Task { await body(); g.leave() }
        g.wait()
    }

    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Pool thread-leak test")

        let cap = Int(sysctlInt("kern.num_taskthreads") ?? 6144)
        print("  kern.num_taskthreads = \(cap)")

        let W = 64
        let baseline = waitForThreads(atMost: 0, timeout: 0.5)  // settle, then read
        print("  baseline threads = \(baseline)")

        // CASE 1: the pool really does create OS threads. If this fails the rest
        // of the test proves nothing, so assert it explicitly.
        var pool: GitWorkPool? = GitWorkPool(width: W)
        let withPool = liveThreads()
        check("a width-\(W) pool creates ~\(W) real OS threads",
              withPool >= baseline + W - 2,
              "baseline \(baseline) → \(withPool)")

        // ...and it still runs work correctly.
        let results = Mutex<[Int]>([])
        if let p = pool {
            sync {
                await withTaskGroup(of: Int.self) { g in
                    for i in 0..<200 { g.addTask { await p.run { i * 2 } } }
                    for await v in g { results.withLock { $0.append(v) } }
                }
            }
        }
        let got = results.withLock { $0.sorted() }
        check("all 200 jobs ran", got.count == 200, "got \(got.count)")
        check("job results are correct", got == (0..<200).map { $0 * 2 })

        // CASE 2: THE LEAK. Releasing the pool must make its threads exit.
        // Before the fix this stayed at baseline+64 forever.
        pool = nil
        let afterRelease = waitForThreads(atMost: baseline + 4, timeout: 10)
        check("releasing the pool retires its worker threads",
              afterRelease <= baseline + 4,
              "expected ~\(baseline), still \(afterRelease) (leaked \(afterRelease - baseline))")

        // CASE 3: the shape that actually bit us — one pool per scheduled run,
        // 48 runs in 24h. Cycle enough pools that the pre-fix leak would be
        // unmistakable (12 × 64 = 768 threads) and assert we end where we began.
        let cycles = 12
        for _ in 0..<cycles {
            var p: GitWorkPool? = GitWorkPool(width: W)
            if let p { sync { _ = await p.run { 1 } } }
            p = nil
        }
        let afterCycles = waitForThreads(atMost: baseline + 4, timeout: 20)
        check("\(cycles) pool lifecycles leak nothing (pre-fix: +\(cycles * W) threads)",
              afterCycles <= baseline + 4,
              "expected ~\(baseline), got \(afterCycles) (leaked \(afterCycles - baseline))")
        check("thread count stays far below the process ceiling",
              afterCycles < cap / 2, "\(afterCycles) of \(cap)")

        // CASE 4: explicit shutdown() retires the threads too, without waiting
        // for release.
        let p4 = GitWorkPool(width: W)
        let before4 = liveThreads()
        p4.shutdown()
        let after4 = waitForThreads(atMost: baseline + 4, timeout: 10)
        check("explicit shutdown() retires the threads",
              after4 <= baseline + 4, "\(before4) → \(after4)")

        // CASE 5: a job submitted to a shut-down pool must still COMPLETE. No
        // worker will dequeue it, and the pre-fix code would suspend on a
        // continuation nobody resumes — the same infinite, CPU-free hang that
        // thread exhaustion produced. This is the reachable proxy for "the pool
        // has no live workers", which we cannot force without exhausting the
        // process's threads for real.
        let ran = Mutex<Bool>(false)
        let finished = DispatchSemaphore(value: 0)
        Task {
            let v = await p4.run { 42 }
            ran.withLock { $0 = (v == 42) }
            finished.signal()
        }
        let landed = finished.wait(timeout: .now() + 10) == .success
        check("run() on a shut-down pool completes instead of hanging", landed)
        check("run() on a shut-down pool returns the real result",
              landed && ran.withLock { $0 })

        // CASE 6: work queued immediately before shutdown is still drained, so
        // shutting down mid-run cannot orphan a continuation either.
        let p6 = GitWorkPool(width: 4)
        let drained = Mutex<Int>(0)
        let allDone = DispatchSemaphore(value: 0)
        Task {
            await withTaskGroup(of: Void.self) { g in
                for _ in 0..<32 {
                    g.addTask { await p6.run { drained.withLock { $0 += 1 } } }
                }
                await g.waitForAll()
            }
            allDone.signal()
        }
        usleep(5_000)
        p6.shutdown()
        let drainedInTime = allDone.wait(timeout: .now() + 15) == .success
        check("jobs queued before shutdown all complete", drainedInTime)
        check("every queued job ran exactly once",
              drained.withLock { $0 } == 32, "ran \(drained.withLock { $0 })/32")

        // CASE 7: the shape fanOut actually uses — the pool is a `let` captured
        // by the task-group child closures, not an explicitly-nilled optional.
        // This is the one that has to hold, because it is the code that ran 48
        // times in the wedged process.
        for _ in 0..<cycles {
            sync {
                let pool = GitWorkPool(width: W)
                await withTaskGroup(of: Void.self) { g in
                    for i in 0..<W { g.addTask { _ = await pool.run { i } } }
                    await g.waitForAll()
                }
            }
        }
        let afterFanOut = waitForThreads(atMost: baseline + 4, timeout: 20)
        check("\(cycles) fanOut-shaped runs leak nothing",
              afterFanOut <= baseline + 4,
              "expected ~\(baseline), got \(afterFanOut) (leaked \(afterFanOut - baseline))")

        let finalCount = waitForThreads(atMost: baseline + 4, timeout: 10)
        print("  final threads = \(finalCount) (baseline \(baseline))")

        print()
        if failures == 0 { print("Pool thread-leak test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }

    private static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 { return value }
        var v32: Int32 = 0
        var s32 = MemoryLayout<Int32>.size
        if sysctlbyname(name, &v32, &s32, nil, 0) == 0 { return Int64(v32) }
        return nil
    }
}

// Minimal lock-guarded box so the test can accumulate results from concurrent
// tasks without pulling in anything from the app.
private final class Mutex<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
