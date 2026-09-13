import Foundation
import Testing
@testable import AIAccounts

@Test func claudeLiveUsageUsesOpenUsageRequestAndCachesPerLogin() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential())
    let http = FakeTransport { _, _ in UsageFixtures.response(200, UsageFixtures.claudeUsageBody()) }
    let service = sandbox.service(http)
    let first = try (await service.activeUsage(.claude, force: false)).get()
    #expect(first.accountEmail == "developer@example.com")
    #expect(first.window("weekly")?.usedPercent == 77)
    let request = try #require(http.requests.first)
    #expect(request.method == "GET")
    #expect(request.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(request.headers["Authorization"] == "Bearer access-1")
    #expect(request.headers["anthropic-beta"] == "oauth-2025-04-20")
    #expect(request.headers["User-Agent"] == "claude-code/2.1.268")

    _ = await service.activeUsage(.claude, force: false)
    #expect(http.requests.count == 1)
    sandbox.clock.advance(301)
    _ = await service.activeUsage(.claude, force: false)
    #expect(http.requests.count == 2)
    // A different login is fetched at once, without waiting for the five-minute interval.
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential(access: "access-other", refresh: "refresh-other"))
    _ = await service.activeUsage(.claude, force: false)
    #expect(http.requests.count == 3)
    #expect(http.requests.last?.headers["Authorization"] == "Bearer access-other")
    await service.invalidate(.claude)
    _ = await service.activeUsage(.claude, force: false)
    #expect(http.requests.count == 4)
    _ = await service.activeUsage(.claude, force: true)
    #expect(http.requests.count == 5)
}

@Test func loginsThatCannotReadUsageNeverCallTheNetwork() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    let http = FakeTransport { _, _ in
        Issue.record("no request expected")
        return UsageFixtures.response(500)
    }
    let service = sandbox.service(http)
    #expect(await service.activeUsage(.claude, force: true) == .failure(.notLoggedIn))
    #expect(await service.activeUsage(.codex, force: true) == .failure(.notLoggedIn))
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential(scopes: ["user:inference"]))
    #expect(await service.activeUsage(.claude, force: true) == .failure(.missingProfileScope))
    #expect(http.requests.isEmpty)
}

@Test func expiringClaudeTokenRotatesAndWritesBackPreservingUnknownKeys() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential(expiresIn: 60))
    let http = FakeTransport { request, _ in
        if request.method == "POST" { return UsageFixtures.tokenGrant("access-2", refresh: "refresh-2", expiresIn: 28_800) }
        return UsageFixtures.response(200, UsageFixtures.claudeUsageBody())
    }
    let service = sandbox.service(http)
    let snapshot = try (await service.activeUsage(.claude, force: false)).get()
    #expect(snapshot.window("session")?.usedPercent == 9)
    #expect(http.requests.map(\.method) == ["POST", "GET"])
    let post = try #require(http.requests.first)
    #expect(post.url.absoluteString == "https://platform.claude.com/v1/oauth/token")
    let postBody = try #require(post.body)
    let body = try #require(try JSONSerialization.jsonObject(with: postBody) as? [String: Any])
    #expect(body["grant_type"] as? String == "refresh_token")
    #expect(body["refresh_token"] as? String == "refresh-1")
    #expect(body["client_id"] as? String == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    #expect(body["scope"] as? String == "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload")
    #expect(http.requests.last?.headers["Authorization"] == "Bearer access-2")

    let stored = try #require(sandbox.liveClaude())
    #expect(stored.accessToken == "access-2")
    #expect(stored.refreshToken == "refresh-2")
    #expect(stored.expiresAtMilliseconds == (UsageFixtures.now.timeIntervalSince1970 + 28_800) * 1000)
    let object = try #require(CredentialJSON.object(from: stored.rawJSON))
    #expect(object["mcpOAuth"] != nil)
    #expect((object["claudeAiOauth"] as? [String: Any])?["refreshTokenExpiresAt"] != nil)
    #expect(sandbox.keychain.snapshot[sandbox.paths.claudeLiveService]?.account == sandbox.paths.keychainAccount)
    // The written-back pair is the store's pair now, so the next call is served from cache.
    _ = await service.activeUsage(.claude, force: false)
    #expect(http.requests.count == 2)
}

