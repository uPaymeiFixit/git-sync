import Foundation
import Synchronization

// The single owner of "can I reach this provider's host right now?".
//
// Before this existed, reachability was a STEP INSIDE one sync path: runFull
// called hostReachable() itself, and runIndividual — added later — simply
// forgot to. Nothing structurally required the check, so a per-repo sync on a
// down VPN skipped straight to discoverOne (5 attempts × 60s + backoff ≈ 5.5
// min) and then to git (GIT_SYNC_TIMEOUT, 1800s), which is the "each sync just
// goes infinitely on wake" report: rows frozen on "starting" with no progress
// events because a stalled connect() emits nothing.
//
// So reachability is now a thing you ASK, not a step you remember to perform.
// Both sync paths gate on `reachable(...)`; the Providers tab status dot reads
// the same cache, so "the dot is red" and "the sync refused" are one fact
// instead of two independent guesses.
//
// Two properties make it safe to consult from the hot path:
//
//   - Cached with a TTL. A batch of 31 individual syncs shares ONE probe
//     instead of paying 8s each (~4 min serially). `probeInFlight` collapses a
//     concurrent burst onto a single in-flight probe rather than letting all 31
//     race and fire 31 HEADs.
//   - Backoff while down. A VPN-down GitLab stays permanently "due" in the
//     scheduler (see Scheduler.fireIfDue), so it re-probed on every 30-min
//     heartbeat AND every wake, forever. Consecutive failures widen the retry
//     interval, so a machine left off-VPN stops probing in a tight loop.
//
// Not an actor: the callers are a mix of actor-isolated (SyncEngine), MainActor
// (AppState/UI) and plain worker threads. A lock-protected value type keeps it
// callable from all three without forcing every reader to be async. The lock is
// held only around small dictionary reads/writes — never across the probe
// itself (see `reachable`), so a slow probe can't convoy other callers. This is
// the same reason AbortBox is atomic rather than lock-guarded, one level up:
// don't hold a lock across I/O.

// What we know about one provider's host, and when we learned it.
struct ProviderHealthState: Sendable, Equatable {
    enum Reachability: Sendable, Equatable {
        case unknown              // never probed (or cache expired)
        case reachable
        case unreachable(String)  // transport-level detail for the UI/log

        var isReachable: Bool { if case .reachable = self { return true } else { return false } }
    }

    var reachability: Reachability = .unknown
    var checkedAt: Date? = nil
    // Consecutive failed probes; drives the retry backoff below.
    var consecutiveFailures: Int = 0

    var isReachable: Bool { reachability.isReachable }

    var detail: String? {
        if case .unreachable(let d) = reachability { return d }
        return nil
    }
}

final class ProviderHealth: @unchecked Sendable {
    // How long a SUCCESSFUL probe stays trusted. Short: a VPN can drop at any
    // moment, and the cost of being wrong is one stalled git call. Long enough
    // that a fan-out batch shares one probe.
    static let successTTL: TimeInterval = 30

    // Retry schedule after consecutive failures — 5s, then 15s, 60s, 300s,
    // capped. The first entry keeps a user who just reconnected from waiting:
    // a manual "Sync this repo" 5s after the VPN comes up re-probes rather
    // than serving a stale "unreachable". The cap stops the scheduler's
    // every-wake retry from probing in a tight loop for hours.
    static let failureBackoff: [TimeInterval] = [5, 15, 60, 300]

    private let lock = NSLock()
    private var states: [String: ProviderHealthState] = [:]   // keyed by providerID
    // providerIDs with a probe in flight, so a burst of callers shares one HEAD
    // request instead of each firing their own.
    private var probeInFlight = Set<String>()

    // Injectable so tests can drive the whole state machine without a network.
    // Returns nil when reachable, or a failure detail when not.
    private let probe: @Sendable (URL) -> String?
    private let now: @Sendable () -> Date

    init(probe: @escaping @Sendable (URL) -> String? = { url in
             hostReachable(url) ? nil : "host did not respond"
         },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.probe = probe
        self.now = now
    }

