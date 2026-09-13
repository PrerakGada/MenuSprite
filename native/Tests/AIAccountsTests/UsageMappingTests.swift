import Foundation
import Testing
@testable import AIAccounts

private func iso(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)!
}

@Test func claudeUsageMapsLikeOpenUsage() throws {
    let credential = try #require(ClaudeCredential(json: UsageFixtures.claudeCredential()))
    let response = UsageFixtures.response(200, UsageFixtures.claudeUsageBody())
    let snapshot = try ClaudeUsageAPI.snapshot(from: response, credential: credential, email: "developer@example.com", now: UsageFixtures.now)
    #expect(snapshot.provider == .claude)
    #expect(snapshot.accountEmail == "developer@example.com")
    #expect(snapshot.plan == "Max 20x")
    // The fixture's `limits` array carries a scoped Opus entry beside Fable; the Fable-only mapping
    // used to drop it silently.
    #expect(snapshot.windows.map(\.id) == ["session", "weekly", "opus", "fable"])
    #expect(snapshot.window("opus")?.usedPercent == 5)
    let session = try #require(snapshot.window("session"))
    #expect(session.usedPercent == 9)
    #expect(session.windowSeconds == 18_000)
    let sessionReset = try #require(session.resetsAt)
    #expect(abs(sessionReset.timeIntervalSince(iso("2026-09-11T08:40:00.666Z"))) < 0.001)
    let weekly = try #require(snapshot.window("weekly"))
    #expect(weekly.usedPercent == 77)
    let weeklyReset = try #require(weekly.resetsAt)
    #expect(abs(weeklyReset.timeIntervalSince(iso("2026-09-11T08:00:00.123Z"))) < 0.001)
    let fable = try #require(snapshot.window("fable"))
    #expect(fable.usedPercent == 100)
    #expect(fable.resetsAt == Date(timeIntervalSince1970: 1_789_000_000))
    let extra = try #require(snapshot.extraUsage)
    #expect(extra.enabled)
    #expect(extra.usedDollars == 12.34)
    #expect(extra.limitDollars == 50)
    #expect(extra.percent == 24.68)
}

@Test func claudePlanNamesMatchOpenUsage() {
    #expect(UsageParse.claudePlan(subscriptionType: "max", rateLimitTier: "default_claude_max_5x") == "Max 5x")
    #expect(UsageParse.claudePlan(subscriptionType: "PRO", rateLimitTier: nil) == "Pro")
    #expect(UsageParse.claudePlan(subscriptionType: "team", rateLimitTier: "default_claude_team") == "Team")
    #expect(UsageParse.claudePlan(subscriptionType: " ", rateLimitTier: nil) == nil)
}

@Test func timestampVariantsParse() {
    let expected = iso("2026-09-11T08:40:00.000Z")
    #expect(UsageParse.date("2026-09-11 08:40:00 UTC") == expected)
    #expect(UsageParse.date("2026-09-11T08:40:00Z") == expected)
    #expect(UsageParse.date("2026-09-11T14:10:00+05:30") == expected)
    #expect(UsageParse.date("2026-09-11T08:40:00") == expected)
    #expect(UsageParse.date("2026-09-11T08:40:00.000000+00:00") == expected)
    #expect(UsageParse.date(expected.timeIntervalSince1970) == expected)
    #expect(UsageParse.date(expected.timeIntervalSince1970 * 1000) == expected)
    #expect(UsageParse.date("soon") == nil)
}

@Test func codexWindowsAreClassifiedByLength() throws {
    let credential = try #require(CodexCredential(json: UsageFixtures.codexAuth(accessExpiry: 2_000_000_000)))
    let response = UsageFixtures.response(200, UsageFixtures.standardCodexBody())
    let snapshot = try CodexUsageAPI.snapshot(from: response, credential: credential, fallbackEmail: nil, now: UsageFixtures.now)
    #expect(snapshot.plan == "Pro 20x")
    #expect(snapshot.accountEmail == "dev@example.com")
    #expect(snapshot.windows.map(\.id) == ["session", "weekly", "spark"])
    #expect(snapshot.window("session")?.usedPercent == 12)
    #expect(snapshot.window("session")?.resetsAt == Date(timeIntervalSince1970: 1_800_010_000))
    #expect(snapshot.window("weekly")?.usedPercent == 47)
    #expect(snapshot.window("weekly")?.resetsAt == UsageFixtures.now.addingTimeInterval(3_600))
    #expect(snapshot.window("spark")?.usedPercent == 3)
    #expect(snapshot.creditsRemaining == 821.5)
}

