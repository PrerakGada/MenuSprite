import AppKit
import SwiftUI
import SystemMonitoring

@MainActor
final class SpriteMenuBar {
    private var items: [UUID: SpriteMenuItem] = [:]
    private var order: [UUID] = []
    private var leftOrder: [UUID] = []
    /// Sprites Prerak moved left are drawn here, over the frontmost app's menus; nil while none are.
    private var strip: LeftStrip?
    private let placement = SpritePlacement.shared
    private unowned let store: MonitoringStore
    private unowned let power: PowerStore
    private let showPower: () -> Void
    private let openEditor: (SpriteConfiguration) -> Void
    /// Opens the AI Accounts board for sprites made only of AI usage readings, anchored to the clicked item.
    var openAccounts: ((NSRect?, NSWindow?) -> Void)?
    init(store: MonitoringStore, power: PowerStore, showPower: @escaping () -> Void, openEditor: @escaping (SpriteConfiguration) -> Void) {
        self.store = store; self.power = power; self.showPower = showPower; self.openEditor = openEditor
        store.changed = { [weak self] in self?.update() }
        placement.changed = { [weak self] in self?.update() }
        update()
    }
    var itemCount: Int { items.count }
    func readoutForValidation(_ id: UUID) -> (image: NSImage?, title: String, frame: NSRect?)? {
        guard let button = items[id]?.button else { return nil }
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
    /// The exact menu a secondary click would show, built without popping it.
    func contextMenuForValidation(_ id: UUID) -> NSMenu? { items[id]?.buildContextMenu() }
    func energyBoardForValidation(_ id: UUID) -> EnergyBoardController? { items[id]?.energyController }
    func closePresentedBoard() -> Bool {
        for item in items.values where item.hasVisibleMemoryPanel { item.closeBoard(); return true }
        return false
    }
    func closeBoardsForValidation() { for item in items.values { item.closeBoard() } }
    func update() {
        let visible = store.sprites.filter(\.showInMenuBar)
        let ids = visible.map(\.id)
        let left = ids.filter(placement.isLeft)
        let right = ids.filter { !placement.isLeft($0) }
        if left != leftOrder, Set(left) == Set(leftOrder), right == order.filter({ !leftOrder.contains($0) }) {
            // Only the strip's order changed (a sprite was dragged): re-arrange it, leave the right side be.
            strip?.arrange(left.compactMap { id in items[id].map { (id, $0.button) } })
            order = ids; leftOrder = left
        }
        if ids != order || left != leftOrder {
            for item in items.values { item.remove() }
            items = [:]
            if left.isEmpty { strip?.tearDown(); strip = nil } else if strip == nil {
                let created = LeftStrip()
                created.reorder = { [weak self] ids in self?.store.reorder(ids) }
                strip = created
            }
            // Status items grow leftward from the main icon; reverse creation preserves
            // the user's left-to-right configuration order within this app's items.
            for config in visible.reversed() {
                items[config.id] = SpriteMenuItem(config: config, strip: placement.isLeft(config.id) ? strip : nil,
                                                  store: store, power: power, showPower: showPower, openEditor: openEditor,
                                                  openAccounts: { [weak self] anchor, window in self?.openAccounts?(anchor, window) })
            }
            strip?.arrange(left.compactMap { id in items[id].map { (id, $0.button) } })
            order = ids; leftOrder = left
        }
        for config in visible { items[config.id]?.update(config) }
        strip?.relayout()
    }
    func removeAll() {
        for item in items.values { item.remove() }
        items = [:]; order = []; leftOrder = []
        strip?.tearDown(); strip = nil
        store.changed = nil; placement.changed = nil
    }
}

@MainActor
private final class SpriteMenuItem: NSObject, NSPopoverDelegate, NSWindowDelegate {
    /// The right-side status item, or nil for a sprite on the left strip.
    let item: NSStatusItem?
    /// Where the sprite is drawn and clicked: the status item's button, or its button on the strip.
    let button: NSButton
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
    private var reservedWidths: [CGFloat] = []
    private var reservedSince: [Double] = []
    /// A designed sprite's reserved text widths, by node.
    private var designReserved: [String: CGFloat] = [:]
    private var designReservedSince: [String: Double] = [:]
    /// A width kept for a value that no longer needs it is given up after this long, so one 100%
    /// reading does not hold an extra digit for the rest of the day.
    private static let reserveLifetime: Double = 90
    private var lastSymbol = ""
    private var contextMenu: SpriteContextMenu?
    private var lastRenderTime = 0.0

