import Foundation

/// One local day of one agent's estimated spend, per model, as MenuSprite's spend cache keeps it.
public struct AgentSpendDay: Equatable, Sendable {
    /// 0 is today, 1 yesterday.
    public var daysAgo: Int
    public var agent: AgentKind
    public var models: [String: AgentTokens]

    public init(daysAgo: Int, agent: AgentKind, models: [String: AgentTokens]) {
        self.daysAgo = daysAgo; self.agent = agent; self.models = models
    }
}

/// What the Spending, Trend and Models cards show for one period. Dollars are API list prices for
/// the same work, never money charged; tokens no rate covers are counted and flagged instead.
public struct AgentSpendSummary: Equatable, Sendable {
    public struct Model: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var agent: AgentKind
        public var value: Double
    }

    public var dollars: Double
    public var dollarsByAgent: [AgentKind: Double]
    public var tokens: Int
    public var tokensByAgent: [AgentKind: Int]
    public var cacheRead: Int
    /// Some tokens had no known price, so dollars are a minimum and rankings use tokens.
    public var hasUnpriced: Bool
    /// Oldest first, one per day, split by agent: dollars when everything is priced, else tokens.
    public var bars: [[AgentKind: Double]]
    public var models: [Model]

    public var barsAreDollars: Bool { !hasUnpriced }
    public var cacheShare: Double { tokens > 0 ? Double(cacheRead) / Double(tokens) : 0 }

    /// Daily bars need a week at least: an hour-by-hour split of today is not kept.
    public static func barCount(_ period: AgentPeriod) -> Int { period == .month ? 30 : 7 }

    public static func make(days: [AgentSpendDay], period: AgentPeriod, agents: Set<AgentKind>,
                            price: (String, AgentTokens) -> Double?) -> AgentSpendSummary {
        var dollars: [AgentKind: Double] = [:]
        var tokens: [AgentKind: Int] = [:]
        var cacheRead = 0
        var unpriced = false
        var modelTotals: [String: (agent: AgentKind, dollars: Double, tokens: Int)] = [:]
        let count = barCount(period)
        var barDollars = Array(repeating: [AgentKind: Double](), count: count)
        var barTokens = Array(repeating: [AgentKind: Double](), count: count)

        for day in days where agents.contains(day.agent) && day.daysAgo >= 0 {
            for (model, used) in day.models where used.total > 0 {
                let cost = price(model, used)
                if day.daysAgo < count {
                    let slot = count - 1 - day.daysAgo
                    barDollars[slot][day.agent, default: 0] += cost ?? 0
                    barTokens[slot][day.agent, default: 0] += Double(used.total)
                }
                guard day.daysAgo < period.days else { continue }
                if cost == nil { unpriced = true }
                dollars[day.agent, default: 0] += cost ?? 0
                tokens[day.agent, default: 0] += used.total
                cacheRead += used.cacheRead
                var entry = modelTotals[model] ?? (day.agent, 0, 0)
                entry.dollars += cost ?? 0
                entry.tokens += used.total
                modelTotals[model] = entry
            }
        }
        let ranked = modelTotals.map { id, entry in
            Model(id: id, name: AgentFormat.modelName(id) ?? id, agent: entry.agent,
                  value: unpriced ? Double(entry.tokens) : entry.dollars)
        }
        .filter { $0.value > 0 }
        .sorted { ($0.value, $1.id) > ($1.value, $0.id) }
        return AgentSpendSummary(dollars: dollars.values.reduce(0, +), dollarsByAgent: dollars,
                                 tokens: tokens.values.reduce(0, +), tokensByAgent: tokens, cacheRead: cacheRead,
                                 hasUnpriced: unpriced, bars: unpriced ? barTokens : barDollars,
                                 models: Array(ranked.prefix(3)))
    }
}
