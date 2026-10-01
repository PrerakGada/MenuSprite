import Combine
import IslandKit
import SwiftUI
import SystemMonitoring

/// Cards of live readings: by default CPU, GPU, memory, battery, network, disk, power and fans, and any
/// reading from MenuSprite's catalog once customised (Settings › Content › System). Samples through the
/// shared monitor only while the page is on screen, and only the readings its cards show; a card opens
/// the matching hub page.
@MainActor
final class SystemSection: IslandSection {
    let id = IslandSectionID.system
    private unowned let environment: IslandEnvironment
    let store: IslandSystemLayoutStore
    static let owner = "island.system"
    private var visible = false
    private var observation: AnyCancellable?

    init(environment: IslandEnvironment) {
        self.environment = environment
        store = IslandSystemLayoutStore(defaults: environment.isHeadless ? nil : .standard)
        observation = store.$layout.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.layoutChanged() } }
        }
    }

    var availability: IslandAvailability { .available }

    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight {
        .fixed(CGFloat(IslandSystemGrid.pageHeight(count: shownCards.count, width: Double(context.width))))
    }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(SystemPage(monitoring: environment.monitoring, store: store, context: context, open: { [weak environment] tab in
            environment?.showHubTab(tab)
        }))
    }

    func options() -> AnyView? { AnyView(SystemCardsEditor(store: store, monitoring: environment.monitoring)) }

    /// Cards whose reading this Mac can report: no battery card on a desktop, no fan card without fans.
    var shownCards: [IslandSystemCard] { SystemCardSupport.shown(store.layout.cards, in: environment.monitoring) }

    func pageDidAppear() {
        visible = true
        environment.monitoring.setSurfaceMetrics(Self.owner, store.layout.metricIDs.union(["battery.state"]), interval: 2)
    }

    func pageDidDisappear() {
        visible = false
        environment.monitoring.setSurfaceMetrics(Self.owner, [])
    }

    func islandDidStop() { pageDidDisappear() }

    private func layoutChanged() {
        if visible { pageDidAppear() }
        environment.invalidate()
    }
}

/// The System page's cards, saved under `MenuSprite.Island.System.cards`. Headless renders keep them
/// in memory only.
@MainActor
final class IslandSystemLayoutStore: ObservableObject {
    static let key = "MenuSprite.Island.System.cards"
    @Published private(set) var layout: IslandSystemLayout
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.key), let saved = try? JSONDecoder().decode(IslandSystemLayout.self, from: data) {
            layout = saved
        } else {
            layout = .standard
        }
    }

    func update(_ change: (inout IslandSystemLayout) -> Void) {
        var copy = layout
        change(&copy)
        guard copy != layout else { return }
        layout = copy
        if let data = try? JSONEncoder().encode(copy) { defaults?.set(data, forKey: Self.key) }
    }

    func reset() {
        layout = .standard
        defaults?.removeObject(forKey: Self.key)
    }
}

/// How a reading is drawn on a card: its symbol, the hub page it opens, and which cards this Mac can show.
enum SystemCardSupport {
    static let hasBattery: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { if service != 0 { IOObjectRelease(service) } }
        return service != 0
    }()

    @MainActor static func shown(_ cards: [IslandSystemCard], in monitoring: MonitoringStore) -> [IslandSystemCard] {
        cards.filter { card in
            if card.metricID.hasPrefix("battery.") { return hasBattery }
            if card.metricID.hasPrefix("sensor.fan") {
                // Fans only when the Mac reports them; unknown until the first sample, so keep it until then.
                guard let reading = monitoring.readings[card.metricID] else { return true }
                return reading.number != nil
            }
            return true
        }
    }

    static func symbol(for metric: Metric) -> String {
        let id = metric.id
        if id.hasPrefix("cpu.") { return "cpu" }
        if id.hasPrefix("gpu.") { return "display" }
        if id.hasPrefix("memory.") { return "memorychip" }
        if id.hasPrefix("battery.") { return metric.unit == .watts ? "powerplug" : "battery.100percent" }
        if id.hasPrefix("network.") { return "network" }
        if id.hasPrefix("disk.") { return "internaldrive" }
        if id.localizedCaseInsensitiveContains("fan") { return "fanblades" }
        if metric.unit == .celsius { return "thermometer.medium" }
        if metric.unit == .watts || metric.unit == .volts || metric.unit == .amps { return "powerplug" }
        return metric.group.icon
    }

    static func hubTab(for metric: Metric) -> HubTab {
        switch metric.group {
        case .network, .wifi: .network
        case .bluetooth: .system
        case .disk: .disk
        case .battery: .power
        case .ai: .ai
        case .sensors: metric.unit == .watts ? .power : .system
        case .cpu, .gpu, .memory, .system: .system
        }
    }

    /// Network rates carry their arrow ("↓ 3.0 MB/s"); every other value stands alone.
    static func arrow(for metric: Metric) -> String? {
        metric.shortName == "↓" || metric.shortName == "↑" ? metric.shortName : nil
    }
}