    init(config: SpriteConfiguration, strip: LeftStrip?, store: MonitoringStore, power: PowerStore, showPower: @escaping () -> Void,
         openEditor: @escaping (SpriteConfiguration) -> Void, openAccounts: @escaping (NSRect?, NSWindow?) -> Void) {
        self.config = config; self.store = store; self.power = power; self.showPower = showPower; self.openEditor = openEditor
        self.openAccounts = openAccounts
        if let strip {
            item = nil; button = strip.makeButton()
        } else {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item = statusItem; button = statusItem.button ?? NSButton()
        }
        super.init()
        item?.autosaveName = "MonitorSprite-\(config.id.uuidString)"
        button.target = self
        button.action = #selector(clicked)
        // Secondary click opens the sprite menu; on a battery item it switches Low Power Mode
        // instead, and control-click (or option-right-click) opens the charge-control menu.
        // Primary click keeps opening the board.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        update(config)
        // macOS posts this when Low Power Mode changes, from any thread and from any cause.
        powerStateObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.config.isBatteryItem else { return }; self.redraw() }
        }
    }
    private var powerStateObserver: NSObjectProtocol?
    /// Draw now rather than at the next refresh interval.
    private func redraw() { lastRenderTime = 0; update(config) }
    func update(_ config: SpriteConfiguration) {
        let configurationChanged = self.config != config
        self.config = config
        let now = ProcessInfo.processInfo.systemUptime
        guard configurationChanged || now - lastRenderTime >= config.interval else { return }
        if config.enabled, config.design != nil { drawDesign(config, button: button, configurationChanged: configurationChanged, now: now); return }
        let text = store.menuText(config)
        let columns = store.menuColumns(config)
        // The ceiling is drawn only while the hardware is actually being limited, so the
        // tick reports the control rather than the saved intention.
        let icon: ReadoutIcon = config.isBatteryItem
            ? .battery(store.batteryGlyph(ceiling: power.activeCeiling, for: config))
            : .symbol(config.symbol)
        let signature = "\(text)|\(config.fontSize)|\(config.bold)|\(config.colorHex)|\(config.iconColorHex)|\(config.symbol)|\(config.name)|\(config.layout.rawValue)|\(config.showLabels)|\(config.enabled)|\(config.showIcon)|\(config.colorRule.rawValue)|\(config.batteryPercentPlacement.rawValue)|\(columns.map { $0.colorHex ?? "" })|\(icon)"
        guard signature != renderedSignature else { return }
        renderedSignature = signature
        lastRenderTime = now
        if config.enabled {
            button.attributedTitle = NSAttributedString(string: "")
            // A column keeps the widest width it has needed lately, so a value crossing a digit
            // boundary does not shuffle the menu bar every second. A configuration change starts
            // afresh, and a width nothing needs any more lapses after `reserveLifetime`.
            let height = NSStatusBar.system.thickness
            let natural = StackedReadout.layout(columns: columns, config: config, height: height, icon: icon).valueWidths
            if configurationChanged || reservedWidths.count != natural.count {
                reservedWidths = natural
                reservedSince = natural.map { _ in now }
            }
            for index in natural.indices where natural[index] >= reservedWidths[index] || now - reservedSince[index] > Self.reserveLifetime {
                reservedWidths[index] = natural[index]
                reservedSince[index] = now
            }
            button.image = StackedReadout.image(columns: columns, config: config, height: height, icon: icon, reserved: reservedWidths)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            lastSymbol = ""
        } else {
            if !config.showIcon {
                button.image = nil; button.imagePosition = .noImage; lastSymbol = ""
            } else if case .battery(let glyph) = icon {
                let height = NSStatusBar.system.thickness
                let size = NSSize(width: BatteryGlyph.width(forHeight: 14), height: height)
                let drawn = NSImage(size: size, flipped: false) { rect in
                    glyph.draw(in: rect, ink: .black); return true
                }
                drawn.isTemplate = !glyph.forcesColor
                button.image = drawn; button.imagePosition = .imageLeft; lastSymbol = ""
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
        if config.isBatteryItem, case .battery(let glyph) = icon {
            button.toolTip = "\(glyph.summary) · \(power.limitStatus)\nClick for Battery & Power · right-click toggles Low Power Mode · control-click for charge controls"
        } else {
            button.toolTip = "\(config.name) — \(config.enabled ? (config.opensAccountsBoard ? "click for AI accounts" : "click for readings") : "paused")"
        }
        button.setAccessibilityLabel("\(config.name): \(text)")
    }
    /// A designed sprite: its tree drawn by `DesignRenderer`. Each text keeps the widest slot it has
    /// needed lately, like the column reservation above, so values crossing a digit do not shuffle the bar.
    private func drawDesign(_ config: SpriteConfiguration, button: NSButton, configurationChanged: Bool, now: Double) {
        if configurationChanged { designReserved = [:]; designReservedSince = [:] }
        guard let natural = store.renderDesign(config, ceiling: power.activeCeiling) else { return }
        for (id, width) in natural.slotWidths
        where width >= (designReserved[id] ?? 0) || now - (designReservedSince[id] ?? 0) > Self.reserveLifetime {
            designReserved[id] = width; designReservedSince[id] = now
        }
        guard let output = store.renderDesign(config, reserved: designReserved, ceiling: power.activeCeiling) else { return }
        let signature = "\(config.name)|\(output.signature)|\(Int(output.size.width))|\(output.isTemplate)"
        lastRenderTime = now
        guard signature != renderedSignature else { return }
        renderedSignature = signature
        button.attributedTitle = NSAttributedString(string: "")
        button.image = output.image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        lastSymbol = ""
        if config.isBatteryItem {
            let glyph = store.batteryGlyph(ceiling: power.activeCeiling)
            button.toolTip = "\(glyph.summary) · \(power.limitStatus)\nClick for Battery & Power · right-click toggles Low Power Mode · control-click for charge controls"
        } else {
            button.toolTip = "\(config.name) — \(config.opensAccountsBoard ? "click for AI accounts" : "click for readings")"
        }
        button.setAccessibilityLabel("\(config.name): \(output.accessibilityText)")
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
    @objc private func clicked() {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp
        let modified = event?.modifierFlags.contains(.control) == true || event?.modifierFlags.contains(.option) == true
        if secondary, !modified, config.isBatteryItem { power.toggleLowPower(); return }
        if secondary || event?.modifierFlags.contains(.control) == true { showMenu(); return }
        showBoard()
    }
    func buildContextMenu() -> NSMenu {
        let controller = contextMenu ?? SpriteContextMenu(power: power, store: store, config: config,
            openDashboard: { [weak self] in self?.showBoard() },
            configure: { [weak self] in guard let self else { return }; self.openEditor(self.config) })
        contextMenu = controller
        return controller.menu(for: config)
    }
    private func showMenu() {
        closeBoard()
        if config.isBatteryItem { power.refreshBatteryStatus() }
        guard let item else {
            buildContextMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 5 : -5), in: button)
            return
        }
        // NSStatusItem only pops a menu it owns; attach it for this click and take it back after.
        item.menu = buildContextMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }
    @objc func showBoard() {
        if popover?.isShown == true || memoryPanel?.isVisible == true { closeBoard(); return }
        let configure: () -> Void = { [weak self] in
            guard let self else { return }
            self.closeBoard()
            self.openEditor(self.config)
        }
        if config.design?.board != nil {
            showCustomBoard(button: button, configure: configure)
            return
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
        if config.opensFanBoard {
            let board = NSPopover()
            board.behavior = .transient
            board.delegate = self
            let host = NSHostingController(rootView: FanBoard(store: store, power: power, id: config.id, configure: configure))
            host.sizingOptions = [.preferredContentSize]
            board.contentViewController = host
            popover = board
            store.openBoard(config.id)
            board.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if item == nil { installDismissal() }
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
        if item == nil { installDismissal() }
    }
    /// The sprite's own board, designed in the studio, in a popover that fits its content.
    private func showCustomBoard(button: NSButton, configure: @escaping () -> Void) {
        let board = NSPopover()
        board.behavior = .transient
        board.delegate = self
        let host = NSHostingController(rootView: CustomBoardPanel(store: store, power: power, id: config.id, configure: configure))
        host.sizingOptions = [.preferredContentSize]
        board.contentViewController = host
        popover = board
        store.openBoard(config.id)
        board.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if item == nil { installDismissal() }
    }
    private func showMemoryPanel(button: NSButton, configure: @escaping () -> Void) {
        let buttonWindow = button.window
        let screen = buttonWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 850)
        // macOS can temporarily hide a status-item window when the bar is full.
        // The app-menu entry still opens its dashboard at the screen's top right.
        let anchor = buttonWindow.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
            ?? NSRect(x: visible.maxX - 20, y: visible.maxY + 6, width: 1, height: 1)
        let isEnergy = config.processPanelKind == .power
        let height = max(400, min(isEnergy ? 850 : 780, visible.height - 20))
        let width: CGFloat = isEnergy ? EnergyDocumentView.preferredWidth : 400
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
        panel.reload = { [weak self, weak memory] in guard let self else { return }; self.store.refresh(); if self.config.enabled { memory?.refresh() } }
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
        installDismissal()
    }
    /// A click on the sprite's own button toggles its board, so outside-click dismissal leaves it alone.
    /// On the strip that is the button alone; the strip's other sprites count as outside.
    private var pointerIsOverAnchor: Bool {
        guard item == nil else { return PanelAnchor.pointerIsOver(button.window) }
        guard let window = button.window, window.isVisible else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }
    /// The open board's window: a process panel, or a popover opened from the strip.
    private var boardWindow: NSWindow? { memoryPanel ?? popover?.contentViewController?.view.window }
    /// Closes the board on a click elsewhere or when another app comes forward. A popover from a status
    /// item gets this from macOS; a panel, or a popover from the strip, does not.
    private func installDismissal() {
        removeDismissal()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !PanelInteraction.isSuspended, !self.pointerIsOverAnchor else { return }
                self.closeBoard()
            }
        }) { panelEventMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard !PanelInteraction.isSuspended else { return }
                if let self, event.window !== self.boardWindow, self.item == nil || event.window !== self.button.window,
                   !self.pointerIsOverAnchor { self.closeBoard() }
            }
            return event
        }) { panelEventMonitors.append(local) }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard !PanelInteraction.isSuspended else { return }
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
    private func removeDismissal() {
        for monitor in panelEventMonitors { NSEvent.removeMonitor(monitor) }; panelEventMonitors = []
        for (center, observer) in panelObservers { center.removeObserver(observer) }; panelObservers = []
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === memoryPanel else { return }
        energyController?.stop(); energyController = nil
        memoryStore?.stop(); memoryStore = nil; store.closeBoard(config.id)
        removeDismissal()
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
        if memoryPanel == nil { removeDismissal() }
        popover?.contentViewController = nil
        popover?.delegate = nil
        popover = nil
    }
    func remove() {
        closeBoard(); store.closeBoard(config.id)
        memoryStore?.stop(); memoryStore = nil
        popover?.contentViewController = nil; popover?.delegate = nil; popover = nil
        removeDismissal()
        button.target = nil
        if let item { NSStatusBar.system.removeStatusItem(item) } else { button.removeFromSuperview() }
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
    var reload: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.isReloadShortcut, let reload { reload(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// A custom board as a popover: scrolls once it is taller than the screen allows.
private struct CustomBoardPanel: View {
    @ObservedObject var store: MonitoringStore
    let power: PowerStore
    let id: UUID
    let configure: () -> Void
    @State private var height: CGFloat = 200

    var body: some View {
        if let config = store.sprites.first(where: { $0.id == id }) {
            let width = config.design?.board?.width ?? 360
            let limit = (NSScreen.main?.visibleFrame.height ?? 900) - 80
            ScrollView {
                BoardView(config: config, environment: BoardEnvironment(monitoring: store, power: power), configure: configure)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .scrollDisabled(height <= limit)
            .frame(width: width, height: min(max(height, 60), limit))
        }
    }
}
