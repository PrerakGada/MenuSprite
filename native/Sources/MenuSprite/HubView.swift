import AIAccounts
import AppKit
import SwiftUI
import SystemMonitoring

/// The hub's frame: brand header, the tab rail, the selected tab's body, and one footer. Each tab's
/// body is a separate view so switching tabs tears the previous one down, releasing its sampling.
struct HubView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var monitoring: MonitoringStore
    let power: PowerStore
    let accounts: AccountsStore
    let actions: HubActions
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            HubTabRail(model: model)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            Divider()
            body(for: model.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func body(for tab: HubTab) -> some View {
        switch tab {
        case .system: HubSystemSection(monitoring: monitoring)
        case .apps: HubAppsSection(model: model, monitoring: monitoring)
        case .network: HubNetworkSection(monitoring: monitoring)
        case .disk: HubDiskSection(monitoring: monitoring)
        case .power: HubPowerSection(model: model, monitoring: monitoring, power: power, actions: actions, close: close)
        case .ai: AccountsBoard(store: accounts, close: close, embedded: true).accessibilityIdentifier("hub-ai")
        case .sprites: HubSpritesSection(monitoring: monitoring, actions: actions, close: close)
        case .work: HubWorkSection(actions: actions, close: close)
        case .tools: HubToolsSection(monitoring: monitoring, power: power, actions: actions, close: close)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if let image = NSImage(named: "BrandIcon") ?? NSImage(named: "MenuBarIcon") {
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: .fit).frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel("MenuSprite")
            } else {
                Text("MenuSprite").font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 6) {
                if monitoring.isSampling {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .help("Shared sampling is active for this tab")
                }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh").accessibilityLabel("Refresh")
                    .accessibilityIdentifier("hub-refresh")
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close").accessibilityLabel("Close MenuSprite panel")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// Every full window, always in view: the hub is the one way into MenuSprite, so nothing may
    /// hide behind a secondary click or the bottom of a tab.
    private var footer: some View {
        HStack(spacing: 6) {
            footerButton("Sprites", "slider.horizontal.3", "Monitoring & Sprites", id: "hub-settings", actions.openSprites)
            footerButton(BuildFeatures.publicPreview ? "Awake" : "Controls", "bolt.badge.clock", BuildFeatures.powerPageTitle,
                         id: "hub-open-power-controls", actions.openPowerControls)
            footerButton("Island", "capsule.fill", "Dynamic Island settings", id: "hub-open-island", actions.openIsland)
            footerButton("Access", "lock.shield", "Permissions & Access", id: "hub-open-permissions", actions.openPermissions)
            footerButton("Quit", "power", "Quit MenuSprite", id: "hub-quit") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func footerButton(_ title: String, _ symbol: String, _ help: String, id: String,
                              _ action: @escaping () -> Void) -> some View {
        Button { if id != "hub-quit" { close() }; action() } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help).accessibilityIdentifier(id)
    }
}

private struct HubTabRail: View {
    @ObservedObject var model: HubModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HubTab.available) { tab in
                let selected = model.tab == tab
                Button { model.select(tab) } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("hub-tab-\(tab.rawValue)")
            }
        }
        .padding(4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.35)))
    }
}

// MARK: - Shared pieces

/// One titled card, the hub's only container. Sections differ in content, not in chrome.
struct HubCard<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack {
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.separator.opacity(0.35)))
    }
}

/// A label with its value on the right, the hub's standard statistic line.
struct HubStat: View {
    let label: String
    let value: String
    var emphasis: Bool = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: emphasis ? 13 : 11, weight: emphasis ? .semibold : .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// A percentage row: name, a proportional bar, the value, and the recent history beneath it.
struct HubMeter: View {
    let title: String
    let value: Double?
    let display: String
    let history: [HistoryPoint]
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 13, weight: .medium)).frame(width: 64, alignment: .leading)
                GeometryReader { geometry in
                    let fraction = min(1, max(0, (value ?? 0) / 100))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule().fill(tint).frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(height: 6)
                Text(display)
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }
            HubSparkline(points: history, percent: true)
                .stroke(tint, lineWidth: 1.4)
                .frame(height: 26)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(display)")
    }
}

struct HubSparkline: Shape {
    let points: [HistoryPoint]
    var percent: Bool = false
    func path(in rect: CGRect) -> Path {
        guard points.count > 1 else { return Path() }
        let values = points.map(\.value)
        let low = percent ? 0 : min(0, values.min() ?? 0)
        let high = percent ? 100 : max(low + 1, values.max() ?? 1)
        var path = Path()
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + Double(index) / Double(values.count - 1) * rect.width,
                                y: rect.maxY - min(1, max(0, (value - low) / (high - low))) * rect.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// A colored status pill, used for memory pressure and thermal state.
struct HubPill: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
    }
}

/// The hub's scrolling body, so every section has the same padding and scroll behavior.
struct HubScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
        }
    }
}

extension MonitoringStore {
    /// The hub reads values straight from the shared store; a missing reading stays an em dash
    /// rather than becoming a zero.
    func hubValue(_ id: String) -> String {
        guard readings[id]?.available == true else { return "—" }
        return display(id, compact: true)
    }
    func hubNumber(_ id: String) -> Double? { readings[id]?.number }
    func hubHistory(_ id: String) -> [HistoryPoint] { history[id] ?? [] }
}
