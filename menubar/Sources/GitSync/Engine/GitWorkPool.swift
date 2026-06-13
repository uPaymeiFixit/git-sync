import Foundation

// Runs blocking git work (RepoSyncer.cloneOrUpdate, which does synchronous
// subprocess I/O) on REAL OS threads via a concurrent DispatchQueue — not
// Swift's cooperative task pool.
//
// Why this exists: git clone/fetch BLOCK their thread on network+disk I/O.
// You want many more of them in flight than you have CPU cores (the work is
// I/O-bound, not CPU-bound) — that's the whole point of "128 workers". Swift's
// cooperative concurrency pool is sized ~= core count and is explicitly NOT
// meant to host blocking calls; doing so risks starvation or thread
// explosion. A dedicated GCD concurrent queue gives us OS threads that can
// all sit blocked on I/O at once, exactly like the Python's
// ThreadPoolExecutor(max_workers=PARALLEL). A semaphore caps the width so we
// never exceed the configured worker count.
//
// `run` is async and bridges the blocking call back to the caller's task via
// a continuation, so the engine's TaskGroup orchestration is unchanged.
final class GitWorkPool: @unchecked Sendable {
    private let queue: DispatchQueue
    private let slots: DispatchSemaphore

    init(width: Int) {
        let w = max(1, width)
        self.queue = DispatchQueue(label: "com.uPaymeiFixit.GitSync.work",
                                   qos: .userInitiated, attributes: .concurrent)
        self.slots = DispatchSemaphore(value: w)
    }

    // Runs `work` on a pool thread, suspending the calling task (not a pool
    // thread) until it completes. The semaphore bounds concurrent blocking
    // ops to `width`.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            queue.async {
                self.slots.wait()
                defer { self.slots.signal() }
                cont.resume(returning: work())
            }
        }
    }
}
