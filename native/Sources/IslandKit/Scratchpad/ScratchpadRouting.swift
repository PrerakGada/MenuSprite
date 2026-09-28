import Foundation

/// Where the scratchpad opens from its shortcut and its Controls tile.
public enum ScratchpadRouting {
    public enum ShortcutAction: Equatable, Sendable {
        /// Show the island's Scratchpad page and give it the keyboard.
        case openPage
        /// The page is showing but another app has the keyboard: take it, do not close.
        case focusPage
        /// The page already has the keyboard: collapse the island.
        case closeIsland
        /// The floating pad: focus it if it is visible but unfocused, else toggle it.
        case floatingPad
    }

    public enum TileAction: Equatable, Sendable {
        /// Switch the open island to its Scratchpad page, without collapsing.
        case showPage
        /// Collapse the island, then open the floating pad.
        case collapseThenFloatingPad
    }

    /// The island page only when the island is on, "Where Scratchpad opens" says Dynamic Island and
    /// the section is shown; otherwise the floating pad.
    public static func route(_ settings: IslandSettings) -> IslandToolRoute {
        settings.enabled && settings.scratchpadInIsland && settings.isVisible(.scratchpad) ? .island : .window
    }

    /// `islandAccepts` is false while the island cannot take interaction (off, locked, no display);
    /// full screen does not matter, the shortcut still opens the page there.
    public static func shortcut(_ settings: IslandSettings, islandAccepts: Bool, pageShowing: Bool, islandIsKey: Bool) -> ShortcutAction {
        guard route(settings) == .island, islandAccepts else { return .floatingPad }
        guard pageShowing else { return .openPage }
        return islandIsKey ? .closeIsland : .focusPage
    }

    public static func tile(_ settings: IslandSettings) -> TileAction {
        route(settings) == .island ? .showPage : .collapseThenFloatingPad
    }
}
