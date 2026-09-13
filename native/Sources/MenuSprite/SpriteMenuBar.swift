import AppKit
import SwiftUI
import SystemMonitoring

@MainActor
final class SpriteMenuBar {
    private var items: [UUID: SpriteMenuItem] = [:]
    private var order: [UUID] = []
    private unowned let store: MonitoringStore
    private unowned let power: PowerStore
    private let showPower: () -> Void
    private let openEditor: (SpriteConfiguration) -> Void
    /// Opens the AI Accounts board for sprites made only of AI usage readings, anchored to the clicked item.
    var openAccounts: ((NSRect?, NSWindow?) -> Void)?
    init(store: MonitoringStore, power: PowerStore, showPower: @escaping () -> Void, openEditor: @escaping (SpriteConfiguration) -> Void) {
        self.store = store; self.power = power; self.showPower = showPower; self.openEditor = openEditor
        store.changed = { [weak self] in self?.update() }
        update()
    }
    var itemCount: Int { items.count }
    func readoutForValidation(_ id: UUID) -> (image: NSImage?, title: String, frame: NSRect?)? {
        guard let button = items[id]?.item.button else { return nil }
        return (button.image, button.attributedTitle.string,
                button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) })
    }
    func openBoardForValidation(_ id: UUID) -> NSView? {
        toggleBoard(id)
    }
    func toggleBoard(_ id: UUID) -> NSView? {
        guard let item = items[id] else { return nil }
        item.showBoard()
        return item.boardView
    }
    func memoryBoardStoreForValidation(_ id: UUID) -> MemoryBoardStore? { items[id]?.memoryStore }
    func energyBoardForValidation(_ id: UUID) -> EnergyBoardController? { items[id]?.energyController }
    func closePresentedBoard() -> Bool {
        for item in items.values where item.hasVisibleMemoryPanel { item.closeBoard(); return true }
        return false
    }
    func closeBoardsForValidation() { for item in items.values { item.closeBoard() } }
    func update() {
        let visible = store.sprites.filter(\.showInMenuBar)
        let ids = visible.map(\.id)
        if ids != order {
            for item in items.values { item.remove() }
            items = [:]
            // Status items grow leftward from the main icon; reverse creation preserves
            // the user's left-to-right configuration order within this app's items.
            for config in visible.reversed() {
                items[config.id] = SpriteMenuItem(config: config, store: store, power: power, showPower: showPower, openEditor: openEditor,
                                                  openAccounts: { [weak self] anchor, window in self?.openAccounts?(anchor, window) })
            }
            order = ids
        }
        for config in visible { items[config.id]?.update(config) }
    }
    func removeAll() { for item in items.values { item.remove() }; items = [:]; order = []; store.changed = nil }
}

@MainActor
private final class SpriteMenuItem: NSObject, NSPopoverDelegate, NSWindowDelegate {
    let item: NSStatusItem
    private var config: SpriteConfiguration
    private unowned let store: MonitoringStore
    private unowned let power: PowerStore
    private let showPower: () -> Void
    private let openEditor: (SpriteConfiguration) -> Void
    private let openAccounts: (NSRect?, NSWindow?) -> Void
    private var popover: NSPopover?
    private var memoryPanel: MemoryPanel?
    private var panelEventMonitors: [Any] = []
    private var panelObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var memoryStore: MemoryBoardStore?
    private(set) var energyController: EnergyBoardController?
    private var renderedSignature = ""
    private var lastSymbol = ""
    private var lastRenderTime = 0.0