@Test func unauthorizedUsageRefreshesOnceAndRetries() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential())
    let http = FakeTransport { _, index in
        switch index {
        case 0: return UsageFixtures.response(401, ["error": "unauthorized"])
        case 1: return UsageFixtures.tokenGrant("access-2", expiresIn: 3_600)
        default: return UsageFixtures.response(200, UsageFixtures.claudeUsageBody())
        }
    }
    let result = await sandbox.service(http).activeUsage(.claude, force: false)
    #expect((try? result.get()) != nil)
    #expect(http.requests.map(\.method) == ["GET", "POST", "GET"])
    #expect(http.requests.last?.headers["Authorization"] == "Bearer access-2")
    #expect(sandbox.liveClaude()?.accessToken == "access-2")
    #expect(sandbox.liveClaude()?.refreshToken == "refresh-1")
}

@Test func rejectedRefreshReportsAnExpiredSessionAndLeavesTheLoginAlone() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    let original = UsageFixtures.claudeCredential()
    try sandbox.setLiveClaude(original)
    let http = FakeTransport { request, _ in
        request.method == "POST" ? UsageFixtures.response(400, ["error": "invalid_grant"]) : UsageFixtures.response(401)
    }
    #expect(await sandbox.service(http).activeUsage(.claude, force: false) == .failure(.sessionExpired))
    #expect(sandbox.keychain.snapshot[sandbox.paths.claudeLiveService]?.value == original)
}

@Test func rateLimitServesLastGoodAndHonoursRetryAfter() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential())
    let http = FakeTransport { _, index in
        index == 0 ? UsageFixtures.response(200, UsageFixtures.claudeUsageBody())
                   : UsageFixtures.response(429, headers: ["Retry-After": "120"])
    }
    let service = sandbox.service(http)
    let good = try (await service.activeUsage(.claude, force: false)).get()
    let limited = try (await service.activeUsage(.claude, force: true)).get()
    #expect(limited.windows == good.windows)
    #expect(limited.notice == "Rate limited · retry in ~2m")
    #expect(http.requests.count == 2)
    _ = await service.activeUsage(.claude, force: true)
    #expect(http.requests.count == 2)
    sandbox.clock.advance(121)
    _ = await service.activeUsage(.claude, force: true)
    #expect(http.requests.count == 3)

    let fresh = sandbox.service(FakeTransport { _, _ in UsageFixtures.response(429, headers: ["retry-after": "120"]) })
    #expect(await fresh.activeUsage(.claude, force: false) == .failure(.rateLimited(retryAfterSeconds: 120)))
}

@Test func rotationIsNotWrittenOverALoginThatChangedMeanwhile() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential(expiresIn: 60))
    let external = UsageFixtures.claudeCredential(access: "access-external", refresh: "refresh-external")
    let keychain = sandbox.keychain
    let paths = sandbox.paths
    let http = FakeTransport { request, _ in
        if request.method == "POST" {
            // Claude Code rotates the live login while MenuSprite's refresh is in flight.
            try keychain.writePassword(service: paths.claudeLiveService, account: paths.keychainAccount, value: external)
            return UsageFixtures.tokenGrant("access-mine", refresh: "refresh-mine", expiresIn: 3_600)
        }
        return UsageFixtures.response(200, UsageFixtures.claudeUsageBody())
    }
    let result = await sandbox.service(http).activeUsage(.claude, force: false)
    #expect((try? result.get()) != nil)
    #expect(sandbox.liveClaude()?.accessToken == "access-external")
    #expect(http.requests.map(\.method) == ["POST", "GET"])
    #expect(http.requests.last?.headers["Authorization"] == "Bearer access-external")
}

