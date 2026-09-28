import Foundation

/// One of MenuSprite's own tools, as the Tools rail and the floating tools panel offer them. The raw
/// values are stored in the person's arrangement: keep them stable.
public enum IslandBuiltInTool: String, CaseIterable, Codable, Sendable, Identifiable {
    case keepAwake, speedTest, commandBar, monitoring, batteryPower, aiAccounts, permissions, menuBarSpacing, appPanel

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keepAwake: "Keep awake"
        case .speedTest: "Speed test"
        case .commandBar: "Command Bar"
        case .monitoring: "Monitoring & Sprites"
        case .batteryPower: "Battery & Power"
        case .aiAccounts: "AI Accounts"
        case .permissions: "Permissions"
        case .menuBarSpacing: "Menu bar spacing"
        case .appPanel: "Open app panel"
        }
    }

    public var symbol: String {
        switch self {
        case .keepAwake: "cup.and.saucer"
        case .speedTest: "speedometer"
        case .commandBar: "command"
        case .monitoring: "menubar.rectangle"
        case .batteryPower: "battery.100percent.bolt"
        case .aiAccounts: "sparkles"
        case .permissions: "lock.shield"
        case .menuBarSpacing: "arrow.left.and.right"
        case .appPanel: "bubble.middle.top"
        }
    }

    /// Words the Command Bar also matches, beyond the title.
    public var keywords: [String] {
        switch self {
        case .keepAwake: ["caffeinate", "sleep", "awake", "prevent"]
        case .speedTest: ["internet", "network", "bandwidth", "download", "upload", "latency"]
        case .commandBar: ["launcher", "search"]
        case .monitoring: ["sprites", "readings", "menu bar", "editor"]
        case .batteryPower: ["battery", "energy", "charge", "power"]
        case .aiAccounts: ["claude", "codex", "limits", "usage"]
        case .permissions: ["access", "privacy", "security"]
        case .menuBarSpacing: ["menu bar", "spacing", "padding", "gap"]
        case .appPanel: ["hub", "panel"]
        }
    }

    public var activation: IslandToolActivation {
        switch self {
        case .keepAwake: .toggle
        case .speedTest: .host
        case .appPanel: .islandPage
        case .commandBar, .monitoring, .batteryPower, .aiAccounts, .permissions, .menuBarSpacing: .dismissThenAct(delay: IslandToolActivation.dismissDelay)
        }
    }
}

/// How a tool behaves when it is activated. Every tool has exactly one of these.
public enum IslandToolActivation: Equatable, Sendable {
    /// Changes something in place; the launcher (or island) stays open.
    case toggle
    /// Shows the tool's own small utility inside the launcher.
    case host
    /// Switches the island to another page without collapsing. From the floating panel it dismisses, then acts.
    case islandPage
    /// Dismisses the launcher (collapses the island) and runs exactly once after `delay` seconds, so a
    /// window or capture never appears under a shrinking panel.
    case dismissThenAct(delay: Double)

    public static let dismissDelay = 0.15
}

/// A tile in the launcher: one of MenuSprite's tools, or an app the person pinned.
public enum IslandTool: Hashable, Sendable, Identifiable {
    case builtIn(IslandBuiltInTool)
    /// A pinned app, by the path of its bundle.
    case app(String)

    public var id: String { storageValue }

    public var storageValue: String {
        switch self {
        case .builtIn(let tool): tool.rawValue
        case .app(let path): Self.appPrefix + path
        }
    }

    public init?(storageValue: String) {
        if storageValue.hasPrefix(Self.appPrefix) {
            let path = String(storageValue.dropFirst(Self.appPrefix.count))
            guard path.hasPrefix("/"), path.hasSuffix(".app") else { return nil }
            self = .app(path)
        } else if let tool = IslandBuiltInTool(rawValue: storageValue) {
            self = .builtIn(tool)
        } else {
            return nil
        }
    }

    public var activation: IslandToolActivation {
        switch self {
        case .builtIn(let tool): tool.activation
        case .app: .dismissThenAct(delay: IslandToolActivation.dismissDelay)
        }
    }

    private static let appPrefix = "app:"
}

/// The person's arrangement of the launcher: the order as a list of identifiers, the built-in tools
/// they hid, and the apps they pinned (which live in the order). Rebuilding from storage drops
/// unknown identifiers and duplicates and appends built-in tools the list does not mention yet, so a
/// tool added in a later version joins at the end.
public struct IslandToolArrangement: Equatable, Sendable {
    public private(set) var order: [IslandTool]
    public private(set) var hidden: Set<IslandBuiltInTool>

    public init(order: [String] = [], hidden: [String] = []) {
        var seen = Set<IslandTool>()
        let stored = order.compactMap(IslandTool.init(storageValue:)).filter { seen.insert($0).inserted }
        self.order = stored + IslandBuiltInTool.allCases.map(IslandTool.builtIn).filter { !seen.contains($0) }
        self.hidden = Set(hidden.compactMap(IslandBuiltInTool.init(rawValue:)))
    }

    public static let standard = IslandToolArrangement()

    public var storedOrder: [String] { order.map(\.storageValue) }
    public var storedHidden: [String] { hidden.map(\.rawValue).sorted() }

    /// The tiles the launcher shows, in order.
    public var visible: [IslandTool] {
        order.filter { tool in
            if case .builtIn(let builtIn) = tool { return !hidden.contains(builtIn) }
            return true
        }
    }

    /// Hidden tools, in the launcher's order, for the "add back" tray.
    public var hiddenTools: [IslandBuiltInTool] {
        order.compactMap { tool in
            if case .builtIn(let builtIn) = tool, hidden.contains(builtIn) { return builtIn }
            return nil
        }
    }

    public var pinnedApps: [String] {
        order.compactMap { tool in
            if case .app(let path) = tool { return path }
            return nil
        }
    }

    /// The minus badge: a built-in tool is hidden (and can be added back where it was); a pinned app is unpinned.
    public mutating func remove(_ tool: IslandTool) {
        switch tool {
        case .builtIn(let builtIn): hidden.insert(builtIn)
        case .app: order.removeAll { $0 == tool }
        }
    }

    public mutating func addBack(_ tool: IslandBuiltInTool) { hidden.remove(tool) }

    /// Pins an app at the end. Returns false when it is already pinned or the path is not an app bundle.
    @discardableResult
    public mutating func pin(app path: String) -> Bool {
        guard let tool = IslandTool(storageValue: "app:" + path), !order.contains(tool) else { return false }
        order.append(tool)
        return true
    }

    /// Drag to reorder: `tool` takes `target`'s place, and the tiles between shift by one.
    public mutating func move(_ tool: IslandTool, to target: IslandTool) {
        guard tool != target, let from = order.firstIndex(of: tool), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(tool, at: to)
    }
}
