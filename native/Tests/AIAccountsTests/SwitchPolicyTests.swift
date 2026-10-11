import Foundation
import Testing
@testable import AIAccounts

private func policyUsage(_ session: Double?, _ weekly: Double?, scoped: (String, Double)? = nil) -> UsageSnapshot {
    var windows: [UsageWindow] = []
    if let session { windows.append(UsageWindow(id: "session", label: "Session", usedPercent: session, resetsAt: nil, windowSeconds: 18_000)) }
    if let weekly { windows.append(UsageWindow(id: "weekly", label: "Weekly", usedPercent: weekly, resetsAt: nil, windowSeconds: 604_800)) }
    if let scoped { windows.append(UsageWindow(id: scoped.0, label: scoped.0, usedPercent: scoped.1, resetsAt: nil, windowSeconds: 604_800)) }
    return UsageSnapshot(provider: .claude, accountEmail: nil, plan: nil, windows: windows, fetchedAt: Date())
}

private func policyAccount(_ email: String, _ provider: AIProvider = .claude, active: Bool = false) -> SwitcherAccount {
    SwitcherAccount(email: email, subscriptionType: "pro", orgName: "", active: active, keychainAccount: email, provider: provider)
}

@Test func switchPolicyExhaustionMatchesSwitcher() {
    #expect(AutoSwitchPolicy.isExhausted(policyUsage(100, 10), threshold: 100))
    #expect(AutoSwitchPolicy.isExhausted(policyUsage(10, 100), threshold: 100))
    #expect(!AutoSwitchPolicy.isExhausted(policyUsage(99.9, 50), threshold: 100))
    #expect(!AutoSwitchPolicy.isExhausted(policyUsage(10, 10, scoped: ("fable", 100)), threshold: 100))
    #expect(!AutoSwitchPolicy.isExhausted(policyUsage(nil, nil), threshold: 100))
    #expect(!AutoSwitchPolicy.isExhausted(nil, threshold: 100))
    #expect(AutoSwitchPolicy.isExhausted(policyUsage(95, nil), threshold: 90))
}

@Test func switchPolicyTargetChoiceMatchesSwitcher() {
    let active = policyAccount("active@example.com", active: true)
    let target = policyAccount("target@example.com")
    let otherProvider = policyAccount("target@example.com", .codex)
    #expect(AutoSwitchPolicy.chooseTarget(provider: .claude, accounts: [active, otherProvider, target], activeEmail: active.email,
                                          usage: [target.email: policyUsage(12, 12)], hasCredential: { _ in true }, threshold: 100) == target)

    let noLogin = policyAccount("no-login@example.com")
    #expect(AutoSwitchPolicy.chooseTarget(provider: .claude, accounts: [active, noLogin, target], activeEmail: active.email,
                                          usage: [noLogin.email: policyUsage(0, 0), target.email: policyUsage(10, 10)],
                                          hasCredential: { $0.email != noLogin.email }, threshold: 100) == target)

    let exhausted = policyAccount("exhausted@example.com")
    #expect(AutoSwitchPolicy.chooseTarget(provider: .claude, accounts: [active, exhausted], activeEmail: active.email,
                                          usage: [exhausted.email: policyUsage(100, 3)], hasCredential: { _ in true }, threshold: 100) == nil)

    let unknown = policyAccount("unknown@example.com")
    #expect(AutoSwitchPolicy.chooseTarget(provider: .claude, accounts: [active, unknown], activeEmail: active.email,
                                          usage: [:], hasCredential: { _ in true }, threshold: 100) == unknown)
    // A known account with room wins over an earlier account whose usage is unknown.
    #expect(AutoSwitchPolicy.chooseTarget(provider: .claude, accounts: [active, unknown, target], activeEmail: active.email,
                                          usage: [target.email: policyUsage(50, 50)], hasCredential: { _ in true }, threshold: 100) == target)
}

@Test func switchPolicyDecisionTable() {
    let now = Date()
    let accounts = [policyAccount("active@example.com", active: true), policyAccount("spare@example.com")]
    func decide(enabled: Bool, running: Bool, active: UsageSnapshot?, last: Date?, spare: UsageSnapshot?) -> AutoSwitchDecision {
        AutoSwitchPolicy.decide(provider: .claude, enabled: enabled, threshold: 100, claudeSwitcherRunning: running,
                                activeEmail: "active@example.com", activeUsage: active, lastAttempt: last, now: now,
                                accounts: accounts, usage: spare.map { ["spare@example.com": $0] } ?? [:],
                                hasCredential: { _ in true })
    }
    let full = policyUsage(100, 20)
    let roomy = policyUsage(5, 5)
    #expect(decide(enabled: false, running: false, active: full, last: nil, spare: roomy) == .disabled)
    #expect(decide(enabled: true, running: true, active: full, last: nil, spare: roomy) == .handledByClaudeSwitcher)
    #expect(decide(enabled: true, running: false, active: policyUsage(40, 40), last: nil, spare: roomy) == .notExhausted)
    #expect(decide(enabled: true, running: false, active: nil, last: nil, spare: roomy) == .notExhausted)
    #expect(decide(enabled: true, running: false, active: full, last: now.addingTimeInterval(-30), spare: roomy) == .coolingDown)
    #expect(decide(enabled: true, running: false, active: full, last: now.addingTimeInterval(-61), spare: roomy) == .switchTo("spare@example.com"))
    #expect(decide(enabled: true, running: false, active: full, last: nil, spare: policyUsage(1, 100)) == .noTarget)
    #expect(decide(enabled: true, running: false, active: full, last: nil, spare: nil) == .switchTo("spare@example.com"))
}

