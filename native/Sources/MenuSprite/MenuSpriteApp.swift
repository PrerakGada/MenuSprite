import AgentProtocol
import AIAccounts
import AppKit
import Combine
import PowerControl
import SwiftUI
import SystemMonitoring

@main
struct MenuSpriteMain {
    @MainActor static func main() {
        // Diagnostic: where the power helper stands with macOS (SMAppService status), with no UI.
        if CommandLine.arguments.contains("--helper-status") {
            print("state \(PowerHelperInstall.state()) · SMAppService status \(PowerHelperInstall.service.status.rawValue) (0 notRegistered, 1 enabled, 2 requiresApproval, 3 notFound) · legacy \(PowerHelperInstall.legacyInstalled)")
            exit(0)
        }
        // Diagnostic: ask the installed power helper to write macOS's charge limit and print its
        // reply, with no UI. The helper serves one app connection at a time, so quit MenuSprite first.
        if let index = CommandLine.arguments.firstIndex(of: "--limit-set"), CommandLine.arguments.indices.contains(index + 1),
           let value = Int(CommandLine.arguments[index + 1]) {
            let connection = NSXPCConnection(machServiceName: PowerIdentity.service, options: .privileged)
            connection.setCodeSigningRequirement(PowerIdentity.helperRequirement)
            connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
            connection.resume()
            let done = DispatchSemaphore(value: 0)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); done.signal() } as? PowerHelperProtocol
            if let data = try? JSONEncoder().encode(PowerRequest(.chargeLimit, limit: value)) {
                proxy?.perform(data) { @Sendable reply in
                    let snapshot = try? JSONDecoder().decode(PowerSnapshot.self, from: reply)
                    FileHandle.standardError.write(Data("stored \(snapshot?.systemLimit.map(String.init) ?? "?") error \(snapshot?.error ?? "none")\n".utf8)); done.signal()
                }
            }
            _ = done.wait(timeout: .now() + 10); connection.invalidate(); exit(0)
        }
        // Off-screen island page renders; exits when done and never reaches the app delegate.
        IslandRenderHarness.runIfRequested()
        EnergyRenderHarness.runIfRequested()
        MenuBarIconRenderHarness.runIfRequested()
        KeepAwakeRenderHarness.runIfRequested()
        FanRenderHarness.runIfRequested()
        SpriteStudioRenderHarness.runIfRequested()
        // The agent server alone, on a scratch store, for testing the `menusprite` command end to end.
        AgentSandbox.runIfRequested()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var powerStore: PowerStore!
    /// MenuSprite's one window; every full page opens in it on its own tab.
    private(set) var appWindow: AppWindowController!
    private var statusItem: NSStatusItem?
    private var awakeObserver: AnyCancellable?
    private var iconObserver: NSObjectProtocol?
    private(set) var permissionStore: PermissionStore?
    private var activationObserver: NSObjectProtocol?
    private var validation: NativeValidation?
    private(set) var monitoringStore: MonitoringStore!
    private(set) var spriteMenuBar: SpriteMenuBar?
    private(set) var accountsStore: AccountsStore?
    private var accountsPanel: AccountsPanelController?
    private(set) var hub: HubPanelController?
    private(set) var workStore: WorkStore?
    private var workPreferencesURL: URL?
    private var monitoringValidation: MonitoringValidation?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var headlessMeasurementActive = false
    private(set) var island: IslandController?
    private(set) var islandEnvironment: IslandEnvironment?
    private var islandSettings: IslandSettingsPage?
    private var islandHub: HubModel?
    /// The socket the `menusprite` command and its MCP server talk to; only the ordinary launch serves it.
    private var agentServer: AgentServer?
    private(set) var agentService: AgentService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        headlessMeasurementActive = arguments.contains("--hub-validate") || arguments.contains("--spacing-validate") || arguments.contains("--monitor-measure") || arguments.contains("--power-validate") || arguments.contains("--discharge-validate") || arguments.contains("--limit-validate") || arguments.contains("--memory-validate") || arguments.contains("--process-panels-validate") || arguments.contains("--readouts-validate") || arguments.contains("--release-validate") || arguments.contains("--energy-validate") || arguments.contains("--usage-validate")
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
        // Restores the owned menu-bar spacing if anything cleared it. Silent, and a no-op unless the
        // stored keys have drifted; skipped on validation launches so they write nothing.
        if backgroundWork { MenuBarSpacing.enforce() }
        appWindow = AppWindowController(pages: .init(make: { [unowned self] in makePage($0) },
                                                     closed: { [unowned self] in pageClosed($0) },
                                                     visibility: { [unowned self] page, visible in
                                                         if page == .island { islandSettings?.visibilityChanged(visible) }
                                                     }))
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
        hub = HubPanelController(monitoring: monitoringStore, power: powerStore, accounts: accounts,
                                 actions: HubActions(openSprites: { [weak self] in self?.showMonitoring() },
                                                     openPermissions: { [weak self] in self?.showSettings() },
                                                     openPowerControls: { [weak self] in self?.showPower() },
                                                     openWork: { [weak self] in self?.showWork() },
                                                     openIsland: { [weak self] in self?.showIslandSettings() },
                                                     editSprite: { [weak self] config in
                                                         self?.showMonitoring(); self?.monitoringStore.edit(config)
                                                     }))
        if backgroundWork {
            accounts.startAutoSwitchMonitor()
            // Render harnesses draw and exit; they must not grab the shortcut or hold the Mac awake.
            if !arguments.contains(where: { $0.hasPrefix("--") && $0.hasSuffix("-render") }) { powerStore.startKeepAwakeServices() }
            startIsland(accounts: accounts)
            if !arguments.contains(where: { $0.hasPrefix("--") && ($0.hasSuffix("-render") || $0.hasPrefix("--render-")) }) { startAgentServer() }
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
                guard let self, self.appWindow.isVisible, let page = self.appWindow.showing else { return }
                self.refresh(page)
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
        } else if let index = arguments.firstIndex(of:"--spacing-validate"), arguments.indices.contains(index+1) {
            SpacingValidation(app:self,directory:URL(fileURLWithPath:arguments[index+1])).start()
        } else if let index = arguments.firstIndex(of:"--battery-validate"), arguments.indices.contains(index+1) {
            BatteryItemValidation(app:self,directory:URL(fileURLWithPath:arguments[index+1])).start()
        } else if let index = arguments.firstIndex(of:"--power-ui-validate"), arguments.indices.contains(index+1) {
            PowerValidation(app:self,directory:URL(fileURLWithPath:arguments[index+1])).startUI()
        } else if let index = arguments.firstIndex(of:"--limit-validate"), arguments.indices.contains(index+1) {
            PowerValidation(app:self,directory:URL(fileURLWithPath:arguments[index+1])).startSystemLimit()
        } else if let index = arguments.firstIndex(of:"--discharge-validate"), arguments.indices.contains(index+1) {
            PowerValidation(app:self,directory:URL(fileURLWithPath:arguments[index+1])).startDischarge()
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
        } else if let index = arguments.firstIndex(of: "--hub-validate"), arguments.indices.contains(index + 1) {
            HubValidation(app: self, directory: URL(fileURLWithPath: arguments[index + 1])).start()
        } else if let index = arguments.firstIndex(of: "--show-hub") {
            let tab = arguments.indices.contains(index + 1) ? HubTab(rawValue: arguments[index + 1]) : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showHub(tab ?? .system) }
        } else if let index = arguments.firstIndex(of: "--render-accounts"), arguments.indices.contains(index + 1),
                  let accounts = accountsStore {
            // Draws the AI Accounts board into a window that is never shown, so the layout can be checked
            // while Prerak works: nothing appears on screen and the menu bar is left alone.
            let directory = URL(fileURLWithPath: arguments[index + 1])
            Task { @MainActor in
                let size = NSSize(width: 440, height: 900)
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: AccountsBoard(store: accounts, close: {}))
                host.frame = NSRect(origin: .zero, size: size)
                window.contentView = host
                accounts.opened()
                for _ in 0..<60 where accounts.isLoadingUsage || accounts.lastReloadAt == nil {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                try? await Task.sleep(for: .seconds(1))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("accounts-board.png"))
                }
                accounts.closed()
                window.contentView = nil
                window.close()
            }
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
        applicationMenu.addItem(menuItem("Dynamic Island…", #selector(showIslandSettings), ""))
        if !BuildFeatures.publicPreview { applicationMenu.addItem(menuItem("Work & Clients…", #selector(showWork), "t")) }
        applicationMenu.addItem(menuItem(BuildFeatures.powerPageTitle + "…", #selector(showPower), "p"))
        applicationMenu.addItem(menuItem("Permissions & Access…", #selector(showSettings), ""))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: "Hide MenuSprite", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
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
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(menuItem("Close", #selector(closeFrontWindow), "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "MenuSprite"
            button.setAccessibilityLabel("MenuSprite")
        }
        // A left click opens the hub, which reaches every MenuSprite page and window. A right click
        // (or ⌃-click) toggles Keep Awake; the icon wears a badge while the Mac is held awake.
        item.button?.target = self
        item.button?.action = #selector(brandItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        applyMenuBarIcon()
        iconObserver = NotificationCenter.default.addObserver(forName: MenuBarIconChoice.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMenuBarIcon() }
        }
        awakeObserver = Publishers.CombineLatest3(powerStore.$awake.removeDuplicates(), powerStore.$awakeIcon.removeDuplicates(),
                                                  powerStore.$awakeTint.removeDuplicates())
            .dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applyMenuBarIcon() }
            }
    }

    /// Puts the chosen artwork on the brand item, sized to the menu bar's height at its own aspect
    /// ratio, with the keep-awake badge while a right click is holding the Mac awake.
    private func applyMenuBarIcon() {
        guard let item = statusItem, let button = item.button else { return }
        let icon = MenuBarIconChoice.currentImage() ?? MenuBarIconChoice.arranger.image(monochrome: false)
        let iconHeight = max(18, NSStatusBar.system.thickness - 2)
        let aspectRatio = icon.map { $0.size.width / max(1, $0.size.height) } ?? 1.5
        let iconWidth = ceil(iconHeight * aspectRatio)
        icon?.size = NSSize(width: iconWidth, height: iconHeight)
        let awake = powerStore?.awake == true
        let active = awake ? AwakeIconArt.image(icon: powerStore.awakeIcon, tint: powerStore.awakeTint,
                                                size: NSSize(width: iconWidth, height: iconHeight)) : nil
        button.image = active ?? icon
        let hint = switch powerStore?.rightClick ?? .toggle {
        case .toggle: awake ? "Right-click to allow sleep" : "Right-click to keep this Mac awake"
        case .durations: "Right-click to choose how long to keep this Mac awake"
        case .hub, .nothing: ""
        }
        button.toolTip = ([awake ? "MenuSprite · keeping this Mac awake" : "MenuSprite"] + (hint.isEmpty ? [] : [hint])).joined(separator: "\n")
        button.setAccessibilityValue(awake ? "Keeping this Mac awake" : nil)
        item.length = max(iconWidth, active?.size.width ?? 0) + 6
    }

    @objc private func brandItemClicked() {
        guard let item = statusItem, let button = item.button else { return }
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if secondary {
            switch powerStore.rightClick {
            case .toggle: powerStore.toggleAwake(); return
            case .durations: popAwakeMenu(item: item, button: button); return
            case .nothing: return
            case .hub: break
            }
        }
        if let island, island.routesAppPanel {
            hub?.close()
            island.toggle(.appPanel)
            return
        }
        let window = button.window
        let anchor = window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        hub?.toggle(anchor: anchor, anchorWindow: window)
    }

    /// The right-click duration menu: every length, the saved default marked, and Turn off while awake.
    private func popAwakeMenu(item: NSStatusItem, button: NSStatusBarButton) {
        let menu = NSMenu()
        let status = NSMenuItem(title: powerStore.awake ? "Keeping awake · \(powerStore.awakeReason)" : "Keep this Mac awake", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        for seconds in AwakeDurations.all {
            let row = NSMenuItem(title: AwakeDurations.title(seconds), action: #selector(startAwakeFromMenu(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = seconds
            if seconds == powerStore.duration { row.state = .mixed; row.toolTip = "Your default" }
            menu.addItem(row)
        }
        if powerStore.awake {
            menu.addItem(.separator())
            menu.addItem(menuItem("Turn off", #selector(stopAwakeFromMenu), ""))
        }
        // NSStatusItem only pops a menu it owns; attach it for this click and take it back after.
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }
    @objc private func startAwakeFromMenu(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        powerStore.startAwake(for: seconds)
    }
    @objc private func stopAwakeFromMenu() { powerStore.stopAwake() }

    /// The Dynamic Island: built once, started with its saved settings (off until turned on).
    private func startIsland(accounts: AccountsStore) {
        let environment = IslandEnvironment(monitoring: monitoringStore, power: powerStore, accounts: accounts,
                                            settings: IslandSettingsStore())
        IslandRegistry.install(in: environment)
        let island = IslandController(environment: environment)
        environment.showHubTab = { [weak self] tab in self?.showHub(tab) }
        environment.showMonitoring = { [weak self] in self?.showMonitoring() }
        environment.showPermissions = { [weak self] in self?.showSettings() }
        environment.showSettings = { [weak self] section in
            if let section { self?.islandSettings?.model.reveal(section) }
            self?.showIslandSettings()
        }
        let hubModel = HubModel(monitoring: monitoringStore, accounts: accounts)
        islandHub = hubModel
        environment.appPanel = { [weak self, weak island] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(HubView(model: hubModel, monitoring: self.monitoringStore, power: self.powerStore, accounts: accounts,
                                   actions: HubActions(openSprites: { [weak self] in self?.showMonitoring() },
                                                       openPermissions: { [weak self] in self?.showSettings() },
                                                       openPowerControls: { [weak self] in self?.showPower() },
                                                       openWork: { [weak self] in self?.showWork() },
                                                       openIsland: { [weak self] in self?.showIslandSettings() },
                                                       editSprite: { [weak self] config in self?.showMonitoring(); self?.monitoringStore.edit(config) }),
                                   close: { [weak island] in island?.close() }))
        }
        environment.appPanelVisibility = { visible in if visible { hubModel.opened() } else { hubModel.closed() } }
        island.menuBarIconChanged = { [weak self, weak island] in
            self?.statusItem?.isVisible = !(island?.hidesMenuBarIcon ?? false)
        }
        islandEnvironment = environment
        self.island = island
        islandSettings = IslandSettingsPage(environment: environment, island: island)
        island.start()
    }

    @objc func showIslandSettings() { open(.island) }

    /// Validation entry points. They drive the same button and panel a person does.
    func clickBrandItemForValidation() { brandItemClicked() }
    func showHubTabForValidation(_ tab: HubTab) {
        guard let button = statusItem?.button else { return }
        let window = button.window
        hub?.show(anchor: window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) },
                  anchorWindow: window, tab: tab)
    }
    var hubProcessKindForValidation: ProcessPanelKind? { hub?.processKind }

    func showHub(_ tab: HubTab) {
        guard !headlessMeasurementActive, let button = statusItem?.button else { return }
        let window = button.window
        let anchor = window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        // Present after any menu finishes tracking, so its dismissal cannot close the new panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.hub?.show(anchor: anchor, anchorWindow: window, tab: tab)
        }
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: The window's pages

    /// The window while it shows that page, for validation runs.
    var settingsWindow: NSWindow? { appWindow.window(showing: .access) }
    var monitoringWindow: NSWindow? { appWindow.window(showing: .sprites) }
    var powerWindow: NSWindow? { appWindow.window(showing: .power) }
    var workWindow: NSWindow? { appWindow.window(showing: .work) }

    @objc func showSettings() { open(.access) }
    @objc func showMonitoring() { open(.sprites) }
    @objc func showPower() { open(.power) }
    @objc func showWork() { openWork() }
    func openWork(preferencesURL: URL? = nil) {
        guard !BuildFeatures.publicPreview else { return }
        workPreferencesURL = preferencesURL
        open(.work)
    }

    /// Opens the window on `page`; asking for the page already showing refreshes it instead.
    private func open(_ page: AppPage) {
        guard !headlessMeasurementActive else { return }
        let showing = appWindow.isVisible && appWindow.showing == page
        appWindow.show(page)
        if showing { refresh(page) }
    }

    private func refresh(_ page: AppPage) {
        switch page {
        case .sprites: monitoringStore.refresh()
        case .power: powerStore.refresh()
        case .access: permissionStore?.refresh()
        case .island: islandSettings?.refreshChecks()
        case .work: break
        }
    }

    /// Builds a page and opens what it reads; `pageClosed` undoes exactly this.
    private func makePage(_ page: AppPage) -> NSView {
        switch page {
        case .sprites:
            monitoringStore.setLibraryOpen(true)
            return host(MonitoringView(store: monitoringStore))
        case .power:
            powerStore.opened()
            return host(PowerView(store: powerStore))
        case .island:
            return islandSettings?.makeView() ?? host(Text("The Dynamic Island is not running in this launch.")
                .foregroundStyle(.secondary).frame(minWidth: 820, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity))
        case .work:
            let store = workPreferencesURL.map { WorkStore(preferencesURL: $0) } ?? WorkStore()
            workStore = store
            store.opened()
            return host(WorkBoard(store: store))
        case .access:
            let store = PermissionStore()
            permissionStore = store
            store.opened()
            return host(PermissionsView(store: store))
        }
    }

    private func pageClosed(_ page: AppPage) {
        switch page {
        case .sprites: monitoringStore.setLibraryOpen(false)
        case .power: powerStore.closed()
        case .island: islandSettings?.closed()
        case .work: workStore?.closed(); workStore = nil; workPreferencesURL = nil
        case .access: permissionStore?.closed(); permissionStore = nil
        }
    }

    /// A page's view passes only its minimum size to the window, which otherwise keeps the size it has.
    private func host<Content: View>(_ view: Content) -> NSView {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.minSize]
        return host
    }

    @objc func showEnergy() {
        guard !headlessMeasurementActive else { return }
        if let sprite = monitoringStore.sprites.first(where: { $0.processPanelKind == .power && $0.showInMenuBar }) {
            // A power sprite owns its own dashboard; open that one so the sprite's click and this
            // entry stay the same window. Present after the menu finishes tracking.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in _ = self?.spriteMenuBar?.toggleBoard(sprite.id) }
        } else {
            // Without such a sprite the dashboard lives in the hub, rather than being unreachable.
            showHub(.power)
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
    @objc func closeMonitoring() { monitoringWindow?.close() }
    @objc func closeSettings() { settingsWindow?.close() }
    @objc func closeFrontWindow() {
        // `keyWindow` is nil while no window of this app is focused, so a window is only matched
        // when it actually exists: `nil === nil` would otherwise swallow the command.
        if let window = appWindow.window, NSApp.keyWindow === window { window.close(); return }
        if hub?.isVisible == true { hub?.close(); return }
        if accountsPanel?.isVisible == true { accountsPanel?.close(); return }
        if spriteMenuBar?.closePresentedBoard() == true { return }
        appWindow.close()
    }
    @objc func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !headlessMeasurementActive else { return false }
        open(appWindow.page)
        return true
    }
    func finishHeadlessMeasurement() { headlessMeasurementActive = false }

    /// Serves agents at `AgentSocket.path`. A second copy of the app finds the socket answered and leaves it
    /// to the first; the listener costs nothing until a connection arrives.
    private func startAgentServer() {
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/menusprite")
        if FileManager.default.isExecutableFile(atPath: cli.path) { CommandVariableRunner.extraEnvironment["MENUSPRITE_CLI"] = cli.path }
        let service = AgentService(store: monitoringStore, host: .app(power: powerStore) { [weak self] id in
            self?.spriteMenuBar?.toggleBoard(id)
        })
        let server = AgentServer(path: AgentSocket.path, handler: service.handler())
        do {
            try server.start()
            agentService = service; agentServer = server
        } catch {
            NSLog("MenuSprite: the agent socket is not available: %@", "\(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentServer?.stop()
        island?.stop()
        appWindow.close()
        powerStore.shutdown()
        accountsStore?.stop()
        accountsPanel?.close()
        hub?.close()
        spriteMenuBar?.removeAll()
        monitoringStore.stop()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
