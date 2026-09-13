import AIAccounts
import AppKit
import SwiftUI
import SystemMonitoring

@main
struct MenuSpriteMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var powerStore: PowerStore!
    private(set) var powerWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private(set) var settingsWindow: NSWindow?
    private(set) var permissionStore: PermissionStore?
    private var activationObserver: NSObjectProtocol?
    private var validation: NativeValidation?
    private(set) var monitoringWindow: NSWindow?
    private(set) var monitoringStore: MonitoringStore!
    private(set) var spriteMenuBar: SpriteMenuBar?
    private(set) var accountsStore: AccountsStore?
    private var accountsPanel: AccountsPanelController?
    private(set) var workWindow: NSWindow?
    private(set) var workStore: WorkStore?
    private var monitoringValidation: MonitoringValidation?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var headlessMeasurementActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        headlessMeasurementActive = arguments.contains("--monitor-measure") || arguments.contains("--power-validate") || arguments.contains("--memory-validate") || arguments.contains("--process-panels-validate") || arguments.contains("--readouts-validate") || arguments.contains("--release-validate") || arguments.contains("--energy-validate") || arguments.contains("--usage-validate")
        let monitoringValidationIndex = arguments.firstIndex(where: { $0 == "--monitor-validate" || $0 == "--monitor-measure" })
        let evidenceDirectory = monitoringValidationIndex.flatMap { index in arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]) : nil }
        let releaseIndex = arguments.firstIndex(of: "--release-validate")
        let releaseDirectory = releaseIndex.flatMap { index in arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]) : nil }
        let energyIndex = arguments.firstIndex(of: "--energy-validate")
        let energyDirectory = energyIndex.flatMap { index in arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]) : nil }
        // Validation and measurement launches do no background credential or log work: a spend scan
        // reads gigabytes of session logs, which would swamp the very measurements being taken.
        let backgroundWork = !arguments.contains { $0.hasPrefix("--") && ($0.hasSuffix("-validate") || $0.hasSuffix("-measure")) }
        monitoringStore = MonitoringStore(configurationURL: (releaseDirectory ?? energyDirectory ?? evidenceDirectory)?.appendingPathComponent("test-config.json"),
                                          spend: backgroundWork ? SpendService.shared : nil)
        let releasePreferences = (releaseDirectory ?? energyDirectory).map { _ in UserDefaults(suiteName: "MenuSprite.ReleaseValidation.\(UUID().uuidString)")! }
        powerStore = PowerStore(preferences: releasePreferences ?? .standard)
        installMenus()
        spriteMenuBar = SpriteMenuBar(store: monitoringStore, power: powerStore, showPower: { [weak self] in self?.showPower() }) { [weak self] config in
            self?.showMonitoring()
            self?.monitoringStore.edit(config)
        }
        let accounts = AccountsStore(switcher: AccountSwitcher(usage: UsageService.shared, http: URLSessionTransport()),
                                     usage: UsageService.shared,
                                     spend: backgroundWork ? SpendService.shared : nil) { [weak self] _ in
            self?.monitoringStore.refresh()
        }
        accountsStore = accounts
        accountsPanel = AccountsPanelController(store: accounts)
        spriteMenuBar?.openAccounts = { [weak self] anchor, window in self?.accountsPanel?.toggle(anchor: anchor, anchorWindow: window) }
        if backgroundWork {
            accounts.startAutoSwitchMonitor()
        }
        if evidenceDirectory == nil { monitoringStore.start() }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitoringStore.suspend() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitoringStore.resume() }
        })
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.settingsWindow?.isVisible == true { self.permissionStore?.refresh() }
                if self.monitoringWindow?.isVisible == true { self.monitoringStore.refresh() }
                if self.powerWindow?.isVisible == true { self.powerStore.refresh() }
            }
        }
        if let energyDirectory {
            EnergyValidation(app: self, directory: energyDirectory).start()
        } else if let releaseDirectory {
            ReleaseValidation(app:self,directory:releaseDirectory).start()
        } else if let index = arguments.firstIndex(of:"--usage-validate"), arguments.indices.contains(index+1) {
            UsageReadoutValidation.start(app: self, directory: URL(fileURLWithPath: arguments[index+1]))
        } else if let index = arguments.firstIndex(of:"--readouts-validate"), arguments.indices.contains(index+1) {
            ReadoutValidation(app:self,directory:URL(fileURLWithPath:arguments[index+1])).start()
        } else if let index = arguments.firstIndex(of:"--process-panels-validate"), arguments.indices.contains(index+1) {
            ProcessPanelValidation(app:self,directory:URL(fileURLWithPath:arguments[index+1])).start()
        } else if let index = arguments.firstIndex(of:"--memory-validate"), arguments.indices.contains(index+1) {
            MemoryValidation(app:self,directory:URL(fileURLWithPath:arguments[index+1])).start()
        } else if let index = arguments.firstIndex(of:"--power-ui-validate"), arguments.indices.contains(index+1) {
            PowerValidation(app:self,directory:URL(fileURLWithPath:arguments[index+1])).startUI()
        } else if let index = arguments.firstIndex(of:"--power-validate"), arguments.indices.contains(index+1) {
            PowerValidation(app:self,directory:URL(fileURLWithPath:arguments[index+1])).start()
        } else if let evidenceDirectory {
            let runner = MonitoringValidation(app: self, directory: evidenceDirectory, measurementsOnly: arguments.contains("--monitor-measure"))
            monitoringValidation = runner
            runner.start()
        } else if let index = arguments.firstIndex(where: { $0 == "--validate" || $0 == "--measure" }), arguments.indices.contains(index + 1) {
            let runner = NativeValidation(app: self, directory: URL(fileURLWithPath: arguments[index + 1]), measurementsOnly: arguments[index] == "--measure")
            validation = runner
            runner.start()
        } else if let index = arguments.firstIndex(of: "--work-validate"), arguments.indices.contains(index + 1), !BuildFeatures.publicPreview {
            WorkValidation(app: self, directory: URL(fileURLWithPath: arguments[index + 1])).start()
        } else if arguments.contains("--show-work"), !BuildFeatures.publicPreview {
            showWork()
        } else if arguments.contains("--show-accounts") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showAccounts() }
        } else if arguments.contains("--show-energy") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showEnergy() }
        } else if !arguments.contains("--background") && !launchedAtLogin {
            showMonitoring()
        }
    }

    private var launchedAtLogin: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private func installMenus() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "MenuSprite")
        applicationMenu.addItem(menuItem("Monitoring & Sprites…", #selector(showMonitoring), ","))
        applicationMenu.addItem(menuItem("Battery & Power…", #selector(showEnergy), "b"))
        applicationMenu.addItem(menuItem("AI Accounts…", #selector(showAccounts), ""))
        if !BuildFeatures.publicPreview { applicationMenu.addItem(menuItem("Work & Clients…", #selector(showWork), "t")) }
        applicationMenu.addItem(menuItem(BuildFeatures.powerPageTitle + "…", #selector(showPower), "p"))
        applicationMenu.addItem(menuItem("Permissions & Access…", #selector(showSettings), ""))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(menuItem("Quit MenuSprite", #selector(quit), "q"))
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(menuItem("Close", #selector(closeFrontWindow), "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu

        let icon = NSImage(named: "MenuBarIcon")
        let iconHeight = max(18, NSStatusBar.system.thickness - 2)
        let aspectRatio = icon.map { $0.size.width / max(1, $0.size.height) } ?? 1.5
        let iconWidth = ceil(iconHeight * aspectRatio)
        let item = NSStatusBar.system.statusItem(withLength: iconWidth + 6)
        if let button = item.button {
            icon?.size = NSSize(width: iconWidth, height: iconHeight)
            button.image = icon
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "MenuSprite"
            button.setAccessibilityLabel("MenuSprite")
        }
        let menu = NSMenu()
        let title = NSMenuItem(title: "MenuSprite", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(menuItem("Monitoring & Sprites…", #selector(showMonitoring), ","))
        menu.addItem(menuItem("Battery & Power…", #selector(showEnergy), "b"))
        menu.addItem(menuItem("AI Accounts…", #selector(showAccounts), ""))
        if !BuildFeatures.publicPreview { menu.addItem(menuItem("Work & Clients…", #selector(showWork), "t")) }
        menu.addItem(menuItem(BuildFeatures.powerPageTitle + "…", #selector(showPower), "p"))
        menu.addItem(menuItem("Permissions & Access…", #selector(showSettings), ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit MenuSprite", #selector(quit), "q"))
        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc func showSettings() {
        guard !headlessMeasurementActive else { return }
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            permissionStore?.refresh()
            return
        }
        let store = PermissionStore()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MenuSprite"
        window.minSize = NSSize(width: 870, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: PermissionsView(store: store))
        window.setFrameAutosaveName("PermissionsAndAccess")
        window.center()
        settingsWindow = window
        permissionStore = store
        store.opened()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showMonitoring() {
        guard !headlessMeasurementActive else { return }
        if let window = monitoringWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            monitoringStore.refresh()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 810),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MenuSprite — Monitoring & Sprites"
        window.minSize = NSSize(width: 900, height: 650)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MonitoringView(store: monitoringStore, showPower: { [weak self] in self?.showPower() }, showWork: { [weak self] in self?.showWork() }, showPermissions: { [weak self] in self?.showSettings() }))
        window.setFrameAutosaveName("MonitoringAndSprites")
        window.center()
        monitoringWindow = window
        monitoringStore.setLibraryOpen(true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showWork() { openWork() }
    func openWork(preferencesURL: URL? = nil) {
        guard !BuildFeatures.publicPreview, !headlessMeasurementActive else { return }
        if let workWindow { workWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let store = preferencesURL.map { WorkStore(preferencesURL: $0) } ?? WorkStore()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 850),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MenuSprite — Work & Clients"
        window.minSize = NSSize(width: 1010, height: 700)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: WorkBoard(store: store))
        window.setFrameAutosaveName("WorkAndClients"); window.center()
        workStore = store; workWindow = window; store.opened()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showEnergy() {
        guard !headlessMeasurementActive else { return }
        if let sprite = monitoringStore.sprites.first(where: { $0.processPanelKind == .power && $0.showInMenuBar }) {
            // Present after the app menu finishes tracking, so its dismissal
            // event cannot immediately dismiss the new transient dashboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in _ = self?.spriteMenuBar?.toggleBoard(sprite.id) }
        } else {
            showMonitoring(); monitoringStore.notice = "Add a System power sprite and show it in the menu bar to open Battery & Power."
        }
    }
    @objc func showAccounts() {
        guard !headlessMeasurementActive else { return }
        // Present after the menu finishes tracking, so its dismissal event cannot close the new board.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let panel = accountsPanel else { return }
            let button = statusItem?.button
            let window = button?.window
            let anchor = button.flatMap { button in window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } }
            panel.show(anchor: anchor, anchorWindow: window)
        }
    }
    @objc func showPower() {
        guard !headlessMeasurementActive else { return }
        if let powerWindow { powerWindow.makeKeyAndOrderFront(nil); powerStore.opened(); NSApp.activate(ignoringOtherApps:true); return }
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:970,height:880),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "MenuSprite — " + BuildFeatures.powerPageTitle
        window.minSize = NSSize(width:850,height:650); window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView:PowerView(store:powerStore,showPermissions:{ [weak self] in self?.showSettings() }))
        window.setFrameAutosaveName("PowerControls"); window.center(); powerWindow = window
        powerStore.opened(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    @objc func closeMonitoring() { monitoringWindow?.close() }
    @objc func closeSettings() { settingsWindow?.close() }
    @objc func closeFrontWindow() {
        if NSApp.keyWindow === workWindow { workWindow?.close(); return }
        if accountsPanel?.isVisible == true { accountsPanel?.close(); return }
        if spriteMenuBar?.closePresentedBoard() == true { return }
        if NSApp.keyWindow === powerWindow { powerWindow?.close() }
        else if NSApp.keyWindow === settingsWindow { closeSettings() }
        else { closeMonitoring() }
    }
    @objc func quit() { NSApp.terminate(nil) }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === workWindow {
            workStore?.closed(); workWindow?.contentView = nil; workWindow?.delegate = nil
            workWindow = nil; workStore = nil; return
        }
        if let closing = notification.object as? NSWindow, closing === monitoringWindow {
            monitoringStore.setLibraryOpen(false)
            monitoringWindow?.contentView = nil
            monitoringWindow?.delegate = nil
            monitoringWindow = nil
            return
        }
        if let closing = notification.object as? NSWindow, closing === powerWindow {
            powerStore.closed(); powerWindow?.contentView = nil; powerWindow?.delegate = nil; powerWindow = nil; return
        }
        permissionStore?.closed()
        settingsWindow?.contentView = nil
        settingsWindow?.delegate = nil
        permissionStore = nil
        settingsWindow = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !headlessMeasurementActive else { return false }
        showMonitoring()
        return true
    }
    func finishHeadlessMeasurement() { headlessMeasurementActive = false }

    func applicationWillTerminate(_ notification: Notification) {
        permissionStore?.closed()
        powerStore.shutdown()
        accountsStore?.stop()
        accountsPanel?.close()
        workStore?.closed()
        spriteMenuBar?.removeAll()
        monitoringStore.stop()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
