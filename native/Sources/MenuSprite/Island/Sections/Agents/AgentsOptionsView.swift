import IslandKit
import SwiftUI

/// Settings › Content › AI Agents: which agents, which cards, how limits read, the live activity and
/// the alerts.
struct AgentsOptionsView: View {
    @ObservedObject var store: AgentsOptionsStore
    let found: Set<AgentKind>
    let spendEnabled: Bool
    let openAccounts: () -> Void
    @State private var dragging: AgentCard?

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 8)]

    var body: some View {
        let options = store.value
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 8) {
                ForEach(AgentKind.allCases) { agentRow($0, options) }
            }

            Text("Cards").font(.headline)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(options.cardOrder) { card in
                    IslandOptionCard(title: card.title, symbol: card.symbol, included: !options.hiddenCards.contains(card),
                                     availability: availability(card)) {
                        store.update { value in
                            if value.hiddenCards.contains(card) { value.hiddenCards.remove(card) } else { value.hiddenCards.insert(card) }
                        }
                    }
                    .opacity(dragging == card ? 0.45 : 1)
                    .onDrag {
                        dragging = card
                        return NSItemProvider(object: card.rawValue as NSString)
                    }
                    .onDrop(of: [.text], delegate: AgentCardReorder(target: card, dragging: $dragging, store: store))
                }
            }
            Text("Drag to reorder. Charts take the full width of the island.").font(.caption).foregroundStyle(.secondary)

            Picker("Show limits as", selection: binding(\.limitDisplay)) {
                ForEach(AgentLimitDisplay.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Text("While an agent works").font(.headline)
            Toggle("Show it in the closed Dynamic Island", isOn: binding(\.liveActivity))
            HStack(spacing: 12) {
                Picker("Beside the camera", selection: binding(\.reading)) {
                    ForEach(AgentReading.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                AgentReadingSample(reading: options.reading, agents: options.isOn(.claude) ? [.claude] : [.codex])
            }
            .disabled(!options.liveActivity)

            Text("Alerts").font(.headline)
            Toggle("When a task finishes", isOn: binding(\.finishNotice))
            Picker("For tasks longer than", selection: binding(\.finishMinimum)) {
                ForEach(AgentOptions.finishMinimums, id: \.self) { Text(Self.minimumTitle($0)).tag($0) }
            }
            .fixedSize()
            .disabled(!options.finishNotice)
            Toggle("Near a plan limit", isOn: binding(\.limitWarning))
            Picker("Warn at", selection: binding(\.warnAt)) {
                ForEach(AgentOptions.warnThresholds, id: \.self) { Text("\(Int($0))% used").tag($0) }
            }
            .fixedSize()
            .disabled(!options.limitWarning)
            Toggle("Also when a warned limit renews", isOn: binding(\.renewalNotice))
                .disabled(!options.limitWarning)

            Text("Where this comes from").font(.headline)
            Text("Limits are the figures Claude's and Codex's own usage services report for the logins on this Mac, fetched at most every five minutes and shared with the menu bar. Working sessions come from Claude Code's session list and the ends of the logs being written. Prompts, replies and files are never kept, and nothing is sent anywhere.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(spendEnabled
                     ? "Costs come from AI Accounts' estimated spend. The island reads what it last worked out and never starts a new pass."
                     : "Estimated spend is off, so Spending, Trend and Models stay empty. Turn it on in AI Accounts.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Open AI Accounts", action: openAccounts).controlSize(.small)
            }
        }
    }

    private func agentRow(_ agent: AgentKind, _ options: AgentOptions) -> some View {
        HStack(spacing: 10) {
            Image(systemName: agent.symbol).foregroundStyle(agent.color).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.productName)
                Text(found.contains(agent) ? "Found on this Mac" : "Not found on this Mac").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(agent.productName, isOn: Binding(get: { options.isOn(agent) },
                                                    set: { on in store.update { $0.setAgent(agent, on) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                // The last agent left on stays on.
                .disabled(options.isOn(agent) && options.agents.count == 1)
        }
    }

    private func availability(_ card: AgentCard) -> IslandAvailability {
        switch card {
        case .projects: .unavailable("Needs per-project history, which the spend estimate does not keep.")
        case .activity: .unavailable("Needs 13 weeks of history; the spend estimate keeps 35 days.")
        default: .available
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<AgentOptions, Value>) -> Binding<Value> {
        Binding(get: { store.value[keyPath: key] }, set: { value in store.update { $0[keyPath: key] = value } })
    }

    static func minimumTitle(_ seconds: Double) -> String {
        switch seconds {
        case 0: "Any length"
        case ..<60: "\(Int(seconds)) s"
        default: "\(Int(seconds / 60)) min"
        }
    }
}

/// A miniature closed island with an example reading, so the choice is seen, not described.
private struct AgentReadingSample: View {
    let reading: AgentReading
    let agents: [AgentKind]

    var body: some View {
        let agent = agents.first ?? .claude
        HStack(spacing: 0) {
            Image(systemName: agent.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(agent.color)
                .frame(width: 58, alignment: .leading)
                .padding(.leading, 10)
            Color.clear.frame(width: 44)
            Text(example)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(agent.color)
                .frame(width: 58, alignment: .trailing)
                .padding(.trailing, 10)
        }
        .frame(height: 24)
        .background(IslandShape().fill(Color.black))
        .accessibilityLabel("Example: \(example)")
    }

    private var example: String {
        switch reading {
        case .time: "12:34"
        case .tokens: "20K"
        case .cost: "$4.56"
        case .limit: "62%"
        }
    }
}

private struct AgentCardReorder: DropDelegate {
    let target: AgentCard
    @Binding var dragging: AgentCard?
    let store: AgentsOptionsStore

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        MainActor.assumeIsolated {
            store.update { value in
                var order = value.cardOrder
                guard let from = order.firstIndex(of: dragging), let to = order.firstIndex(of: target) else { return }
                order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                value.cardOrder = order
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}
