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

// MARK: - Auto refresh

private func snapshot(session: Double, weekly: Double = 10, resetsIn: TimeInterval? = 3 * 3600, at now: Date) -> UsageSnapshot {
    UsageSnapshot(provider: .claude, accountEmail: "developer@example.com", plan: "Max", windows: [
        UsageWindow(id: "session", label: "5-hour", usedPercent: session, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, windowSeconds: 18_000),
        UsageWindow(id: "weekly", label: "Weekly", usedPercent: weekly, resetsAt: Date(timeIntervalSince1970: 1_000_000 + 4 * 86_400), windowSeconds: 604_800)
    ], fetchedAt: now)
}

@Test func autoPacingBacksOffWhileNothingChangesAndSnapsBackOnUse() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var pacer = UsageAutoPacer()
    var waits: [TimeInterval] = []
    for _ in 0..<8 { waits.append(pacer.observe(snapshot(session: 20, at: now), now: now)) }
    #expect(waits == [120, 300, 600, 900, 1800, 3600, 3600, 3600])
    // Two points of real use: back to the shortest wait.
    #expect(pacer.observe(snapshot(session: 22, at: now), now: now) == 120)
    // A one-point drift neither resets nor backs off.
    #expect(pacer.observe(snapshot(session: 23, at: now), now: now) == 120)
    #expect(pacer.observe(snapshot(session: 23, at: now), now: now) == 300)
    // ⌘R starts the ladder again whatever the last answer said.
    pacer.restart()
    #expect(pacer.observe(snapshot(session: 23, at: now), now: now) == 120)
    #expect(pacer.observe(snapshot(session: 23, at: now), now: now) == 300)
}

@Test func autoPacingWatchesANearlyFullSessionCloselyButNotForever() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var pacer = UsageAutoPacer()
    var waits: [TimeInterval] = []
    for _ in 0..<10 { waits.append(pacer.observe(snapshot(session: 96, at: now), now: now)) }
    #expect(waits == [60, 60, 60, 60, 60, 120, 120, 120, 300, 300])
    var warm = UsageAutoPacer()
    #expect(warm.observe(snapshot(session: 91, at: now), now: now) == 120)
    #expect(warm.observe(snapshot(session: 91, at: now), now: now) == 120)
    // Below 90% the ordinary ladder applies.
    var calm = UsageAutoPacer()
    _ = calm.observe(snapshot(session: 60, at: now), now: now)
    #expect(calm.observe(snapshot(session: 60, at: now), now: now) == 300)
}

@Test func autoPacingChecksJustAfterTheSessionResets() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let resetsAt = start.addingTimeInterval(700)
    func reading(at now: Date) -> UsageSnapshot { snapshot(session: 40, resetsIn: resetsAt.timeIntervalSince(now), at: now) }
    var pacer = UsageAutoPacer()
    #expect(pacer.observe(reading(at: start), now: start) == 120)
    let second = start.addingTimeInterval(120)
    #expect(pacer.observe(reading(at: second), now: second) == 300)
    // The ladder's next wait is 600 s, but the reset lands 280 s away: check just after it instead.
    let third = start.addingTimeInterval(420)
    #expect(pacer.observe(reading(at: third), now: third) == 285)
}

@Test func autoRefreshServesTheCacheForTheLadderAndRestartsOnCommand() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setClaudeState(email: "developer@example.com")
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential())
    let http = FakeTransport { _, _ in UsageFixtures.response(200, UsageFixtures.claudeUsageBody()) }
    let clock = sandbox.clock
    let service = UsageService(paths: sandbox.paths, keychain: sandbox.keychain, http: http, now: { clock.now },
                               refreshInterval: { UsageRefreshInterval.auto })
    _ = await service.activeUsage(.claude, force: false)
    #expect(http.requests.count == 1)
    clock.advance(100)
    _ = await service.activeUsage(.claude, force: false)
    #expect(http.requests.count == 1)
    clock.advance(30)   // 130 s: past the first 2-minute wait
    _ = await service.activeUsage(.claude, force: false)
    #expect(http.requests.count == 2)
    clock.advance(200)  // identical answer, so the wait is now 5 minutes
    _ = await service.activeUsage(.claude, force: false)
    #expect(http.requests.count == 2)
    let due = await service.nextRefreshDate()
    #expect(due != nil)
    // ⌘R: a forced fetch, and the wait after it is 2 minutes again rather than the next rung.
    await service.restartAutoPacing()
    _ = await service.activeUsage(.claude, force: true)
    #expect(http.requests.count == 3)
    clock.advance(130)
    _ = await service.activeUsage(.claude, force: false)
    #expect(http.requests.count == 4)
}

