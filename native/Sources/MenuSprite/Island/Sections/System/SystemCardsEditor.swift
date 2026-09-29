import IslandKit
import SwiftUI
import SystemMonitoring

/// Settings › Content › System: the page's cards in order. Each card picks any reading from the
/// catalog, an optional title, and what sits under the value (a bar or a second reading). Cards can be
/// added (up to twelve), removed, dragged into a new order, or reset to the original eight.
struct SystemCardsEditor: View {
    @ObservedObject var store: IslandSystemLayoutStore
    @ObservedObject var monitoring: MonitoringStore
    @State private var dragging: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each card shows one reading from MenuSprite's catalog. Drag to reorder.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(store.layout.cards) { card in
                SystemCardRow(card: card, store: store, monitoring: monitoring)
                    .opacity(dragging == card.id ? 0.45 : 1)
                    .onDrag {
                        dragging = card.id
                        return NSItemProvider(object: card.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: SystemCardReorder(target: card.id, dragging: $dragging, store: store))
            }
            HStack {
                ReadingMenu(monitoring: monitoring, selected: nil, accepts: { _ in true }) { metric in
                    store.update { $0.add(IslandSystemCard(metricID: metric.id, detail: metric.unit == .percent ? .bar : .none)) }
                } label: {
                    Label("Add card", systemImage: "plus")
                }
                .disabled(store.layout.isFull)
                .help(store.layout.isFull ? "The System page holds up to twelve cards." : "Add a card for any reading")
                Spacer()
                Button("Reset to default") { store.reset() }
                    .disabled(store.layout == .standard)
            }
        }
    }
}

private struct SystemCardRow: View {
    let card: IslandSystemCard
    let store: IslandSystemLayoutStore
    @ObservedObject var monitoring: MonitoringStore

