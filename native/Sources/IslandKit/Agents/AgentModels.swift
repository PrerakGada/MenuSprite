import Foundation

/// The two command-line agents the AI Agents section follows. Each keeps one fixed tint so the
/// strip, the notices and the cards read as the same agent everywhere.
public enum AgentKind: String, CaseIterable, Codable, Sendable, Identifiable, Comparable {
    case claude, codex
    public var id: String { rawValue }

    public var title: String { self == .claude ? "Claude" : "Codex" }
    /// The product whose sessions are followed.
    public var productName: String { self == .claude ? "Claude Code" : "Codex" }

    /// sRGB components of the agent's tint.
    public var tint: (red: Double, green: Double, blue: Double) {
        self == .claude ? (0.85, 0.47, 0.34) : (0.49, 0.60, 1.0)
    }

    /// A system symbol standing in for the vendor's mark. MenuSprite is public source, so it never
    /// borrows brand artwork.
    public var symbol: String { self == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right" }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs == .claude && rhs == .codex }
}

/// Tokens of one response, split the way the providers bill them.
public struct AgentTokens: Equatable, Sendable {
    public var input: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int
    public var output: Int

    public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input; self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead; self.output = output
    }

    public var total: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }

    /// A streamed reply is logged once per content block with growing counts, so repeats of one
    /// response merge by keeping the largest of each count: the response counts once, at its end.
    public func merged(with other: AgentTokens) -> AgentTokens {
        AgentTokens(input: max(input, other.input), cacheWrite5m: max(cacheWrite5m, other.cacheWrite5m),
                    cacheWrite1h: max(cacheWrite1h, other.cacheWrite1h), cacheRead: max(cacheRead, other.cacheRead),
                    output: max(output, other.output))
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
             cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h, cacheRead: lhs.cacheRead + rhs.cacheRead,
             output: lhs.output + rhs.output)
    }

    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
}

/// What the closed island shows beside the camera while an agent works.
public enum AgentReading: String, CaseIterable, Codable, Sendable, Identifiable {
    case time, tokens, cost, limit
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .time: "Time"
        case .tokens: "Tokens written"
        case .cost: "API value"
        case .limit: "Limit"
        }
    }
    /// Only a clock and a limit that can renew change without new data; tokens and cost change
    /// only when the logs do.
    public var needsClock: Bool { self == .time || self == .limit }
}

/// Whether limits read as what is left or what is used.
public enum AgentLimitDisplay: String, CaseIterable, Codable, Sendable, Identifiable {
    case left, used
    public var id: String { rawValue }
    public var title: String { self == .left ? "Left" : "Used" }
}

/// The period the Spending, Trend and Models cards cover.
public enum AgentPeriod: String, CaseIterable, Codable, Sendable, Identifiable {
    case today, week, month
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        }
    }
    /// Local days the period spans, today included.
    public var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }
}

/// One card of the AI Agents page. The raw values are stored: keep them stable.
public enum AgentCard: String, CaseIterable, Codable, Sendable, Identifiable {
    case limits, spending, now, trend, models, projects, activity
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .limits: "Limits"
        case .spending: "Spending"
        case .now: "Now"
        case .trend: "Trend"
        case .models: "Models"
        case .projects: "Projects"
        case .activity: "Activity"
        }
    }

    public var symbol: String {
        switch self {
        case .limits: "gauge.with.needle"
        case .spending: "dollarsign.circle"
        case .now: "waveform"
        case .trend: "chart.bar"
        case .models: "cpu"
        case .projects: "folder"
        case .activity: "square.grid.3x3"
        }
    }

    /// Charts take the full width of the page.
    public var isChart: Bool { self == .trend || self == .activity }

    /// A stored order with unknown and repeated entries dropped, then any card missing from it.
    public static func normalized(_ stored: [String]) -> [AgentCard] {
        var seen = Set<AgentCard>()
        let known = stored.compactMap(AgentCard.init(rawValue:)).filter { seen.insert($0).inserted }
        return known + allCases.filter { !seen.contains($0) }
    }
}

/// Everything the person can choose for the AI Agents section. Pure, so the rules (the last agent
/// cannot be switched off, the minimum is clamped) are testable.
public struct AgentOptions: Equatable, Sendable {
    public static let finishMinimums: [Double] = [0, 30, 60, 120, 300]
    public static let warnThresholds: [Double] = [50, 75, 80, 90, 95]

    public private(set) var agents: Set<AgentKind> = Set(AgentKind.allCases)
    public var cardOrder: [AgentCard] = AgentCard.allCases
    public var hiddenCards: Set<AgentCard> = []
    public var limitDisplay: AgentLimitDisplay = .left
    /// Show a working agent beside the camera. On for new setups.
    public var liveActivity = true
    public var reading: AgentReading = .time
    public var finishNotice = true
    public var finishMinimum: Double = 60 { didSet { finishMinimum = Self.clampMinimum(finishMinimum) } }
    public var limitWarning = true
    public var warnAt: Double = 80 { didSet { warnAt = Self.clampThreshold(warnAt) } }
    public var renewalNotice = true
    public var period: AgentPeriod = .today

    public init() {}

    /// Turns an agent on or off. The last agent left on stays on.
    @discardableResult
    public mutating func setAgent(_ agent: AgentKind, _ on: Bool) -> Bool {
        if on { agents.insert(agent); return true }
        guard agents.count > 1 || !agents.contains(agent) else { return false }
        agents.remove(agent)
        return true
    }

    public func isOn(_ agent: AgentKind) -> Bool { agents.contains(agent) }

    public var visibleCards: [AgentCard] { cardOrder.filter { !hiddenCards.contains($0) } }

    public static func clampMinimum(_ value: Double) -> Double {
        guard value.isFinite else { return 60 }
        return min(3600, max(0, value))
    }

    public static func clampThreshold(_ value: Double) -> Double {
        guard value.isFinite else { return 80 }
        return min(100, max(1, value))
    }
}
