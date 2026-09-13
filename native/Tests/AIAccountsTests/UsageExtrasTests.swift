import Foundation
import Testing
@testable import AIAccounts

// Fixtures shaped like the payloads both providers actually returned on 13 September 2026,
// nulls and all. Local to this file so the shared fixtures stay as other suites expect them.

private func claudeBody(limits: [Any]? = nil, sevenDaySonnet: Any = NSNull(), spend: Any? = nil,
                        extraUsage: Any? = nil, breakdown: Any? = nil) -> [String: Any] {
    var body: [String: Any] = [
        "five_hour": ["utilization": 6.0, "resets_at": "2026-09-13T19:40:00.948626+00:00"] as [String: Any],
        "seven_day": ["utilization": 56.0, "resets_at": "2026-09-18T08:00:00.948644+00:00"] as [String: Any],
        "seven_day_sonnet": sevenDaySonnet,
        "seven_day_opus": NSNull(),
        "member_dashboard_available": false
    ]
    if let limits { body["limits"] = limits }
    if let spend { body["spend"] = spend }
    if let extraUsage { body["extra_usage"] = extraUsage }
    if let breakdown { body["seven_day_breakdown"] = breakdown }
    return body
}

private func scopedLimit(_ model: String, percent: Double) -> [String: Any] {
    ["kind": "weekly_scoped", "percent": percent, "resets_at": "2026-09-18T08:00:00.948811+00:00",
     "scope": ["model": ["display_name": model] as [String: Any]] as [String: Any]]
}

/// The session and weekly_all rows the live payload carries beside the scoped ones. A function, not a
/// global: a JSON array is not `Sendable` and would not survive Swift 6's concurrency checking.
private func repeatedLimits() -> [Any] {
    [
        ["kind": "session", "percent": 6, "resets_at": "2026-09-13T19:40:00.948626+00:00"] as [String: Any],
        ["kind": "weekly_all", "percent": 56, "resets_at": "2026-09-18T08:00:00.948644+00:00"] as [String: Any]
    ]
}

private func claudeSnapshot(_ body: [String: Any]) throws -> UsageSnapshot {
    let credential = try #require(ClaudeCredential(json: UsageFixtures.claudeCredential()))
    return try ClaudeUsageAPI.snapshot(from: UsageFixtures.response(200, body), credential: credential,
                                       email: nil, now: UsageFixtures.now)
}

private func codexSnapshot(_ body: [String: Any], resetCredits: HTTPResponse? = nil) throws -> UsageSnapshot {
    let credential = try #require(CodexCredential(json: UsageFixtures.codexAuth(accessExpiry: 2_000_000_000)))
    return try CodexUsageAPI.snapshot(from: UsageFixtures.response(200, body), credential: credential,
                                      fallbackEmail: nil, resetCredits: resetCredits, now: UsageFixtures.now)
}

@Test func claudeMapsEveryModelScopedWeeklyLimit() throws {
    let limits = repeatedLimits() + [scopedLimit("Fable", percent: 4), scopedLimit("Sonnet", percent: 31),
                                     scopedLimit("Opus", percent: 12)]
    let snapshot = try claudeSnapshot(claudeBody(limits: limits))
    #expect(snapshot.windows.map(\.id) == ["session", "weekly", "fable", "sonnet", "opus"])
    #expect(snapshot.window("sonnet")?.usedPercent == 31)
    #expect(snapshot.window("opus")?.label == "Opus")
    #expect(snapshot.window("opus")?.windowSeconds == 604_800)
    #expect(snapshot.window("fable")?.resetsAt == UsageParse.date("2026-09-18T08:00:00.948Z"))
    // The session and weekly_all rows repeat five_hour/seven_day; mapping them again would double them.
    #expect(snapshot.windows.filter { $0.id == "session" }.count == 1)
    #expect(snapshot.window("session")?.usedPercent == 6)
    #expect(snapshot.window("weekly")?.usedPercent == 56)
}

@Test func scopedModelLimitSupersedesTheLegacySevenDayKey() throws {
    let legacySonnet: [String: Any] = ["utilization": 5.0, "resets_at": "2026-09-18T08:00:00Z"]
    let both = try claudeSnapshot(claudeBody(limits: [scopedLimit("Sonnet", percent: 31)], sevenDaySonnet: legacySonnet))
    #expect(both.windows.filter { $0.id == "sonnet" }.count == 1)
    #expect(both.window("sonnet")?.usedPercent == 31)

    let legacyOnly = try claudeSnapshot(claudeBody(sevenDaySonnet: legacySonnet))
    #expect(legacyOnly.window("sonnet")?.usedPercent == 5)
}