@Test func codexSoleWeeklyWindowInPrimarySlotIsWeekly() throws {
    let credential = try #require(CodexCredential(json: UsageFixtures.codexAuth(accessExpiry: 2_000_000_000)))
    let body = UsageFixtures.codexUsageBody(primary: ["used_percent": 47, "limit_window_seconds": 604_800, "reset_at": 1_800_300_000] as [String: Any],
                                            secondary: nil)
    let snapshot = try CodexUsageAPI.snapshot(from: UsageFixtures.response(200, body), credential: credential, fallbackEmail: nil, now: UsageFixtures.now)
    #expect(snapshot.windows.filter { $0.id == "session" || $0.id == "weekly" }.map(\.id) == ["weekly"])
    #expect(snapshot.window("weekly")?.usedPercent == 47)
    #expect(snapshot.window("weekly")?.windowSeconds == 604_800)
}

@Test func codexHeaderPercentsAndUnfamiliarDurationsFallBackToSlots() throws {
    let credential = try #require(CodexCredential(json: UsageFixtures.codexAuth(accessExpiry: 2_000_000_000)))
    let headers = ["X-Codex-Primary-Used-Percent": "33", "x-codex-secondary-used-percent": "4", "x-codex-credits-balance": "12"]
    let headerOnly = try CodexUsageAPI.snapshot(from: UsageFixtures.response(200, ["plan_type": "plus"], headers: headers),
                                                credential: credential, fallbackEmail: nil, now: UsageFixtures.now)
    #expect(headerOnly.window("session")?.usedPercent == 33)
    #expect(headerOnly.window("weekly")?.usedPercent == 4)
    #expect(headerOnly.creditsRemaining == 12)
    #expect(headerOnly.plan == "Plus")
    let odd = UsageFixtures.codexUsageBody(primary: ["used_percent": 20, "limit_window_seconds": 3_600] as [String: Any],
                                           secondary: ["used_percent": 60, "limit_window_seconds": 604_800] as [String: Any])
    let oddSnapshot = try CodexUsageAPI.snapshot(from: UsageFixtures.response(200, odd), credential: credential, fallbackEmail: nil, now: UsageFixtures.now)
    #expect(oddSnapshot.window("session")?.usedPercent == 20)
    #expect(oddSnapshot.window("session")?.windowSeconds == 3_600)
    #expect(oddSnapshot.window("weekly")?.usedPercent == 60)
}

@Test func codexPlanNamesMatchOpenUsage() {
    #expect(UsageParse.codexPlan("prolite") == "Pro 5x")
    #expect(UsageParse.codexPlan("pro") == "Pro 20x")
    #expect(UsageParse.codexPlan("self_serve_business_prolite") == "Business Premium")
    #expect(UsageParse.codexPlan("team_enterprise") == "Team Enterprise")
    #expect(UsageParse.codexPlan(nil) == nil)
}

@Test func refreshErrorsMapToLoginStates() {
    #expect(throws: UsageError.sessionExpired) { try ClaudeUsageAPI.parseRefresh(UsageFixtures.response(400, ["error": "invalid_grant"])) }
    #expect(throws: UsageError.requestFailed(status: 401)) { try ClaudeUsageAPI.parseRefresh(UsageFixtures.response(401, ["message": "proxy"])) }
    #expect(throws: UsageError.requestFailed(status: 503)) { try ClaudeUsageAPI.parseRefresh(UsageFixtures.response(503)) }
    #expect(throws: UsageError.sessionExpired) { try CodexUsageAPI.parseRefresh(UsageFixtures.response(401, ["error": ["code": "refresh_token_reused"]])) }
    #expect(throws: UsageError.sessionExpired) { try CodexUsageAPI.parseRefresh(UsageFixtures.response(400, ["error": "refresh_token_expired"])) }
    #expect(throws: UsageError.sessionExpired) { try CodexUsageAPI.parseRefresh(UsageFixtures.response(400, ["code": "refresh_token_invalidated"])) }
    #expect(throws: UsageError.requestFailed(status: 400)) { try CodexUsageAPI.parseRefresh(UsageFixtures.response(400, ["error": "other"])) }
}

