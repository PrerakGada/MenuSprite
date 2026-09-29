import AIAccounts
import AppKit
import SwiftUI
import SystemMonitoring

/// Every MenuSprite surface in one panel under the brand icon, instead of six menu entries each
/// opening a separate window. One tab is visible at a time and only that tab's readings are
/// requested, so the hub costs what a single board costs today rather than the sum of all of them.
enum HubTab: String, CaseIterable, Identifiable {
    case system, apps, network, disk, power, ai, sprites, work, tools
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .apps: "Apps"
        case .network: "Network"
        case .disk: "Disk"
        case .power: "Power"
        case .ai: "AI"
        case .sprites: "Sprites"
        case .work: "Work"
        case .tools: "Tools"
        }
    }
    var symbol: String {
        switch self {
        case .system: "cpu"
        case .apps: "square.grid.2x2"
        case .network: "globe"
        case .disk: "internaldrive"
        case .power: "bolt.fill"
        case .ai: "sparkles"
        case .sprites: "slider.horizontal.3"
        case .work: "briefcase"
        case .tools: "wrench.and.screwdriver"
        }
    }
    /// Readings this tab shows. The hub asks the shared sampler for exactly this set while the tab
    /// is visible; tabs whose content owns its own sampling (Power, AI, Apps) declare what their
    /// summary rows read and nothing more.
    var metricIDs: [String] {
        switch self {
        case .system:
            ["sensor.cpuTemperature", "sensor.gpuTemperature", "cpu.usage", "gpu.usage",
             "memory.usage", "memory.used", "memory.total", "memory.pressure", "memory.compressed",
             "memory.cached", "memory.swapUsed", "system.uptime", "system.thermal"]
        case .apps: ["cpu.usage", "memory.usage", "memory.used", "memory.total", "sensor.PSTR"]
        case .network:
            ["network.download", "network.upload", "network.received", "network.sent",
             "network.packetsIn", "network.packetsOut"]
        case .disk:
            ["disk.usage", "disk.used", "disk.free", "disk.total", "disk.available",
             "disk.read", "disk.write", "disk.readIOPS", "disk.writeIOPS"]
        case .power: ProcessPanelKind.power.metricIDs + ["sensor.fanSpeed", "sensor.cpuTemperature"]
        case .ai: []
        case .sprites: []
        case .work: []
        case .tools: ["sensor.fanSpeed", "sensor.cpuTemperature", "sensor.gpuTemperature", "system.thermal"]
        }
    }
    /// Each page gets the height its content needs, so a short tab is not a tall box with a gap in
    /// it. Clamped to the screen when the panel is placed.
    var preferredHeight: CGFloat {
        switch self {
        case .system: 620
        case .apps: 760
        case .network: 470
        case .disk: 600
        case .power: 820
        case .ai: 880
        case .sprites: 660
        case .work: 330
        case .tools: 540
        }
    }
    /// The Power page carries the power flow's category pills and the grouped apps list; the
    /// other pages keep the hub's usual width.
    var preferredWidth: CGFloat { self == .power ? EnergyDocumentView.preferredWidth : 480 }
    static var available: [HubTab] {
        allCases.filter { !(BuildFeatures.publicPreview && $0 == .work) }
    }
}

@MainActor
final class HubPanelController: NSObject, NSWindowDelegate {
    private let monitoring: MonitoringStore
    private let power: PowerStore
    private let accounts: AccountsStore
    private let actions: HubActions
    private var panel: HubPanel?
    private weak var anchorWindow: NSWindow?
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private let model: HubModel

    init(monitoring: MonitoringStore, power: PowerStore, accounts: AccountsStore, actions: HubActions) {
        self.monitoring = monitoring
        self.power = power
        self.accounts = accounts
        self.actions = actions
        model = HubModel(monitoring: monitoring, accounts: accounts)
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }
    var selectedTab: HubTab { model.tab }
    /// The hosted view, for validation runs.
    var contentView: NSView? { panel?.contentViewController?.view }
    var panelWindow: NSWindow? { panel }
    var processKind: ProcessPanelKind? { model.processes?.kind }

    func toggle(anchor: NSRect?, anchorWindow: NSWindow?, tab: HubTab? = nil) {
        if isVisible, tab == nil || tab == model.tab { close() }
        else { show(anchor: anchor, anchorWindow: anchorWindow, tab: tab) }
    }