@Test func savedClaudeRotationWritesOnlyTheSavedCopy() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    let live = UsageFixtures.claudeCredential(access: "live-access", refresh: "live-refresh")
    try sandbox.setLiveClaude(live)
    let savedService = sandbox.paths.savedService(.claude, email: "secondary@example.com")
    try sandbox.keychain.writePassword(service: savedService, account: "testuser",
                                       value: UsageFixtures.claudeCredential(access: "saved-access", refresh: "saved-refresh", expiresIn: 30))
    let http = FakeTransport { request, _ in
        request.method == "POST" ? UsageFixtures.tokenGrant("saved-access-2", refresh: "saved-refresh-2", expiresIn: 3_600)
                                 : UsageFixtures.response(200, UsageFixtures.claudeUsageBody())
    }
    let snapshot = try (await sandbox.service(http).savedUsage(.claude, email: "secondary@example.com", force: false)).get()
    #expect(snapshot.accountEmail == "secondary@example.com")
    #expect(http.requests.last?.headers["Authorization"] == "Bearer saved-access-2")
    let saved = try #require(sandbox.keychain.snapshot[savedService])
    #expect(saved.account == "testuser")
    #expect(ClaudeCredential(json: saved.value)?.refreshToken == "saved-refresh-2")
    #expect(sandbox.keychain.snapshot[sandbox.paths.claudeLiveService]?.value == live)
}

@Test func savedUsageOfTheLiveAccountNeverSpendsTheSavedRefreshToken() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential(access: "live-access"))
    try sandbox.keychain.writePassword(service: sandbox.paths.savedService(.claude, email: "developer@example.com"), account: "testuser",
                                       value: UsageFixtures.claudeCredential(access: "stale-saved", refresh: "stale-refresh", expiresIn: -60))
    let http = FakeTransport { _, _ in UsageFixtures.response(200, UsageFixtures.claudeUsageBody()) }
    _ = await sandbox.service(http).savedUsage(.claude, email: "Developer@example.com", force: false)
    #expect(http.requests.map(\.method) == ["GET"])
    #expect(http.requests.first?.headers["Authorization"] == "Bearer live-access")
}

@Test func codexRefreshRotatesTheAuthFileKeepingItsOtherKeys() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    let start = UsageFixtures.now.timeIntervalSince1970
    try sandbox.setCodexAuth(UsageFixtures.codexAuth(accessExpiry: start + 60))
    let newAccess = UsageFixtures.jwt(["exp": start + 86_400, "tag": "a2"])
    let http = FakeTransport { request, _ in
        request.method == "POST" ? UsageFixtures.tokenGrant(newAccess, refresh: "r2")
                                 : UsageFixtures.response(200, UsageFixtures.standardCodexBody())
    }
    let service = sandbox.service(http)
    let snapshot = try (await service.activeUsage(.codex, force: false)).get()
    #expect(snapshot.plan == "Pro 20x")
    #expect(snapshot.accountEmail == "dev@example.com")
    #expect(snapshot.window("weekly")?.usedPercent == 47)
    let post = try #require(http.requests.first)
    #expect(post.url.absoluteString == "https://auth.openai.com/oauth/token")
    #expect(post.headers["Content-Type"] == "application/x-www-form-urlencoded")
    let form = try #require(post.body)
    #expect(String(decoding: form, as: UTF8.self) == "grant_type=refresh_token&client_id=app_EMoamEEZ73f0CkXaXp7hrann&refresh_token=r1")
    let get = try #require(http.requests.last)
    #expect(get.url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    #expect(get.headers["Authorization"] == "Bearer \(newAccess)")
    #expect(get.headers["ChatGPT-Account-Id"] == "acct-1")

    let stored = try #require(try sandbox.codexAuth())
    #expect(stored.accessToken == newAccess)
    #expect(stored.refreshToken == "r2")
    #expect(stored.accountID == "acct-1")
    #expect(stored.lastRefresh == UsageFixtures.now)
    let object = try #require(CredentialJSON.object(from: stored.rawJSON))
    #expect(object["auth_mode"] as? String == "chatgpt")
    #expect(object["OPENAI_API_KEY"] is NSNull)
    let mode = try FileManager.default.attributesOfItem(atPath: sandbox.paths.codexAuth.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    _ = await service.activeUsage(.codex, force: false)
    #expect(http.requests.count == 2)
}

