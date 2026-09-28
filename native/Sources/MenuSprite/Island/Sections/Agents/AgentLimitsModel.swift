import AIAccounts
import Foundation
import IslandKit

/// Where one agent's limits stand.
struct AgentLimitStatus: Equatable {
    var plan: String?
    var readAt: Date?
    /// The usage service's own note, such as serving the last values while rate limited.
    var notice: String?
    /// Why there is no reading at all ("Not signed in.").
    var issue: String?
}

/// MenuSprite's estimated spend, as far as the island may know it.
enum AgentSpendState: Equatable {
    /// Estimated spend is off in AI Accounts.
    case off
    /// On, but no pass has finished yet.
    case waiting
    case ready(days: [AgentSpendDay], scannedAt: Date)
}

/// Plan limits and estimated spend for the island. Limits are the server figures MenuSprite's AI
/// readings already fetch: the island registers demand for an `ai.` reading with the monitoring store
/// (which shares the usage service's five-minute cache with the menu bar) and reads its snapshots, so
/// it never calls the usage endpoints itself. Spend is read from the estimate's in-memory cache and
/// never starts a scan of the logs.
@MainActor
final class AgentLimitsModel: ObservableObject {
    static let owner = "island.agents"

    struct Demand: Equatable {
        /// Something needs limits: the resting wings, warnings or the strip's Limit reading.
        var limits = false
        var page = false
        var spend = false
        var agents: Set<AgentKind> = []
        var warnAt: Double = 80
        var warnings = false
        var running: Bool { limits || page || spend }
    }

    @Published private(set) var windows: [AgentLimitWindow] = []
    @Published private(set) var status: [AgentKind: AgentLimitStatus] = [:]
    @Published private(set) var spend: AgentSpendState = .off
    /// Moves once a minute (every 15 s while the page shows) so countdowns and renewals follow the clock.
    @Published private(set) var now = Date()
    var onAlert: ((AgentLimitAlerts.Event) -> Void)?
    var onChange: (() -> Void)?

    private unowned let monitoring: MonitoringStore
    private let preview: Bool
    private var demand = Demand()
    private var alerts = AgentLimitAlerts()
    private var loop: Task<Void, Never>?
    private var spendTask: Task<Void, Never>?

    /// `preview` (the off-screen render harness) shows example limits and spend and touches no login.
    init(monitoring: MonitoringStore, preview: Bool) {
        self.monitoring = monitoring
        self.preview = preview
    }

    func configure(_ new: Demand) {
        guard new.running else { stop(); return }
        let old = demand
        demand = new
        if !preview, old.agents != new.agents || old.limits != new.limits || old.page != new.page {
            let ids = new.limits || new.page ? Set(new.agents.map { "ai.\($0.rawValue).session" }) : []
            monitoring.setSurfaceMetrics(Self.owner, ids, interval: 60)
        }
        if old.agents != new.agents || old.warnAt != new.warnAt || !new.warnings { alerts = AgentLimitAlerts() }
        if loop == nil || old.page != new.page { startLoop() }
        refresh()
    }

    func stop() {
        loop?.cancel(); loop = nil
        spendTask?.cancel(); spendTask = nil
        if !preview, demand.running { monitoring.setSurfaceMetrics(Self.owner, []) }
        demand = Demand()
        alerts = AgentLimitAlerts()
        if !windows.isEmpty { windows = [] }
        if !status.isEmpty { status = [:] }
        if spend != .off { spend = .off }
    }

    private func startLoop() {
        loop?.cancel()
        let period: Double = demand.page ? 15 : 60
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(period))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    /// Whether limits are being followed; an idle model shows only what a peek found.
    var isRunning: Bool { demand.limits || demand.page }

    /// For the settings preview: whatever the monitoring store already fetched, asking for nothing.
    func peek(agents: Set<AgentKind>) {
        guard !demand.running else { return }
        now = Date()
        let (list, states) = read(agents)
        if list != windows { windows = list }
        if states != status { status = states }
    }

    func refresh() {
        now = Date()
        let (list, states) = isRunning ? read(demand.agents) : ([], [:])
        if list != windows { windows = list }
        if states != status { status = states }
        if demand.warnings {
            for event in alerts.observe(list, threshold: demand.warnAt, now: now) + alerts.tick(now: now) { onAlert?(event) }
        }
        if demand.spend { loadSpend() } else if spend != .off { spend = .off }
        onChange?()
    }

