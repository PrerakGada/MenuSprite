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
