import AppKit
import Combine
import IslandKit
import SwiftUI

/// The Tools section's saved choices, under `MenuSprite.Island.Tools.*`: the tile arrangement and the
/// two global shortcuts, which ship unset.
@MainActor
final class ToolsPreferences: ObservableObject {
    @Published private(set) var arrangement: IslandToolArrangement
    @Published var toolsShortcut: IslandShortcut? { didSet { store(toolsShortcut, Self.toolsShortcutKey) } }
    @Published var commandBarShortcut: IslandShortcut? { didSet { store(commandBarShortcut, Self.commandBarShortcutKey) } }
    private let defaults: UserDefaults

    static let orderKey = "MenuSprite.Island.Tools.order"
    static let hiddenKey = "MenuSprite.Island.Tools.hidden"
    static let toolsShortcutKey = "MenuSprite.Island.Tools.shortcut"
    static let commandBarShortcutKey = "MenuSprite.Island.Tools.commandBarShortcut"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        arrangement = IslandToolArrangement(order: defaults.stringArray(forKey: Self.orderKey) ?? [],
                                            hidden: defaults.stringArray(forKey: Self.hiddenKey) ?? [])
        toolsShortcut = Self.shortcut(defaults, Self.toolsShortcutKey)
        commandBarShortcut = Self.shortcut(defaults, Self.commandBarShortcutKey)
    }

    func update(_ change: (inout IslandToolArrangement) -> Void) {
        var copy = arrangement
        change(&copy)
        guard copy != arrangement else { return }
        arrangement = copy
        defaults.set(copy.storedOrder, forKey: Self.orderKey)
        defaults.set(copy.storedHidden, forKey: Self.hiddenKey)
    }

    private func store(_ shortcut: IslandShortcut?, _ key: String) {
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    private static func shortcut(_ defaults: UserDefaults, _ key: String) -> IslandShortcut? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(IslandShortcut.self, from: $0) }
    }
}

/// Where the launcher is on screen: the island's Tools page or the floating tools panel.
enum ToolsSurface {
    case island, panel
}

/// Everything the island page and the floating panel share: the launcher's state, the arrangement,
/// the speed test, and live tile states. The section decides what an activation does; this model
/// only records it and hands it over.
@MainActor
final class ToolsModel: ObservableObject {
    @Published private(set) var launcher = IslandToolLauncher()
    /// Drawn on the island's rail only after an arrow key moved it in this presentation.
    @Published private(set) var showsSelection = false
    @Published private(set) var awake = false
    @Published var toolsShortcutRejected = false
    @Published var commandBarShortcutRejected = false

    let preferences: ToolsPreferences
    let speedTest = SpeedTestModel()
    /// Set by the section: carry out an activation from a surface.
    var perform: (IslandToolLaunch, ToolsSurface) -> Void = { _, _ in }
    /// Set by the section: the page's height or hold changed.
    var layoutChanged: () -> Void = {}

    private var apps: [String: (name: String, icon: NSImage)] = [:]
    private var observations: Set<AnyCancellable> = []

    /// Utilities MenuSprite can host. The speed test needs nothing installed, so it is always here.
    static let hostable: Set<IslandBuiltInTool> = [.speedTest]

    init(preferences: ToolsPreferences, power: PowerStore) {
        self.preferences = preferences
        launcher = IslandToolLauncher(tools: preferences.arrangement.visible, hostable: Self.hostable)
        awake = power.awake
        preferences.$arrangement.dropFirst().sink { [weak self] arrangement in
            guard let self else { return }
            launcher.update(tools: arrangement.visible, hostable: Self.hostable)
            layoutChanged()
        }.store(in: &observations)
        power.$awake.removeDuplicates().sink { [weak self] in self?.awake = $0 }.store(in: &observations)
        speedTest.$status.map(\.isRunning).removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
    }

    var tools: [IslandTool] { launcher.tools }

    /// Whether a tile's feature is doing something right now (the green dot).
    func isActive(_ tool: IslandTool) -> Bool {
        switch tool {
        case .builtIn(.keepAwake): awake
        case .builtIn(.speedTest): speedTest.status.isRunning
        default: false
        }
    }

    func title(_ tool: IslandTool) -> String {
        switch tool {
        case .builtIn(let builtIn): builtIn.title
        case .app(let path): app(path).name
        }
    }

    func symbol(_ tool: IslandTool) -> String {
        if tool == .builtIn(.keepAwake), awake { return "cup.and.saucer.fill" }
        if case .builtIn(let builtIn) = tool { return builtIn.symbol }
        return "app"
    }

    /// A pinned app's name and icon, read once and kept until the launcher leaves the screen.
    func app(_ path: String) -> (name: String, icon: NSImage) {
        if let known = apps[path] { return known }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let entry = (name, NSWorkspace.shared.icon(forFile: path))
        apps[path] = entry
        return entry
    }

    // MARK: Presentation

    /// The launcher appeared on a surface.
    func present() {
        launcher.present()
        showsSelection = false
        layoutChanged()
    }

    /// The launcher left the screen: edit mode ends with it, and cached app icons are let go.
    func dismissed() {
        let wasEditing = launcher.editing
        launcher.setEditing(false)
        showsSelection = false
        apps = [:]
        if wasEditing { layoutChanged() }
    }

    func setEditing(_ on: Bool) {
        launcher.setEditing(on)
        layoutChanged()
    }

    func activate(_ tool: IslandTool, from surface: ToolsSurface) {
        guard let launch = launcher.activate(tool) else { return }
        if case .host = launch { layoutChanged() }
        perform(launch, surface)
    }

    func activateSelection(from surface: ToolsSurface) {
        guard let tool = launcher.selectedTool else { return }
        activate(tool, from: surface)
    }

    func select(_ index: Int, byKeyboard: Bool) {
        launcher.select(index)
        if byKeyboard { showsSelection = true }
    }

    /// Opens a utility directly, from the Controls tile or the Command Bar.
    @discardableResult
    func host(_ utility: IslandBuiltInTool) -> Bool {
        guard launcher.host(utility) else { return false }
        layoutChanged()
        return true
    }

    func closeUtility() {
        launcher.closeUtility()
        layoutChanged()
    }

    /// Escape: peels the utility, then edit mode. False when nothing was left, so the surface hides.
    func escape() -> Bool {
        guard launcher.escape() else { return false }
        layoutChanged()
        return true
    }

    // MARK: Editing

    func remove(_ tool: IslandTool) { preferences.update { $0.remove(tool) } }
    func addBack(_ tool: IslandBuiltInTool) { preferences.update { $0.addBack(tool) } }
    func move(_ tool: IslandTool, to target: IslandTool) { preferences.update { $0.move(tool, to: target) } }

    /// Chooses apps to pin with the standard open panel, one level above the surface that asked.
    func chooseApps(above level: NSWindow.Level) {
        let panel = NSOpenPanel()
        panel.message = "Choose apps to add to Tools."
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        NSApp.activate()
        panel.begin { [weak self, panel] response in
            guard response == .OK else { return }
            let paths = panel.urls.map { $0.resolvingSymlinksInPath().path }
            MainActor.assumeIsolated {
                self?.preferences.update { arrangement in for path in paths { arrangement.pin(app: path) } }
            }
        }
    }
}