    var body: some View {
        let metric = monitoring.metric(card.metricID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag to reorder")
                Image(systemName: SystemCardSupport.symbol(for: metric)).frame(width: 18).foregroundStyle(Color.accentColor)
                TextField(metric.name, text: Binding(get: { card.title }, set: { title in
                    var copy = card; copy.title = title; store.update { $0.update(copy) }
                }))
                .textFieldStyle(.roundedBorder)
                Button {
                    store.update { $0.remove(card.id) }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this card")
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Reading").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    ReadingMenu(monitoring: monitoring, selected: card.metricID, accepts: { _ in true }) { picked in
                        var copy = card
                        copy.metricID = picked.id
                        // A bar needs a percentage: a non-percentage reading keeps its bar only with its own source.
                        if copy.detail == .bar, copy.detailMetricID.isEmpty, picked.unit != .percent { copy.detail = .none }
                        store.update { $0.update(copy) }
                    } label: {
                        Text(metric.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                GridRow {
                    Text("Under it").foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { card.detail }, set: { detail in
                        var copy = card
                        copy.detail = detail
                        if detail == .bar, !copy.detailMetricID.isEmpty,
                           monitoring.metric(copy.detailMetricID).unit != .percent { copy.detailMetricID = "" }
                        if detail == .reading, copy.detailMetricID.isEmpty { copy.detailMetricID = card.metricID }
                        store.update { $0.update(copy) }
                    })) {
                        ForEach(IslandSystemCardDetail.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                detailRows(metric)
            }
            .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            Button("Move up") { move(by: -1) }
            Button("Move down") { move(by: 1) }
        }
    }

    @ViewBuilder private func detailRows(_ metric: Metric) -> some View {
        switch card.detail {
        case .none:
            EmptyView()
        case .bar:
            let source = card.detailMetricID.isEmpty ? nil : monitoring.metric(card.detailMetricID)
            GridRow {
                Text("Bar from").foregroundStyle(.secondary)
                ReadingMenu(monitoring: monitoring, selected: card.barMetricID, accepts: { $0.unit == .percent },
                            leading: metric.unit == .percent ? "This card's reading" : nil) { picked in
                    var copy = card
                    copy.detailMetricID = picked?.id == card.metricID ? "" : (picked?.id ?? "")
                    store.update { $0.update(copy) }
                } label: {
                    Text(source?.name ?? (metric.unit == .percent ? "This card's reading" : "Choose a percentage…"))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Fill with what's left", isOn: Binding(get: { card.barShowsRemainder }, set: { value in
                    var copy = card; copy.barShowsRemainder = value; store.update { $0.update(copy) }
                }))
                .toggleStyle(.checkbox)
                .help("Fill the bar with 100 minus the reading, like free disk space")
            }
        case .reading:
            GridRow {
                Text("Second").foregroundStyle(.secondary)
                ReadingMenu(monitoring: monitoring, selected: card.detailMetricID, accepts: { _ in true }) { picked in
                    var copy = card; copy.detailMetricID = picked.id; store.update { $0.update(copy) }
                } label: {
                    Text(card.detailMetricID.isEmpty ? "Choose a reading…" : monitoring.metric(card.detailMetricID).name)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private func move(by offset: Int) {
        guard let index = store.layout.cards.firstIndex(where: { $0.id == card.id }) else { return }
        let target = index + offset
        guard store.layout.cards.indices.contains(target) else { return }
        store.update { $0.move(card.id, to: offset > 0 ? target + 1 : target) }
    }
}

private struct SystemCardReorder: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let store: IslandSystemLayoutStore

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        MainActor.assumeIsolated {
            guard let to = store.layout.cards.firstIndex(where: { $0.id == target }),
                  let from = store.layout.cards.firstIndex(where: { $0.id == dragging }) else { return }
            store.update { $0.move(dragging, to: to > from ? to + 1 : to) }
        }
    }

    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

/// A menu of the catalog's readings, one submenu per category, the detailed readings (cores, interfaces,
/// firmware keys) folded into "More". `leading` adds a first item that picks nil.
private struct ReadingMenu<MenuLabel: View>: View {
    @ObservedObject var monitoring: MonitoringStore
    let selected: String?
    let accepts: (Metric) -> Bool
    var leading: String?
    let pick: (Metric?) -> Void
    @ViewBuilder let label: () -> MenuLabel

    init(monitoring: MonitoringStore, selected: String?, accepts: @escaping (Metric) -> Bool, leading: String? = nil,
         pick: @escaping (Metric?) -> Void, @ViewBuilder label: @escaping () -> MenuLabel) {
        self.monitoring = monitoring
        self.selected = selected
        self.accepts = accepts
        self.leading = leading
        self.pick = pick
        self.label = label
    }

    init(monitoring: MonitoringStore, selected: String?, accepts: @escaping (Metric) -> Bool,
         pick: @escaping (Metric) -> Void, @ViewBuilder label: @escaping () -> MenuLabel) {
        self.init(monitoring: monitoring, selected: selected, accepts: accepts, leading: nil,
                  pick: { if let metric = $0 { pick(metric) } }, label: label)
    }

    var body: some View {
        let byGroup = Dictionary(grouping: monitoring.catalog.filter(accepts), by: \.group)
        Menu {
            if let leading {
                Button(leading) { pick(nil) }
                Divider()
            }
            ForEach(MetricGroup.allCases.filter { byGroup[$0] != nil }, id: \.self) { group in
                let rows = byGroup[group] ?? []
                Menu(group.rawValue) {
                    ForEach(rows.filter { !$0.advanced }) { item($0) }
                    let detailed = rows.filter(\.advanced)
                    if !detailed.isEmpty {
                        Divider()
                        Menu("More") { ForEach(detailed) { item($0) } }
                    }
                }
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func item(_ metric: Metric) -> some View {
        Button {
            pick(metric)
        } label: {
            if metric.id == selected { Label(metric.name, systemImage: "checkmark") } else { Text(metric.name) }
        }
    }
}
