import Foundation
import Network

// Watches the system network path so the app can tell "the network is up" from
// "the network is coming up".
//
// Why this exists: the scheduler's wake trigger is
// NSWorkspace.didWakeNotification, which fires when the machine wakes — BEFORE
// the VPN finishes reconnecting. That is the exact window the "syncs go
// infinitely on first wake" report lands in, and it is worse than being simply
// offline: with the tunnel half-up, DNS can resolve while packets go nowhere, so
// git stalls in connect() instead of failing fast. A stalled connect emits no
// progress, so the UI sits on "starting" until GIT_SYNC_TIMEOUT (1800s).
//
// Two jobs:
//   1. Report whether a usable path exists at all, so a run can be deferred
//      rather than started into a void.
//   2. Fire on every path CHANGE, which is what lets "the VPN just came up"
//      trigger a re-probe + catch-up immediately instead of waiting up to 30
//      minutes for the next scheduler heartbeat.
//
// NWPathMonitor reports interface-level reachability only. It cannot know
// whether a specific host behind a VPN is answering — that stays
// ProviderHealth's job (an actual probe). This narrows the window; it does not
// replace the probe.

final class NetworkPathMonitor: @unchecked Sendable {
    // Called on every path change, with the new satisfied-ness. Set before
    // start(). Invoked on an internal queue, NOT the main thread.
    var onChange: (@Sendable (Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.uPaymeiFixit.GitSync.pathmonitor")
    private let lock = NSLock()
    private var _satisfied = true      // optimistic until told otherwise
    private var started = false

    // Whether the system currently has a usable network path. Optimistic before
    // the first callback: never let an un-started monitor be the reason a sync
    // refuses to run.
    var isSatisfied: Bool {
        lock.lock(); defer { lock.unlock() }
        return _satisfied
    }

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            self.lock.lock()
            let changed = self._satisfied != satisfied
            self._satisfied = satisfied
            self.lock.unlock()
            // Fire on EVERY update, not only on changed satisfied-ness: a VPN
            // coming up while already on Wi-Fi keeps status == .satisfied but
            // changes which interfaces/routes exist, and that transition is
            // precisely the "VPN is back, retry now" signal we want. `changed`
            // is passed along only for logging.
            RunLog.networkPath(satisfied: satisfied, changed: changed)
            self.onChange?(satisfied)
        }
        monitor.start(queue: queue)
    }

    // Wait (up to `timeout`) for a usable network path. Returns true if one is
    // available. Used to hold a wake-triggered run for a few seconds while the
    // interfaces settle, instead of launching it into a half-up tunnel.
    //
    // Polls rather than using a continuation because callers are a mix of sync
    // worker contexts and async tasks; the wait is short and coarse.
    func waitForPath(timeout: TimeInterval) async -> Bool {
        if isSatisfied { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if isSatisfied { return true }
        }
        return isSatisfied
    }
}
