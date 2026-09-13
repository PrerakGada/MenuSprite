import SwiftUI
import SystemMonitoring

struct MonitoringView: View {
    @ObservedObject var store: MonitoringStore
    var showPower: () -> Void = {}
    var showWork: () -> Void = {}
    let showPermissions: () -> Void
    @State private var search = ""
    @State private var group: MetricGroup?
    @State private var advanced = false

    private var metrics: [Metric] {
        store.catalog.filter {
            (group == nil || $0.group == group) && (advanced || !$0.advanced) &&
            (search.isEmpty || "\($0.name) \($0.id) \($0.group.rawValue)".localizedStandardContains(search))
        }
    }
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
                Spacer()
                Button { store.newSprite() } label: { Image(systemName: "plus") }
                    .help("New sprite").accessibilityLabel("New sprite").accessibilityIdentifier("new-sprite")
            }.padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.sprites.isEmpty {
                        Text("Add a reading from the library to create your first sprite.").foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(store.sprites) { config in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: config.symbol).font(.title3).frame(width: 22)
                                Text(config.name).fontWeight(.semibold).lineLimit(1)
                                Spacer()
                                Menu {
                                    Button("Edit sprite") { store.edit(config) }
                                    Button("Move up in list") { store.move(config.id, offset: -1) }
                                    Button("Move down in list") { store.move(config.id, offset: 1) }
                                    Divider()
                                    Button("Remove sprite", role: .destructive) { store.remove(config.id) }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
                            }
                            Text(store.menuText(config)).font(.system(size: 12, design: .monospaced)).lineLimit(2).foregroundStyle(.secondary)
                            HStack {
                                Toggle("Enabled", isOn: Binding(get: { config.enabled }, set: { store.setEnabled(config.id, $0) }))
                                    .toggleStyle(.switch).controlSize(.mini).accessibilityIdentifier("enabled-\(config.id)")
                                Spacer()
                                Button("Edit…") { store.edit(config) }.controlSize(.small).accessibilityIdentifier("edit-\(config.id)")
                            }
                            Toggle("Show in menu bar", isOn: Binding(get: { config.showInMenuBar }, set: { store.setMenuBar(config.id, $0) }))
                                .font(.caption).accessibilityIdentifier("visible-\(config.id)")
                            Text("\(config.metricIDs.count) readings · every \(Int(config.interval))s")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(13)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4)))
                    }
                    Text("Hide a sprite to remove its menu-bar item. Disable it to stop its monitoring. Readings visible in this window still refresh.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    Text("⌘-drag menu-bar items to change their position.").font(.caption).foregroundStyle(.secondary)
                    Divider().padding(.vertical, 4)
                    Text("Quick start").font(.headline)
                    ForEach([
                        ("CPU", "cpu", ["cpu.usage"]), ("Memory", "memorychip", ["memory.usage"]),
                        ("Network", "network", ["network.download", "network.upload"]),
                        ("Battery", "battery.100percent", ["battery.charge"]),
                        ("Power & temperature", "bolt", ["sensor.PSTR", "sensor.cpuTemperature"]),
                        ("Claude usage", "sparkles", ["ai.claude.session", "ai.claude.weekly"]),
                        ("Codex usage", "terminal", ["ai.codex.session", "ai.codex.weekly"])
                    ], id: \.0) { name, icon, ids in
                        Button {
                            store.editingSprite = SpriteConfiguration(name: name, symbol: icon, metricIDs: ids)
                            store.isShowingEditor = true
                        } label: { Label(name, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain).padding(.vertical, 5)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 20)
            }
        }
    }

    private var readingLibrary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Available readings").font(.headline)
                Spacer()
                if store.discoveringSensors { ProgressView().controlSize(.small); Text("Discovering sensors…").font(.caption) }
                else { Text("\(store.catalog.count) in catalog").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 20).padding(.top, 16)
            HStack {
                TextField("Search readings or sensor keys", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("monitor-search")
                Picker("Category", selection: $group) {
                    Text("All categories").tag(MetricGroup?.none)
                    ForEach(MetricGroup.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }.labelsHidden().frame(width: 160).accessibilityIdentifier("monitor-category")
                Toggle("Advanced", isOn: $advanced).toggleStyle(.checkbox).font(.caption).accessibilityIdentifier("monitor-advanced")
            }.padding(.horizontal, 20).padding(.vertical, 12)
            if advanced {
                Text("Individual cores, interfaces and firmware keys. Unmapped sensors keep their raw key names; availability varies by Mac.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 9)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if metrics.isEmpty {
                        ContentUnavailableView("No matching readings", systemImage: "magnifyingglass",
                                               description: Text("Try another category, search term or the Advanced filter."))
                            .frame(maxWidth: .infinity).padding(.vertical, 45)
                    }
                    ForEach(MetricGroup.allCases, id: \.self) { category in
                        let rows = metrics.filter { $0.group == category }
                        if !rows.isEmpty {
                            Label(category.rawValue, systemImage: category.icon).font(.headline)
                                .padding(.top, 18).padding(.bottom, 7)
                            ForEach(rows) { metric in
                                ReadingRow(metric: metric, store: store)
                                    .onAppear { store.visible(metric.id, true) }
                                    .onDisappear { store.visible(metric.id, false) }
                                Divider()
                            }
                        }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }.accessibilityIdentifier("monitor-readings")
        }
    }
}