@Test func claudeSpendIsPreferredAndADisabledAllowanceIsARealZero() throws {
    // Prerak's live shape: a spend record that exists but is switched off.
    let disabled: [String: Any] = [
        "used": ["amount_minor": 0, "currency": "USD", "exponent": 2] as [String: Any],
        "limit": NSNull(), "percent": 0, "severity": "normal", "enabled": false,
        "disabled_reason": NSNull(), "user_disabled": true
    ]
    let staleExtraUsage: [String: Any] = ["is_enabled": true, "used_credits": 1234, "monthly_limit": 5000]
    let off = try #require(try claudeSnapshot(claudeBody(spend: disabled, extraUsage: staleExtraUsage)).extraUsage)
    #expect(!off.enabled)
    #expect(off.usedDollars == 0)
    #expect(off.limitDollars == nil)

    let spending: [String: Any] = [
        "used": ["amount_minor": 4567, "currency": "USD", "exponent": 2] as [String: Any],
        "limit": ["amount_minor": 50_000, "currency": "USD", "exponent": 2] as [String: Any],
        "percent": 9.13, "enabled": true, "disabled_reason": NSNull()
    ]
    let on = try #require(try claudeSnapshot(claudeBody(spend: spending)).extraUsage)
    #expect(on.enabled)
    #expect(abs(on.usedDollars - 45.67) < 0.000_001)
    #expect(abs((on.limitDollars ?? 0) - 500) < 0.000_001)
    #expect(on.percent == 9.13)

    // Without `spend`, the older cents-based shape still maps.
    let legacy = try #require(try claudeSnapshot(claudeBody(extraUsage: staleExtraUsage)).extraUsage)
    #expect(legacy.enabled)
    #expect(abs(legacy.usedDollars - 12.34) < 0.000_001)
    #expect(legacy.limitDollars == 50)
}

@Test func claudeWeeklyBreakdownBecomesRows() throws {
    let breakdown: [String: Any] = [
        "as_of": "2026-09-13T15:20:36.989302+00:00",
        "window_started_at": "2026-09-11T08:00:00.954541+00:00",
        "rows": [
            ["key": "claude_code", "display_name": "Claude Code", "percent": 98] as [String: Any],
            ["key": "chat", "display_name": "Chats", "percent": 1] as [String: Any],
            ["key": "cowork", "display_name": "Cowork", "percent": 1] as [String: Any],
            ["key": "other", "display_name": "Other", "percent": 0] as [String: Any]
        ] as [Any]
    ]
    let snapshot = try claudeSnapshot(claudeBody(breakdown: breakdown))
    #expect(snapshot.breakdown.map(\.id) == ["claude_code", "chat", "cowork", "other"])
    #expect(snapshot.breakdown.map(\.label) == ["Claude Code", "Chats", "Cowork", "Other"])
    #expect(snapshot.breakdown.map(\.percent) == [98, 1, 1, 0])
    #expect(try claudeSnapshot(claudeBody()).breakdown.isEmpty)
}

@Test func codexResetCreditsPreferTheDedicatedEndpointAndSortExpiries() throws {
    var body = UsageFixtures.standardCodexBody()
    body["rate_limit_reset_credits"] = ["available_count": 1, "applicable_available_count": 1] as [String: Any]
    let dedicated: [String: Any] = ["available_count": 2, "total_earned_count": 5, "history_enabled": true, "credits": [
        ["expires_at": "2026-09-20T08:00:00Z", "status": "available"] as [String: Any],
        ["expires_at": "2026-09-15T08:00:00Z"] as [String: Any],
        ["expires_at": "2026-09-14T08:00:00Z", "status": "consumed"] as [String: Any]
    ] as [Any]]
    let resets = try #require(try codexSnapshot(body, resetCredits: UsageFixtures.response(200, dedicated)).resetCredits)
    #expect(resets.available == 2)
    #expect(resets.expiries.count == 2)
    #expect(resets.expiries == resets.expiries.sorted())
    #expect(resets.expiries.first == UsageParse.date("2026-09-15T08:00:00Z"))
}