@Test func aStateFileNamingAnotherAccountDoesNotMakeTwoRowsReadTheSameLogin() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    // The keychain holds hemali's login, but ~/.claude.json still names prerak.
    try sandbox.setClaudeState(email: "prerak@example.com")
    let hemali = UsageFixtures.claudeCredential(access: "hemali-access", refresh: "hemali-refresh")
    try sandbox.setLiveClaude(hemali)
    try sandbox.keychain.writePassword(service: sandbox.paths.savedService(.claude, email: "hemali@example.com"), account: "testuser", value: hemali)
    try sandbox.keychain.writePassword(service: sandbox.paths.savedService(.claude, email: "prerak@example.com"), account: "testuser",
                                       value: UsageFixtures.claudeCredential(access: "prerak-access", refresh: "prerak-refresh"))
    let accounts = ["hemali@example.com", "prerak@example.com"].map {
        ["email": $0, "provider": "claude", "active": $0 == "hemali@example.com", "keychain_account": "testuser",
         "org_name": "", "subscription_type": "max"] as [String: Any]
    }
    try FileManager.default.createDirectory(at: sandbox.paths.switcherConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["accounts": accounts]).write(to: sandbox.paths.switcherConfig)
    let http = FakeTransport { _, _ in UsageFixtures.response(200, UsageFixtures.claudeUsageBody()) }
    let service = sandbox.service(http)
    _ = await service.savedUsage(.claude, email: "prerak@example.com", force: false)
    _ = await service.savedUsage(.claude, email: "hemali@example.com", force: false)
    let tokens = http.requests.compactMap { $0.headers["Authorization"] }
    #expect(tokens.contains("Bearer prerak-access"))
    #expect(tokens.contains("Bearer hemali-access"))
}

@Test func aRotatedLiveLoginIsNamedByAnthropicNotByTheDesktopAppsStateFile() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    // The Claude desktop app keeps writing prerak into ~/.claude.json; the CLI is signed in as hemali,
    // and its tokens have rotated since hemali's copy was saved, so no saved copy matches.
    try sandbox.setClaudeState(email: "prerak@example.com")
    try sandbox.setLiveClaude(UsageFixtures.claudeCredential(access: "hemali-rotated", refresh: "hemali-rotated-refresh"))
    for (email, access) in [("hemali@example.com", "hemali-old"), ("prerak@example.com", "prerak-access")] {
        try sandbox.keychain.writePassword(service: sandbox.paths.savedService(.claude, email: email), account: "testuser",
                                           value: UsageFixtures.claudeCredential(access: access, refresh: "\(access)-refresh"))
    }
    let accounts = ["hemali@example.com", "prerak@example.com"].map {
        ["email": $0, "provider": "claude", "active": $0 == "hemali@example.com", "keychain_account": "testuser",
         "org_name": "", "subscription_type": "max"] as [String: Any]
    }
    try FileManager.default.createDirectory(at: sandbox.paths.switcherConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["accounts": accounts]).write(to: sandbox.paths.switcherConfig)
    let http = FakeTransport { request, _ in
        request.url.path.hasSuffix("/profile")
            ? UsageFixtures.response(200, ["account": ["email": "hemali@example.com"]])
            : UsageFixtures.response(200, UsageFixtures.claudeUsageBody())
    }
    let clock = sandbox.clock
    let service = UsageService(paths: sandbox.paths, keychain: sandbox.keychain, http: http, now: { clock.now },
                               verifiesLiveIdentity: true, verifiedLogins: VerifiedClaudeLogins())
    _ = await service.savedUsage(.claude, email: "prerak@example.com", force: false)
    let live = try (await service.activeUsage(.claude, force: false)).get()
    let tokens = http.requests.filter { !$0.url.path.hasSuffix("/profile") }.compactMap { $0.headers["Authorization"] }
    #expect(tokens.contains("Bearer prerak-access"))
    #expect(tokens.contains("Bearer hemali-rotated"))
    #expect(live.accountEmail == "hemali@example.com")
}
