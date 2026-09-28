import Foundation

/// Which display hosts the island.
public struct IslandScreenInfo: Equatable, Sendable {
    public var id: UInt32
    public var isBuiltIn: Bool
    public var isNotched: Bool
    /// The display holding the menu bar in the arrangement (frame origin 0,0).
    public var isPrimary: Bool
    public init(id: UInt32, isBuiltIn: Bool, isNotched: Bool, isPrimary: Bool) {
        self.id = id; self.isBuiltIn = isBuiltIn; self.isNotched = isNotched; self.isPrimary = isPrimary
    }
}

public enum IslandDisplaySelection {
    /// Automatic: the notched built-in screen even beside an external main display, else any notched
    /// screen, else the primary. Built-in: the laptop screen, nothing while the lid is closed; a Mac
    /// without a lid behaves as Main. Main: the menu-bar display.
    public static func select(_ screens: [IslandScreenInfo], choice: IslandDisplayChoice, hasLid: Bool) -> UInt32? {
        guard !screens.isEmpty else { return nil }
        let primary = screens.first(where: \.isPrimary) ?? screens[0]
        switch choice {
        case .automatic:
            if let builtIn = screens.first(where: { $0.isBuiltIn && $0.isNotched }) { return builtIn.id }
            if let notched = screens.first(where: \.isNotched) { return notched.id }
            return primary.id
        case .builtIn:
            if let builtIn = screens.first(where: \.isBuiltIn) { return builtIn.id }
            return hasLid ? nil : primary.id
        case .main:
            return primary.id
        }
    }
}

/// Where the open island can be.
public enum IslandDestination: Hashable, Sendable {
    case section(IslandSectionID)
    case explore
    case appPanel

    public var section: IslandSectionID? {
        if case .section(let id) = self { return id }
        return nil
    }
}

public enum IslandNavigation {
    /// Sections shown in the island, in order: the stored order (unknown and duplicate ids ignored),
    /// new sections at the end, without hidden or unavailable ones.
    public static func visibleSections(_ settings: IslandSettings, available: (IslandSectionID) -> Bool) -> [IslandSectionID] {
        settings.orderedSections.filter { settings.isVisible($0) && available($0) }
    }

    /// Where an opening that names no page goes: a visible activity's page first, then the saved
    /// destination, then the last page. A hidden saved page falls back to the first visible one.
    public static func reopenDestination(settings: IslandSettings, visible: [IslandSectionID], lastPage: IslandSectionID?,
                                         activity: IslandSectionID?) -> IslandDestination {
        let fallback: IslandDestination = .section(visible.first ?? .controls)
        if let activity, visible.contains(activity) { return .section(activity) }
        switch settings.reopen {
        case .appPanel: return .appPanel
        case .explore: return .explore
        case .section(let id): return visible.contains(id) ? .section(id) : fallback
        case .lastPage:
            if let lastPage, visible.contains(lastPage) { return .section(lastPage) }
            return fallback
        }
    }

    /// The section a ⌥⌘ letter opens, among the visible ones.
    public static func section(forShortcut key: Character, visible: [IslandSectionID]) -> IslandSectionID? {
        let lower = Character(key.lowercased())
        return visible.first { $0.shortcut == lower }
    }

    /// ⌃Tab / ⌃⇧Tab: the next or previous visible section, wrapping.
    public static func cycle(from current: IslandSectionID?, visible: [IslandSectionID], forward: Bool) -> IslandSectionID? {
        guard !visible.isEmpty else { return nil }
        guard let current, let index = visible.firstIndex(of: current) else { return forward ? visible.first : visible.last }
        let next = (index + (forward ? 1 : -1) + visible.count) % visible.count
        return visible[next]
    }

    /// Explore search: every typed word must match (any order), ignoring case, accents, width and
    /// surrounding spaces, against the title, the identifier and search aliases.
    public static func search(_ query: String, in sections: [IslandSectionID]) -> [IslandSectionID] {
        let words = normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return sections }
        return sections.filter { section in
            let haystack = section.searchTerms.map(normalize).joined(separator: " ")
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The Explore gallery's rows: whole rows step, with a resting position per row that can lead.
public struct IslandExplorePaging: Equatable, Sendable {
    public static let tileWidth: CGFloat = 92
    public static let tileHeight: CGFloat = 86
    public static let spacing: CGFloat = 8
    public static let indicatorWidth: CGFloat = 12

    public var columns: Int
    public var rows: Int
    public var visibleRows: Int

    public init(count: Int, contentWidth: CGFloat, height: CGFloat) {
        columns = max(1, Int((contentWidth - Self.indicatorWidth + Self.spacing) / (Self.tileWidth + Self.spacing)))
        rows = max(1, Int(ceil(Double(count) / Double(columns))))
        visibleRows = max(1, min(rows, Int((height + Self.spacing) / (Self.tileHeight + Self.spacing))))
    }

    /// How many first-row positions exist.
    public var positions: Int { max(1, rows - visibleRows + 1) }

    public func clamp(_ first: Int) -> Int { min(max(0, first), positions - 1) }

    /// The first row that shows `row` while moving the least from `first`.
    public func reveal(_ row: Int, from first: Int) -> Int {
        let start = clamp(first)
        if row < start { return clamp(row) }
        if row >= start + visibleRows { return clamp(row - visibleRows + 1) }
        return start
    }
}