    private func read(_ agents: Set<AgentKind>) -> ([AgentLimitWindow], [AgentKind: AgentLimitStatus]) {
        var list: [AgentLimitWindow] = []
        var states: [AgentKind: AgentLimitStatus] = [:]
        for agent in AgentKind.allCases where agents.contains(agent) {
            if preview {
                list += Self.previewWindows(agent, now: now)
                states[agent] = AgentLimitStatus(plan: agent == .claude ? "Max 20x" : "Plus", readAt: now.addingTimeInterval(-120))
                continue
            }
            guard let provider = AIProvider(rawValue: agent.rawValue) else { continue }
            if let snapshot = monitoring.usageSnapshot(provider) {
                list += snapshot.windows.map { window in
                    AgentLimitWindow(agent: agent, key: window.id, label: window.label, usedPercent: window.usedPercent,
                                     resetsAt: window.resetsAt, windowSeconds: window.windowSeconds,
                                     readAt: snapshot.fetchedAt, account: snapshot.accountEmail)
                }.filter(AgentLimits.isFollowed)
                states[agent] = AgentLimitStatus(plan: snapshot.plan, readAt: snapshot.fetchedAt, notice: snapshot.notice)
            } else {
                states[agent] = AgentLimitStatus(issue: monitoring.readings[AIUsageMetrics.id(provider, window: "session")]?.issue)
            }
        }
        return (list, states)
    }

    private func loadSpend() {
        if preview {
            let state = AgentSpendState.ready(days: Self.previewDays, scannedAt: now.addingTimeInterval(-3600))
            if spend != state { spend = state }
            return
        }
        guard SpendPreference.isEnabled else {
            if spend != .off { spend = .off; onChange?() }
            return
        }
        let agents = demand.agents
        spendTask?.cancel()
        spendTask = Task { [weak self] in
            var days: [AgentSpendDay] = []
            var scannedAt: Date?
            for agent in AgentKind.allCases where agents.contains(agent) {
                guard let provider = AIProvider(rawValue: agent.rawValue),
                      let history = await SpendService.shared.cachedHistory(provider) else { continue }
                scannedAt = min(scannedAt ?? history.scannedAt, history.scannedAt)
                days += history.days.map { AgentSpendDay(daysAgo: $0.daysAgo, agent: agent, models: $0.models.mapValues(AgentTokens.init)) }
            }
            guard let self, !Task.isCancelled else { return }
            let state: AgentSpendState = scannedAt.map { .ready(days: days, scannedAt: $0) } ?? .waiting
            if state != self.spend { self.spend = state; self.onChange?() }
        }
    }

    /// Today's API value, for the resting wing when no limit is known.
    func todayValue() -> Double? {
        guard case .ready(let days, _) = spend else { return nil }
        let summary = AgentSpendSummary.make(days: days, period: .today, agents: demand.agents, price: AgentActivityService.price)
        return summary.dollars > 0 ? summary.dollars : nil
    }

    // MARK: Example data for off-screen renders

    private static func previewWindows(_ agent: AgentKind, now: Date) -> [AgentLimitWindow] {
        let read = now.addingTimeInterval(-120)
        switch agent {
        case .claude:
            return [AgentLimitWindow(agent: .claude, key: "session", label: "Session", usedPercent: 38, resetsAt: now.addingTimeInterval(7_500),
                                     windowSeconds: 18_000, readAt: read),
                    AgentLimitWindow(agent: .claude, key: "weekly", label: "Weekly", usedPercent: 71, resetsAt: now.addingTimeInterval(273_600),
                                     windowSeconds: 604_800, readAt: read)]
        case .codex:
            return [AgentLimitWindow(agent: .codex, key: "session", label: "Session", usedPercent: 12, resetsAt: now.addingTimeInterval(14_000),
                                     windowSeconds: 18_000, readAt: read),
                    AgentLimitWindow(agent: .codex, key: "weekly", label: "Weekly", usedPercent: 83, resetsAt: now.addingTimeInterval(180_000),
                                     windowSeconds: 604_800, readAt: read)]
        }
    }

    private static let previewDays: [AgentSpendDay] = (0..<30).flatMap { ago -> [AgentSpendDay] in
        let scale = [3, 5, 2, 0, 6, 4, 7][ago % 7]
        return [AgentSpendDay(daysAgo: ago, agent: .claude,
                              models: ["claude-opus-5": AgentTokens(input: 900 * scale, cacheWrite1h: 40_000 * scale,
                                                                    cacheRead: 900_000 * scale, output: 30_000 * scale),
                                       "claude-haiku-4-5": AgentTokens(input: 2_000 * scale, cacheRead: 60_000 * scale, output: 4_000 * scale)]),
                AgentSpendDay(daysAgo: ago, agent: .codex,
                              models: ["gpt-6-astra": AgentTokens(input: 20_000 * scale, cacheRead: 200_000 * scale, output: 9_000 * scale)])]
    }
}

extension AgentTokens {
    init(_ tokens: TokenBreakdown) {
        self.init(input: tokens.input, cacheWrite5m: tokens.cacheWrite5m, cacheWrite1h: tokens.cacheWrite1h,
                  cacheRead: tokens.cacheRead, output: tokens.output)
    }
}
