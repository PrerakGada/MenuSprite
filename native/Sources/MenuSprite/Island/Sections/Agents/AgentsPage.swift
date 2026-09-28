import IslandKit
import SwiftUI

/// One card on the AI Agents page. The limits card repeats for each agent.
enum AgentTile: Hashable, Identifiable {
    case limits(AgentKind), spending, now, trend, models

    var id: String {
        switch self {
        case .limits(let agent): "limits." + agent.rawValue
        case .spending: "spending"
        case .now: "now"
        case .trend: "trend"
        case .models: "models"
        }
    }

    var isChart: Bool { self == .trend }
}

/// Which cards the page shows and how they are arranged, shared by the page and its height.
@MainActor
struct AgentsLayout {
    enum State: Equatable {
        /// The section is off: the settings preview shows what it would do.
        case off
        case reading
        /// Neither agent has left anything on this Mac.
        case empty
        /// Every card is hidden.
        case nothingChosen
        case cards
    }

    static let messageHeight: CGFloat = 120

    var state: State
    var tiles: [AgentTile]
    var rows: [[Int]]
    var height: CGFloat

    /// Projects and the 13-week Activity map need history MenuSprite's spend estimate does not keep.
    static let unbuilt: Set<AgentCard> = [.projects, .activity]

    init(options: AgentOptions, activity: AgentActivityService, limits: AgentLimitsModel, found: Set<AgentKind>,
         sectionOn: Bool, width: CGFloat) {
        let seen = Self.seen(options: options, activity: activity.snapshot, limits: limits, found: found)
        tiles = options.visibleCards.flatMap { card -> [AgentTile] in
            switch card {
            case .limits: AgentKind.allCases.filter(seen.contains).map(AgentTile.limits)
            case .spending: [.spending]
            case .now: [.now]
            case .trend: [.trend]
            case .models: [.models]
            case .projects, .activity: []
            }
        }
        if !sectionOn { state = .off }
        else if activity.isRunning && !activity.snapshot.loaded { state = .reading }
        else if seen.isEmpty { state = .empty }
        else if tiles.isEmpty { state = .nothingChosen }
        else { state = .cards }
        let charts = tiles.map(\.isChart)
        rows = state == .cards ? AgentGrid.rows(charts: charts, width: width) : []
        height = state == .cards ? AgentGrid.height(rows: rows, charts: charts) : Self.messageHeight
    }

    /// Agents switched on that have left something on this Mac: logs, a session, or a limit reading.
    static func seen(options: AgentOptions, activity: AgentActivitySnapshot, limits: AgentLimitsModel, found: Set<AgentKind>) -> Set<AgentKind> {
        let withLimits = Set(limits.windows.map(\.agent))
        return found.union(activity.seen).union(withLimits).filter(options.isOn)
    }
}

/// What the page's buttons do.
struct AgentsPageActions {
    var openAccounts: () -> Void
    var setPeriod: (AgentPeriod) -> Void
}

struct AgentsPage: View {
    @ObservedObject var activity: AgentActivityService
    @ObservedObject var limits: AgentLimitsModel
    @ObservedObject var options: AgentsOptionsStore
    let found: Set<AgentKind>
    let sectionOn: Bool
    let context: IslandPageContext
    let actions: AgentsPageActions

    var body: some View {
        let layout = AgentsLayout(options: options.value, activity: activity, limits: limits, found: found,
                                  sectionOn: sectionOn, width: context.width)
        Group {
            switch layout.state {
            case .off:
                IslandUnavailableView(symbol: "sparkles", message: "Claude Code and Codex usage, limits and costs.")
            case .reading:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading usage…").font(.system(size: 12, weight: .medium)).foregroundStyle(IslandStyle.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                IslandUnavailableView(symbol: "sparkles",
                                      message: "No usage from Claude Code or Codex yet. It appears here as soon as either one works on this Mac.")
            case .nothingChosen:
                IslandUnavailableView(symbol: "sparkles", message: "Choose what this page shows in Dynamic Island settings.")
            case .cards:
                grid(layout)
            }
        }
        .frame(width: context.width, height: min(layout.height, context.budget), alignment: .top)
    }

    private func grid(_ layout: AgentsLayout) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: AgentGrid.spacing) {
                    ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: AgentGrid.spacing) {
                            ForEach(row, id: \.self) { index in card(layout.tiles[index], now: timeline.date) }
                        }
                        .frame(height: row.contains { layout.tiles[$0].isChart } ? AgentGrid.chartRowHeight : AgentGrid.rowHeight)
                    }
                }
            }
            .scrollDisabled(layout.height <= context.budget)
        }
    }

    @ViewBuilder private func card(_ tile: AgentTile, now: Date) -> some View {
        let value = options.value
        switch tile {
        case .limits(let agent):
            AgentLimitsCard(agent: agent, windows: limits.windows, status: limits.status[agent], display: value.limitDisplay,
                            working: activity.snapshot.workingAgents.contains(agent), following: limits.isRunning, now: now)
        case .now:
            AgentNowCard(snapshot: activity.snapshot, agents: AgentKind.allCases.filter {
                value.isOn($0) && AgentsLayout.seen(options: value, activity: activity.snapshot, limits: limits, found: found).contains($0)
            }, now: now)
        case .spending:
            AgentSpendingCard(state: limits.spend, period: value.period, agents: value.agents, actions: actions, now: now)
        case .trend:
            AgentTrendCard(state: limits.spend, period: value.period, agents: value.agents, actions: actions)
        case .models:
            AgentModelsCard(state: limits.spend, period: value.period, agents: value.agents, actions: actions)
        }
    }
}

/// A page card: 12/10 padding, the island's surface, and a 17-pt header of a symbol or mark, a
/// title and an accessory at the right.
struct AgentCardFrame<Header: View, Accessory: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                header
                Spacer(minLength: 4)
                accessory
            }
            .frame(height: 17)
            // Exactly the room left under the header: a busy card clips rather than growing past its row.
            content.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading).clipped()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: IslandStyle.cardRadius, style: .continuous).fill(IslandStyle.surface))
    }
}

/// A card title: a symbol in a tint and the name at 90% white.
struct AgentCardTitle: View {
    var symbol: String
    var title: String
    var tint: Color = .white.opacity(0.75)
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
        }
    }
}

/// A small tinted capsule: plan names, "+2".
struct AgentChip: View {
    var text: String
    var tint: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

/// A calm one- or two-line message inside a card.
struct AgentCardMessage: View {
    var title: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(IslandStyle.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