    init(config: SpriteConfiguration, store: MonitoringStore, power: PowerStore, showPower: @escaping () -> Void, openEditor: @escaping (SpriteConfiguration) -> Void,
         openAccounts: @escaping (NSRect?, NSWindow?) -> Void) {
        self.config = config; self.store = store; self.power = power; self.showPower = showPower; self.openEditor = openEditor
        self.openAccounts = openAccounts
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "MonitorSprite-\(config.id.uuidString)"
        item.button?.target = self
        item.button?.action = #selector(showBoard)
        update(config)
    }
    func update(_ config: SpriteConfiguration) {
        let configurationChanged = self.config != config
        self.config = config
        guard let button = item.button else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard configurationChanged || now - lastRenderTime >= config.interval else { return }
        let text = store.menuText(config)
        let columns = store.menuColumns(config)
        let signature = "\(text)|\(config.fontSize)|\(config.bold)|\(config.colorHex)|\(config.iconColorHex)|\(config.symbol)|\(config.name)|\(config.layout.rawValue)|\(config.showLabels)|\(config.enabled)|\(config.showIcon)|\(config.colorRule.rawValue)|\(columns.map { $0.colorHex ?? "" })"
        guard signature != renderedSignature else { return }
        renderedSignature = signature
        lastRenderTime = now
        if config.enabled {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = StackedReadout.image(columns: columns, config: config, height: NSStatusBar.system.thickness)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            lastSymbol = ""
        } else {
            if !config.showIcon {
                button.image = nil; button.imagePosition = .noImage; lastSymbol = ""
            } else if lastSymbol != config.symbol {
                let image = NSImage(systemSymbolName: config.symbol, accessibilityDescription: config.name)
                    ?? NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: config.name)
                image?.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeft
                button.imageScaling = .scaleProportionallyDown
                lastSymbol = config.symbol
            }
            let title = NSMutableAttributedString(string: config.showIcon ? " " : "")
            title.append(StackedReadout.attributedText(columns: columns, config: config))
            button.attributedTitle = title
        }
        button.toolTip = "\(config.name) — \(config.enabled ? (config.opensAccountsBoard ? "click for AI accounts" : "click for readings") : "paused")"
        button.setAccessibilityLabel("\(config.name): \(text)")
    }
    var hasVisibleMemoryPanel: Bool { memoryPanel?.isVisible == true }
    var boardView: NSView? {
        if memoryPanel?.isVisible == true { return memoryPanel?.contentViewController?.view }
        return popover?.isShown == true ? popover?.contentViewController?.view : nil
    }
    func closeBoard() {
        energyController?.stop()
        memoryStore?.stop()
        store.closeBoard(config.id)
        popover?.performClose(nil)
        memoryPanel?.close()
    }
    @objc func showBoard() {
        if popover?.isShown == true || memoryPanel?.isVisible == true { closeBoard(); return }
        guard let button = item.button else { return }
        let configure: () -> Void = { [weak self] in
            guard let self else { return }
            self.closeBoard()
            self.openEditor(self.config)
        }
        if config.opensAccountsBoard {
            let window = button.window
            openAccounts(window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }, window)
            return
        }
        if config.processPanelKind != nil {
            showMemoryPanel(button: button, configure: configure)
            return
        }
        let board = NSPopover()
        board.behavior = .transient
        board.delegate = self
        board.contentSize = NSSize(width: 370, height: min(660, 145 + 102 * config.metricIDs.count))
        board.contentViewController = NSHostingController(rootView: SpriteBoard(store: store, id: config.id, configure: configure))
        popover = board
        store.openBoard(config.id)
        board.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    private func showMemoryPanel(button: NSStatusBarButton, configure: @escaping () -> Void) {
        let buttonWindow = button.window
        let screen = buttonWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 850)
        // macOS can temporarily hide a status-item window when the bar is full.
        // The app-menu entry still opens its dashboard at the screen's top right.
        let anchor = buttonWindow.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
            ?? NSRect(x: visible.maxX - 20, y: visible.maxY + 6, width: 1, height: 1)
        let isEnergy = config.processPanelKind == .power
        let height = max(400, min(isEnergy ? 850 : 780, visible.height - 20))
        let width: CGFloat = isEnergy ? 430 : 350
        let origin = NSPoint(x: min(max(anchor.midX - width / 2, visible.minX + 8), visible.maxX - width - 8),
                             y: max(visible.minY + 8, anchor.minY - height - 6))
        let panel = MemoryPanel(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "MenuSprite — \(config.processPanelKind?.title ?? "Readings")"
        panel.isOpaque = !isEnergy; panel.backgroundColor = isEnergy ? .clear : .windowBackgroundColor
        panel.level = .popUpMenu; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.animationBehavior = isEnergy ? .utilityWindow : .none
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.dismiss = { [weak self] in self?.closeBoard() }
        panel.delegate = self
        let memory = MemoryBoardStore(kind: config.processPanelKind ?? .memory); memoryStore = memory
        if isEnergy {
            let energy = EnergyBoardController(monitoring: store, processes: memory, power: power, id: config.id,
                configure: configure, showPower: showPower, close: { [weak self] in self?.closeBoard() })
            energyController = energy; panel.contentViewController = energy
        } else {
            panel.contentViewController = MemoryBoardController(monitoring: store, processes: memory, id: config.id,
                configure: configure, close: { [weak self] in self?.closeBoard() })
        }
        memoryPanel = panel; store.openBoard(config.id)
        if config.enabled { memory.start() }
        panel.makeKeyAndOrderFront(nil)
        // The explicit measurement run keeps its window visible while the user
        // works in other apps. Normal popovers still dismiss on outside events.
        if CommandLine.arguments.contains("--energy-validate") || CommandLine.arguments.contains("--memory-validate") { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closeBoard() }
        }) { panelEventMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.memoryPanel, event.window !== self.item.button?.window { self.closeBoard() }
            }
            return event
        }) { panelEventMonitors.append(local) }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    if let activatedPID {
                        if activatedPID == ProcessInfo.processInfo.processIdentifier { return }
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier != activatedPID { return }
                    }
                    self?.closeBoard()
                }
            }
            panelObservers.append((workspace, observer))
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === memoryPanel else { return }
        energyController?.stop(); energyController = nil
        memoryStore?.stop(); memoryStore = nil; store.closeBoard(config.id)
        for monitor in panelEventMonitors { NSEvent.removeMonitor(monitor) }; panelEventMonitors = []
        for (center, observer) in panelObservers { center.removeObserver(observer) }; panelObservers = []
        memoryPanel?.contentViewController = nil; memoryPanel?.delegate = nil; memoryPanel?.dismiss = nil; memoryPanel = nil
    }
    func popoverWillClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        memoryStore?.stop()
        store.closeBoard(config.id)
    }
    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover else { return }
        memoryStore?.stop(); memoryStore = nil
        store.closeBoard(config.id)
        popover?.contentViewController = nil
        popover?.delegate = nil
        popover = nil
    }
    func remove() {
        closeBoard(); store.closeBoard(config.id)
        memoryStore?.stop(); memoryStore = nil
        popover?.contentViewController = nil; popover?.delegate = nil; popover = nil
        item.button?.target = nil
        NSStatusBar.system.removeStatusItem(item)
    }
}