private struct ReadingRow: View {
    let metric: Metric
    @ObservedObject var store: MonitoringStore
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 9)
                        Text(metric.name).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("metric-detail-\(metric.id)")
                Text(store.display(metric.id)).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(store.readings[metric.id]?.available == true ? .primary : .secondary)
                    .lineLimit(2).frame(width: 158, alignment: .trailing).accessibilityIdentifier("reading-\(metric.id)")
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
                .menuStyle(.borderlessButton).frame(width: 25).help("Add this reading to a sprite")
                    .accessibilityIdentifier("add-reading-\(metric.id)")
            }
            if expanded {
                Text(metric.detail).font(.callout).textSelection(.enabled)
                Text("Source: \(metric.source)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let reading = store.readings[metric.id] {
                    Text("Last sampled \(reading.measuredAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 12)
    }
}

struct SpriteEditor: View {
    @ObservedObject var store: MonitoringStore
    @State var draft: SpriteConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category: MetricGroup?
    @State private var advanced = false
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
                            let image = StackedReadout.image(columns: store.menuColumns(draft), config: draft, height: NSStatusBar.system.thickness)
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
                    HStack {
                        Picker("Category", selection: $category) {
                            Text("All categories").tag(MetricGroup?.none)
                            ForEach(MetricGroup.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                        }.labelsHidden()
                        Toggle("Advanced", isOn: $advanced).toggleStyle(.checkbox)
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.catalog.filter { (advanced || !$0.advanced) && (category == nil || $0.group == category) && (search.isEmpty || "\($0.name) \($0.id)".localizedStandardContains(search)) }) { metric in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(metric.name).font(.callout)
                                        Text(metric.group.rawValue).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        if draft.metricIDs.contains(metric.id) { draft.metricIDs.removeAll { $0 == metric.id } }
                                        else if draft.metricIDs.count < 8 { draft.metricIDs.append(metric.id) }
                                    } label: { Image(systemName: draft.metricIDs.contains(metric.id) ? "checkmark.circle.fill" : "plus.circle") }
                                    .buttonStyle(.borderless).disabled(!draft.metricIDs.contains(metric.id) && draft.metricIDs.count >= 8)
                                    .accessibilityIdentifier("select-metric-\(metric.id)")
                                }.padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                    Text("Only enabled sprites and visible previews request samples. Several readings in one sprite share their collectors.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }
        }
        .padding(24).frame(width: 810, height: 730)
        .onAppear { store.preview(draft.metricIDs) }
        .onChange(of: draft.metricIDs) { _, value in store.preview(value) }
        .onDisappear { store.preview([]) }
    }
}

func spriteColor(_ hex: String) -> Color {
    guard let value = UInt32(hex, radix: 16) else { return Color(nsColor: .labelColor) }
    return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
}
