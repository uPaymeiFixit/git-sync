import Foundation

// Regression for the lock-convoy wedge: AbortBox.value is polled in a tight
// per-output-chunk loop by every git worker. When it was guarded by an NSLock,
// 128 worker threads each taking that pthread_mutex on every progress chunk
// convoyed in the kernel (__psynch_mutexwait), collapsing 128-way parallelism
// to crawling single-file lock handoff — the "591 repos, stuck 10 min" hang.
//
//   GitSync --abort-contention-test
//
// Simulates the hot path: W threads each poll AbortBox.value POLLS_PER_THREAD
// times with zero real work between polls (worst case for lock contention).
// With the lock-free Atomic implementation this is a few hundred ms; with a
// contended NSLock at this width it takes many seconds (or worse). We assert a
// generous wall-clock ceiling that a lock-free read clears comfortably and a
// 128-way-contended mutex cannot.
enum AbortContentionTest {
    static func run() -> Int32 {
        let W = 128
        let pollsPerThread = 2_000_000
        let abort = AbortBox()

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Abort-contention test (\(W) threads × \(pollsPerThread) polls)")

        // Sum the reads so the optimizer can't elide the loop.
        let counter = Counter()
        let start = Date()
        DispatchQueue.concurrentPerform(iterations: W) { _ in
            var seen = 0
            for _ in 0..<pollsPerThread {
                if abort.value { seen += 1 }
            }
            counter.add(seen)
        }
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "  %d total polls in %.3fs (%.1fM polls/s), abort never set (seen=%d)",
                     W * pollsPerThread, elapsed,
                     Double(W * pollsPerThread) / elapsed / 1_000_000, counter.value))

        // Lock-free: ~hundreds of ms even on modest hardware. A 128-way
        // contended NSLock blows past this by an order of magnitude.
        check("256M contended polls complete under 5s (no lock convoy)",
              elapsed < 5.0, String(format: "took %.3fs", elapsed))
        check("abort flag stayed false", counter.value == 0)

        // Sanity: set/reset still observable across threads.
        abort.set()
        check("set() is visible", abort.value == true)
        abort.reset()
        check("reset() is visible", abort.value == false)

        print()
        if failures == 0 { print("Abort-contention test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }

    // Tiny lock-guarded accumulator — touched once per thread (not in the hot
    // loop), so it doesn't itself perturb the measurement.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _v = 0
        func add(_ n: Int) { lock.lock(); _v += n; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return _v }
    }
}