@Test func switchPolicySwitchesBeforeTheWall() {
    let now = Date()
    let accounts = [policyAccount("active@example.com", active: true), policyAccount("spare@example.com")]
    func decide(_ active: UsageSnapshot?, spare: UsageSnapshot?, wall: Bool = false) -> AutoSwitchDecision {
        AutoSwitchPolicy.decide(provider: .claude, enabled: true, threshold: 100, claudeSwitcherRunning: false,
                                activeEmail: "active@example.com", activeUsage: active, lastAttempt: nil, now: now,
                                accounts: accounts, usage: spare.map { ["spare@example.com": $0] } ?? [:],
                                hasCredential: { _ in true }, hitWall: wall)
    }
    #expect(AutoSwitchPolicy.switchPoint(100) == 99)
    // At 100% Claude Code has already refused; MenuSprite moves at 99.
    #expect(decide(policyUsage(20, 99), spare: policyUsage(5, 5)) == .switchTo("spare@example.com"))
    #expect(decide(policyUsage(20, 98), spare: policyUsage(5, 5)) == .notExhausted)
    // A spare that is itself about to hit the wall is not a target.
    #expect(decide(policyUsage(20, 99), spare: policyUsage(5, 99.5)) == .noTarget)
    // Figures that could not be refreshed are minutes old: switch a point early, at 98.
    let stale = policyUsage(20, 98).withNotice("Rate limited · showing the last values")
    #expect(AutoSwitchPolicy.switchPoint(100, for: stale) == 98)
    #expect(decide(stale, spare: policyUsage(5, 5)) == .switchTo("spare@example.com"))
    #expect(decide(policyUsage(20, 97).withNotice("Couldn't refresh"), spare: policyUsage(5, 5)) == .notExhausted)
    // A refused session outranks stale figures.
    #expect(decide(policyUsage(20, 60), spare: policyUsage(5, 5), wall: true) == .switchTo("spare@example.com"))
    #expect(decide(nil, spare: policyUsage(5, 5), wall: true) == .switchTo("spare@example.com"))
    // Checks speed up near the limit, on either window.
    #expect(AutoSwitchPolicy.nextCheck(after: policyUsage(20, 30)) == AutoSwitchPolicy.cadence)
    #expect(AutoSwitchPolicy.nextCheck(after: policyUsage(20, 91)) == AutoSwitchPolicy.nearCadence)
    #expect(AutoSwitchPolicy.nextCheck(after: policyUsage(92, 10)) == AutoSwitchPolicy.nearCadence)
    #expect(AutoSwitchPolicy.nextCheck(after: nil) == AutoSwitchPolicy.cadence)
}

// MARK: - Limit walls in transcripts

private func lines(_ entries: [String]) -> Data { Data((entries.joined(separator: "\n") + "\n").utf8) }

/// The shape Claude Code 2.1.295 wrote on 9 Oct 2026, trimmed to the fields that matter.
private let weeklyWall = #"{"type":"assistant","timestamp":"2026-10-09T09:44:52.602Z","message":{"role":"assistant","content":[{"type":"text","text":"You've hit your weekly limit · resets Oct 14 at 12:30am (Asia/Calcutta)"}]},"apiError":"usage_limit_reached","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1791918000,"rateLimitType":"seven_day"}},"quotaLimits":{"status":"rejected","resetsAt":1791918000,"rateLimitType":"seven_day"},"error":"rate_limit","isApiErrorMessage":true}"#
private let reply = #"{"type":"assistant","timestamp":"2026-10-09T09:40:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Working on it"}]}}"#

@Test func limitWallReadsAStoppedSessionThroughLocalCommands() {
    let tail = lines([
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"con", // a line cut by the read window
        reply, weeklyWall,
        #"{"type":"system","subtype":"turn_duration","durationMs":4775284}"#,
        #"{"type":"user","message":{"role":"user","content":"<local-command-caveat>The command below was run directly</local-command-caveat>"},"isMeta":true}"#,
        #"{"type":"user","message":{"role":"user","content":"<command-name>/rate-limit-options</command-name>"}}"#,
        #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Claude Code will continue automatically at Oct 14</local-command-stdout>"}}"#,
        #"{"type":"file-history-snapshot","messageId":"x","snapshot":{}}"#,
        #"{"type":"ai-title","aiTitle":"Something"}"#,
    ])
    guard case .stopped(let wall) = LimitWall.read(tail: tail) else { Issue.record("expected a stopped session"); return }
    #expect(wall.limitType == "seven_day")
    #expect(wall.isAccountWide)
    #expect(wall.resetsAt == Date(timeIntervalSince1970: 1_791_918_000))
    #expect(wall.at == Date(timeIntervalSince1970: 1791539092.602))
}

@Test func limitWallSeesASessionThatCarriedOn() {
    let typed = #"{"type":"user","message":{"role":"user","content":"The limit is reset now. You can continue."},"origin":{"kind":"human"}}"#
    let automatic = #"{"type":"user","message":{"role":"user","content":"Your claude.ai usage limit has reset. Continue the task"},"isMeta":true}"#
    #expect(LimitWall.read(tail: lines([weeklyWall, typed])) == .running)
    #expect(LimitWall.read(tail: lines([weeklyWall, automatic])) == .running)
    #expect(LimitWall.read(tail: lines([weeklyWall, typed, reply])) == .running)
    #expect(LimitWall.read(tail: lines([reply])) == .running)
    #expect(LimitWall.read(tail: lines([#"{"type":"ai-title","aiTitle":"x"}"#])) == .undecided)
    // A model-scoped wall is still a stop, but not one auto-switch acts on.
    let scoped = weeklyWall.replacingOccurrences(of: "seven_day", with: "seven_day_opus")
    guard case .stopped(let wall) = LimitWall.read(tail: lines([scoped])) else { Issue.record("expected a stop"); return }
    #expect(!wall.isAccountWide)
}
