import Foundation

/// One plan-limit window as the provider's server reported it, in the island's own terms.
public struct AgentLimitWindow: Equatable, Sendable, Identifiable {
    public var agent: AgentKind
    /// The provider's window key: `session`, `weekly`, `sonnet`, a model name…
    public var key: String
    public var label: String
    /// 0…100, the server's own figure.
    public var usedPercent: Double
    public var resetsAt: Date?
    public var windowSeconds: Double?
    /// When the reading was taken.
    public var readAt: Date?
    /// The account the reading belongs to, so a switched login is never compared with the last one.
    public var account: String?

    public init(agent: AgentKind, key: String, label: String, usedPercent: Double, resetsAt: Date? = nil,
                windowSeconds: Double? = nil, readAt: Date? = nil, account: String? = nil) {
        self.agent = agent; self.key = key; self.label = label; self.usedPercent = usedPercent
        self.resetsAt = resetsAt; self.windowSeconds = windowSeconds; self.readAt = readAt; self.account = account
    }

    public var id: String { agent.rawValue + "." + key }

    /// The five-hour kind of window: named so, or twelve hours or shorter.
    public var isSession: Bool { key == "session" || (windowSeconds.map { $0 <= 12 * 3600 } ?? false) }

    /// Six to eight days long.
    public var isWeekLong: Bool { windowSeconds.map { (6 * 86_400...8 * 86_400).contains($0) } ?? (key == "weekly") }

    /// Used right now. A window whose renewal has passed has nothing used: its old figure belongs to
    /// the instance that ended.
    public func used(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        guard usedPercent.isFinite else { return 0 }
        return min(100, max(0, usedPercent))
    }

    /// "Session", "Week", "Week · Opus", or the provider's own label for anything else.
    public var shortTitle: String {
        if key == "session" { return "Session" }
        if key == "weekly" { return "Week" }
        if isSession { return label }
        if isWeekLong { return "Week · " + label }
        return label
    }

    /// "Claude · Session", as a notice title.
    public var noticeTitle: String { agent.title + " · " + shortTitle }
}

/// How a limit is coloured: the agent's own tint, orange from 80% used, red from 95%.
public enum AgentLimitTone: Equatable, Sendable {
    case agent, orange, red
    public static let orangeFrom: Double = 80
    public static let redFrom: Double = 95

    public static func tone(used: Double) -> AgentLimitTone {
        if used >= redFrom { return .red }
        if used >= orangeFrom { return .orange }
        return .agent
    }
}

/// Selection, wording and pace for plan limits.
public enum AgentLimits {
    /// Codex reports model-specific allowances (Spark) beside its main one. Only the main allowance
    /// is followed, so a model's own allowance never stands in for it or warns a second time.
    public static func isFollowed(_ window: AgentLimitWindow) -> Bool {
        !(window.agent == .codex && window.key.lowercased().hasPrefix("spark"))
    }

    /// The allowance closest to running out: the highest used percentage. Within one agent a tie goes
    /// to the window that renews later; across agents a tie goes to Claude.
    public static func binding(_ windows: [AgentLimitWindow], now: Date) -> AgentLimitWindow? {
        let perAgent = AgentKind.allCases.compactMap { agent in
            mostUsed(windows.filter { $0.agent == agent && isFollowed($0) }, now: now)
        }
        // Claude comes first, and only a strictly higher figure displaces it.
        var best: AgentLimitWindow?
        for window in perAgent where best.map({ window.used(at: now) > $0.used(at: now) }) ?? true { best = window }
        return best
    }

    /// The limits card's rows for one agent: the session window, then the most used longer window.
    public static func cardRows(_ windows: [AgentLimitWindow], agent: AgentKind, now: Date) -> [AgentLimitWindow] {
        let own = windows.filter { $0.agent == agent && isFollowed($0) }
        let session = own.first { $0.key == "session" } ?? own.first(where: \.isSession)
        let longer = mostUsed(own.filter { $0.id != session?.id && !$0.isSession }, now: now)
        return [session, longer].compactMap { $0 }
    }

