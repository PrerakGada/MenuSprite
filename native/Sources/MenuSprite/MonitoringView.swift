import SwiftUI
import SystemMonitoring

struct MonitoringView: View {
    @ObservedObject var store: MonitoringStore
    var showPower: () -> Void = {}
    var showWork: () -> Void = {}
    let showPermissions: () -> Void
    @State private var search = ""
    @AppStorage("MenuSprite.OpenReadingGroups") private var openGroupsStored = "CPU|Memory"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if let image = NSImage(named: "BrandIcon") {
                    Image(nsImage: image).resizable().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Monitoring & Sprites").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text(BuildFeatures.publicPreview ? "Public preview · choose your menu-bar readings." : "Choose your readings. Make the menu bar yours.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !BuildFeatures.publicPreview { Button("Work & Clients", action: showWork).controlSize(.small) }
                Button(BuildFeatures.powerPageTitle,action:showPower).controlSize(.small)
                Button("Permissions & Access", action: showPermissions).controlSize(.small)
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).accessibilityIdentifier("refresh-monitoring")
            }.padding(24)
            Divider()
            HSplitView {
                spriteList.frame(minWidth: 250, idealWidth: 275, maxWidth: 325)
                readingLibrary.frame(minWidth: 520, maxWidth: .infinity)
            }
            Divider()
            VStack(spacing: 5) {
                if let notice = store.notice {
                    HStack {
                        Text(notice).font(.callout).textSelection(.enabled)
                        Spacer()
                        if store.canUndoRemove { Button("Undo") { store.undoRemove() } }
                        Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss")
                    }
                }
                HStack {
                    Label(store.suspended ? "Paused during sleep" : (store.isSampling ? "Shared sampling is active" : "Sampling is stopped"), systemImage: store.isSampling ? "waveform.path" : "pause.circle")
                    Spacer()
                    Text("\(store.requestedMetricCount) requested readings")
                    if let time = store.lastSample { Text("Checked \(time.formatted(date: .omitted, time: .standard))").monospacedDigit() }
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 11)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $store.isShowingEditor, onDismiss: { store.preview([]) }) {
            if let config = store.editingSprite { SpriteEditor(store: store, draft: config) }
        }
    }

    private var spriteList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("My sprites").font(.headline)
                Text("\(store.sprites.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Empty sprite") { store.newSprite() }
                    Divider()
                    Section("Start from") {
                        ForEach(Self.presets, id: \.0) { name, icon, ids in
                            Button { store.editingSprite = SpriteConfiguration(name: name, symbol: icon, metricIDs: ids); store.isShowingEditor = true }
                                label: { Label(name, systemImage: icon) }
                        }
                    }
                } label: { Image(systemName: "plus") } primaryAction: { store.newSprite() }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("New sprite · hold for presets").accessibilityLabel("New sprite").accessibilityIdentifier("new-sprite")
            }.padding(.horizontal, 16).padding(.vertical, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if store.sprites.isEmpty {
                        Text("Add a reading from the library, or press + to start from a preset.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(store.sprites) { SpriteRow(config: $0, store: store) }
                }.padding(.horizontal, 8)
            }
            Divider()
            Text("The switch stops a sprite's monitoring; the eye only hides it from the menu bar. ⌘-drag menu-bar items to reorder them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    static let presets: [(String, String, [String])] = [
        ("CPU", "cpu", ["cpu.usage"]), ("Memory", "memorychip", ["memory.usage"]),
        ("Network", "network", ["network.download", "network.upload"]),
        ("Battery", "battery.100percent", ["battery.charge"]),
        ("Power & temperature", "bolt", ["sensor.PSTR", "sensor.cpuTemperature"]),
        ("Claude usage", "sparkles", ["ai.claude.session", "ai.claude.weekly"]),
        ("Codex usage", "terminal", ["ai.codex.session", "ai.codex.weekly"])
    ]

    private var readingLibrary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Readings").font(.headline)
                if store.discoveringSensors { ProgressView().controlSize(.small); Text("Discovering sensors…").font(.caption) }
                else { Text("\(store.catalog.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                TextField("Search readings or sensor keys", text: $search).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300).accessibilityIdentifier("monitor-search")
                Button(openGroups.isEmpty ? "Expand all" : "Collapse all") {
                    openGroups = openGroups.isEmpty ? Set(MetricGroup.allCases) : []
                }.controlSize(.small).disabled(!search.isEmpty)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            ReadingGroupList(store: store, search: search, expanded: openGroupsBinding) { metric in
                Menu {
                    Button("New sprite with this reading…") { store.newSprite(metricID: metric.id) }
                    if !store.sprites.isEmpty {
                        Divider()
                        ForEach(store.sprites) { config in
                            Button("Add to \(config.name)") { store.add(metric.id, to: config.id) }
                                .disabled(config.metricIDs.contains(metric.id) || config.metricIDs.count >= 8)
                        }
                    }
                } label: { Image(systemName: "plus.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).help("Add this reading to a sprite")
                .accessibilityIdentifier("add-reading-\(metric.id)")
            }.accessibilityIdentifier("monitor-readings")
        }
    }

    /// Which category cards are open, remembered across window openings.
    private var openGroups: Set<MetricGroup> {
        get { Set(openGroupsStored.split(separator: "|").compactMap { MetricGroup(rawValue: String($0)) }) }
        nonmutating set { openGroupsStored = newValue.map(\.rawValue).sorted().joined(separator: "|") }
    }
    private var openGroupsBinding: Binding<Set<MetricGroup>> { Binding(get: { openGroups }, set: { openGroups = $0 }) }
}

/// One sprite as a single line: identity, live readout, monitoring switch, menu-bar eye, actions.
private struct SpriteRow: View {
    let config: SpriteConfiguration
    @ObservedObject var store: MonitoringStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button { store.edit(config) } label: {
                HStack(spacing: 10) {
                    Image(systemName: config.symbol).font(.system(size: 15)).frame(width: 22)
                        .foregroundStyle(config.enabled ? .primary : .tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(store.menuText(config)).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Edit sprite · \(config.metricIDs.count) readings, every \(Int(config.interval))s")
                .accessibilityIdentifier("edit-\(config.id)")
            Button { store.setMenuBar(config.id, !config.showInMenuBar) } label: {
                Image(systemName: config.showInMenuBar ? "eye" : "eye.slash").frame(width: 18)
                    .foregroundStyle(config.showInMenuBar ? .primary : .tertiary)
            }.buttonStyle(.borderless).help(config.showInMenuBar ? "Shown in the menu bar · click to hide" : "Hidden from the menu bar · click to show")
                .accessibilityLabel("Show in menu bar").accessibilityValue(config.showInMenuBar ? "On" : "Off")
                .accessibilityIdentifier("visible-\(config.id)")
            Toggle("Enabled", isOn: Binding(get: { config.enabled }, set: { store.setEnabled(config.id, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .help(config.enabled ? "Monitoring · click to pause" : "Paused · click to resume")
                .accessibilityIdentifier("enabled-\(config.id)")
            Menu {
                Button("Edit sprite…") { store.edit(config) }
                Button("Move up in list") { store.move(config.id, offset: -1) }
                Button("Move down in list") { store.move(config.id, offset: 1) }
                Divider()
                Button("Remove sprite", role: .destructive) { store.remove(config.id) }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit sprite…") { store.edit(config) }
            Button("Move up in list") { store.move(config.id, offset: -1) }
            Button("Move down in list") { store.move(config.id, offset: 1) }
            Divider()
            Button("Remove sprite", role: .destructive) { store.remove(config.id) }
        }
    }
}

struct SpriteEditor: View {
    @ObservedObject var store: MonitoringStore
    @State var draft: SpriteConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var openGroups: Set<MetricGroup> = []
    private let symbols = ["cpu", "memorychip", "network", "internaldrive", "display", "battery.100percent", "bolt", "fan", "fan.fill", "thermometer.medium", "gauge.with.dots.needle.50percent", "chart.xyaxis.line", "star", "sparkles", "terminal"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(store.sprites.contains(where: { $0.id == draft.id }) ? "Edit sprite" : "New sprite")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save sprite") { store.save(draft); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(draft.metricIDs.isEmpty).accessibilityIdentifier("save-sprite")
            }
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Sprite name", text: $draft.name).textFieldStyle(.roundedBorder).accessibilityIdentifier("sprite-name")
                    Text("Menu-bar preview").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: true) {
                        if draft.enabled {
                            let image = StackedReadout.image(columns: store.menuColumns(draft), config: draft, height: NSStatusBar.system.thickness,
                                                            icon: draft.isBatteryItem ? .battery(store.batteryGlyph(ceiling: nil, for: draft)) : nil)
                            Image(nsImage: image).foregroundStyle(spriteColor(draft.colorHex))
                                .padding(.horizontal, 12).frame(height: 32)
                                .accessibilityLabel(store.menuText(draft))
                        } else {
                        HStack(spacing: 6) {
                            if draft.showIcon { Image(systemName: draft.symbol) }
                            Text(AttributedString(StackedReadout.attributedText(columns: store.menuColumns(draft), config: draft)))
                        }
                        .foregroundStyle(spriteColor(draft.colorHex)).padding(.horizontal, 12).frame(height: 32)
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
                    if draft.metricIDs.count > 1 { Text("Scroll sideways for longer previews.").font(.caption2).foregroundStyle(.secondary) }
                    Picker("Layout", selection: $draft.layout) {
                        ForEach(SpriteReadoutLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("sprite-layout")
                    if draft.layout == .stacked {
                        Text("Small labels sit above each value. Text fits within the menu-bar height.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if draft.layout == .twoRows {
                        Text("Pairs of readings share one column: first on top, second beneath it.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if draft.layout == .bar {
                        Text("Each percentage reading is a thin standing bar that fills from the bottom. It keeps the menu-bar color, turns amber above the warning line and red above the alert line. Other readings stay as numbers.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Stepper("Amber above \(draft.barWarning)%", value: $draft.barWarning, in: 5...95, step: 5)
                            .accessibilityIdentifier("sprite-bar-warning")
                        Stepper("Red above \(draft.barAlert)%", value: $draft.barAlert, in: max(10, draft.barWarning + 5)...100, step: 5)
                            .accessibilityIdentifier("sprite-bar-alert")
                    }
                    Text("Icon").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 6), spacing: 8) {
                        ForEach(symbols, id: \.self) { symbol in
                            Button { draft.symbol = symbol } label: { Image(systemName: symbol).frame(width: 27, height: 25) }
                                .buttonStyle(.borderless).background(draft.symbol == symbol ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .help(symbol)
                        }
                    }
                    HStack {
                        Text("Refresh").font(.callout)
                        Spacer()
                        Picker("Refresh interval", selection: $draft.interval) {
                            ForEach([1.0,2,5,10,30,60], id: \.self) { Text("Every \(Int($0))s").tag($0) }
                        }.labelsHidden().frame(width: 120).accessibilityIdentifier("sprite-interval")
                    }
                    HStack {
                        Text("Text size").font(.callout)
                        Spacer()
                        Picker("Text size", selection: $draft.fontSize) {
                            ForEach([10.0,11,12,13,14,15,16], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                        }.labelsHidden().frame(width: 100)
                    }
                    Picker("Color rule", selection: $draft.colorRule) {
                        ForEach(SpriteColorRule.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("sprite-color-rule")
                    if draft.colorRule.usesUsagePace {
                        Text("Weekly: 14.3% per day. Five-hour: 20% per hour. Green within the current allowance; amber up to one extra day/hour; red beyond that or at 100%. Each reading is colored separately. Missing or stale timing is gray.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if draft.colorRule == .memoryPressure {
                        Text("RAM labels follow macOS memory pressure (the value keeps the text color): green when normal, yellow at warning, red when critical. Other readings use the text color.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if draft.colorRule == .powerDraw {
                        Text("The label of a watts reading keeps the text color below 35 W, turns yellow from 35 W to 45 W and red above 45 W; the value stays in the text color. Other readings use the text color.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if draft.colorRule == .networkDirection {
                        Text("Upload readings are orange and download readings green, label included. Other readings use the text color.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(draft.colorRule == .usagePace ? "Other readings" : "Text color").font(.callout)
                        Spacer()
                        Picker("Color", selection: $draft.colorHex) {
                            Text("Automatic").tag("auto"); Text("Purple").tag("B8A1F3"); Text("Mint").tag("78DFBD")
                            Text("Blue").tag("79BFFA"); Text("Orange").tag("FFAD66"); Text("White").tag("FFFFFF")
                        }.labelsHidden().frame(width: 120)
                    }
                    Toggle("Bold text", isOn: $draft.bold)
                    Toggle("Show icon in menu bar", isOn: $draft.showIcon)
                    if draft.showIcon && draft.isBatteryItem {
                        HStack {
                            Text("Percentage")
                            Spacer()
                            Picker("Percentage", selection: $draft.batteryPercentPlacement) {
                                ForEach(BatteryPercentPlacement.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
                                .accessibilityIdentifier("sprite-battery-percent")
                        }
                        if draft.batteryPercentPlacement == .inside && !draft.metricIDs.contains("battery.charge") {
                            Text("Add the Battery charge reading to show a number inside the battery.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if draft.showIcon {
                        Picker("Icon color", selection: $draft.iconColorHex) {
                            Text("Same as text").tag("text"); Text("Automatic").tag("auto")
                            Text("Purple").tag("B8A1F3"); Text("Mint").tag("78DFBD")
                            Text("Blue").tag("79BFFA"); Text("Orange").tag("FFAD66"); Text("White").tag("FFFFFF")
                        }
                    }
                    Toggle("Show reading labels", isOn: $draft.showLabels)
                    Toggle("Show units", isOn: $draft.showUnits)
                    HStack {
                        Text("Decimal places")
                        Spacer()
                        Picker("Decimal places", selection: $draft.decimals) { ForEach(0...2, id: \.self) { Text("\($0)").tag($0) } }
                            .labelsHidden().frame(width: 80)
                    }
                    Toggle("Temperatures in Fahrenheit", isOn: $draft.fahrenheit)
                    Toggle("Network rates in bits/s", isOn: $draft.networkBits)
                    Divider()
                    Toggle("Enabled", isOn: $draft.enabled).accessibilityIdentifier("sprite-enabled")
                    Toggle("Show in menu bar", isOn: $draft.showInMenuBar).accessibilityIdentifier("sprite-menu-visible")
                }.font(.callout).frame(maxWidth: .infinity)
                }.frame(width: 250)

                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Readings in this sprite").font(.headline); Spacer(); Text("\(draft.metricIDs.count)/8").font(.caption).foregroundStyle(.secondary) }
                    VStack(spacing: 5) {
                        ForEach(Array(draft.metricIDs.enumerated()), id: \.element) { index, id in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(store.metric(id).name).font(.callout).lineLimit(1)
                                    TextField("Label: \(store.metric(id).shortName)", text: Binding(
                                        get: { draft.customLabel(for: id) },
                                        set: { draft.setLabel($0, for: id) }))
                                        .textFieldStyle(.roundedBorder).font(.caption)
                                        .accessibilityLabel("Menu-bar label for \(store.metric(id).name)")
                                }
                                Spacer()
                                Button { draft.metricIDs.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                                Button { draft.metricIDs.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == draft.metricIDs.count - 1)
                                Button { draft.metricIDs.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.help("Remove reading")
                            }.buttonStyle(.borderless)
                        }
                    }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    TextField("Find a reading to add", text: $search).textFieldStyle(.roundedBorder).accessibilityIdentifier("sprite-metric-search")
                    ReadingGroupList(store: store, search: search, expanded: $openGroups) { metric in
                        let chosen = draft.metricIDs.contains(metric.id)
                        Button {
                            if chosen { draft.metricIDs.removeAll { $0 == metric.id } }
                            else if draft.metricIDs.count < 8 { draft.metricIDs.append(metric.id) }
                        } label: { Image(systemName: chosen ? "checkmark.circle.fill" : "plus.circle") }
                        .buttonStyle(.borderless).disabled(!chosen && draft.metricIDs.count >= 8)
                        .help(chosen ? "Remove from this sprite" : "Add to this sprite")
                        .accessibilityIdentifier("select-metric-\(metric.id)")
                    }
                    .padding(.horizontal, -16)
                    Text("Only enabled sprites and visible previews request samples. Several readings in one sprite share their collectors.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }
        }
        .padding(24).frame(width: 810, height: 730)
        .onAppear {
            store.preview(draft.metricIDs)
            openGroups = Set(draft.metricIDs.map { store.metric($0).group })
        }
        .onChange(of: draft.metricIDs) { _, value in store.preview(value) }
        .onDisappear { store.preview([]) }
    }
}

func spriteColor(_ hex: String) -> Color {
    guard let value = UInt32(hex, radix: 16) else { return Color(nsColor: .labelColor) }
    return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
}