private struct SpriteBoard: View {
    @ObservedObject var store: MonitoringStore
    let id: UUID
    let configure: () -> Void
    private var config: SpriteConfiguration? { store.sprites.first { $0.id == id } }
    var body: some View {
        if let config {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(config.name, systemImage: config.symbol).font(.headline)
                    Spacer()
                    Button("Configure…", action: configure).controlSize(.small)
                }
                if !config.enabled {
                    Text("This sprite is paused.").foregroundStyle(.secondary)
                    Button("Enable sprite") { store.setEnabled(id, true) }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(config.metricIDs, id: \.self) { metricID in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(store.metric(metricID).name).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(store.display(metricID, config: config)).font(.system(size: 16, weight: .medium, design: .rounded))
                                    }
                                    if store.metric(metricID).unit != .text {
                                        Sparkline(points: store.history[metricID] ?? [], percent: store.metric(metricID).unit == .percent)
                                            .stroke(spriteColor(config.colorHex), lineWidth: 1.5).frame(height: 35)
                                    }
                                    if let reading = store.readings[metricID] {
                                        Text(reading.issue ?? "Sampled \(reading.measuredAt.formatted(date: .omitted, time: .standard))")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                    HStack {
                        Text("Up to 60 samples · every \(Int(config.interval))s").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Pause") { store.setEnabled(id, false) }.controlSize(.small)
                    }
                }
            }.padding(17).frame(width: 370)
        }
    }
}

private struct Sparkline: Shape {
    let points: [HistoryPoint]
    let percent: Bool
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

@MainActor
private final class MemoryPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}
