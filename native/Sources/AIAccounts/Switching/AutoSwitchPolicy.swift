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
    /// How often MenuSprite checks usage while every window is well clear of the limit.
    public static let cadence: TimeInterval = 300
    /// How often it checks once a session or weekly window passes `nearPercent`, so the switch lands
    /// before the wall. It reads the shared usage cache, which the pacer keeps no fresher than a minute.
    public static let nearCadence: TimeInterval = 60
    public static let nearPercent = 90.0
    /// MenuSprite switches this many points *before* the threshold. At 100% Claude Code has already
    /// been refused and every running session has stopped at the wall (10 Oct 2026), so switching at
    /// the threshold itself is always a few minutes late. One point (99% of 100), Prerak's call: from
    /// 98% usage is read every two minutes (`UsageAutoPacer.critical`), and a point takes longer than
    /// that at his weekly pace. A 5-hour window under many sessions can outrun it; the wall check then
    /// switches within 30 s and the stopped sessions are told to carry on. Claude Switcher switches at the threshold.
    public static let headroom = 1.0
    /// When the active account's figures could not be refreshed (rate limited, offline, a login
    /// awaiting renewal), the last good ones are all there is and they can be minutes old, so the
    /// switch comes a point earlier: 98% of 100. (10 Oct 2026, Prerak.)
    public static let blindHeadroom = 2.0
    public static let claudeSwitcherBundleID = "com.emilejouannet.claude-switcher"

    /// The switcher's `is_exhausted`: the highest known window reaches the threshold. It only reads the
    /// session and weekly windows, so model-scoped limits (Sonnet, Fable, Spark) never trigger a switch.
    public static func isExhausted(_ usage: UsageSnapshot?, threshold: Double) -> Bool {
        guard let highest = limitingPercents(usage).max() else { return false }
        return highest >= threshold
    }

    /// The point MenuSprite actually switches at: the shared threshold less `headroom`.
    public static func switchPoint(_ threshold: Double) -> Double { min(threshold, 100) - headroom }

    /// The switch point for the active account given what its figures are: a snapshot carrying a
    /// notice is the last good one served because no new request could be made.
    public static func switchPoint(_ threshold: Double, for usage: UsageSnapshot?) -> Double {
        isStale(usage) ? min(threshold, 100) - blindHeadroom : switchPoint(threshold)
    }

    /// `UsageService` sets a notice only when it serves the last good figures instead of new ones.
    public static func isStale(_ usage: UsageSnapshot?) -> Bool { usage?.notice != nil }

    /// How long to wait before the next check, from what the active account last showed.
    public static func nextCheck(after usage: UsageSnapshot?) -> TimeInterval {
        (limitingPercents(usage).max() ?? 0) >= nearPercent ? nearCadence : cadence
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
                              hasCredential: (SwitcherAccount) -> Bool, hitWall: Bool = false) -> AutoSwitchDecision {
        guard enabled else { return .disabled }
        guard !claudeSwitcherRunning else { return .handledByClaudeSwitcher }
        // A session that was just refused for the session or weekly limit is proof the account is out,
        // whatever the last (cached, possibly minutes old) usage figures said.
        let point = switchPoint(threshold)
        guard let activeEmail, hitWall || isExhausted(activeUsage, threshold: switchPoint(threshold, for: activeUsage)) else { return .notExhausted }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < cooldown { return .coolingDown }
        guard let target = chooseTarget(provider: provider, accounts: accounts, activeEmail: activeEmail, usage: usage,
                                        hasCredential: hasCredential, threshold: point) else { return .noTarget }
        return .switchTo(target.email)
    }

    private static func limitingPercents(_ usage: UsageSnapshot?) -> [Double] {
        (usage?.windows ?? []).filter { $0.id == "session" || $0.id == "weekly" }.map(\.usedPercent)
    }
}