    // ---- Reads (never probe) ------------------------------------------

    func state(_ providerID: String) -> ProviderHealthState {
        lock.lock(); defer { lock.unlock() }
        return states[providerID] ?? ProviderHealthState()
    }

    // True when the cached answer is still within its TTL / backoff window.
    // Callers that merely DISPLAY health use this to avoid triggering probes
    // from a view body.
    func isFresh(_ providerID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isFreshLocked(states[providerID])
    }

    private func isFreshLocked(_ s: ProviderHealthState?) -> Bool {
        guard let s, let checkedAt = s.checkedAt else { return false }
        let age = now().timeIntervalSince(checkedAt)
        switch s.reachability {
        case .unknown:
            return false
        case .reachable:
            return age < Self.successTTL
        case .unreachable:
            let idx = min(max(0, s.consecutiveFailures - 1), Self.failureBackoff.count - 1)
            return age < Self.failureBackoff[idx]
        }
    }

    // ---- The gate ------------------------------------------------------

    // The question both sync paths ask. Returns the cached answer when fresh,
    // otherwise probes once and caches.
    //
    // `probeURL` nil = the provider has no probe endpoint; treat as reachable
    // (we can't tell, and refusing would break a provider we simply can't
    // pre-check) — matching runFull's original `if let probe` behavior.
    func reachable(providerID: String, probeURL: URL?) -> ProviderHealthState {
        guard let probeURL else {
            return ProviderHealthState(reachability: .reachable, checkedAt: now())
        }

        // Fast path: fresh cached answer, or someone else is already probing.
        lock.lock()
        if let s = states[providerID], isFreshLocked(s) {
            lock.unlock()
            return s
        }
        if probeInFlight.contains(providerID) {
            // A probe is already running. Serve the last known answer rather
            // than piling on a duplicate request — for a 31-repo burst that is
            // the difference between 1 HEAD and 31. A stale answer here is
            // acceptable: the in-flight probe will land in a moment and the
            // worst case is one extra git attempt.
            let s = states[providerID] ?? ProviderHealthState()
            lock.unlock()
            return s
        }
        probeInFlight.insert(providerID)
        let previous = states[providerID] ?? ProviderHealthState()
        lock.unlock()

        // Probe OUTSIDE the lock — this is a network round trip (up to ~8s).
        // Holding the lock here would serialize every other provider's health
        // query behind it.
        let failure = probe(probeURL)

        lock.lock()
        var next = previous
        next.checkedAt = now()
        if let failure {
            next.reachability = .unreachable(failure)
            next.consecutiveFailures = previous.consecutiveFailures + 1
        } else {
            next.reachability = .reachable
            next.consecutiveFailures = 0
        }
        states[providerID] = next
        probeInFlight.remove(providerID)
        lock.unlock()
        return next
    }

    // ---- Invalidation --------------------------------------------------

    // Drop every cached answer. Called when the network path changes (VPN up /
    // interface change / wake): whatever we knew about reachability was learned
    // on a different network and is now worthless. This is what turns "the VPN
    // came back" into an immediate re-probe instead of waiting out the backoff.
    func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        for key in states.keys {
            states[key]?.reachability = .unknown
            states[key]?.checkedAt = nil
            states[key]?.consecutiveFailures = 0
        }
    }

    func invalidate(providerID: String) {
        lock.lock(); defer { lock.unlock() }
        states[providerID] = ProviderHealthState()
    }

    // Record an externally-obtained verdict (e.g. the Providers tab's
    // "Test connection", which makes a real authenticated request and
    // therefore knows more than a HEAD probe does). Keeps the dot and the
    // sync gate consistent — one fact, not two.
    func note(providerID: String, reachable: Bool, detail: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var s = states[providerID] ?? ProviderHealthState()
        s.checkedAt = now()
        if reachable {
            s.reachability = .reachable
            s.consecutiveFailures = 0
        } else {
            s.reachability = .unreachable(detail ?? "host did not respond")
            s.consecutiveFailures += 1
        }
        states[providerID] = s
    }
}
