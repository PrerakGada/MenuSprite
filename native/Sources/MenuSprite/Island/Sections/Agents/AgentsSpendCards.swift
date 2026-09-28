import IslandKit
import SwiftUI

/// Today, 7 days or 30 days as three small capsules: a direct choice, with no menu to hold the island
/// open for.
struct AgentPeriodPicker: View {
    let period: AgentPeriod
    let choose: (AgentPeriod) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(AgentPeriod.allCases) { option in
                Button { choose(option) } label: {
                    Text(option == .today ? "Today" : (option == .week ? "7d" : "30d"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(option == period ? Color.black : Color.white.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(option == period ? Color.white.opacity(0.9) : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(option.title)
            }
        }
    }
}

/// The period's API value, split by agent, with its tokens and cache share.
struct AgentSpendingCard: View {
    let state: AgentSpendState
    let period: AgentPeriod
    let agents: Set<AgentKind>
    let actions: AgentsPageActions
    let now: Date

    var body: some View {
        AgentCardFrame {
            AgentCardTitle(symbol: "dollarsign.circle", title: "Spending")
        } accessory: {
            AgentPeriodPicker(period: period, choose: actions.setPeriod)
        } content: {
            switch state {
            case .off:
                AgentSpendOff(openAccounts: actions.openAccounts)
            case .waiting:
                AgentCardMessage(title: "Estimating…", detail: "AI Accounts is reading the logs for the first time.")
            case .ready(let days, let scannedAt):
                let summary = AgentSpendSummary.make(days: days, period: period, agents: agents, price: AgentActivityService.price)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text((summary.hasUnpriced ? "≥ " : "") + AgentFormat.cost(summary.dollars))
                            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("API value").font(.system(size: 10, weight: .medium)).foregroundStyle(IslandStyle.secondaryText)
                    }
                    AgentSplitBar(shares: Dictionary(uniqueKeysWithValues: agents.map { agent in
                        (agent, summary.hasUnpriced ? Double(summary.tokensByAgent[agent] ?? 0) : summary.dollarsByAgent[agent] ?? 0)
                    }))
                    Text("\(AgentFormat.tokens(summary.tokens)) tokens · \(Int((summary.cacheShare * 100).rounded()))% from cache")
                        .font(.system(size: 10)).foregroundStyle(IslandStyle.secondaryText).lineLimit(1)
                }
                .help(tooltip(summary, scannedAt: scannedAt))
            }
        }
    }

    private func tooltip(_ summary: AgentSpendSummary, scannedAt: Date) -> String {
        let meaning = summary.hasUnpriced
            ? "Some models have no known price, so this is a minimum."
            : "API value is what the same work would cost at API list prices. Plans charge a fixed price instead."
        return meaning + "\nEstimated from this Mac's logs by AI Accounts, updated " + AgentFormat.ago(now.timeIntervalSince(scannedAt)).lowercased() + "."
    }
}

/// A 4-pt bar sharing its width between agents, each visible agent keeping at least a 4-pt sliver.
struct AgentSplitBar: View {
    let shares: [AgentKind: Double]

    var body: some View {
        GeometryReader { proxy in
            let visible = AgentKind.allCases.filter { (shares[$0] ?? 0) > 0 }
            let total = visible.reduce(0) { $0 + (shares[$1] ?? 0) }
            let spacing: CGFloat = 1
            let room = max(0, proxy.size.width - spacing * CGFloat(max(0, visible.count - 1)) - 4 * CGFloat(visible.count))
            HStack(spacing: spacing) {
                if visible.isEmpty { Capsule().fill(Color.white.opacity(0.14)) }
                ForEach(visible) { agent in
                    Capsule().fill(agent.color).frame(width: 4 + room * CGFloat(total > 0 ? (shares[agent] ?? 0) / total : 0))
                }
            }
        }
        .frame(height: 4)
    }
}

/// The spend cards when estimates are off.
struct AgentSpendOff: View {
    let openAccounts: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Estimated spend is off").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            Button("Turn it on in AI Accounts", action: openAccounts)
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Daily bars split by agent: 7 days (Today and 7 days) or 30.
struct AgentTrendCard: View {
    let state: AgentSpendState
    let period: AgentPeriod
    let agents: Set<AgentKind>
    let actions: AgentsPageActions
    @State private var hovered: Int?

    var body: some View {
        let summary = self.summary
        AgentCardFrame {
            AgentCardTitle(symbol: "chart.bar", title: "Trend")
        } accessory: {
            if let summary {
                Text(accessory(summary)).font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(IslandStyle.secondaryText).lineLimit(1)
            }
        } content: {
            if let summary {
                chart(summary)
            } else if state == .off {
                AgentSpendOff(openAccounts: actions.openAccounts)
            } else {
                AgentCardMessage(title: "Estimating…")
            }
        }
    }

