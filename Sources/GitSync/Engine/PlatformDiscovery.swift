import Foundation

// Discovery layer: each platform client lists the remote-known repos via its
// REST API. Returns DiscoveredRepo rows plus a `complete` flag — false ⇒
// the listing had errors, so the caller suppresses the stale scan (a partial
// listing would otherwise flag every un-enumerated repo as deleted).

struct DiscoveredRepo: Sendable {
    // Provider-local path, relative to the client's platformRoot (the provider's
    // localPath). No platform-dir prefix in the multi-provider model, e.g. "foo/bar".
    let rel: String
    let sshURL: String
    let defaultBranch: String
    let namespacePath: String  // platform-native path used for skip-matching
}

struct DiscoveryResult: Sendable {
    var repos: [DiscoveredRepo] = []
    var complete: Bool = true       // false = listing had errors (skip stale scan)
    var skipReason: String? = nil   // non-nil = platform skipped (creds/host missing)
    var fatalError: String? = nil   // non-nil = hard failure (exit 1 equivalent)
}

// Common protocol; each platform is a Sendable value built from settings.
protocol PlatformDiscovery: Sendable {
    var platform: Platform { get }
    // The base URL to probe for reachability before the (expensive) discovery.
    // A short-timeout connect here fails fast (~seconds) when the host is
    // unreachable — e.g. GitLab when the VPN is down — instead of letting
    // discoverAll grind through 5 × 60s connect timeouts (~5 min).
    var probeURL: URL? { get }
    func discoverAll(skip: SkipMatcher) -> DiscoveryResult
    // `namespacePath` is the platform-native repo path (RepoID.namespacePath):
    // GitLab path_with_namespace, GitHub repo name, Bitbucket slug.
    func discoverOne(namespacePath: String) -> DiscoveredRepo?
}

// Fast reachability probe: can we open a connection to `url` within `timeout`
// seconds? Uses a HEAD request and treats ANY HTTP response (even 401/404) as
// "reachable" — we only care whether the host answered, not whether we're
// authorized. A connection-level failure (VPN down, DNS, refused) → false.
func hostReachable(_ url: URL, timeout: TimeInterval = 8) -> Bool {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "HEAD"
    // Mutable box for the URLSession completion handler. The semaphore provides
    // the happens-before barrier (signal after the write, read after wait), so
    // @unchecked Sendable is sound here — matches HTTPClient.ResponseBox.
    final class Box: @unchecked Sendable { var ok = false }
    let box = Box()
    let sem = DispatchSemaphore(value: 0)
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = timeout
    cfg.timeoutIntervalForResource = timeout
    let task = URLSession(configuration: cfg).dataTask(with: req) { _, resp, err in
        // Any HTTP response means the host answered. Only a transport error
        // (no response) counts as unreachable.
        if resp != nil { box.ok = true }
        else if err == nil { box.ok = true }
        sem.signal()
    }
    task.resume()
    // The URLSession itself enforces `timeout` and always fires the handler
    // (success or error) at/after the deadline, so the semaphore is guaranteed
    // to be signalled. Wait a hair past the session timeout (a fixed +1s for
    // handler-dispatch latency, not a second full timeout) purely as a
    // belt-and-suspenders deadlock guard; if it ever trips we cancel the task
    // so nothing dangles.
    if sem.wait(timeout: .now() + timeout + 1) == .timedOut {
        task.cancel()
        return false
    }
    return box.ok
}

// Comma-separated skip patterns matched as path prefixes against the
// platform-native namespace path (case-insensitive,
// like RepoActions.isInSkipList).
struct SkipMatcher: Sendable {
    let patterns: [String]
    init(_ raw: String) {
        patterns = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
    func matches(_ namespacePath: String) -> Bool {
        let p = namespacePath.lowercased()
        return patterns.contains { p.hasPrefix($0) }
    }
}

// ---- GitLab: direct REST via URLSession + PRIVATE-TOKEN, consistent with
// the GitHub/Bitbucket clients. Replaces the old `glab` shell-out — no
// bundled binary, no PATH fragility. Auth is the GitLab token from Settings
// (Keychain → GITLAB_TOKEN). ----

struct GitLabClient: PlatformDiscovery {
    let platform = Platform.gitlab
    let host: String           // e.g. "gitlabdev.paciolan.info" (no scheme)
    let token: String          // PRIVATE-TOKEN
    let includeArchived: Bool
    let syncRoot: URL
    // The folder this provider's repos live in, and the base `rel` is relative
    // to. Defaults to syncRoot/Gitlab (legacy single-provider path); the
    // provider path passes the provider's own localPath. `rel` is therefore
    // provider-local (no platform-dir prefix).
    var localRoot: URL? = nil

