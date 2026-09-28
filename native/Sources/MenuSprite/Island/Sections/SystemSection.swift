import IslandKit
import SwiftUI
import SystemMonitoring

/// CPU, GPU, memory, battery, network, disk, power and fans as cards. Samples through the shared
/// monitor only while the page is on screen; a card opens the matching hub page.
@MainActor
final class SystemSection: IslandSection {
    let id = IslandSectionID.system
    private unowned let environment: IslandEnvironment
    static let owner = "island.system"

    init(environment: IslandEnvironment) { self.environment = environment }

    var availability: IslandAvailability { .available }

    static let metricIDs: Set<String> = ["cpu.usage", "gpu.usage", "memory.usage", "memory.used", "memory.total",
                                         "battery.charge", "battery.state", "network.download", "network.upload",
                                         "disk.available", "disk.usage", "sensor.PSTR", "battery.adapterRated", "sensor.fanSpeed"]

    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight {
        let cards = SystemCard.available(in: environment.monitoring)
        return .fixed(SystemGrid.height(count: cards.count, width: context.width))
    }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(SystemPage(monitoring: environment.monitoring, context: context, open: { [weak environment] tab in
            environment?.showHubTab(tab)
        }))
    }

    func pageDidAppear() { environment.monitoring.setSurfaceMetrics(Self.owner, Self.metricIDs, interval: 2) }
    func pageDidDisappear() { environment.monitoring.setSurfaceMetrics(Self.owner, []) }
    func islandDidStop() { pageDidDisappear() }
}

enum SystemCard: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, battery, network, disk, power, fans
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .battery: "Battery"
        case .network: "Network"
        case .disk: "Disk available"
        case .power: "Power"
        case .fans: "Fans"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "display"
        case .memory: "memorychip"
        case .battery: "battery.100percent"
        case .network: "network"
        case .disk: "internaldrive"
        case .power: "powerplug"
        case .fans: "fanblades"
        }
    }

    var hubTab: HubTab {
        switch self {
        case .cpu, .gpu, .memory, .fans: .system
        case .battery, .power: .power
        case .network: .network
        case .disk: .disk
        }
    }

    /// Cards only for readings this Mac reports: battery only with a battery, fans only with fans.
    @MainActor static func available(in monitoring: MonitoringStore) -> [SystemCard] {
        allCases.filter { card in
            switch card {
            case .battery: monitoring.readings["battery.charge"]?.number != nil || monitoring.readings["battery.charge"] == nil && hasBattery
            case .fans: monitoring.readings["sensor.fanSpeed"]?.number != nil
            default: true
            }
        }
    }

    static let hasBattery: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { if service != 0 { IOObjectRelease(service) } }
        return service != 0
    }()
}

enum SystemGrid {
    static let minWidth: CGFloat = 128
    static let height: CGFloat = 72
    static let spacing: CGFloat = 10

    static func columns(width: CGFloat) -> Int { max(1, Int((width + spacing) / (minWidth + spacing))) }

    /// Balanced rows in reading order: 8 cards in 3 columns → 3, 3, 2.
    static func rows(count: Int, width: CGFloat) -> [Int] {
        guard count > 0 else { return [] }
        let columns = columns(width: width)
        let rowCount = Int(ceil(Double(count) / Double(columns)))
        let base = count / rowCount, extra = count % rowCount
        return (0..<rowCount).map { $0 < extra ? base + 1 : base }
    }

    static func height(count: Int, width: CGFloat) -> CGFloat {
        let rows = rows(count: count, width: width).count
        return rows == 0 ? 140 : CGFloat(rows) * height + CGFloat(rows - 1) * spacing
    }
}

private struct SystemPage: View {
    @ObservedObject var monitoring: MonitoringStore
    let context: IslandPageContext
    let open: (HubTab) -> Void

    var body: some View {
        let cards = SystemCard.available(in: monitoring)
        let rows = SystemGrid.rows(count: cards.count, width: context.width)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: SystemGrid.spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, count in
                    let start = rows.prefix(index).reduce(0, +)
                    HStack(spacing: SystemGrid.spacing) {
                        ForEach(cards[start..<start + count]) { card in
                            SystemCardView(card: card, monitoring: monitoring) { open(card.hubTab) }
                        }
                    }
                }
            }
        }
        .frame(width: context.width)
    }
}

private struct SystemCardView: View {
    let card: SystemCard
    @ObservedObject var monitoring: MonitoringStore
    let action: () -> Void

    var body: some View {
        let reading = content
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Label(card.title, systemImage: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IslandStyle.secondaryText)
                Text(reading.value)
                    .font(.system(size: reading.detail == nil ? 22 : 15, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.25), value: reading.value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let detail = reading.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(IslandStyle.secondaryText).lineLimit(1)
                } else if let meter = reading.meter {
                    IslandMeter(value: meter, tint: reading.attention ? .orange : .white, height: 4)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: SystemGrid.height, maxHeight: SystemGrid.height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: IslandStyle.cardRadius, style: .continuous).fill(IslandStyle.surface))
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: IslandStyle.cardRadius))
    }

    private var symbol: String {
        if card == .battery, monitoring.readings["battery.state"]?.text?.localizedCaseInsensitiveContains("charg") == true {
            return "battery.100percent.bolt"
        }
        return card.symbol
    }

    private func value(_ id: String) -> Double? { monitoring.readings[id]?.number }

    private var content: (value: String, detail: String?, meter: Double?, attention: Bool) {
        func percent(_ id: String) -> (String, Double?) {
            guard let v = value(id) else { return ("…", nil) }
            return ("\(Int(v.rounded()))%", v / 100)
        }
        switch card {
        case .cpu, .gpu, .memory:
            let id = card == .cpu ? "cpu.usage" : (card == .gpu ? "gpu.usage" : "memory.usage")
            let (text, fraction) = percent(id)
            return (text, nil, fraction ?? 0, (fraction ?? 0) >= 0.85)
        case .battery:
            let (text, fraction) = percent("battery.charge")
            let onAC = monitoring.readings["battery.state"]?.text.map { !$0.localizedCaseInsensitiveContains("battery") } ?? false
            return (text, nil, fraction ?? 0, (fraction ?? 1) <= 0.2 && !onAC)
        case .network:
            return ("↓ " + monitoring.display("network.download", compact: true), "↑ " + monitoring.display("network.upload", compact: true), nil, false)
        case .disk:
            let free = value("disk.usage").map { 1 - $0 / 100 }
            return (value("disk.available") == nil ? "…" : monitoring.display("disk.available"), nil, free ?? 0, (free ?? 1) < 0.1)
        case .power:
            let detail = value("battery.adapterRated").map { "Adapter \(Int($0.rounded())) W" }
            return (value("sensor.PSTR") == nil ? "…" : monitoring.display("sensor.PSTR"), detail, nil, false)
        case .fans:
            return (value("sensor.fanSpeed") == nil ? "…" : monitoring.display("sensor.fanSpeed"), nil, nil, false)
        }
    }
}
