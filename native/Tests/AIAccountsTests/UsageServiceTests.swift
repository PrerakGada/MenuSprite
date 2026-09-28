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

@Test func liveClaudeTokenNearExpiryIsUsedAsIsAndNeverRotated() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    let original = UsageFixtures.claudeCredential(expiresIn: 60)
    try sandbox.setLiveClaude(original)
    let http = FakeTransport { _, _ in UsageFixtures.response(200, UsageFixtures.claudeUsageBody()) }
    let snapshot = try (await sandbox.service(http).activeUsage(.claude, force: false)).get()
    #expect(snapshot.window("session")?.usedPercent == 9)
    // Still valid, so it is simply used: no token request, and the CLI's login is untouched.
    #expect(http.requests.map(\.method) == ["GET"])
    #expect(http.requests.first?.headers["Authorization"] == "Bearer access-1")
    #expect(sandbox.keychain.snapshot[sandbox.paths.claudeLiveService]?.value == original)
}

@Test func expiredLiveClaudeTokenWaitsForClaudeCodeWithoutNetworkOrKeychainWrites() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    let original = UsageFixtures.claudeCredential(expiresIn: -60)
    try sandbox.setLiveClaude(original)
    let http = FakeTransport { _, _ in UsageFixtures.response(200, UsageFixtures.claudeUsageBody()) }
    #expect(await sandbox.service(http).activeUsage(.claude, force: false) == .failure(.awaitingCLIRenewal))
    #expect(http.requests.isEmpty)
    #expect(sandbox.keychain.snapshot[sandbox.paths.claudeLiveService]?.value == original)
}

@Test func unauthorizedLiveClaudeIsNeverRefreshedOrWritten() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    let original = UsageFixtures.claudeCredential()
    try sandbox.setLiveClaude(original)
    let http = FakeTransport { _, _ in UsageFixtures.response(401, ["error": "unauthorized"]) }
    #expect(await sandbox.service(http).activeUsage(.claude, force: false) == .failure(.awaitingCLIRenewal))
    // One usage request and nothing else: the refresh token is never spent.
    #expect(http.requests.map(\.method) == ["GET"])
    #expect(sandbox.keychain.snapshot[sandbox.paths.claudeLiveService]?.value == original)
}

@Test func liveClaudeAdoptsTheTokenTheCLIRenewedAndKeepsLastFiguresMeanwhile() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential())
    let http = FakeTransport { _, _ in UsageFixtures.response(200, UsageFixtures.claudeUsageBody()) }
    let service = sandbox.service(http)
    _ = try (await service.activeUsage(.claude, force: false)).get()
    // The token expires and the CLI has not renewed it yet: the last figures stay, flagged.
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential(expiresIn: -60))
    sandbox.clock.advance(301)
    let waiting = try (await service.activeUsage(.claude, force: false)).get()
    #expect(waiting.window("weekly")?.usedPercent == 77)
    #expect(waiting.notice?.contains("renews it the next time") == true)
    // The CLI renews it: the new login is fetched at once.
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential(access: "access-renewed", refresh: "refresh-renewed"))
    _ = try (await service.activeUsage(.claude, force: false)).get()
    #expect(http.requests.last?.headers["Authorization"] == "Bearer access-renewed")
    #expect(http.requests.allSatisfy { $0.method == "GET" })
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

@Test func savedRotationIsNotWrittenOverACopyThatChangedMeanwhile() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential(access: "live-access", refresh: "live-refresh"))
    let savedService = sandbox.paths.savedService(.claude, email: "secondary@example.com")
    try sandbox.keychain.writePassword(service: savedService, account: "testuser",
                                       value: UsageFixtures.claudeCredential(access: "saved-access", refresh: "saved-refresh", expiresIn: 60))
    let external = UsageFixtures.claudeCredential(access: "access-external", refresh: "refresh-external")
    let keychain = sandbox.keychain
    let http = FakeTransport { request, _ in
        if request.method == "POST" {
            // Something else rewrites the saved copy while MenuSprite's refresh is in flight.
            try keychain.writePassword(service: savedService, account: "testuser", value: external)
            return UsageFixtures.tokenGrant("access-mine", refresh: "refresh-mine", expiresIn: 3_600)
        }
        return UsageFixtures.response(200, UsageFixtures.claudeUsageBody())
    }
    let result = await sandbox.service(http).savedUsage(.claude, email: "secondary@example.com", force: false)
    #expect((try? result.get()) != nil)
    #expect(ClaudeCredential(json: try #require(keychain.snapshot[savedService]?.value))?.accessToken == "access-external")
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
    let object = try #require(CredentialJSON.object(from: saved.value))
    #expect((object["claudeAiOauth"] as? [String: Any])?["refreshTokenExpiresAt"] != nil)
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