@Test func reusedCodexRefreshTokenIsAnExpiredSession() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    let original = UsageFixtures.codexAuth(accessExpiry: UsageFixtures.now.timeIntervalSince1970 - 10)
    try sandbox.setCodexAuth(original)
    let http = FakeTransport { request, _ in
        request.method == "POST" ? UsageFixtures.response(401, ["error": ["code": "refresh_token_reused"]])
                                 : UsageFixtures.response(200, UsageFixtures.standardCodexBody())
    }
    #expect(await sandbox.service(http).activeUsage(.codex, force: false) == .failure(.sessionExpired))
    #expect(try String(contentsOf: sandbox.paths.codexAuth, encoding: .utf8) == original)
}

@Test func savedCodexRotationKeepsTheSavedAccountAttribute() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    let start = UsageFixtures.now.timeIntervalSince1970
    try sandbox.setCodexAuth(UsageFixtures.codexAuth(accessExpiry: start + 86_400, email: "live@example.com", accountID: "acct-live"))
    let service = sandbox.paths.savedService(.codex, email: "other@example.com")
    try sandbox.keychain.writePassword(service: service, account: "other@example.com",
                                       value: UsageFixtures.codexAuth(accessExpiry: start - 10, email: "other@example.com", accountID: "acct-other"))
    let newAccess = UsageFixtures.jwt(["exp": start + 86_400, "tag": "saved"])
    let http = FakeTransport { request, _ in
        request.method == "POST" ? UsageFixtures.tokenGrant(newAccess, refresh: "r-saved-2")
                                 : UsageFixtures.response(200, UsageFixtures.standardCodexBody())
    }
    let snapshot = try (await sandbox.service(http).savedUsage(.codex, email: "other@example.com", force: false)).get()
    #expect(snapshot.accountEmail == "other@example.com")
    #expect(http.requests.last?.headers["ChatGPT-Account-Id"] == "acct-other")
    let saved = try #require(sandbox.keychain.snapshot[service])
    #expect(saved.account == "other@example.com")
    #expect(CodexCredential(json: saved.value)?.refreshToken == "r-saved-2")
    #expect(try sandbox.codexAuth()?.accountID == "acct-live")
}

@Test func connectionFailureKeepsLastGoodAndRetriesSooner() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setCodexAuth(UsageFixtures.codexAuth(accessExpiry: UsageFixtures.now.timeIntervalSince1970 + 86_400))
    let http = FakeTransport { _, index in
        if index >= 1 { throw OfflineError() }
        return UsageFixtures.response(200, UsageFixtures.standardCodexBody())
    }
    let service = sandbox.service(http)
    let good = try (await service.activeUsage(.codex, force: false)).get()
    sandbox.clock.advance(301)
    let served = try (await service.activeUsage(.codex, force: false)).get()
    #expect(served.windows == good.windows)
    #expect(served.notice?.hasPrefix("Couldn't refresh") == true)
    sandbox.clock.advance(30)
    _ = await service.activeUsage(.codex, force: false)
    #expect(http.requests.count == 2)
    sandbox.clock.advance(31)
    _ = await service.activeUsage(.codex, force: false)
    #expect(http.requests.count == 3)
}

@Test func concurrentCallersShareOneRequest() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setCodexAuth(UsageFixtures.codexAuth(accessExpiry: UsageFixtures.now.timeIntervalSince1970 + 86_400))
    let http = FakeTransport(delay: .milliseconds(80)) { _, _ in UsageFixtures.response(200, UsageFixtures.standardCodexBody()) }
    let service = sandbox.service(http)
    async let first = service.activeUsage(.codex, force: false)
    async let second = service.activeUsage(.codex, force: false)
    let results = await [first, second]
    #expect(results.allSatisfy { (try? $0.get()) != nil })
    #expect(http.requests.count == 1)
}