    /// Highest used percentage; a tie goes to the window that renews later.
    static func mostUsed(_ windows: [AgentLimitWindow], now: Date) -> AgentLimitWindow? {
        windows.max { lhs, rhs in
            let (a, b) = (lhs.used(at: now), rhs.used(at: now))
            if a != b { return a < b }
            return (lhs.resetsAt ?? .distantPast) < (rhs.resetsAt ?? .distantPast)
        }
    }

    /// The figure a ring or meter shows, 0…1, as left or used.
    public static func fraction(_ window: AgentLimitWindow, display: AgentLimitDisplay, now: Date) -> Double {
        let used = window.used(at: now) / 100
        return display == .left ? 1 - used : used
    }

    /// "62%" for the resting wing.
    public static func percent(_ window: AgentLimitWindow, display: AgentLimitDisplay, now: Date) -> String {
        "\(Int((fraction(window, display: display, now: now) * 100).rounded()))%"
    }

    /// "18% left" or "82% used".
    public static func phrase(_ window: AgentLimitWindow, display: AgentLimitDisplay, now: Date) -> String {
        percent(window, display: display, now: now) + (display == .left ? " left" : " used")
    }

    /// Where the pace tick sits on a meter: the share of the window's time already gone, mirrored
    /// when the meter shows what is left. No tick for a renewed window, one read before it began, or
    /// one within 2% of either end.
    public static func paceTick(_ window: AgentLimitWindow, display: AgentLimitDisplay, now: Date) -> Double? {
        guard let reset = window.resetsAt, let length = window.windowSeconds, length > 0, now < reset else { return nil }
        let start = reset.addingTimeInterval(-length)
        if let readAt = window.readAt, readAt < start { return nil }
        let elapsed = now.timeIntervalSince(start) / length
        guard elapsed >= 0.02, elapsed <= 0.98 else { return nil }
        return display == .left ? 1 - elapsed : elapsed
    }
}

/// Decides limit warnings and renewals between readings. Pure state: feed it every reading and
/// the clock, and it says what is news.
public struct AgentLimitAlerts: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case warning(AgentLimitWindow)
        case renewed(AgentLimitWindow)
    }

    private struct Seen: Equatable, Sendable {
        var used: Double
        var resetsAt: Date?
        var account: String?
    }

    private var seen: [String: Seen] = [:]
    /// Windows warned about, with the renewal the warning belonged to.
    private var warned: [String: AgentLimitWindow] = [:]

    public init() {}

    /// A new reading. A warning comes when a window crosses from below the threshold to at or above
    /// it, or when a renewed instance (its reset moved more than a minute later) is already above it.
    /// The first reading of a window, or of a different account, is never news.
    public mutating func observe(_ windows: [AgentLimitWindow], threshold: Double, now: Date) -> [Event] {
        var events: [Event] = []
        for window in windows where AgentLimits.isFollowed(window) {
            let used = window.used(at: now)
            defer { seen[window.id] = Seen(used: used, resetsAt: window.resetsAt, account: window.account) }
            guard let previous = seen[window.id], previous.account == window.account else {
                warned[window.id] = nil
                continue
            }
            let renewed = Self.moved(from: previous.resetsAt, to: window.resetsAt)
            if renewed, let old = warned[window.id], used < threshold {
                events.append(.renewed(old))
                warned[window.id] = nil
            }
            if used >= threshold, previous.used < threshold || renewed {
                events.append(.warning(window))
                warned[window.id] = window
            }
        }
        return events
    }

    /// The clock moved: a warned window whose renewal has passed is renewed.
    public mutating func tick(now: Date) -> [Event] {
        var events: [Event] = []
        for (id, window) in warned.sorted(by: { $0.key < $1.key }) {
            guard let reset = window.resetsAt, reset <= now else { continue }
            events.append(.renewed(window))
            warned[id] = nil
        }
        return events
    }

    /// The next moment `tick` can say something, so the owner can wait for exactly that.
    public var nextRenewal: Date? { warned.values.compactMap(\.resetsAt).min() }

    private static func moved(from old: Date?, to new: Date?) -> Bool {
        guard let old, let new else { return false }
        return new.timeIntervalSince(old) > 60
    }
}