    private var apiBase: String { "https://\(host)/api/v4" }
    private var platformRoot: URL { localRoot ?? syncRoot.appendingPathComponent("Gitlab") }
    private let accept = "application/json"
    private var headers: [String: String] { ["PRIVATE-TOKEN": token] }

    // GitLab is the one behind the VPN, so this probe is what makes a VPN-down
    // retry cheap: /api/v4/version answers instantly when reachable.
    var probeURL: URL? { URL(string: "https://\(host)/api/v4/version") }

    func discoverAll(skip: SkipMatcher) -> DiscoveryResult {
        var result = DiscoveryResult()
        var seen = Set<String>()
        // min_access_level=10 (Guest+ = member); simple=true trims payload.
        let archivedQS = includeArchived ? "" : "&archived=false"
        var next: URL? = URL(string:
            "\(apiBase)/projects?min_access_level=10\(archivedQS)&simple=true&per_page=100&page=1")
        while let url = next {
            let resp: (status: Int, body: Data, link: String)
            do {
                resp = try HTTPClient.get(url, headers: headers, accept: accept)
            } catch {
                result.fatalError = "GitLab discovery: \(error.localizedDescription)"
                return result
            }
            guard let arr = try? JSONSerialization.jsonObject(with: resp.body) as? [[String: Any]] else {
                result.fatalError = "GitLab discovery: unparseable page"
                return result
            }
            for p in arr {
                guard let branch = p["default_branch"] as? String, !branch.isEmpty,
                      let sshURL = p["ssh_url_to_repo"] as? String, !sshURL.isEmpty,
                      let pathNS = p["path_with_namespace"] as? String, !pathNS.isEmpty,
                      !seen.contains(sshURL) else { continue }
                seen.insert(sshURL)
                let dest = platformRoot.appendingPathComponent(pathNS)
                result.repos.append(DiscoveredRepo(
                    rel: rel(dest), sshURL: sshURL, defaultBranch: branch, namespacePath: pathNS))
            }
            // GitLab sends RFC5988 Link headers with rel="next".
            next = parseNextLink(resp.link)
        }
        return result
    }

    func discoverOne(namespacePath target: String) -> DiscoveredRepo? {
        // `target` is the bare namespace path (caller passes RepoID.namespacePath).
        // URL-encode it (slashes become %2F) for GET /projects/:url-encoded-path.
        let ns = target
        guard let enc = ns.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "\(apiBase)/projects/\(enc)") else { return nil }
        guard let resp = try? HTTPClient.get(url, headers: headers, accept: accept),
              let p = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let branch = p["default_branch"] as? String, !branch.isEmpty,
              let sshURL = p["ssh_url_to_repo"] as? String, !sshURL.isEmpty,
              let pathNS = p["path_with_namespace"] as? String, !pathNS.isEmpty
        else { return nil }
        let dest = platformRoot.appendingPathComponent(pathNS)
        return DiscoveredRepo(rel: rel(dest), sshURL: sshURL, defaultBranch: branch, namespacePath: pathNS)
    }

    private func parseNextLink(_ header: String) -> URL? {
        guard !header.isEmpty,
              let r = header.range(of: #"<([^>]+)>;\s*rel="next""#, options: .regularExpression)
        else { return nil }
        let seg = String(header[r])
        guard let lt = seg.firstIndex(of: "<"), let gt = seg.firstIndex(of: ">") else { return nil }
        return URL(string: String(seg[seg.index(after: lt)..<gt]))
    }

    private func rel(_ dest: URL) -> String {
        let root = platformRoot.standardizedFileURL.path
        let d = dest.standardizedFileURL.path
        return d.hasPrefix(root + "/") ? String(d.dropFirst(root.count + 1)) : d
    }
}

// ---- Shared synchronous HTTP GET with retry (ports urllib http_get_json).
// Synchronous because the engine calls discovery from a worker task and the
// whole engine is structured around blocking git calls anyway; a sync HTTP
// call keeps the porting 1:1 and avoids mixing async into the value-typed
// clients. Returns (status, data) or throws after `attempts`.

enum HTTPClient {
    struct HTTPCodeError: LocalizedError {
        let code: Int
        var errorDescription: String? {
            switch code {
            case 401: return "HTTP 401 unauthorized — check the token / app password"
            case 403: return "HTTP 403 forbidden — the token lacks access (or is wrong)"
            case 404: return "HTTP 404 not found — check the workspace / org / host slug"
            default:  return "HTTP \(code)"
            }
        }
    }

