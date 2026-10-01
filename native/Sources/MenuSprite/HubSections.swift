import AppKit
import SwiftUI
import SystemMonitoring

// MARK: - System

/// Temperatures, hardware usage and memory on one page — the readings people open a menu-bar
/// monitor for. Everything here comes from the shared sampler; nothing is derived or invented.
struct HubSystemSection: View {
    @ObservedObject var monitoring: MonitoringStore

    var body: some View {
        HubScroll {
            HubCard(title: "Temperatures") {
                HStack(spacing: 10) {
                    HubTemperature(symbol: "cpu", label: "CPU", value: monitoring.hubValue("sensor.cpuTemperature"))
                    HubTemperature(symbol: "display", label: "GPU", value: monitoring.hubValue("sensor.gpuTemperature"))
                }
                if let thermal = monitoring.readings["system.thermal"]?.text {
                    HStack {
                        Text("Thermal pressure").font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                        HubPill(text: thermal, color: thermalColor(thermal))
                    }
                }
            }
            HubCard(title: "Hardware usage") {
                HubMeter(title: "CPU", value: monitoring.hubNumber("cpu.usage"),
                         display: monitoring.hubValue("cpu.usage"), history: monitoring.hubHistory("cpu.usage"))
                HubMeter(title: "GPU", value: monitoring.hubNumber("gpu.usage"),
                         display: monitoring.hubValue("gpu.usage"), history: monitoring.hubHistory("gpu.usage"),
                         tint: .teal)
            }
            HubCard(title: "Memory") {
                HStack(alignment: .firstTextBaseline) {
                    Text("Pressure").font(.system(size: 13)).foregroundStyle(.secondary)
                    if let pressure = monitoring.readings["memory.pressure"]?.text {
                        HubPill(text: pressure, color: pressureColor(pressure))
                    }
                    Spacer(minLength: 8)
                    Text("\(monitoring.hubValue("memory.used")) / \(monitoring.hubValue("memory.total"))")
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).truncationMode(.middle)
                }
                HubStat(label: "Compressed", value: monitoring.hubValue("memory.compressed"))
                HubStat(label: "Cached files", value: monitoring.hubValue("memory.cached"))
                HubStat(label: "Swap used", value: monitoring.hubValue("memory.swapUsed"))
                HubSparkline(points: monitoring.hubHistory("memory.usage"), percent: true)
                    .stroke(Color.mint, lineWidth: 1.4).frame(height: 26)
            }
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Up for \(monitoring.hubValue("system.uptime"))")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.leading, 2)
        }
    }

    private func pressureColor(_ value: String) -> Color {
        switch value { case "Normal": .green; case "Warning": .orange; case "Critical": .red; default: .secondary }
    }
    private func thermalColor(_ value: String) -> Color {
        switch value { case "Nominal": .green; case "Fair": .yellow; case "Serious": .orange; case "Critical": .red; default: .secondary }
    }
}

private struct HubTemperature: View {
    let symbol: String
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) temperature: \(value)")
    }
}

// MARK: - Apps

/// Per-app CPU, memory and CPU-power ranking. Ranking is the hub's most expensive reading, so it
/// samples only while this tab is the visible one.
struct HubAppsSection: View {
    @ObservedObject var model: HubModel
    @ObservedObject var monitoring: MonitoringStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { model.appsKind }, set: { model.selectAppsKind($0) })) {
                Text("CPU").tag(ProcessPanelKind.cpu)
                Text("Memory").tag(ProcessPanelKind.memory)
                Text("Power").tag(ProcessPanelKind.power)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            .accessibilityIdentifier("hub-apps-kind")
            if let processes = model.processes {
                HubAppsList(monitoring: monitoring, processes: processes)
            } else {
                Spacer()
            }
        }
    }
}

private struct HubAppsList: View {
    @ObservedObject var monitoring: MonitoringStore
    @ObservedObject var processes: MemoryBoardStore

    private var content: ProcessBoardContent { .init(kind: processes.kind, monitoring: monitoring, processes: processes) }