private struct SystemPage: View {
    @ObservedObject var monitoring: MonitoringStore
    @ObservedObject var store: IslandSystemLayoutStore
    let context: IslandPageContext
    let open: (HubTab) -> Void

    var body: some View {
        let cards = SystemCardSupport.shown(store.layout.cards, in: monitoring)
        let rows = IslandSystemGrid.rows(count: cards.count, width: Double(context.width))
        Group {
            if cards.isEmpty {
                IslandUnavailableView(symbol: "gauge.with.dots.needle.50percent",
                                      message: "No cards yet. Add readings in Settings › Content › System.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: CGFloat(IslandSystemGrid.spacing)) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, count in
                            let start = rows.prefix(index).reduce(0, +)
                            HStack(spacing: CGFloat(IslandSystemGrid.spacing)) {
                                ForEach(cards[start..<start + count]) { card in
                                    SystemCardView(card: card, monitoring: monitoring) {
                                        open(SystemCardSupport.hubTab(for: monitoring.metric(card.metricID)))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: context.width)
    }
}

private struct SystemCardView: View {
    let card: IslandSystemCard
    @ObservedObject var monitoring: MonitoringStore
    let action: () -> Void

    var body: some View {
        let metric = monitoring.metric(card.metricID)
        let secondLine = secondReading
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Label(card.title.isEmpty ? metric.name : card.title, systemImage: symbol(metric))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .lineLimit(1)
                Text(value(metric))
                    .font(.system(size: secondLine == nil ? 22 : 15, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.25), value: value(metric))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let secondLine {
                    Text(secondLine).font(.system(size: 11)).foregroundStyle(IslandStyle.secondaryText).lineLimit(1)
                } else if card.detail == .bar {
                    let percent = monitoring.readings[card.barMetricID]?.number
                    IslandMeter(value: percent.map { card.barFraction(percent: $0) } ?? 0,
                                tint: percent.map { card.barWantsAttention(percent: $0, onBattery: onBattery) } == true ? .orange : .white,
                                height: 4)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: CGFloat(IslandSystemGrid.height), maxHeight: CGFloat(IslandSystemGrid.height),
                   alignment: .leading)
            .background(RoundedRectangle(cornerRadius: IslandStyle.cardRadius, style: .continuous).fill(IslandStyle.surface))
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: IslandStyle.cardRadius))
        .help(metric.detail)
    }

    private var onBattery: Bool {
        monitoring.readings["battery.state"]?.text?.localizedCaseInsensitiveContains("battery") ?? false
    }

    private func symbol(_ metric: Metric) -> String {
        if metric.id == "battery.charge", monitoring.readings["battery.state"]?.text?.localizedCaseInsensitiveContains("charg") == true {
            return "battery.100percent.bolt"
        }
        return SystemCardSupport.symbol(for: metric)
    }

    private func value(_ metric: Metric) -> String {
        guard let reading = monitoring.readings[metric.id], reading.number != nil || reading.text != nil else { return "…" }
        if metric.unit == .percent, let number = reading.number { return "\(Int(number.rounded()))%" }
        let text = monitoring.display(metric.id)
        return SystemCardSupport.arrow(for: metric).map { "\($0) \(text)" } ?? text
    }

    private var secondReading: String? {
        guard card.detail == .reading, !card.detailMetricID.isEmpty else { return nil }
        let metric = monitoring.metric(card.detailMetricID)
        guard let reading = monitoring.readings[metric.id], reading.number != nil || reading.text != nil else { return nil }
        return "\(metric.shortName) \(monitoring.display(metric.id))"
    }
}
