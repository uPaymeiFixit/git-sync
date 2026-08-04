import Foundation

// Regression for the "each sync just goes infinitely on first wake" wedge.
//
// Reachability was a STEP INSIDE runFull (it called hostReachable itself), so
// runIndividual — added later — simply never checked. A per-repo sync on a down
// VPN therefore went straight into discoverOne (5 HTTP attempts × 60s + ~30s
// backoff ≈ 5.5 min) and then into git with GIT_SYNC_TIMEOUT (1800s), emitting
// no progress events the whole time. The UI sat on "starting" with no error:
// 31 repos × that, which is what the screenshot showed.
//
//   GitSync --reachability-gate-test
//
// The fix makes reachability a thing you ASK (ProviderHealth), shared by both
// sync paths and the UI dot. This test drives that state machine with an
// injected probe — no network, no VPN, fully deterministic — and pins the
// properties that actually prevent the wedge:
//
//   1. An unreachable host is reported as such (the gate answers at all).
//   2. A burst of callers pays ONE probe, not one each (31 repos ≠ 31 × 8s).
//   3. A failed answer is cached, so repos 2..N fail instantly from cache.
//   4. Failure backoff widens, so the scheduler's every-wake retry can't spin.
//   5. A network-path change invalidates the cache, so "the VPN came back"
//      re-probes immediately instead of serving a stale "unreachable".
//   6. An auth failure still counts as REACHABLE (the host answered) — a
//      wrong token must not be misreported as VPN-down and refuse syncs.
//   7. A nil probeURL is treated as reachable (can't pre-check ⇒ don't block).
enum ReachabilityGateTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Reachability-gate test")

        let url = URL(string: "https://gitlab.example.com/api/v4/version")!
        let pid = "provider-1"

        // A controllable clock + probe counter, so we can assert on probe COUNT
        // and step time forward without sleeping.
        final class Harness: @unchecked Sendable {
            let lock = NSLock()
            var probeCount = 0
            var failWith: String? = "host did not respond"
            var now = Date(timeIntervalSince1970: 1_000_000)
            func probe(_: URL) -> String? {
                lock.lock(); defer { lock.unlock() }
                probeCount += 1
                return failWith
            }
            func clock() -> Date {
                lock.lock(); defer { lock.unlock() }
                return now
            }
            func advance(_ s: TimeInterval) {
                lock.lock(); defer { lock.unlock() }
                now = now.addingTimeInterval(s)
            }
            var count: Int {
                lock.lock(); defer { lock.unlock() }
                return probeCount
            }
        }

        // ---- 1. The gate answers: unreachable host reports unreachable ----
        let h1 = Harness()
        let health1 = ProviderHealth(probe: { h1.probe($0) }, now: { h1.clock() })
        let s1 = health1.reachable(providerID: pid, probeURL: url)
        check("unreachable host reports not-reachable", !s1.isReachable)
        check("unreachable carries a detail for the user",
              s1.detail?.isEmpty == false, "detail=\(s1.detail ?? "nil")")
        check("one call → one probe", h1.count == 1, "probes=\(h1.count)")

        // ---- 2+3. A burst shares one probe; later callers hit cache --------
        // This is the 31-repos-in-the-screenshot case. Serially probing each
        // would be 31 × 8s ≈ 4 minutes of "starting" before the first error.
        let h2 = Harness()
        let health2 = ProviderHealth(probe: { h2.probe($0) }, now: { h2.clock() })
        for _ in 0..<31 { _ = health2.reachable(providerID: pid, probeURL: url) }
        check("31 sequential callers share one cached probe", h2.count == 1,
              "probes=\(h2.count)")
        check("cached answer is still unreachable",
              !health2.state(pid).isReachable)

        // Concurrent burst: probeInFlight must collapse a real parallel storm
        // onto a single request. 31 threads, all arriving at once.
        let h3 = Harness()
        let health3 = ProviderHealth(probe: { u in
            Thread.sleep(forTimeInterval: 0.05)   // make the window real
            return h3.probe(u)
        }, now: { h3.clock() })
        let group = DispatchGroup()
        for _ in 0..<31 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                _ = health3.reachable(providerID: pid, probeURL: url)
            }
        }
        group.wait()
        check("31 CONCURRENT callers collapse onto one in-flight probe",
              h3.count == 1, "probes=\(h3.count)")

        // ---- 4. Failure backoff widens -----------------------------------
        let h4 = Harness()
        let health4 = ProviderHealth(probe: { h4.probe($0) }, now: { h4.clock() })
        _ = health4.reachable(providerID: pid, probeURL: url)   // probe 1, fail
        check("fresh immediately after a failed probe", health4.isFresh(pid))
        // First backoff step is 5s: at 4s still cached, at 6s re-probes.
        h4.advance(4)
        _ = health4.reachable(providerID: pid, probeURL: url)
        check("within first backoff window → no re-probe", h4.count == 1,
              "probes=\(h4.count)")
        h4.advance(3)   // now 7s past
        _ = health4.reachable(providerID: pid, probeURL: url)
        check("past first backoff window → re-probes", h4.count == 2,
              "probes=\(h4.count)")
        check("consecutive failures accumulate",
              health4.state(pid).consecutiveFailures == 2,
              "failures=\(health4.state(pid).consecutiveFailures)")
        // Second step is 15s — 7s is NOT enough now (it was, at step 1).
        h4.advance(7)
        _ = health4.reachable(providerID: pid, probeURL: url)
        check("backoff widened (7s no longer enough at step 2)", h4.count == 2,
              "probes=\(h4.count)")
        h4.advance(10)  // 17s past the 2nd failure
        _ = health4.reachable(providerID: pid, probeURL: url)
        check("past widened window → re-probes", h4.count == 3, "probes=\(h4.count)")

        // ---- 5. Path change invalidates, so a VPN return is noticed now ----
        let h5 = Harness()
        let health5 = ProviderHealth(probe: { h5.probe($0) }, now: { h5.clock() })
        _ = health5.reachable(providerID: pid, probeURL: url)   // fail, cached
        check("cached unreachable before path change", health5.isFresh(pid))
        h5.failWith = nil                                       // VPN comes up
        // Without invalidation the backoff window would still serve the stale
        // "unreachable" — this is the "waits up to 30 min to notice" bug.
        _ = health5.reachable(providerID: pid, probeURL: url)
        check("stale cache would still say unreachable", !health5.state(pid).isReachable)
        health5.invalidateAll()
        check("invalidateAll clears freshness", !health5.isFresh(pid))
        let s5 = health5.reachable(providerID: pid, probeURL: url)
        check("after invalidation the recovered host is reachable", s5.isReachable)
        check("recovery resets the failure counter",
              health5.state(pid).consecutiveFailures == 0,
              "failures=\(health5.state(pid).consecutiveFailures)")

        // ---- 6. Auth failure ≠ unreachable --------------------------------
        // A 401 proves the host ANSWERED. Recording it as unreachable would
        // refuse syncs for a wrong-token provider with a VPN-down message.
        let h6 = Harness()
        let health6 = ProviderHealth(probe: { h6.probe($0) }, now: { h6.clock() })
        health6.note(providerID: pid, reachable: true)   // what AppState does for 401/403/404
        check("auth-failed-but-answered counts as reachable",
              health6.state(pid).isReachable)
        check("noted verdict is fresh (no probe needed)", health6.isFresh(pid))
        check("noting did not fire a probe", h6.count == 0, "probes=\(h6.count)")
        health6.note(providerID: pid, reachable: false, detail: "connection refused")
        check("a transport failure notes as unreachable",
              !health6.state(pid).isReachable)
        check("noted failure keeps its detail",
              health6.state(pid).detail == "connection refused",
              "detail=\(health6.state(pid).detail ?? "nil")")

        // ---- 7. No probe endpoint ⇒ don't block the provider --------------
        let h7 = Harness()
        let health7 = ProviderHealth(probe: { h7.probe($0) }, now: { h7.clock() })
        let s7 = health7.reachable(providerID: pid, probeURL: nil)
        check("nil probeURL treated as reachable", s7.isReachable)
        check("nil probeURL fires no probe", h7.count == 0, "probes=\(h7.count)")

        // ---- 8. Success TTL: a good answer is cached, then re-checked -----
        let h8 = Harness()
        h8.failWith = nil
        let health8 = ProviderHealth(probe: { h8.probe($0) }, now: { h8.clock() })
        _ = health8.reachable(providerID: pid, probeURL: url)
        h8.advance(ProviderHealth.successTTL / 2)
        _ = health8.reachable(providerID: pid, probeURL: url)
        check("reachable answer is cached within its TTL", h8.count == 1,
              "probes=\(h8.count)")
        h8.advance(ProviderHealth.successTTL)
        _ = health8.reachable(providerID: pid, probeURL: url)
        check("reachable answer re-probes after its TTL", h8.count == 2,
              "probes=\(h8.count)")

        // ---- 9. Per-provider isolation ------------------------------------
        // A down GitLab must not make GitHub/Bitbucket look down (the whole
        // point of the per-platform isolation the scheduler relies on).
        let h9 = Harness()
        let health9 = ProviderHealth(probe: { u in
            u.absoluteString.contains("gitlab") ? "host did not respond" : nil
        }, now: { h9.clock() })
        let gl = health9.reachable(providerID: "gitlab-1", probeURL: url)
        let gh = health9.reachable(providerID: "github-1",
                                   probeURL: URL(string: "https://api.github.com")!)
        check("down provider reports unreachable", !gl.isReachable)
        check("healthy provider is unaffected by the down one", gh.isReachable)

        // ---- 10. Local remotes bypass the gate ----------------------------
        // The gate avoids a doomed NETWORK round trip. A file:// or absolute-path
        // remote reaches no host, so an unreachable provider API host must not
        // refuse a sync that works fine offline (this is also what the
        // abort-reset fixture relies on).
        check("absolute path is a local remote",
              SyncEngine.isLocalRemote("/tmp/gitsync/repo.git"))
        check("file:// URL is a local remote",
              SyncEngine.isLocalRemote("file:///tmp/gitsync/repo.git"))
        check("scp-style git@host:path is NOT local",
              !SyncEngine.isLocalRemote("git@gitlab.example.com:group/repo.git"))
        check("ssh:// URL is NOT local",
              !SyncEngine.isLocalRemote("ssh://git@gitlab.example.com/group/repo.git"))
        check("https URL is NOT local",
              !SyncEngine.isLocalRemote("https://gitlab.example.com/group/repo.git"))

        print()
        if failures == 0 { print("Reachability-gate test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }
}
