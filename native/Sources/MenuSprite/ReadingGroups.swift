import SwiftUI
import SystemMonitoring

extension MetricGroup {
    /// The readings a collapsed category card shows in its header. Only these are sampled while it is closed.
    var headlineIDs: [String] {
        switch self {
        case .cpu: ["cpu.usage", "cpu.load1"]
        case .memory: ["memory.usage", "memory.pressure"]
        case .network: ["network.upload", "network.download"]
        case .disk: ["disk.usage", "disk.available"]
        case .gpu: ["gpu.usage"]
        case .battery: ["battery.charge", "battery.state"]
        case .system: ["system.thermal", "system.uptime"]
        case .sensors: ["sensor.PSTR", "sensor.cpuTemperature", "sensor.fanSpeed"]
        case .ai: ["ai.claude.session", "ai.claude.weekly", "ai.codex.weekly"]
        case .wifi: ["wifi.state", "wifi.signal"]
        case .bluetooth: ["bluetooth.state", "bluetooth.audioBattery"]
        }
    }
}

/// The reading catalog as one collapsible card per category: the headline figure while closed,
/// the everyday readings when opened, and the detailed ones (cores, interfaces, firmware keys)
/// folded into a "More" section inside the same card. Shared by the library and the sprite editor.
struct ReadingGroupList<Accessory: View>: View {
    @ObservedObject var store: MonitoringStore
    let search: String
    @Binding var expanded: Set<MetricGroup>
    @ViewBuilder let accessory: (Metric) -> Accessory
    @State private var openMore: Set<String> = []

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    private func matches(_ metric: Metric) -> Bool {
        !searching || "\(metric.name) \(metric.id) \(metric.group.rawValue)".localizedStandardContains(search)
    }
    private func isOpen(_ group: MetricGroup) -> Bool { searching || expanded.contains(group) }

    var body: some View {
        let byGroup = Dictionary(grouping: store.catalog.filter(matches), by: \.group)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if byGroup.isEmpty {
                    ContentUnavailableView("No matching readings", systemImage: "magnifyingglass",
                                           description: Text("Search covers every reading, including cores, interfaces and firmware sensor keys."))
                        .frame(maxWidth: .infinity).padding(.vertical, 45)
                }
                ForEach(MetricGroup.allCases.filter { byGroup[$0] != nil }, id: \.self) { group in
                    let rows = byGroup[group] ?? []
                    header(group, count: rows.count).padding(.top, 8)
                    if isOpen(group) {
                        let primary = rows.filter { !$0.advanced }, detailed = rows.filter(\.advanced)
                        ForEach(primary) { row($0) }
                        if !detailed.isEmpty {
                            if searching { ForEach(detailed) { row($0) } }
                            else { more(group, detailed) }
                        }
                    }
                }
            }.padding(.horizontal, 16).padding(.bottom, 16)
        }
    }

    private func header(_ group: MetricGroup, count: Int) -> some View {
        let open = isOpen(group)
        let headline = group.headlineIDs.filter { id in store.catalog.contains { $0.id == id } }
        return Button {
            if expanded.contains(group) { expanded.remove(group) } else { expanded.insert(group) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10).foregroundStyle(.secondary)
                Image(systemName: group.icon).frame(width: 20)
                Text(group.rawValue).font(.system(size: 13, weight: .semibold))
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(headline.map { "\(store.metric($0).shortName) \(store.display($0))" }.joined(separator: "   "))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.35)))
        .onAppear { group.headlineIDs.forEach { store.visible($0, true) } }
        .onDisappear { group.headlineIDs.forEach { store.visible($0, false) } }
        .accessibilityIdentifier("reading-group-\(group.rawValue)")
    }

    /// Detailed readings stay folded. Large sets (firmware keys, interfaces) split by their name prefix,
    /// so "Temperature", "Power" or "en0" each open on their own instead of as one 600-row list.
    @ViewBuilder private func more(_ group: MetricGroup, _ rows: [Metric]) -> some View {
        let key = group.rawValue
        disclosure(key, title: "More \(group.rawValue) readings", count: rows.count, indent: 0)
        if openMore.contains(key) {
            let parts = Dictionary(grouping: rows, by: Self.family)
            if rows.count > 24 && parts.count > 1 {
                ForEach(parts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { family in
                    let subKey = key + "/" + family
                    disclosure(subKey, title: family, count: parts[family]?.count ?? 0, indent: 16)
                    if openMore.contains(subKey) { ForEach(parts[family] ?? []) { row($0, indent: 16) } }
                }
            } else {
                ForEach(rows) { row($0) }
            }
        }
    }

    private static func family(_ metric: Metric) -> String {
        if let range = metric.name.range(of: " · ") { return String(metric.name[..<range.lowerBound]) }
        return metric.unit == .rpm ? "Fans" : "Other"
    }

    private func disclosure(_ key: String, title: String, count: Int, indent: CGFloat) -> some View {
        Button {
            if openMore.contains(key) { openMore.remove(key) } else { openMore.insert(key) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(openMore.contains(key) ? 90 : 0)).frame(width: 9)
                Text(title).font(.system(size: 12, weight: .medium))
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .foregroundStyle(.secondary).padding(.leading, 30 + indent).padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func row(_ metric: Metric, indent: CGFloat = 0) -> some View {
        ReadingLine(metric: metric, store: store, indent: indent, accessory: accessory)
            .onAppear { store.visible(metric.id, true) }
            .onDisappear { store.visible(metric.id, false) }
    }
}

private struct ReadingLine<Accessory: View>: View {
    let metric: Metric
    @ObservedObject var store: MonitoringStore
    let indent: CGFloat
    let accessory: (Metric) -> Accessory
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(metric.name).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(store.display(metric.id)).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(store.readings[metric.id]?.available == true ? .primary : .secondary)
                .lineLimit(1).accessibilityIdentifier("reading-\(metric.id)")
            accessory(metric)
        }
        .padding(.leading, 30 + indent).padding(.trailing, 8).padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    private var tooltip: String {
        let sampled = store.readings[metric.id].map { "\nLast sampled \($0.measuredAt.formatted(date: .omitted, time: .standard))" } ?? ""
        return "\(metric.detail)\n\nSource: \(metric.source)\(sampled)"
    }
}
