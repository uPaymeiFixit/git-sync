import Foundation

// Discovery layer for the native engine — ports the three sync-*.py mains'
// API listing + _sync_only paths. Each client returns DiscoveredRepo rows
// (remote-known projects) plus a `complete` flag mirroring Python's
// discovery_complete (false ⇒ suppress the stale scan, since a partial
// listing would flag every un-enumerated repo as deleted).

struct DiscoveredRepo: Sendable {
    let rel: String            // sync-root-relative incl. platform dir, e.g. "Gitlab/foo/bar"
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
    func discoverAll(skip: SkipMatcher) -> DiscoveryResult
    func discoverOne(rel: String) -> DiscoveredRepo?
}

// Port of matches_skip — comma-separated GIT_SYNC_SKIP patterns matched as
// path prefixes against the platform-native namespace path (case-insensitive,
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

// ---- GitLab: shells `glab` via GitRunner (preserves the bundled-glab auth
// story — GITLAB_TOKEN env or glab config). Port of sync-gitlab.py. ----

struct GlabError: Error { let message: String }

struct GitLabClient: PlatformDiscovery {
    let platform = Platform.gitlab
    let host: String
    let includeArchived: Bool
    let syncRoot: URL
    let env: [String: String]   // includes GITLAB_TOKEN if set, PATH with bundled glab

    private var platformRoot: URL { syncRoot.appendingPathComponent("Gitlab") }

    // Transient glab error substrings → retry. Port of _RETRYABLE_PATTERNS.
    private static let retryable = [
        "no route to host", "connection refused", "connection reset",
        "i/o timeout", "tls handshake timeout", "eof",
        "temporary failure in name resolution", "502", "503", "504",
    ]
    private func isRetryable(_ stderr: String) -> Bool {
        let l = stderr.lowercased()
        return Self.retryable.contains { l.contains($0) }
    }

    // One `glab api` call with retry on transient failures. Port of
    // _glab_api_single. Returns decoded JSON or a failure message.
    private func glabAPISingle(_ path: String, attempts: Int = 4) -> Result<Any, GlabError> {
        var delay = 2.0
        var lastErr = ""
        for attempt in 1...attempts {
            let r = GitRunner.gitRawProgram(
                "glab", ["api", "--hostname", host, path], env: env)
            if r.code == 0 {
                guard let data = r.out.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) else {
                    return .failure(GlabError(message: "glab api \(path): unparseable JSON"))
                }
                return .success(json)
            }
            lastErr = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if attempt >= attempts || !isRetryable(lastErr) {
                return .failure(GlabError(message: "glab api \(path) failed: \(lastErr)"))
            }
            Thread.sleep(forTimeInterval: delay * Double.random(in: 0.5...1.5))
            delay *= 2
        }
        return .failure(GlabError(message: "glab api \(path) failed: \(lastErr)"))
    }

    // Manual pagination — append &page=N until a short/empty page. Port of
    // glab_api (paginate=true). --paginate concatenates unparseable arrays,
    // so we page by hand.
    private func glabAPIPaginated(_ path: String, perPage: Int) -> Result<[Any], GlabError> {
        let sep = path.contains("?") ? "&" : "?"
        var page = 1
        var merged: [Any] = []
        while true {
            switch glabAPISingle("\(path)\(sep)page=\(page)") {
            case .failure(let e): return .failure(e)
            case .success(let json):
                guard let chunk = json as? [Any] else {
                    // Non-list endpoint — return as-is wrapped.
                    return .success([json])
                }
                if chunk.isEmpty { return .success(merged) }
                merged.append(contentsOf: chunk)
                if chunk.count < perPage { return .success(merged) }
                page += 1
            }
        }
    }

    func discoverAll(skip: SkipMatcher) -> DiscoveryResult {
        var result = DiscoveryResult()
        let archivedQS = includeArchived ? "" : "&archived=false"
        let path = "projects?min_access_level=10\(archivedQS)&simple=true&per_page=100"
        switch glabAPIPaginated(path, perPage: 100) {
        case .failure(let e):
            result.fatalError = e.message
            return result
        case .success(let projects):
            var seen = Set<String>()
            for case let p as [String: Any] in projects {
                guard let branch = p["default_branch"] as? String, !branch.isEmpty,
                      let url = p["ssh_url_to_repo"] as? String, !url.isEmpty,
                      let pathNS = p["path_with_namespace"] as? String, !pathNS.isEmpty
                else { continue }
                if seen.contains(url) { continue }
                seen.insert(url)
                let dest = platformRoot.appendingPathComponent(pathNS)
                result.repos.append(DiscoveredRepo(
                    rel: rel(dest), sshURL: url, defaultBranch: branch, namespacePath: pathNS))
            }
            return result
        }
    }

    func discoverOne(rel target: String) -> DiscoveredRepo? {
        let ns = target.contains("/") ? String(target.drop(while: { $0 != "/" }).dropFirst()) : target
        guard let enc = ns.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        switch glabAPISingle("projects/\(enc)") {
        case .failure: return nil
        case .success(let json):
            guard let p = json as? [String: Any],
                  let branch = p["default_branch"] as? String, !branch.isEmpty,
                  let url = p["ssh_url_to_repo"] as? String, !url.isEmpty,
                  let pathNS = p["path_with_namespace"] as? String, !pathNS.isEmpty
            else { return nil }
            let dest = platformRoot.appendingPathComponent(pathNS)
            return DiscoveredRepo(rel: rel(dest), sshURL: url, defaultBranch: branch, namespacePath: pathNS)
        }
    }

    private func rel(_ dest: URL) -> String {
        let root = syncRoot.standardizedFileURL.path
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
    struct HTTPCodeError: Error { let code: Int }

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
    // immediately on 401/403/404 (non-transient, like the Python).
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

// ---- GitHub: URLSession. Port of sync-github.py. ----

struct GitHubClient: PlatformDiscovery {
    let platform = Platform.github
    let org: String
    let token: String          // GIT_SYNC_GITHUB_TOKEN (Bearer); netrc not ported (app uses token)
    let includeArchived: Bool
    let syncRoot: URL

    private let api = "https://api.github.com"
    private var platformRoot: URL { syncRoot.appendingPathComponent("Github") }
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

    func discoverOne(rel target: String) -> DiscoveredRepo? {
        let name = target.contains("/") ? String(target.drop(while: { $0 != "/" }).dropFirst()) : target
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

    // Port of _parse_next_link: <url>; rel="next"
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
        let root = syncRoot.standardizedFileURL.path
        let d = dest.standardizedFileURL.path
        return d.hasPrefix(root + "/") ? String(d.dropFirst(root.count + 1)) : d
    }
}

// ---- Bitbucket: URLSession. Port of sync-bitbucket.py. ----

struct BitbucketClient: PlatformDiscovery {
    let platform = Platform.bitbucket
    let workspace: String
    let user: String
    let appPassword: String
    let syncRoot: URL

    private let api = "https://api.bitbucket.org/2.0"
    private var platformRoot: URL { syncRoot.appendingPathComponent("Bitbucket") }
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

    func discoverOne(rel target: String) -> DiscoveredRepo? {
        let slug = target.contains("/") ? String(target.drop(while: { $0 != "/" }).dropFirst()) : target
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
        let root = syncRoot.standardizedFileURL.path
        let d = dest.standardizedFileURL.path
        return d.hasPrefix(root + "/") ? String(d.dropFirst(root.count + 1)) : d
    }
}
