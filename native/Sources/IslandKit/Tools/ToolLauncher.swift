import Foundation

/// What activating a tool asks the surface showing the launcher to do.
public enum IslandToolLaunch: Equatable, Sendable {
    case toggle(IslandBuiltInTool)
    case host(IslandBuiltInTool)
    case islandPage(IslandBuiltInTool)
    case dismissThenAct(IslandTool, delay: Double)
}

/// The launcher's working state, shared by the island's Tools page and the floating tools panel:
/// the tiles on show, the keyboard selection, edit mode, and the utility it hosts. Pure, so every
/// activation rule is testable without a window.
///
/// `hostable` is the set of utilities whose feature is available right now. It is separate from the
/// tiles: hiding the Speed test tile does not remove the speed test, but a utility whose feature goes
/// away is dropped at once, even while nothing is on screen, and cannot come back.
public struct IslandToolLauncher: Equatable, Sendable {
    public private(set) var tools: [IslandTool]
    public private(set) var hostable: Set<IslandBuiltInTool>
    public private(set) var selection: Int?
    public private(set) var editing = false
    public private(set) var hosted: IslandBuiltInTool?
    /// Counts presentations, so a view can tell a fresh opening from a re-render.
    public private(set) var presentation = 0

    public init(tools: [IslandTool] = [], hostable: Set<IslandBuiltInTool> = []) {
        self.tools = tools
        self.hostable = hostable
        selection = tools.isEmpty ? nil : 0
    }

    public var selectedTool: IslandTool? { selection.flatMap { tools.indices.contains($0) ? tools[$0] : nil } }

    /// While editing or hosting, the surface stays open through clicks elsewhere and app switches, so
    /// drags and dialogs work.
    public var holdsSurface: Bool { editing || hosted != nil }

    /// The launcher appeared: edit controls reset and the first tile is selected, so Return works at
    /// once. A hosted utility whose feature is still available stays.
    public mutating func present() {
        presentation += 1
        editing = false
        dropUnavailableUtility()
        selection = tools.isEmpty ? nil : 0
    }

    /// The tiles or the available utilities changed.
    public mutating func update(tools: [IslandTool], hostable: Set<IslandBuiltInTool>) {
        let selected = selectedTool
        self.tools = tools
        self.hostable = hostable
        dropUnavailableUtility()
        if tools.isEmpty {
            selection = nil
        } else if let selected, let index = tools.firstIndex(of: selected) {
            selection = index
        } else {
            selection = min(selection ?? 0, tools.count - 1)
        }
    }

    public mutating func select(_ index: Int) {
        guard tools.indices.contains(index) else { return }
        selection = index
    }

    /// Edit mode belongs to the tile grid; it cannot start while a utility is hosted.
    public mutating func setEditing(_ on: Bool) {
        guard !on || hosted == nil else { return }
        editing = on
    }

    /// Activates a tile. Nothing happens in edit mode, or for a tile that is no longer offered (a
    /// stale view cannot run a removed tool).
    public mutating func activate(_ tool: IslandTool) -> IslandToolLaunch? {
        guard !editing, let index = tools.firstIndex(of: tool) else { return nil }
        selection = index
        switch (tool.activation, tool) {
        case (.toggle, .builtIn(let builtIn)): return .toggle(builtIn)
        case (.host, .builtIn(let builtIn)):
            guard hostable.contains(builtIn) else { return nil }
            hosted = builtIn
            return .host(builtIn)
        case (.islandPage, .builtIn(let builtIn)): return .islandPage(builtIn)
        case (.dismissThenAct(let delay), _): return .dismissThenAct(tool, delay: delay)
        default: return nil
        }
    }

    /// Return: activates the selected tile. An empty launcher has no target.
    public mutating func activateSelection() -> IslandToolLaunch? {
        guard let tool = selectedTool else { return nil }
        return activate(tool)
    }

    /// Opens a utility directly (the Controls tile, the Command Bar). Refused when its feature is unavailable.
    @discardableResult
    public mutating func host(_ utility: IslandBuiltInTool) -> Bool {
        guard utility.activation == .host, hostable.contains(utility) else { return false }
        editing = false
        hosted = utility
        return true
    }

    /// Back from a hosted utility to the tiles.
    public mutating func closeUtility() { hosted = nil }

    /// Escape peels one layer: the hosted utility, then edit mode. Returns false when there was nothing
    /// left to peel, so the caller hides the launcher.
    public mutating func escape() -> Bool {
        if hosted != nil { hosted = nil; return true }
        if editing { editing = false; return true }
        return false
    }

    private mutating func dropUnavailableUtility() {
        if let hosted, !hostable.contains(hosted) { self.hosted = nil }
    }
}
