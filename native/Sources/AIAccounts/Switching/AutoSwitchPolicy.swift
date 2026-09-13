import Foundation

public enum AutoSwitchDecision: Sendable, Equatable {
    case disabled
    /// Claude Switcher is running and owns auto-switch, so the two apps never both switch.
    case handledByClaudeSwitcher
    case notExhausted
    case coolingDown
    case noTarget
    case switchTo(String)
}

/// Claude Switcher's auto-switch rules, kept pure so they can be tested without credentials.
public enum AutoSwitchPolicy {
    /// Minimum time between attempts for one provider (the switcher's `AUTO_SWITCH_COOLDOWN_SECONDS`).
    public static let cooldown: TimeInterval = 60
    /// How often the switcher checks usage.
    public static let cadence: TimeInterval = 300
    public static let claudeSwitcherBundleID = "com.emilejouannet.claude-switcher"

    /// The switcher's `is_exhausted`: the highest known window reaches the threshold. It only reads the
    /// session and weekly windows, so model-scoped limits (Sonnet, Fable, Spark) never trigger a switch.
    public static func isExhausted(_ usage: UsageSnapshot?, threshold: Double) -> Bool {
        guard let highest = limitingPercents(usage).max() else { return false }
        return highest >= threshold
    }

    /// The switcher's target choice: another account of the same provider with a saved login,
    /// preferring one whose usage is known and below the threshold, else one whose usage is unknown.
    public static func chooseTarget(provider: AIProvider, accounts: [SwitcherAccount], activeEmail: String,
                                    usage: [String: UsageSnapshot], hasCredential: (SwitcherAccount) -> Bool,
                                    threshold: Double) -> SwitcherAccount? {
        var unknown: [SwitcherAccount] = []
        for account in accounts where account.provider == provider && account.email != activeEmail && hasCredential(account) {
            let snapshot = usage[account.email]
            if limitingPercents(snapshot).isEmpty {
                unknown.append(account)
            } else if !isExhausted(snapshot, threshold: threshold) {
                return account
            }
        }
        return unknown.first
    }

    public static func decide(provider: AIProvider, enabled: Bool, threshold: Double, claudeSwitcherRunning: Bool,
                              activeEmail: String?, activeUsage: UsageSnapshot?, lastAttempt: Date?, now: Date,
                              accounts: [SwitcherAccount], usage: [String: UsageSnapshot],
                              hasCredential: (SwitcherAccount) -> Bool) -> AutoSwitchDecision {
        guard enabled else { return .disabled }
        guard !claudeSwitcherRunning else { return .handledByClaudeSwitcher }
        guard let activeEmail, isExhausted(activeUsage, threshold: threshold) else { return .notExhausted }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < cooldown { return .coolingDown }
        guard let target = chooseTarget(provider: provider, accounts: accounts, activeEmail: activeEmail, usage: usage,
                                        hasCredential: hasCredential, threshold: threshold) else { return .noTarget }
        return .switchTo(target.email)
    }

    private static func limitingPercents(_ usage: UsageSnapshot?) -> [Double] {
        (usage?.windows ?? []).filter { $0.id == "session" || $0.id == "weekly" }.map(\.usedPercent)
    }
}
