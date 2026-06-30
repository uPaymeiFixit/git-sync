import Foundation

// Tests the credential-test layer: the HTTP-status → ConnectionTestResult
// classification, the per-kind credential guidance, and the user-facing
// headline/detail messages. No network — it drives classifyAuthProbe's mapping
// indirectly via the result type and pins the messages that tell a user WHY
// their setup failed (the whole point of the feature: no more silent "0 repos").
//
//   GitSync --connection-test
enum ConnectionTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(label)") }
            else { failures += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        print("Connection-test classification + credential-guidance test")

        // ---- Result → user message mapping -------------------------------

        check("ok reports connected",
              ConnectionTestResult.ok(reposVisible: 5).isOK)
        check("ok with count phrases repos",
              ConnectionTestResult.ok(reposVisible: 5).headline.contains("5"))
        check("ok with nil count still reads connected",
              ConnectionTestResult.ok(reposVisible: nil).headline == "Connected")
        check("401 is not OK", !ConnectionTestResult.unauthorized.isOK)
        check("401 headline mentions authentication",
              ConnectionTestResult.unauthorized.headline.lowercased().contains("auth"))
        check("403 is not OK", !ConnectionTestResult.forbidden.isOK)
        check("404 is not OK", !ConnectionTestResult.notFound.isOK)
        check("unreachable is not OK", !ConnectionTestResult.unreachable("timed out").isOK)

        // ---- The Bitbucket-specific guidance (the actual bug the friend hit) --

        let bbUnauth = ConnectionTestResult.unauthorized.detail(for: .bitbucket)
        check("Bitbucket 401 warns off the account password",
              bbUnauth.lowercased().contains("account password"),
              bbUnauth)
        check("Bitbucket 401 points at API token",
              bbUnauth.lowercased().contains("api token"), bbUnauth)

        let bb404 = ConnectionTestResult.notFound.detail(for: .bitbucket)
        check("Bitbucket 404 talks about the workspace slug",
              bb404.lowercased().contains("workspace") && bb404.lowercased().contains("slug"),
              bb404)

        let gh404 = ConnectionTestResult.notFound.detail(for: .github)
        check("GitHub 404 talks about the organization",
              gh404.lowercased().contains("organization"), gh404)

        let any403 = ConnectionTestResult.forbidden.detail(for: .bitbucket)
        check("403 mentions a missing read scope",
              any403.lowercased().contains("read"), any403)

        // ---- Credential guidance per kind --------------------------------

        check("Bitbucket credential label is 'API token' (not 'App password')",
              ProviderKind.bitbucket.credentialLabel == "API token")
        check("GitLab credential label is a PAT",
              ProviderKind.gitlab.credentialLabel == "Personal access token")
        check("Bitbucket help warns off the account password",
              ProviderKind.bitbucket.credentialHelp.lowercased().contains("not your"))
        check("GitLab help names the read scopes",
              ProviderKind.gitlab.credentialHelp.contains("read_api"))
        check("Bitbucket credential URL is the Atlassian token page",
              ProviderKind.bitbucket.credentialURL?.absoluteString.contains("id.atlassian.com") ?? false)
        check("GitHub credential URL is the tokens page",
              ProviderKind.github.credentialURL?.absoluteString.contains("github.com/settings/tokens") ?? false)
        check("GitLab credential URL is host-specific (nil here)",
              ProviderKind.gitlab.credentialURL == nil)

        // ---- ConnectionTester empty-field guards (no network) ------------

        let r1 = ConnectionTester.test(kind: .bitbucket, host: "", scope: "", bitbucketUser: "", token: "")
        check("Bitbucket with no token fails fast (no network)",
              { if case .failed = r1 { return true } else { return false } }())
        let r2 = ConnectionTester.test(kind: .bitbucket, host: "", scope: "", bitbucketUser: "", token: "abc")
        check("Bitbucket with token but no workspace fails fast",
              { if case .failed = r2 { return true } else { return false } }())
        let r3 = ConnectionTester.test(kind: .bitbucket, host: "", scope: "ws", bitbucketUser: "", token: "abc")
        check("Bitbucket with workspace+token but no username fails fast",
              { if case .failed = r3 { return true } else { return false } }())
        let r4 = ConnectionTester.test(kind: .gitlab, host: "", scope: "", bitbucketUser: "", token: "abc")
        check("GitLab with token but no host fails fast",
              { if case .failed = r4 { return true } else { return false } }())

        print()
        if failures == 0 { print("Connection test passed."); return 0 }
        print("\(failures) check(s) failed."); return 1
    }
}