@Test func aiReadingsCoverEveryContractID() {
    let snapshot = UsageSnapshot(provider: .codex, accountEmail: "dev@example.com", plan: "Pro 20x", windows: [
        UsageWindow(id: "weekly", label: "Weekly", usedPercent: 47, resetsAt: UsageFixtures.now.addingTimeInterval(7_200), windowSeconds: 604_800)
    ], creditsRemaining: 821, creditDollars: 32.84, resetCredits: ResetCredits(available: 2), fetchedAt: UsageFixtures.now)
    let codex = AIUsageMetrics.values(for: .codex, result: .success(snapshot), now: UsageFixtures.now)
    // Every declared reading must get a value, or a saved sprite would read "Not sampled" forever.
    #expect(Set(codex.keys) == Set(AIUsageMetrics.ids(for: .codex)))
    #expect(codex["ai.codex.weekly"] == .percent(47))
    #expect(codex["ai.codex.weeklyReset"] == .seconds(7_200))
    #expect(codex["ai.codex.account"] == .text("dev@example.com"))
    #expect(codex["ai.codex.plan"] == .text("Pro 20x"))
    #expect(codex["ai.codex.credits"] == .count(821))
    #expect(codex["ai.codex.creditsValue"] == .currency(32.84))
    #expect(codex["ai.codex.resets"] == .count(2))
    if case .unavailable? = codex["ai.codex.session"] {} else { Issue.record("a missing session window must read as unavailable") }
    if case .unavailable? = codex["ai.codex.spark"] {} else { Issue.record("a missing Spark window must read as unavailable") }
    if case .unavailable? = codex["ai.codex.spendToday"] {} else { Issue.record("unscanned spend must read as unavailable") }

    // A model-scoped window the catalog never heard of still becomes a reading of its own.
    let scoped = UsageSnapshot(provider: .claude, accountEmail: nil, plan: nil, windows: [
        UsageWindow(id: "opus", label: "Opus", usedPercent: 12, resetsAt: nil, windowSeconds: 604_800)
    ], fetchedAt: UsageFixtures.now)
    #expect(AIUsageMetrics.discoveredWindows(scoped).map { $0.id } == ["ai.claude.opus"])
    #expect(AIUsageMetrics.values(for: .claude, result: .success(scoped), now: UsageFixtures.now)["ai.claude.opus"] == .percent(12))

    // A login failure blanks the provider's own readings; estimated spend is a separate local source.
    let claude = AIUsageMetrics.values(for: .claude, result: .failure(.notLoggedIn), now: UsageFixtures.now)
    #expect(Set(claude.keys) == Set(AIUsageMetrics.ids(for: .claude)))
    let loginError = AIUsageValue.unavailable(UsageError.notLoggedIn.localizedDescription)
    #expect(claude["ai.claude.weekly"] == loginError)
    #expect(claude["ai.claude.extraUsage"] == loginError)
    #expect(claude["ai.claude.spendToday"] != loginError)

    let spend = SpendSummary(provider: .claude, today: 4.5, last7Days: 30, last30Days: 120,
                             tokensToday: 1_000, tokens30Days: 40_000, scannedAt: UsageFixtures.now)
    let priced = AIUsageMetrics.values(for: .claude, result: .failure(.notLoggedIn), spend: spend, now: UsageFixtures.now)
    #expect(priced["ai.claude.spendToday"] == .currency(4.5))
    #expect(priced["ai.claude.spend30d"] == .currency(120))

    // Tokens counted but unpriced must say so rather than report a total that ignores them.
    let unpriced = SpendSummary(provider: .codex, today: 0, last7Days: 0, last30Days: 0, tokensToday: 500,
                                tokens30Days: 9_000, unpricedModels: ["gpt-6-astra"], scannedAt: UsageFixtures.now)
    #expect(AIUsageMetrics.values(for: .codex, result: .success(snapshot), spend: unpriced, now: UsageFixtures.now)["ai.codex.spend7d"]
            == .unavailable("No published rate for gpt-6-astra"))

    #expect(AIUsageMetrics.provider(for: "ai.codex.weekly") == .codex)
    #expect(AIUsageMetrics.provider(for: "cpu.usage") == nil)
}