@Test func codexResetCreditsFallBackToTheUsageBodyCount() throws {
    var body = UsageFixtures.standardCodexBody()
    body["rate_limit_reset_credits"] = ["available_count": 1] as [String: Any]
    let failed = try #require(try codexSnapshot(body, resetCredits: UsageFixtures.response(500)).resetCredits)
    #expect(failed.available == 1)
    #expect(failed.expiries.isEmpty)

    let skipped = try #require(try codexSnapshot(body).resetCredits)
    #expect(skipped.available == 1)
    // A payload that never mentions reset credits reports nothing rather than a fabricated zero.
    #expect(try codexSnapshot(UsageFixtures.standardCodexBody()).resetCredits == nil)
}

@Test func codexSparkWindowsCarryBothDurations() throws {
    var body = UsageFixtures.standardCodexBody()
    body["additional_rate_limits"] = [[
        "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
        "rate_limit": ["primary_window": ["used_percent": 3, "limit_window_seconds": 18_000, "reset_at": 1_800_018_000] as [String: Any],
                       "secondary_window": ["used_percent": 8, "limit_window_seconds": 604_800, "reset_at": 1_800_600_000] as [String: Any]] as [String: Any]
    ] as [String: Any]] as [Any]
    let snapshot = try codexSnapshot(body)
    #expect(snapshot.window("spark")?.usedPercent == 3)
    #expect(snapshot.window("spark")?.windowSeconds == 18_000)
    #expect(snapshot.window("sparkWeekly")?.usedPercent == 8)
    #expect(snapshot.window("sparkWeekly")?.windowSeconds == 604_800)
}

@Test func resetCreditsAreFetchedOnlyWhenTheAccountHoldsThem() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setCodexAuth(UsageFixtures.codexAuth(accessExpiry: UsageFixtures.now.timeIntervalSince1970 + 86_400))

    var empty = UsageFixtures.standardCodexBody()
    empty["rate_limit_reset_credits"] = ["available_count": 0] as [String: Any]
    // Serialize each body before the handler: a JSON dictionary cannot cross into a @Sendable closure.
    let emptyResponse = UsageFixtures.response(200, empty)
    let quiet = FakeTransport { _, _ in emptyResponse }
    let none = try (await sandbox.service(quiet).activeUsage(.codex, force: false)).get()
    #expect(quiet.requests.count == 1)
    #expect(none.resetCredits?.available == 0)

    var holding = UsageFixtures.standardCodexBody()
    holding["rate_limit_reset_credits"] = ["available_count": 2] as [String: Any]
    let dedicated: [String: Any] = ["available_count": 2, "credits": [["expires_at": "2026-09-20T08:00:00Z"] as [String: Any]] as [Any]]
    let holdingResponse = UsageFixtures.response(200, holding)
    let dedicatedResponse = UsageFixtures.response(200, dedicated)
    let busy = FakeTransport { request, _ in
        request.url.absoluteString.hasSuffix("rate-limit-reset-credits") ? dedicatedResponse : holdingResponse
    }
    let snapshot = try (await sandbox.service(busy).activeUsage(.codex, force: false)).get()
    #expect(busy.requests.count == 2)
    let second = try #require(busy.requests.last)
    #expect(second.url.absoluteString == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
    #expect(second.headers["OpenAI-Beta"] == "codex-1")
    #expect(second.headers["originator"] == "Codex Desktop")
    #expect(second.headers["ChatGPT-Account-Id"] == "acct-1")
    #expect(snapshot.resetCredits?.available == 2)
    #expect(snapshot.resetCredits?.expiries.count == 1)
}

@Test func aFailingResetCreditsFetchNeverFailsTheRefresh() async throws {
    let sandbox = UsageSandbox(); defer { sandbox.cleanup() }
    try sandbox.setCodexAuth(UsageFixtures.codexAuth(accessExpiry: UsageFixtures.now.timeIntervalSince1970 + 86_400))
    var body = UsageFixtures.standardCodexBody()
    body["rate_limit_reset_credits"] = ["available_count": 3] as [String: Any]
    let usageResponse = UsageFixtures.response(200, body)
    let http = FakeTransport { request, _ in
        if request.url.absoluteString.hasSuffix("rate-limit-reset-credits") { throw OfflineError() }
        return usageResponse
    }
    let snapshot = try (await sandbox.service(http).activeUsage(.codex, force: false)).get()
    #expect(http.requests.count == 2)
    #expect(snapshot.window("weekly")?.usedPercent == 47)
    #expect(snapshot.resetCredits?.available == 3)
    #expect(snapshot.resetCredits?.expiries.isEmpty == true)
}
