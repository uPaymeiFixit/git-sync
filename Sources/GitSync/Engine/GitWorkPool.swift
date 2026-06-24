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
// Thread count is therefore strictly bounded at `width` and never grows.
// Submitting (`run`) never blocks an OS thread: it appends to the queue under
// a brief lock and signals; the calling Swift TASK suspends on the
// continuation (not a thread) until a worker finishes the work.
final class GitWorkPool: @unchecked Sendable {
    // A queued unit of work: the closure to run and the resume hook. Type
    // erasure (the closure already captures its own T and resumes the
    // continuation) keeps the queue homogeneous.
    private typealias Job = @Sendable () -> Void

    private let cond = NSCondition()
    private var jobs: [Job] = []          // guarded by cond
    private var shuttingDown = false      // guarded by cond
    private let width: Int

    init(width: Int) {
        self.width = max(1, width)
        for i in 0..<self.width {
            let t = Thread { [weak self] in self?.workerLoop() }
            t.name = "GitWorkPool-\(i)"
            t.stackSize = 4 << 20          // 4 MB; git output buffers are small
            t.start()
        }
    }

    deinit {
        cond.lock()
        shuttingDown = true
        cond.broadcast()                  // wake idle workers so they can exit
        cond.unlock()
    }

    // Worker thread main loop. Blocks (releasing the lock) until a job is
    // available or shutdown is requested. Runs the blocking job OUTSIDE the
    // lock so workers don't serialize.
    private func workerLoop() {
        while true {
            cond.lock()
            while jobs.isEmpty && !shuttingDown {
                cond.wait()
            }
            if shuttingDown && jobs.isEmpty {
                cond.unlock()
                return
            }
            let job = jobs.removeFirst()
            cond.unlock()
            job()                          // blocking git work, off the lock
        }
    }

    // Submit blocking work; suspend the calling task until it completes.
    // Never blocks an OS thread on a lock/semaphore — only appends + signals.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let job: Job = { cont.resume(returning: work()) }
            cond.lock()
            jobs.append(job)
            cond.signal()                  // wake one idle worker
            cond.unlock()
        }
    }
}
