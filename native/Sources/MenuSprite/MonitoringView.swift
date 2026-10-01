import SwiftUI
import SystemMonitoring

struct MonitoringView: View {
    @ObservedObject var store: MonitoringStore
    @State private var search = ""
    /// The sprite open in the studio, which then fills the right side of the window.
    @State private var studio: StudioModel?
    @AppStorage("MenuSprite.OpenReadingGroups") private var openGroupsStored = "CPU|Memory"
    /// What the right side shows while no sprite is open: the gallery or every reading.
    @AppStorage("MenuSprite.SpritesPane") private var pane = "gallery"
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
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).accessibilityIdentifier("refresh-monitoring")
            }.padding(24)
            Divider()
            HSplitView {
                spriteList.frame(minWidth: 240, idealWidth: 270, maxWidth: 330)
                if let studio {
                    SpriteStudio(model: studio, store: store, close: closeStudio)
                        .id(studio.id)
                        .frame(minWidth: 820, maxWidth: .infinity)
                } else {
                    VStack(spacing: 0) {
                        Picker("Show", selection: $pane) {
                            Text("Gallery").tag("gallery")
                            Text("Readings").tag("readings")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                        .padding(.top, 12).accessibilityIdentifier("sprites-pane")
                        if pane == "readings" { readingLibrary } else { SpriteGallery(store: store) { open($0) } }
                    }.frame(minWidth: 520, maxWidth: .infinity)
                }
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
        .frame(minWidth: studio == nil ? 900 : 1120, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        // Every "edit this sprite" entry point (menu bar, hub, presets) opens it in the studio.
        .onChange(of: store.isShowingEditor, initial: true) { _, showing in
            guard showing else { return }
            if let config = store.editingSprite { open(config) }
            store.isShowingEditor = false
        }
        // An agent changed or removed the sprite open here: take its copy rather than saving ours over it.
        .onChange(of: store.lastAgentChange) { _, change in
            guard let change, let studio, studio.id == change.id else { return }
            if let saved = store.sprites.first(where: { $0.id == change.id }) { studio.adopt(saved) }
            else { studio.discard(); self.studio = nil }
        }
        .onDisappear { studio?.close() }
    }

    private func open(_ config: SpriteConfiguration) {
        if studio?.id == config.id { return }
        studio?.close()
        studio = StudioModel(config: store.sprites.first { $0.id == config.id } ?? config, store: store)
        studio?.selection = nil
    }
    private func closeStudio() { studio?.close(); studio = nil }

    /// A sprite with a single text to start from.
    private static var blankSprite: SpriteConfiguration {
        var config = SpriteConfiguration(name: "New sprite", symbol: "sparkles", metricIDs: [])
        var text = DesignNode.text([.literal("Hello")], size: 13, name: "Text"); text.style.tabular = false
        var root = DesignNode.row([text], gap: 4, name: "Sprite"); root.style.padding = 3; root.style.color = "auto"
        config.design = SpriteDesign(root: root)
        return config
    }

    private var spriteList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("My sprites").font(.headline)
                Text("\(store.sprites.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button { closeStudio(); pane = "gallery" } label: { Label("From the gallery…", systemImage: "square.grid.2x2") }
                    Button { open(Self.blankSprite) } label: { Label("Blank sprite", systemImage: "square.dashed") }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("New sprite").accessibilityLabel("New sprite").accessibilityIdentifier("new-sprite")
            }.padding(.horizontal, 16).padding(.vertical, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if store.sprites.isEmpty {
                        Text("Nothing in the menu bar yet. Add something from the gallery, or press + for a blank sprite.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    if let studio, !studio.isSaved {
                        SpriteRow(config: studio.config, store: store, selected: true, unsaved: true) { }
                    }
                    ForEach(store.sprites) { config in
                        SpriteRow(config: config, store: store, selected: studio?.id == config.id) { open(config) }
                    }
                }.padding(.horizontal, 8)
            }
            Divider()
            Text("Click a sprite to design it. The switch stops its readings; the eye only hides it from the menu bar. ⌘-drag menu-bar items to reorder them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

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

/// One sprite: drawn exactly as the menu bar draws it, its name, and its switches.
private struct SpriteRow: View {
    let config: SpriteConfiguration
    @ObservedObject var store: MonitoringStore
    var selected = false
    var unsaved = false
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 5) {
                    MenuBarChip(config: config, store: store)
                    Text(unsaved ? "\(config.name) · not saved" : config.name)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Design this sprite")
            .accessibilityLabel("\(config.name): \(store.menuText(config))")
            .accessibilityIdentifier("edit-\(config.id)")
            if !unsaved {
                Button { store.setMenuBar(config.id, !config.showInMenuBar) } label: {
                    Image(systemName: config.showInMenuBar ? "eye" : "eye.slash").frame(width: 18)
                        .foregroundStyle(config.showInMenuBar ? .primary : .tertiary)
                }.buttonStyle(.borderless).help(config.showInMenuBar ? "Shown in the menu bar · click to hide" : "Hidden from the menu bar · click to show")
                    .accessibilityLabel("Show in menu bar").accessibilityValue(config.showInMenuBar ? "On" : "Off")
                    .accessibilityIdentifier("visible-\(config.id)")
                Toggle("Enabled", isOn: Binding(get: { config.enabled }, set: { store.setEnabled(config.id, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .help(config.enabled ? "Running · click to pause" : "Paused · click to resume")
                    .accessibilityIdentifier("enabled-\(config.id)")
                Menu { actions } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.06) : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .contextMenu { if !unsaved { actions } }
    }

    @ViewBuilder private var actions: some View {
        Button("Design sprite…", action: open)
        Button("Move up in list") { store.move(config.id, offset: -1) }
        Button("Move down in list") { store.move(config.id, offset: 1) }
        Button("Duplicate") {
            var copy = config; copy.id = UUID(); copy.name = "\(config.name) copy"
            // The copy gets its own copy of the sprite's files and runs its commands there: sharing the
            // original's folder would share its state, and removing the original would leave the copy's
            // commands running in the home folder instead.
            let files = SpriteFolders.directory(for: config.id), own = SpriteFolders.directory(for: copy.id)
            if CommandVariableRunner.existingDirectory(files.path) != nil, (try? FileManager.default.copyItem(at: files, to: own)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: own.path)
                copy.design?.setCommandDirectory(own.path)
            } else {
                copy.design?.setCommandDirectory(nil)
            }
            store.save(copy)
        }
        Divider()
        Button("Remove sprite", role: .destructive) { store.remove(config.id) }
    }
}

/// The sprite at its real menu-bar size on a strip of menu bar, so the list shows what the bar shows.
struct MenuBarChip: View {
    let config: SpriteConfiguration
    @ObservedObject var store: MonitoringStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: 4) {
            if config.enabled, let output = store.renderDesign(config) {
                Image(nsImage: StudioCanvas.scaled(output.image, zoom: 1, dark: dark))
            } else {
                Image(systemName: config.symbol).font(.system(size: 12))
                Text(config.enabled ? store.menuText(config) : "Paused").font(.system(size: 12))
            }
        }
        .foregroundStyle(dark ? Color.white : Color.black)
        .opacity(config.enabled ? 1 : 0.5)
        .padding(.horizontal, 6)
        .frame(height: NSStatusBar.system.thickness + 6)
        .background(dark ? Color(white: 0.13) : Color(white: 0.9), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08)))
    }
}

func spriteColor(_ hex: String) -> Color {
    Color(nsColor: SpriteColors.color(hex) ?? .labelColor)
}
