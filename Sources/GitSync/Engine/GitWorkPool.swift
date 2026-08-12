import Foundation

// A fixed pool of REAL OS threads for running blocking git work (clone/fetch
// shell out and block on network+disk I/O) — a bounded worker pool of width N.
//
// WHY NOT the obvious GCD version: the previous implementation did
// `concurrentQueue.async { semaphore.wait(); work() }`. At width=128 GCD
// eagerly schedules many blocks, each PARKS a GCD worker thread on the
// semaphore, GCD hits its ~70-thread soft limit with every thread blocked,
// and nothing progresses — a thread-explosion deadlock. Blocking a GCD
// worker thread on a semaphore is the documented antipattern.
//
// This version creates exactly `width` long-lived worker threads up front.
// Each worker loops: pull a job off a condition-guarded queue, run the
// blocking closure ON ITS OWN OS THREAD, resume the job's continuation, repeat.
// Thread count is therefore strictly bounded at `width` per pool, and a pool's
// threads exit when the pool is released (see Shared).
// Submitting (`run`) never blocks an OS thread: it appends to the queue under
// a brief lock and signals; the calling Swift TASK suspends on the
// continuation (not a thread) until a worker finishes the work.
final class GitWorkPool: @unchecked Sendable {

    // The queue, condvar and shutdown flag — held STRONGLY by the worker
    // threads. Splitting this out of GitWorkPool is not tidiness, it IS the fix
    // for a 24-hour-fuse thread leak:
    //
    // The workers used to capture the pool itself as
    //     Thread { [weak self] in self?.workerLoop() }
    // which reads as leak-safe and is not. `self?.workerLoop()` upgrades the
    // weak reference to a STRONG one for the duration of the call, and that call
    // is an infinite loop that only returns once `shuttingDown` is set — which
    // only `deinit` ever did. So each of the 128 workers held +1 on the pool,
    // the refcount never reached 0, deinit never ran, and the workers never
    // exited. Every full sync run permanently leaked its whole pool: 128 OS
    // threads and 512 MB of stack address space, for the life of the process.
    //
    // macOS caps one process at kern.num_taskthreads = 6144 threads. At the
    // 30-minute scheduler heartbeat that ceiling arrives after 48 runs — almost
    // exactly 24 hours of uptime — and then pthread_create starts failing,
    // nothing can be dispatched, and every repo row sits on "starting" with the
    // clock ticking up, zero CPU, and no git child process anywhere. Quitting
    // and relaunching cleared it, which is why it kept reading as a wake/VPN
    // bug: the machine that had just slept was also the machine that had been
    // up long enough to run out of threads.
    //
    // Workers holding `Shared` instead of the pool means the pool's refcount is
    // driven only by its actual users, so releasing it runs deinit, which tells
    // the workers to exit. No call site has to remember to clean up.
    // Guarded by --pool-leak-test.
    private final class Shared: @unchecked Sendable {
        // A queued unit of work: the closure to run and the resume hook. Type
        // erasure (the closure already captures its own T and resumes the
        // continuation) keeps the queue homogeneous.
        typealias Job = @Sendable () -> Void

        let cond = NSCondition()
        var jobs: [Job] = []              // guarded by cond
        var shuttingDown = false          // guarded by cond
        var liveWorkers = 0               // workers inside their loop; guarded by cond
        var hasWorkers = false            // set once by init; guarded by cond

        // Worker thread main loop. Blocks (releasing the lock) until a job is
        // available or shutdown is requested. Runs the blocking job OUTSIDE the
        // lock so workers don't serialize.
        func workerLoop() {
            cond.lock()
            liveWorkers += 1
            // Only the first worker has to wake init's "did a thread actually
            // start?" wait; broadcasting from all N would churn the idle ones.
            if liveWorkers == 1 { cond.broadcast() }
            cond.unlock()

            while true {
                cond.lock()
                while jobs.isEmpty && !shuttingDown {
                    cond.wait()
                }
                // Drain before exiting: a job accepted moments before shutdown
                // still has a continuation waiting to be resumed.
                if jobs.isEmpty {                  // implies shuttingDown
                    liveWorkers -= 1
                    cond.unlock()
                    return
                }
                let job = jobs.removeFirst()
                cond.unlock()
                job()                              // blocking git work, off the lock
            }
        }

        func shutdown() {
            cond.lock()
            shuttingDown = true
            cond.broadcast()                       // wake idle workers so they can exit
            cond.unlock()
        }
    }

    private let shared = Shared()

    init(width: Int) {
        let s = shared      // a LOCAL: `Thread { shared… }` would capture self.
        for i in 0..<max(1, width) {
            let t = Thread { s.workerLoop() }
            t.name = "GitWorkPool-\(i)"
            t.stackSize = 4 << 20          // 4 MB; git output buffers are small
            t.start()
        }
        // Confirm at least one worker actually reached its loop. Thread.start()
        // reports nothing at all when pthread_create fails with EAGAIN (the
        // process is out of threads), and a pool with zero workers would accept
        // jobs forever and run none of them — a continuation nobody resumes,
        // which is an infinite hang with no CPU and nothing to see in a sample.
        // Normally this returns in microseconds; the deadline only bites when
        // the process is genuinely out of threads, and then `run` degrades to
        // inline execution instead of hanging.
        s.cond.lock()
        let deadline = Date(timeIntervalSinceNow: 2)
        while s.liveWorkers == 0 && Date() < deadline {
            _ = s.cond.wait(until: deadline)
        }
        s.hasWorkers = s.liveWorkers > 0
        s.cond.unlock()
    }

    deinit {
        // The only thing that stops the worker threads. Reachable precisely
        // because the workers hold `shared` rather than `self` — see Shared.
        shared.shutdown()
    }

    // Stop the workers now rather than waiting for release. Optional: deinit
    // does this too, so no caller is obliged to call it.
    func shutdown() { shared.shutdown() }

    // Submit blocking work; suspend the calling task until it completes.
    // Never blocks an OS thread on a lock/semaphore — only appends + signals.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            shared.cond.lock()
            if shared.hasWorkers && !shared.shuttingDown {
                shared.jobs.append { cont.resume(returning: work()) }
                shared.cond.signal()               // wake one idle worker
                shared.cond.unlock()
                return
            }
            shared.cond.unlock()
            // Nobody will ever dequeue this job — no worker thread started, or
            // the pool is already shutting down. Run it on the calling thread:
            // slower, and outside the width bound, but it FINISHES. The
            // alternative is a continuation nobody resumes, which is the exact
            // silent-forever shape this file cost us once already.
            cont.resume(returning: work())
        }
    }
}