    var body: some View {
        HubScroll {
            HubCard {
                HStack(alignment: .firstTextBaseline) {
                    Text(content.mainValue).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    Spacer()
                    Text(processes.kind.title).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Text(content.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                HubSparkline(points: monitoring.hubHistory(processes.kind.summaryID),
                             percent: processes.kind != .power)
                    .stroke(Color.accentColor, lineWidth: 1.4).frame(height: 28)
            }
            HubCard(title: processes.kind.listTitle) {
                let rows = processes.visibleRows(limit: 25)
                if rows.isEmpty {
                    Text(processes.loading ? "Reading processes…" : processes.emptyMessage)
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.row.id) { item in
                    let row = item.row
                    HStack(spacing: 8) {
                        if item.depth > 0 { Rectangle().fill(.separator).frame(width: 1).padding(.leading, 6).padding(.trailing, 3) }
                        if let path = row.consumer.presentation.iconBundlePath, let icon = processes.icons[path] {
                            Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                        } else {
                            Image(systemName: row.consumer.presentation.symbol)
                                .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 15)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.consumer.presentation.title).font(.system(size: 13)).lineLimit(1)
                            if let subtitle = row.consumer.presentation.subtitle {
                                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if ProcessQuitArming.shared.isArmed(row.id) {
                            Text("quitting…").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.orange)
                        } else {
                            Text(content.formatted(row))
                                .font(.system(size: 13, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProcessQuitButton(row: row, processes: processes)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if !row.members.isEmpty { processes.toggle(row.id) } }
                    .help(content.tooltip(row))
                }
                if let notice = processes.notice {
                    Text(notice).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
                Text(processes.kind.scope).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
            }
            Text(content.explanation)
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Activity Monitor") {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                                   configuration: .init())
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Network

struct HubNetworkSection: View {
    @ObservedObject var monitoring: MonitoringStore

    var body: some View {
        HubScroll {
            HubCard(title: "Throughput") {
                HubRate(symbol: "arrow.down", label: "Download", value: monitoring.hubValue("network.download"),
                        history: monitoring.hubHistory("network.download"), tint: .blue)
                HubRate(symbol: "arrow.up", label: "Upload", value: monitoring.hubValue("network.upload"),
                        history: monitoring.hubHistory("network.upload"), tint: .orange)
            }
            HubCard(title: "Since the interfaces came up") {
                HubStat(label: "Received", value: monitoring.hubValue("network.received"))
                HubStat(label: "Sent", value: monitoring.hubValue("network.sent"))
                HubStat(label: "Packets in / s", value: monitoring.hubValue("network.packetsIn"))
                HubStat(label: "Packets out / s", value: monitoring.hubValue("network.packetsOut"))
            }
            Text("Hardware interfaces only — VPN, loopback and bridge counters are excluded so traffic is not counted twice. This is traffic, not an internet speed test.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Disk

struct HubDiskSection: View {
    @ObservedObject var monitoring: MonitoringStore

    var body: some View {
        HubScroll {
            HubCard(title: "Data volume") {
                HubMeter(title: "Used", value: monitoring.hubNumber("disk.usage"),
                         display: monitoring.hubValue("disk.usage"), history: monitoring.hubHistory("disk.usage"),
                         tint: .purple)
                HubStat(label: "Used", value: monitoring.hubValue("disk.used"))
                HubStat(label: "Free", value: monitoring.hubValue("disk.free"))
                HubStat(label: "Available to you", value: monitoring.hubValue("disk.available"))
                HubStat(label: "Capacity", value: monitoring.hubValue("disk.total"))
            }
            HubCard(title: "Block device activity") {
                HubRate(symbol: "arrow.down.doc", label: "Read", value: monitoring.hubValue("disk.read"),
                        history: monitoring.hubHistory("disk.read"), tint: .blue)
                HubRate(symbol: "arrow.up.doc", label: "Write", value: monitoring.hubValue("disk.write"),
                        history: monitoring.hubHistory("disk.write"), tint: .orange)
                HubStat(label: "Reads / s", value: monitoring.hubValue("disk.readIOPS"))
                HubStat(label: "Writes / s", value: monitoring.hubValue("disk.writeIOPS"))
            }
            Text("APFS volumes share container capacity, so free space can change without this Mac writing anything. Block I/O covers every storage driver, including mounted disk images.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HubRate: View {
    let symbol: String
    let label: String
    let value: String
    let history: [HistoryPoint]
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
                Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            HubSparkline(points: history)
                .stroke(tint, lineWidth: 1.4).frame(height: 24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Power

/// The existing Battery & Power dashboard, hosted inside the hub instead of in its own panel. It
/// keeps its charge-band controls; the hub supplies the surrounding chrome.
struct HubPowerSection: View {
    @ObservedObject var model: HubModel
    let monitoring: MonitoringStore
    let power: PowerStore
    let actions: HubActions
    let close: () -> Void

    var body: some View {
        if let processes = model.processes, processes.kind == .power {
            EnergyBoardHost(monitoring: monitoring, processes: processes, power: power,
                            showPower: { close(); actions.openPowerControls() })
        } else {
            Color.clear
        }
    }
}

private struct EnergyBoardHost: NSViewControllerRepresentable {
    let monitoring: MonitoringStore
    let processes: MemoryBoardStore
    let power: PowerStore
    let showPower: () -> Void

    func makeNSViewController(context: Context) -> EnergyBoardController {
        EnergyBoardController(monitoring: monitoring, processes: processes, power: power, id: nil, embedded: true,
                              configure: {}, showPower: showPower, close: {})
    }
    func updateNSViewController(_ controller: EnergyBoardController, context: Context) {}
    static func dismantleNSViewController(_ controller: EnergyBoardController, coordinator: ()) {
        controller.stop()
    }
}

// MARK: - Sprites

/// The menu bar itself: what is showing, what is paused, and a way into the full editor.
struct HubSpritesSection: View {
    @ObservedObject var monitoring: MonitoringStore
    @ObservedObject private var placement = SpritePlacement.shared
    let actions: HubActions
    let close: () -> Void

    var body: some View {
        HubScroll {
            HubCard(title: "Left strip") {
                Picker("Pointing at the strip", selection: $placement.reveal) {
                    ForEach(SpritePlacement.Reveal.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden().font(.system(size: 12))
                if placement.reveal == .hover {
                    Picker("Menus after resting for", selection: $placement.hoverDelay) {
                        ForEach(SpritePlacement.hoverDelays, id: \.self) { Text("\($0.formatted()) s").tag($0) }
                    }
                    .font(.system(size: 12)).fixedSize()
                }
                Text("Put a sprite there from its right-click menu or the studio's Left | Right switch. Drag strip sprites to reorder them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if monitoring.sprites.isEmpty {
                HubCard {
                    Text("No sprites yet. Open Settings to build your first menu-bar reading.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            ForEach(monitoring.sprites) { config in
                HubCard {
                    HStack(spacing: 8) {
                        Image(systemName: config.symbol).font(.system(size: 14)).frame(width: 16)
                        Text(config.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Button("Edit") { close(); actions.editSprite(config) }
                            .controlSize(.small).accessibilityIdentifier("hub-edit-\(config.id)")
                    }
                    Text(monitoring.menuText(config))
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Toggle("Enabled", isOn: Binding(get: { config.enabled },
                                                        set: { monitoring.setEnabled(config.id, $0) }))
                            .toggleStyle(.switch).controlSize(.mini)
                        Spacer()
                        Toggle("In menu bar", isOn: Binding(get: { config.showInMenuBar },
                                                            set: { monitoring.setMenuBar(config.id, $0) }))
                            .toggleStyle(.switch).controlSize(.mini)
                    }
                    .font(.system(size: 12))
                }
            }
            Button { close(); actions.openSprites() } label: {
                Label("Open Monitoring & Sprites", systemImage: "slider.horizontal.3")
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Work

struct HubWorkSection: View {
    let actions: HubActions
    let close: () -> Void

    var body: some View {
        HubScroll {
            HubCard(title: "Work & Clients") {
                Text("Hours and client assignments from the collected pane history, with billable projects, rates and CSV export.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { close(); actions.openWork() } label: {
                    Label("Open the work report", systemImage: "briefcase")
                }
                .controlSize(.small).accessibilityIdentifier("hub-open-work")
            }
            Text("The report needs the room of a full window, so it opens beside this panel rather than inside it.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Tools

/// Keep-awake, the sensors that have no page of their own, and the way into the two full windows.
struct HubToolsSection: View {
    @ObservedObject var monitoring: MonitoringStore
    @ObservedObject var power: PowerStore
    let actions: HubActions
    let close: () -> Void

    var body: some View {
        HubScroll {
            HubKeepAwakeCard(power: power, openPowerControls: { close(); actions.openPowerControls() })
            HubMenuBarSpacingCard()
            HubMenuBarIconCard()
            HubCard(title: "Fans") { FanControlView(power: power) }
            HubCard(title: "Sensors") {
                HubStat(label: "CPU temperature", value: monitoring.hubValue("sensor.cpuTemperature"))
                HubStat(label: "GPU temperature", value: monitoring.hubValue("sensor.gpuTemperature"))
            }
        }
    }
}

/// Which artwork MenuSprite's own menu-bar item wears: the default Arranger or any of the early brand
/// explorations. A pick applies at once; the monochrome switch follows the menu bar's light or dark.
struct HubMenuBarIconCard: View {
    @State private var choice: MenuBarIconChoice
    @State private var monochrome: Bool

    /// The arguments exist for `--menu-bar-icon-render`, which draws states without saving them.
    init(choice: MenuBarIconChoice = MenuBarIconChoice.saved, monochrome: Bool = MenuBarIconChoice.monochrome) {
        _choice = State(initialValue: choice)
        _monochrome = State(initialValue: monochrome)
    }

    var body: some View {
        HubCard(title: "Menu bar icon") {
            ForEach(MenuBarIconChoice.Family.allCases) { family in
                Text(family.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(MenuBarIconChoice.allCases.filter { $0.family == family }) { option in
                        tile(option)
                    }
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monochrome").font(.system(size: 13))
                    Text(choice.hasMonochrome
                         ? "Follows the menu bar, black on light and white on dark."
                         : "\(choice.title) is a 3D render and has colour only.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { monochrome }, set: { MenuBarIconChoice.monochrome = $0; monochrome = $0 }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(!choice.hasMonochrome)
                    .accessibilityLabel("Monochrome menu bar icon")
                    .accessibilityIdentifier("hub-menubar-icon-monochrome")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MenuBarIconChoice.changed)) { _ in
            choice = MenuBarIconChoice.saved
            monochrome = MenuBarIconChoice.monochrome
        }
    }

    private func tile(_ option: MenuBarIconChoice) -> some View {
        let selected = option == choice
        let template = monochrome && option.hasMonochrome
        return Button {
            MenuBarIconChoice.saved = option
            choice = option
        } label: {
            Group {
                if let image = option.image(monochrome: template) {
                    Image(nsImage: image).resizable().renderingMode(template ? .template : .original)
                        .aspectRatio(contentMode: .fit).foregroundStyle(.primary)
                } else {
                    Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary)
                }
            }
            .frame(height: 30).frame(maxWidth: .infinity).padding(.vertical, 7).padding(.horizontal, 4)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(option.title)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("hub-menubar-icon-\(option.rawValue)")
    }
}

/// The Bartender-style item-spacing setting. Writes the two AppKit defaults, keeps them through the
/// launch-time `MenuBarSpacing.enforce`, and says plainly that apps only read them at launch rather
/// than pretending the menu bar changed.
struct HubMenuBarSpacingCard: View {
    @State private var saved = MenuBarSpacing.current()
    @State private var atLogin = LoginItem.isEnabled
    @State private var failed = false

    var body: some View {
        HubCard(title: "Menu bar spacing") {
            Picker("", selection: Binding(get: { saved.preset ?? .standard }, set: choose)) {
                ForEach(MenuBarSpacing.Preset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .accessibilityLabel("Menu bar item spacing")
            .accessibilityIdentifier("hub-menubar-spacing")
            HubStat(label: "Saved", value: saved.summary)
            if failed {
                Text("macOS did not accept the change.").font(.system(size: 11)).foregroundStyle(.red)
            } else if saved != MenuBarSpacing.atLaunch {
                Text("Log out and back in to apply it to every menu-bar item. An app you quit and reopen picks it up on its own.")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button { MenuBarSpacing.relaunch() } label: {
                    Label("Relaunch MenuSprite now", systemImage: "arrow.clockwise")
                }
                .controlSize(.small).accessibilityIdentifier("hub-menubar-spacing-relaunch")
            } else if MenuBarSpacing.owned != nil {
                Text("MenuSprite owns this and puts it back at every launch, so no other menu-bar app is needed at login. Items macOS draws itself may keep their own gaps.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Pick a preset to let MenuSprite own it. macOS stores the value, so it survives a restart on its own.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login").font(.system(size: 13))
                    Text(MenuBarSpacing.owned == nil
                         ? "Keeps the readings in the menu bar from the moment you sign in."
                         : "Also lets MenuSprite put the spacing back if anything changes it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { atLogin }, set: setLogin))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel("Open MenuSprite at login")
                    .accessibilityIdentifier("hub-open-at-login")
            }
            if LoginItem.needsApproval {
                Text("Switched off for MenuSprite in System Settings → General → Login Items. Turn it back on there.")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choose(_ preset: MenuBarSpacing.Preset) {
        failed = !MenuBarSpacing.apply(preset)
        saved = MenuBarSpacing.current()
    }

    private func setLogin(_ enabled: Bool) {
        LoginItem.set(enabled)
        atLogin = LoginItem.isEnabled
    }
}