    private var summary: AgentSpendSummary? {
        guard case .ready(let days, _) = state else { return nil }
        return AgentSpendSummary.make(days: days, period: period, agents: agents, price: AgentActivityService.price)
    }

    private func chart(_ summary: AgentSpendSummary) -> some View {
        let count = summary.bars.count
        let totals = summary.bars.map { $0.values.reduce(0, +) }
        let peak = max(totals.max() ?? 0, .leastNonzeroMagnitude)
        let order = AgentKind.allCases.filter(agents.contains).reversed()
        return VStack(spacing: 3) {
            GeometryReader { proxy in
                let gap: CGFloat = count <= 24 ? 4 : 2
                let width = max(1, (proxy.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(0..<count, id: \.self) { index in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            if totals[index] <= 0 {
                                Capsule().fill(Color.white.opacity(0.12)).frame(height: 2)
                            } else {
                                ForEach(Array(order), id: \.self) { agent in
                                    Rectangle().fill(agent.color)
                                        .frame(height: proxy.size.height * CGFloat((summary.bars[index][agent] ?? 0) / peak))
                                }
                            }
                        }
                        .frame(width: width)
                        .clipShape(RoundedRectangle(cornerRadius: min(2, width / 2), style: .continuous))
                        .opacity(hovered == nil || hovered == index ? 1 : 0.35)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = min(count - 1, max(0, Int(point.x / (width + gap))))
                    case .ended: hovered = nil
                    }
                }
            }
            axis(count: count)
        }
    }

    private func axis(count: Int) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func day(_ index: Int) -> Date { calendar.date(byAdding: .day, value: index - (count - 1), to: today) ?? today }
        return HStack(spacing: 0) {
            if count <= 7 {
                ForEach(0..<count, id: \.self) { index in
                    Text(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: day(index)) - 1])
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text(day(0).formatted(.dateTime.month(.abbreviated).day()))
                Spacer(minLength: 0)
                Text(day(count / 2).formatted(.dateTime.month(.abbreviated).day()))
                Spacer(minLength: 0)
                Text("Today")
            }
        }
        .font(.system(size: 8.5, weight: .medium))
        .foregroundStyle(IslandStyle.tertiaryText)
        .frame(height: 10)
    }

    private func accessory(_ summary: AgentSpendSummary) -> String {
        let count = summary.bars.count
        func value(_ amount: Double) -> String {
            summary.barsAreDollars ? AgentFormat.cost(amount) : AgentFormat.tokens(Int(amount)) + " tokens"
        }
        if let hovered, summary.bars.indices.contains(hovered) {
            let date = Calendar.current.date(byAdding: .day, value: hovered - (count - 1), to: Date()) ?? Date()
            let label = hovered == count - 1 ? "Today" : date.formatted(.dateTime.weekday(.abbreviated).day())
            return label + " · " + value(summary.bars[hovered].values.reduce(0, +))
        }
        let total = summary.bars.reduce(0) { $0 + $1.values.reduce(0, +) }
        return (count == 30 ? "30 days" : "7 days") + " · " + value(total)
    }
}

/// The period's top three models, bars scaled to the first.
struct AgentModelsCard: View {
    let state: AgentSpendState
    let period: AgentPeriod
    let agents: Set<AgentKind>
    let actions: AgentsPageActions

    var body: some View {
        AgentCardFrame {
            AgentCardTitle(symbol: "cpu", title: "Models")
        } accessory: {
            Text(period.title).font(.system(size: 9.5, weight: .medium)).foregroundStyle(IslandStyle.secondaryText)
        } content: {
            switch state {
            case .off:
                AgentSpendOff(openAccounts: actions.openAccounts)
            case .waiting:
                AgentCardMessage(title: "Estimating…")
            case .ready(let days, _):
                let summary = AgentSpendSummary.make(days: days, period: period, agents: agents, price: AgentActivityService.price)
                if summary.models.isEmpty {
                    AgentCardMessage(title: "Nothing in this period")
                } else {
                    let top = max(summary.models.first?.value ?? 1, .leastNonzeroMagnitude)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.models) { model in
                            HStack(spacing: 6) {
                                Text(model.name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                                Spacer(minLength: 4)
                                Capsule().fill(model.agent.color).frame(width: max(3, 44 * CGFloat(model.value / top)), height: 4)
                                Text(summary.hasUnpriced ? AgentFormat.tokens(Int(model.value)) : AgentFormat.cost(model.value))
                                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                                    .foregroundStyle(IslandStyle.secondaryText)
                                    .frame(minWidth: 36, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }
}