    // Mutable box for the URLSession completion handler. The semaphore
    // provides the happens-before barrier (signal after writes, read after
    // wait), so @unchecked Sendable is sound here.
    private final class ResponseBox: @unchecked Sendable {
        var data: Data?
        var resp: URLResponse?
        var err: Error?
    }

    // Synchronous GET. Returns (httpStatus, body, linkHeader). Retries on
    // transient/network errors with exponential backoff; raises HTTPCodeError
    // immediately on 401/403/404 (non-transient — retrying won't help).
    static func get(
        _ url: URL, headers: [String: String], accept: String,
        attempts: Int = 5, backoff: Double = 2.0
    ) throws -> (status: Int, body: Data, link: String) {
        var delay = backoff
        var lastErr = "unknown"
        for attempt in 1...attempts {
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue(accept, forHTTPHeaderField: "Accept")
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

            let sem = DispatchSemaphore(value: 0)
            let box = ResponseBox()
            URLSession.shared.dataTask(with: req) { d, r, e in
                box.data = d; box.resp = r; box.err = e; sem.signal()
            }.resume()
            sem.wait()
            let outData = box.data, outResp = box.resp, outErr = box.err

            if let http = outResp as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 404 {
                    throw HTTPCodeError(code: http.statusCode)
                }
                if (200...299).contains(http.statusCode) {
                    let link = http.value(forHTTPHeaderField: "Link") ?? ""
                    return (http.statusCode, outData ?? Data(), link)
                }
                lastErr = "HTTP \(http.statusCode)"
            } else if let e = outErr {
                lastErr = e.localizedDescription
            }
            if attempt < attempts {
                Thread.sleep(forTimeInterval: delay)
                delay *= 2
            }
        }
        throw NSError(domain: "HTTPClient", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "GET \(url) failed after \(attempts): \(lastErr)"])
    }
}

// ---- GitHub: org repos via the REST API (URLSession). ----

struct GitHubClient: PlatformDiscovery {
    let platform = Platform.github
    let org: String
    let token: String          // GIT_SYNC_GITHUB_TOKEN (Bearer); netrc not ported (app uses token)
    let includeArchived: Bool
    let syncRoot: URL
    var localRoot: URL? = nil  // provider folder; defaults to syncRoot/Github

