import AppKit
import Combine
import IslandKit
import SwiftUI

/// Tools: a customisable rail of MenuSprite's own tools and pinned apps, the speed test it hosts,
/// the floating tools panel, and the Command Bar, plus the Speed test and Command Bar tiles on the
/// Controls page. Nothing runs at rest except the two optional global shortcuts: the panels are
/// built when shown and released when hidden, the speed test runs only when pressed, and the
/// page's keyboard handling exists only while the page is on screen.
@MainActor
final class ToolsSection: IslandSection {
    let id = IslandSectionID.tools
    let model: ToolsModel
    private unowned let environment: IslandEnvironment
    private let speedTile: IslandControlModel
    private let commandTile: IslandControlModel
    private lazy var quickPanel = ToolsQuickPanel(model: model)
    private lazy var commandBar = CommandBar(actions: { [weak self] in self?.commandActions() ?? [] })
    private var pageVisible = false
    private var holding = false
    private var keyMonitor: Any?
    private var railSize = CGSize(width: 504, height: 264)
    private var visibility: AnyCancellable?
    private var shortcuts: Set<AnyCancellable> = []

    private static let toolsHotKey = "island.tools"
    private static let commandBarHotKey = "island.commandBar"

    init(environment: IslandEnvironment) {
        self.environment = environment
        model = ToolsModel(preferences: ToolsPreferences(), power: environment.power)
        speedTile = IslandControlModel(.speedTest) {}
        speedTile.symbol = "speedometer"
        commandTile = IslandControlModel(.commandBar) {}
        speedTile.perform = { [weak self] in self?.openLauncher(hosting: .speedTest) }
        commandTile.perform = { [weak self] in self?.collapseThen { self?.commandBar.show() } }
        speedTile.availability = Self.speedTileAvailability(visible: environment.settings.isVisible(.tools), environment: environment)
        environment.register(speedTile)
        environment.register(commandTile)
        model.perform = { [weak self] launch, surface in self?.run(launch, from: surface) }
        model.layoutChanged = { [weak self] in self?.layoutChanged() }
        visibility = environment.settingsStore.$value
            .map { $0.isVisible(.tools) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] visible in
                guard let self else { return }
                speedTile.availability = Self.speedTileAvailability(visible: visible, environment: self.environment)
                self.environment.invalidate()
            }
    }

    /// The Speed test tile opens the test on this page, so it exists only while the page is shown.
    private static func speedTileAvailability(visible: Bool, environment: IslandEnvironment) -> IslandAvailability {
        visible ? .available : .unavailable("Show “Tools” on the Content tab.", fixTitle: "Show") { [weak environment] in
            environment?.actions.openSettings(.tools)
        }
    }

    // MARK: IslandSection

    var availability: IslandAvailability { .available }

    /// Editing and hosted utilities take the full-page budget.
    var isVertical: Bool { model.launcher.holdsSurface }

    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight {
        if model.launcher.holdsSurface { return .fill }
        return .fixed(IslandToolRail(count: model.tools.count, width: context.width, budget: context.budget).height)
    }

    func page(_ context: IslandPageContext) -> AnyView {
        if !context.isPreview { railSize = CGSize(width: context.width, height: context.budget) }
        return AnyView(ToolsPage(model: model, context: context,
                                 chooseApps: { [weak self] in self?.model.chooseApps(above: Self.islandLevel) },
                                 close: { [weak self] in self?.closeFromUtility() }))
    }

    /// Settings › Content › Tools: the same editor the island's "Customize tools" opens — remove, reorder,
    /// add back, pin apps, record the two shortcuts — on the island's black so it reads the same.
    func options() -> AnyView? {
        AnyView(ToolsEditView(model: model, preferences: model.preferences, columns: 4,
                              chooseApps: { [weak self] in self?.model.chooseApps(above: .normal) })
            .padding(14)
            .frame(height: 380)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black))
            .environment(\.colorScheme, .dark))
    }

    func headerAccessory(_ context: IslandPageContext) -> AnyView? {
        AnyView(ToolsCustomizeButton(model: model))
    }

    func islandDidStart() {
        guard !environment.isHeadless else { return }
        Publishers.CombineLatest3(model.preferences.$toolsShortcut, model.preferences.$commandBarShortcut,
                                  model.$launcher.map(\.editing).removeDuplicates())
            .sink { [weak self] tools, commandBar, editing in self?.syncShortcuts(tools, commandBar, editing: editing) }
            .store(in: &shortcuts)
    }

    func islandDidStop() {
        shortcuts.removeAll()
        IslandShortcuts.shared.unregister(Self.toolsHotKey)
        IslandShortcuts.shared.unregister(Self.commandBarHotKey)
        model.speedTest.cancel()
        quickPanel.hide()
        commandBar.hide()
        pageDidDisappear()
    }

    func pageDidAppear() {
        pageVisible = true
        model.present()
        installKeyboard()
        syncHold()
    }

    func pageDidDisappear() {
        guard pageVisible else { return }
        pageVisible = false
        removeKeyboard()
        model.dismissed()
        syncHold()
    }

    // MARK: Routing

    private static let islandLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    /// "Tools" opens in the island when set to, the island is on and taking input, and the page is shown.
    private var routesToIsland: Bool {
        let settings = environment.settings
        return settings.enabled && settings.toolsInIsland && environment.isRunning && environment.visibleSections.contains(.tools)
    }

    private var showingInIsland: Bool { environment.isOpen && environment.destination == .section(.tools) }

    /// The Tools shortcut: toggles the island's Tools page, or the floating panel when the island
    /// is not the destination or declines to open.
    private func toolsShortcutPressed() {
        if routesToIsland {
            if showingInIsland { environment.close(); return }
            quickPanel.hide()
            environment.open(.tools)
            if showingInIsland { return }
        }
        quickPanel.toggle()
    }

    /// Opens the launcher where "Tools" opens, optionally with a utility already up.
    private func openLauncher(hosting utility: IslandBuiltInTool? = nil) {
        if let utility { model.host(utility) }
        if routesToIsland {
            environment.open(.tools)
            if showingInIsland { return }
        }
        quickPanel.show()
    }

    private func run(_ launch: IslandToolLaunch, from surface: ToolsSurface) {
        switch launch {
        case .toggle: toggleAwake()
        case .host: syncHold()
        case .islandPage(let tool):
            if surface == .island { perform(.builtIn(tool)) }
            else { quickPanel.dismiss(after: IslandToolActivation.dismissDelay) { [weak self] in self?.perform(.builtIn(tool)) } }
        case .dismissThenAct(let tool, let delay):
            if surface == .island { collapseThen { [weak self] in self?.perform(tool) } }
            else { quickPanel.dismiss(after: delay) { [weak self] in self?.perform(tool) } }
        }
    }

    private func perform(_ tool: IslandTool) {
        switch tool {
        case .builtIn(.keepAwake): toggleAwake()
        case .builtIn(.speedTest): openLauncher(hosting: .speedTest)
        case .builtIn(.commandBar): commandBar.show()
        case .builtIn(.monitoring): environment.showMonitoring()
        case .builtIn(.batteryPower): environment.showHubTab(.power)
        case .builtIn(.aiAccounts): environment.showHubTab(.ai)
        case .builtIn(.permissions): environment.showPermissions()
        case .builtIn(.menuBarSpacing): environment.showHubTab(.tools)
        case .builtIn(.appPanel): environment.actions.openAppPanel()
        case .app(let path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    private func toggleAwake() {
        let power = environment.power
        if power.awake { power.stopAwake() } else { power.startAwake() }
    }

    /// Collapses the island if it is open, then runs `action` once its closing animation has settled.
    private func collapseThen(_ action: @escaping @MainActor () -> Void) {
        environment.actions.closeThen(action)
    }

    /// Close on a hosted utility: the utility goes, and so does the island.
    private func closeFromUtility() {
        model.closeUtility()
        environment.close()
    }

    // MARK: Hold, layout, keyboard

    private func layoutChanged() {
        syncHold()
        environment.invalidate()
    }

    /// While the page is editing or hosting a utility, the island stays open through outside clicks
    /// and app switches, so drags and the app chooser work.
    private func syncHold() {
        let wanted = pageVisible && model.launcher.holdsSurface
        guard wanted != holding else { return }
        holding = wanted
        environment.actions.holdOpen(wanted)
    }

    /// Arrows follow the rail, Return runs the selected tile, and Escape peels a hosted utility or
    /// edit mode before the island's own Escape closes it. Only while this page is on screen and the
    /// island has the keyboard.
    private func installKeyboard() {
        guard keyMonitor == nil, !environment.isHeadless else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.islandKey(event) ?? false }
            return handled ? nil : event
        }
    }

    private func removeKeyboard() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func islandKey(_ event: NSEvent) -> Bool {
        guard event.window is IslandPanel, showingInIsland,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 53 { return model.escape() }
        guard !model.launcher.holdsSurface else { return false }
        let rail = IslandToolRail(count: model.tools.count, width: railSize.width, budget: railSize.height)
        let current = model.launcher.selection ?? 0
        let direction: IslandToolDirection
        switch event.keyCode {
        case 36, 76:
            model.activateSelection(from: .island)
            return true
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        default: return false
        }
        guard !model.tools.isEmpty else { return true }
        model.select(rail.move(current, direction), byKeyboard: true)
        return true
    }

    // MARK: Shortcuts and the Command Bar

    /// Registers both shortcuts so a rejected one is reported at once. While the grid is being edited
    /// (where the recorders are) they are released again, so recording can capture their own keys.
    private func syncShortcuts(_ tools: IslandShortcut?, _ commandBar: IslandShortcut?, editing: Bool) {
        let shortcuts = IslandShortcuts.shared
        model.toolsShortcutRejected = !shortcuts.register(Self.toolsHotKey, tools) { [weak self] in self?.toolsShortcutPressed() }
        model.commandBarShortcutRejected = !shortcuts.register(Self.commandBarHotKey, commandBar) { [weak self] in
            self?.commandBarShortcutPressed()
        }
        if editing {
            shortcuts.unregister(Self.toolsHotKey)
            shortcuts.unregister(Self.commandBarHotKey)
        }
    }

    private func commandBarShortcutPressed() {
        if commandBar.isVisible { commandBar.hide() } else { collapseThen { [weak self] in self?.commandBar.show() } }
    }

    /// What the Command Bar offers besides apps: every tool, Tools itself, each app-panel page and
    /// the island's settings.
    private func commandActions() -> [CommandBarAction] {
        var actions: [CommandBarAction] = IslandBuiltInTool.allCases.filter { $0 != .commandBar }.map { tool in
            let awake = tool == .keepAwake && environment.power.awake
            return CommandBarAction(id: tool.rawValue, title: awake ? "Stop keeping awake" : tool.title, detail: "MenuSprite",
                                    symbol: awake ? "cup.and.saucer.fill" : tool.symbol, keywords: tool.keywords) { [weak self] in
                self?.perform(.builtIn(tool))
            }
        }
        actions.append(CommandBarAction(id: "tools", title: "Tools", detail: "MenuSprite", symbol: IslandSectionID.tools.symbol,
                                        keywords: ["launcher", "quick"]) { [weak self] in self?.openLauncher() })
        for tab in HubTab.allCases where !(tab == .work && BuildFeatures.publicPreview) {
            actions.append(CommandBarAction(id: "hub." + tab.rawValue, title: tab.title, detail: "App panel", symbol: tab.symbol,
                                            keywords: ["hub", "panel", "page"]) { [weak self] in self?.environment.showHubTab(tab) })
        }
        actions.append(CommandBarAction(id: "island.settings", title: "Dynamic Island settings", detail: "MenuSprite",
                                        symbol: "gearshape", keywords: ["island", "notch", "preferences"]) { [weak self] in
            self?.environment.showSettings(nil)
        })
        return actions
    }
}