    func show(anchor: NSRect?, anchorWindow: NSWindow?, tab: HubTab? = nil) {
        if let tab { model.select(tab) }
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        self.anchorWindow = anchorWindow
        let screen = anchorWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 900)
        let anchor = anchor ?? NSRect(x: visible.maxX - 20, y: visible.maxY + 6, width: 1, height: 1)
        let width = model.tab.preferredWidth
        let height = height(for: model.tab, on: visible)
        let origin = NSPoint(x: min(max(anchor.midX - width / 2, visible.minX + 8), visible.maxX - width - 8),
                             y: max(visible.minY + 8, anchor.minY - height - 6))
        let panel = HubPanel(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "MenuSprite"
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.dismiss = { [weak self] in self?.close() }
        panel.reload = { [weak self] in self?.model.refresh() }
        panel.delegate = self
        let hosting = NSHostingController(rootView: HubView(model: model, monitoring: monitoring, power: power,
                                                            accounts: accounts, actions: actions,
                                                            close: { [weak self] in self?.close() }))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: width, height: height))
        self.panel = panel
        model.tabChanged = { [weak self] tab in self?.resize(for: tab) }
        model.opened()
        panel.makeKeyAndOrderFront(nil)
        installDismissal()
    }

    func close() { panel?.close() }

    private func height(for tab: HubTab, on visible: NSRect) -> CGFloat {
        max(300, min(tab.preferredHeight, visible.height - 20))
    }

    /// Growing a tab keeps the panel pinned under the menu bar, the edge it is anchored to, and
    /// widens it about its centre (kept on screen) for the Power page.
    private func resize(for tab: HubTab) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let target = height(for: tab, on: visible), width = tab.preferredWidth
        var frame = panel.frame
        guard abs(frame.height - target) > 0.5 || abs(frame.width - width) > 0.5 else { return }
        frame.origin.y = max(visible.minY + 8, frame.maxY - target)
        frame.size.height = target
        frame.origin.x = min(max(frame.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        frame.size.width = width
        panel.setFrame(frame, display: true, animate: false)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors = []
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        model.tabChanged = nil
        model.closed()
        panel?.contentViewController = nil
        panel?.delegate = nil
        panel?.dismiss = nil
        panel?.reload = nil
        panel = nil
    }

    /// Same dismissal contract as the sprite boards: outside clicks, app switches, sleep and Space
    /// changes close it. Clicks on the brand status item are left to its own toggle.
    private func installDismissal() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !PanelInteraction.isSuspended, !PanelAnchor.pointerIsOver(self.anchorWindow) else { return }
                self.close()
            }
        }) { eventMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard !PanelInteraction.isSuspended else { return }
                if let self, event.window !== self.panel, event.window !== self.anchorWindow,
                   !PanelAnchor.pointerIsOver(self.anchorWindow) { self.close() }
            }
            return event
        }) { eventMonitors.append(local) }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard !PanelInteraction.isSuspended else { return }
                    if let activatedPID {
                        if activatedPID == ProcessInfo.processInfo.processIdentifier { return }
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier != activatedPID { return }
                    }
                    self?.close()
                }
            })
        }
    }
}

@MainActor
final class HubPanel: NSPanel {
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

/// What the hub can hand back to the app: the full windows that are too large for a panel.
struct HubActions {
    var openSprites: () -> Void = {}
    var openPermissions: () -> Void = {}
    var openPowerControls: () -> Void = {}
    var openWork: () -> Void = {}
    var openIsland: () -> Void = {}
    var editSprite: (SpriteConfiguration) -> Void = { _ in }
}

/// Owns the selected tab, the readings the hub asks for, and the per-tab process sampler. Keeping
/// this out of the SwiftUI view means switching tabs stops the old tab's sampling immediately.
@MainActor
final class HubModel: ObservableObject {
    @Published private(set) var tab: HubTab = .system
    @Published var appsKind: ProcessPanelKind = .cpu
    private unowned let monitoring: MonitoringStore
    private unowned let accounts: AccountsStore
    private var open = false
    private var accountsOpen = false
    /// Set by the panel controller so a tab change can resize the window to that page.
    var tabChanged: ((HubTab) -> Void)?
    /// Published: the panel is built before `opened()` runs, so the tab body has to be told when
    /// its process sampler appears.
    @Published private(set) var processes: MemoryBoardStore?
    private static let tabKey = "MenuSprite.HubTab"
    private static let appsKindKey = "MenuSprite.HubAppsKind"

    init(monitoring: MonitoringStore, accounts: AccountsStore) {
        self.monitoring = monitoring
        self.accounts = accounts
        if let saved = UserDefaults.standard.string(forKey: Self.tabKey),
           let restored = HubTab(rawValue: saved), HubTab.available.contains(restored) { tab = restored }
        if let saved = UserDefaults.standard.string(forKey: Self.appsKindKey),
           let restored = ProcessPanelKind(rawValue: saved) { appsKind = restored }
    }

    func select(_ tab: HubTab) {
        guard HubTab.available.contains(tab) else { return }
        guard tab != self.tab else { return }
        self.tab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey)
        applyDemand()
        tabChanged?(tab)
    }

    func selectAppsKind(_ kind: ProcessPanelKind) {
        guard kind != appsKind else { return }
        appsKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: Self.appsKindKey)
        applyDemand()
    }

    func opened() {
        open = true
        applyDemand()
    }

    func closed() {
        open = false
        processes?.stop()
        processes = nil
        if accountsOpen { accounts.closed(); accountsOpen = false }
        monitoring.setHubMetrics([])
    }

    func refresh() {
        monitoring.refresh()
        processes?.refresh()
        if accountsOpen { accounts.reload(force: true) }
    }

    /// Process ranking is expensive, so it runs only on the tabs that show it and stops the moment
    /// another tab is selected or the panel closes.
    private func applyDemand() {
        guard open else { return }
        let wantsProcesses: ProcessPanelKind? = tab == .apps ? appsKind : (tab == .power ? .power : nil)
        if processes?.kind != wantsProcesses {
            processes?.stop()
            processes = wantsProcesses.map { MemoryBoardStore(kind: $0) }
            processes?.start()
        }
        // The accounts board fetches from the providers, so it only runs while its tab is showing.
        let wantsAccounts = tab == .ai
        if wantsAccounts != accountsOpen {
            accountsOpen = wantsAccounts
            if wantsAccounts { accounts.opened() } else { accounts.closed() }
        }
        monitoring.setHubMetrics(Set(tab.metricIDs))
    }
}