    private let api = "https://api.github.com"
    var probeURL: URL? { URL(string: api) }
    private var platformRoot: URL { localRoot ?? syncRoot.appendingPathComponent("Github") }
    private var authHeader: String { "Bearer \(token)" }
    private let accept = "application/vnd.github+json"
    private var headers: [String: String] {
        ["Authorization": authHeader, "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "git-sync"]
    }

    func discoverAll(skip: SkipMatcher) -> DiscoveryResult {
        var result = DiscoveryResult()
        var seen = Set<String>()
        var next: URL? = URL(string: "\(api)/orgs/\(org)/repos?per_page=100&type=all")
        while let url = next {
            let resp: (status: Int, body: Data, link: String)
            do {
                resp = try HTTPClient.get(url, headers: headers, accept: accept)
            } catch {
                result.fatalError = "fetch \(url): \(error.localizedDescription)"
                return result
            }
            guard let arr = try? JSONSerialization.jsonObject(with: resp.body) as? [[String: Any]] else {
                result.fatalError = "github: unparseable page"
                return result
            }
            for v in arr {
                if (v["archived"] as? Bool == true) && !includeArchived { continue }
                guard let branch = v["default_branch"] as? String, !branch.isEmpty,
                      let ssh = v["ssh_url"] as? String, !ssh.isEmpty,
                      let name = v["name"] as? String, !name.isEmpty,
                      !seen.contains(name) else { continue }
                seen.insert(name)
                let dest = platformRoot.appendingPathComponent(name)
                result.repos.append(DiscoveredRepo(
                    rel: rel(dest), sshURL: ssh, defaultBranch: branch, namespacePath: name))
            }
            next = parseNextLink(resp.link)
        }
        return result
    }

    func discoverOne(namespacePath target: String) -> DiscoveredRepo? {
        let name = target   // bare repo name (caller passes RepoID.namespacePath)
        guard let url = URL(string: "\(api)/repos/\(org)/\(name)") else { return nil }
        guard let resp = try? HTTPClient.get(url, headers: headers, accept: accept),
              let v = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let branch = v["default_branch"] as? String, !branch.isEmpty,
              let ssh = v["ssh_url"] as? String, !ssh.isEmpty,
              let repoName = v["name"] as? String, !repoName.isEmpty
        else { return nil }
        let dest = platformRoot.appendingPathComponent(repoName)
        return DiscoveredRepo(rel: rel(dest), sshURL: ssh, defaultBranch: branch, namespacePath: repoName)
    }

    // Parse the RFC 5988 Link header's rel="next" URL: <url>; rel="next"
    private func parseNextLink(_ header: String) -> URL? {
        guard !header.isEmpty,
              let r = header.range(of: #"<([^>]+)>;\s*rel="next""#, options: .regularExpression)
        else { return nil }
        // Extract the URL inside the angle brackets of the matched segment.
        let seg = String(header[r])
        guard let lt = seg.firstIndex(of: "<"), let gt = seg.firstIndex(of: ">") else { return nil }
        return URL(string: String(seg[seg.index(after: lt)..<gt]))
    }

    private func rel(_ dest: URL) -> String {
        let root = platformRoot.standardizedFileURL.path
        let d = dest.standardizedFileURL.path
        return d.hasPrefix(root + "/") ? String(d.dropFirst(root.count + 1)) : d
    }
}

// ---- Bitbucket: workspace repos via the 2.0 REST API (URLSession). ----

struct BitbucketClient: PlatformDiscovery {
    let platform = Platform.bitbucket
    let workspace: String
    let user: String
    let appPassword: String
    let syncRoot: URL
    var localRoot: URL? = nil  // provider folder; defaults to syncRoot/Bitbucket

    private let api = "https://api.bitbucket.org/2.0"
    var probeURL: URL? { URL(string: api) }
    private var platformRoot: URL { localRoot ?? syncRoot.appendingPathComponent("Bitbucket") }
    private let accept = "application/json"
    private var headers: [String: String] {
        let raw = "\(user):\(appPassword)".data(using: .utf8)!.base64EncodedString()
        return ["Authorization": "Basic \(raw)"]
    }

    func discoverAll(skip: SkipMatcher) -> DiscoveryResult {
        var result = DiscoveryResult()
        var seen = Set<String>()
        var next: URL? = URL(string:
            "\(api)/repositories/\(workspace)?pagelen=100&fields=values.slug,values.mainbranch.name,values.links.clone,next")
        while let url = next {
            let resp: (status: Int, body: Data, link: String)
            do {
                resp = try HTTPClient.get(url, headers: headers, accept: accept)
            } catch {
                result.fatalError = "fetch \(url): \(error.localizedDescription)"
                return result
            }
            guard let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
                result.fatalError = "bitbucket: unparseable page"
                return result
            }
            let values = obj["values"] as? [[String: Any]] ?? []
            for v in values {
                guard let mb = (v["mainbranch"] as? [String: Any])?["name"] as? String, !mb.isEmpty,
                      let ssh = cloneSSH(v), let slug = v["slug"] as? String, !slug.isEmpty,
                      !seen.contains(slug) else { continue }
                seen.insert(slug)
                let dest = platformRoot.appendingPathComponent(slug)
                result.repos.append(DiscoveredRepo(
                    rel: rel(dest), sshURL: ssh, defaultBranch: mb, namespacePath: slug))
            }
            next = (obj["next"] as? String).flatMap(URL.init(string:))
        }
        return result
    }

    func discoverOne(namespacePath target: String) -> DiscoveredRepo? {
        let slug = target   // bare repo slug (caller passes RepoID.namespacePath)
        guard let url = URL(string:
            "\(api)/repositories/\(workspace)/\(slug)?fields=slug,mainbranch.name,links.clone") else { return nil }
        guard let resp = try? HTTPClient.get(url, headers: headers, accept: accept),
              let v = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let mb = (v["mainbranch"] as? [String: Any])?["name"] as? String, !mb.isEmpty,
              let ssh = cloneSSH(v), let repoSlug = v["slug"] as? String, !repoSlug.isEmpty
        else { return nil }
        let dest = platformRoot.appendingPathComponent(repoSlug)
        return DiscoveredRepo(rel: rel(dest), sshURL: ssh, defaultBranch: mb, namespacePath: repoSlug)
    }

    // Extract the SSH clone URL from links.clone[] where name == "ssh".
    private func cloneSSH(_ v: [String: Any]) -> String? {
        let clones = (v["links"] as? [String: Any])?["clone"] as? [[String: Any]] ?? []
        return clones.first { ($0["name"] as? String) == "ssh" }?["href"] as? String
    }

    private func rel(_ dest: URL) -> String {
        let root = platformRoot.standardizedFileURL.path
        let d = dest.standardizedFileURL.path
        return d.hasPrefix(root + "/") ? String(d.dropFirst(root.count + 1)) : d
    }
}