@Test func liveCodexTokenNearExpiryIsUsedAsIsAndTheAuthFileIsNeverWritten() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    let start = UsageFixtures.now.timeIntervalSince1970
    let original = UsageFixtures.codexAuth(accessExpiry: start + 60)
    try sandbox.setCodexAuth(original)
    let http = FakeTransport { _, _ in UsageFixtures.response(200, UsageFixtures.standardCodexBody()) }
    let snapshot = try (await sandbox.service(http).activeUsage(.codex, force: false)).get()
    #expect(snapshot.plan == "Pro 20x")
    #expect(snapshot.accountEmail == "dev@example.com")
    #expect(snapshot.window("weekly")?.usedPercent == 47)
    let get = try #require(http.requests.first)
    #expect(http.requests.map(\.method) == ["GET"])
    #expect(get.url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    #expect(get.headers["ChatGPT-Account-Id"] == "acct-1")
    #expect(try String(contentsOf: sandbox.paths.codexAuth, encoding: .utf8) == original)
}

@Test func expiredLiveCodexTokenWaitsForTheCLIAndNeverSpendsItsRefreshToken() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    let original = UsageFixtures.codexAuth(accessExpiry: UsageFixtures.now.timeIntervalSince1970 - 10)
    try sandbox.setCodexAuth(original)
    let http = FakeTransport { _, _ in UsageFixtures.response(200, UsageFixtures.standardCodexBody()) }
    #expect(await sandbox.service(http).activeUsage(.codex, force: false) == .failure(.awaitingCLIRenewal))
    #expect(http.requests.isEmpty)
    #expect(try String(contentsOf: sandbox.paths.codexAuth, encoding: .utf8) == original)
}

@Test func unauthorizedLiveCodexIsNeverRefreshedOrWritten() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    let original = UsageFixtures.codexAuth(accessExpiry: UsageFixtures.now.timeIntervalSince1970 + 3_600)
    try sandbox.setCodexAuth(original)
    let http = FakeTransport { _, _ in UsageFixtures.response(401) }
    #expect(await sandbox.service(http).activeUsage(.codex, force: false) == .failure(.awaitingCLIRenewal))
    #expect(http.requests.map(\.method) == ["GET"])
    #expect(try String(contentsOf: sandbox.paths.codexAuth, encoding: .utf8) == original)
}

@Test func reusedSavedCodexRefreshTokenIsAnExpiredSession() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    let start = UsageFixtures.now.timeIntervalSince1970
    try sandbox.setCodexAuth(UsageFixtures.codexAuth(accessExpiry: start + 86_400, email: "live@example.com", accountID: "acct-live"))
    let service = sandbox.paths.savedService(.codex, email: "other@example.com")
    let original = UsageFixtures.codexAuth(accessExpiry: start - 10, email: "other@example.com", accountID: "acct-other")
    try sandbox.keychain.writePassword(service: service, account: "other@example.com", value: original)
    let http = FakeTransport { request, _ in
        request.method == "POST" ? UsageFixtures.response(401, ["error": ["code": "refresh_token_reused"]])
                                 : UsageFixtures.response(200, UsageFixtures.standardCodexBody())
    }
    #expect(await sandbox.service(http).savedUsage(.codex, email: "other@example.com", force: false) == .failure(.sessionExpired))
    #expect(sandbox.keychain.snapshot[service]?.value == original)
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

@Test func cachedUsageFollowsTheChosenRefreshIntervalAtOnce() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential())
    let http = FakeTransport { _, _ in UsageFixtures.response(200, UsageFixtures.claudeUsageBody()) }
    let interval = TestClock(Date(timeIntervalSince1970: 300))
    let clock = sandbox.clock
    let service = UsageService(paths: sandbox.paths, keychain: sandbox.keychain, http: http, now: { clock.now },
                               refreshInterval: { interval.now.timeIntervalSince1970 })
    _ = await service.activeUsage(.claude, force: false)
    sandbox.clock.advance(61)
    _ = await service.activeUsage(.claude, force: false)
    #expect(http.requests.count == 1)
    // Shortening the interval applies to the snapshot already cached, not only to the next fetch.
    interval.advance(-240)
    _ = await service.activeUsage(.claude, force: false)
    #expect(http.requests.count == 2)
}
