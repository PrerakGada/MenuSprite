import Foundation

public enum IslandSize: String, CaseIterable, Codable, Sendable {
    case compact, spacious, custom
    public var title: String {
        switch self {
        case .compact: "Compact"
        case .spacious: "Spacious"
        case .custom: "Custom"
        }
    }
}

/// How the closed island opens. Stored as one value rather than Vorssaint's three switches, so an
/// impossible combination (hidden without hover) cannot be saved.
public enum IslandOpening: String, CaseIterable, Codable, Sendable {
    case click, preview, expand, hidden
    public var title: String {
        switch self {
        case .click: "Click to open"
        case .preview: "Preview on hover"
        case .expand: "Expand on hover"
        case .hidden: "Hidden until hover"
        }
    }
    public var usesHover: Bool { self != .click }
}

public enum IslandDisplayChoice: String, CaseIterable, Codable, Sendable {
    case automatic, builtIn, main
    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .builtIn: "Built-in display"
        case .main: "Main display"
        }
    }
}

/// Where an opening that names no page lands.
public enum IslandReopen: Hashable, Sendable, Codable {
    case lastPage, appPanel, explore
    case section(IslandSectionID)

    public var storageValue: String {
        switch self {
        case .lastPage: "lastPage"
        case .appPanel: "appPanel"
        case .explore: "explore"
        case .section(let id): id.rawValue
        }
    }

    public init(storageValue: String) {
        switch storageValue {
        case "lastPage": self = .lastPage
        case "appPanel": self = .appPanel
        case "explore": self = .explore
        default: self = IslandSectionID(rawValue: storageValue).map { .section($0) } ?? .section(.controls)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(storageValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

public enum IslandFloatingSide: String, CaseIterable, Codable, Sendable {
    case left, right, bottom
    public var title: String { rawValue.capitalized }
}

public struct IslandFloatingButton: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var action: IslandFloatingAction
    public var side: IslandFloatingSide
    /// Optional name shown as the tooltip; single line, at most 40 characters.
    public var label: String

    public init(id: UUID = UUID(), action: IslandFloatingAction, side: IslandFloatingSide, label: String = "") {
        self.id = id; self.action = action; self.side = side; self.label = IslandFloatingButton.clean(label)
    }

    private enum CodingKeys: String, CodingKey { case id, action, side, label }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        action = try c.decode(IslandFloatingAction.self, forKey: .action)
        side = try c.decode(IslandFloatingSide.self, forKey: .side)
        label = IslandFloatingButton.clean((try? c.decodeIfPresent(String.self, forKey: .label)) ?? "")
    }

    public static func clean(_ label: String) -> String {
        let line = label.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String(line.prefix(40))
    }

    public var displayTitle: String { label.isEmpty ? action.title : label }
}

/// The round buttons beside the open island: at most three per side.
public struct IslandFloatingLayout: Codable, Sendable, Hashable {
    public static let perSide = 3
    public private(set) var buttons: [IslandFloatingButton]

    public init(buttons: [IslandFloatingButton]) {
        self.buttons = []
        for button in buttons.prefix(64) { _ = append(button) }
    }

    /// Explore and Timer on the left, Settings and the mixer on the right, Music below.
    public static let standard = IslandFloatingLayout(buttons: [
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, action: .explore, side: .left),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, action: .section(.timer), side: .left),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, action: .settings, side: .right),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!, action: .section(.mixer), side: .right),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!, action: .section(.music), side: .bottom),
    ])

    public func buttons(on side: IslandFloatingSide) -> [IslandFloatingButton] { buttons.filter { $0.side == side } }
    public func isFull(_ side: IslandFloatingSide) -> Bool { buttons(on: side).count >= Self.perSide }
    public var isEmpty: Bool { buttons.isEmpty }

    /// Adds a button to its side unless that side is full or the id already exists.
    @discardableResult
    public mutating func append(_ button: IslandFloatingButton) -> Bool {
        guard !isFull(button.side), !buttons.contains(where: { $0.id == button.id }) else { return false }
        var value = button
        value.label = IslandFloatingButton.clean(button.label)
        buttons.append(value)
        return true
    }

    public mutating func remove(_ id: UUID) { buttons.removeAll { $0.id == id } }

    public mutating func update(_ button: IslandFloatingButton) {
        guard let index = buttons.firstIndex(where: { $0.id == button.id }) else { return }
        var value = button
        value.label = IslandFloatingButton.clean(button.label)
        if value.side != buttons[index].side, isFull(value.side) { value.side = buttons[index].side }
        buttons[index] = value
    }

    /// Moves a button to `side`, before the sibling at `index` (appending when past the end).
    /// Refused when the destination side is full and the button is not already on it.
    @discardableResult
    public mutating func move(_ id: UUID, to side: IslandFloatingSide, at index: Int) -> Bool {
        guard let current = buttons.firstIndex(where: { $0.id == id }) else { return false }
        var button = buttons[current]
        if button.side != side, isFull(side) { return false }
        buttons.remove(at: current)
        button.side = side
        let siblings = buttons.enumerated().filter { $0.element.side == side }.map(\.offset)
        if index < siblings.count { buttons.insert(button, at: siblings[max(0, index)]) }
        else if let last = siblings.last { buttons.insert(button, at: last + 1) }
        else { buttons.append(button) }
        return true
    }

    /// Moves a button one place up or down within its side.
    public mutating func shift(_ id: UUID, by offset: Int) {
        guard let button = buttons.first(where: { $0.id == id }) else { return }
        let siblings = self.buttons(on: button.side)
        guard let position = siblings.firstIndex(of: button) else { return }
        let target = position + offset
        guard siblings.indices.contains(target) else { return }
        move(id, to: button.side, at: offset > 0 ? target + 1 : target)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown actions and malformed entries are dropped one by one rather than losing the layout.
        var entries = try container.nestedUnkeyedContainer(forKey: .buttons)
        var decoded: [IslandFloatingButton] = []
        while !entries.isAtEnd {
            if let button = try? entries.decode(IslandFloatingButton.self) { decoded.append(button) }
            else { _ = try? entries.decode(Discard.self) }
        }
        self.init(buttons: decoded)
    }

    private struct Discard: Decodable {}
    private enum CodingKeys: String, CodingKey { case buttons }
}

/// Every island preference. Decoding fills anything missing or unreadable with its default, so a
/// file written by an older or newer build never loses the rest.
public struct IslandSettings: Codable, Sendable, Equatable {
    public static let customWidthRange: ClosedRange<Double> = 360...600
    public static let customHeightRange: ClosedRange<Double> = 260...640
    public static let hoverDelayRange: ClosedRange<Double> = 0.10...1.00

    // Master switch and look.
    public var enabled = false
    public var size: IslandSize = .spacious
    public var customWidth: Double = 440 { didSet { customWidth = Self.clamp(customWidth, Self.customWidthRange, 440) } }
    public var customHeight: Double = 480 { didSet { customHeight = Self.clamp(customHeight, Self.customHeightRange, 480) } }
    public var outline = false

    // Behavior.
    public var opening: IslandOpening = .click
    public var hoverDelay: Double = 0.25 { didSet { hoverDelay = Self.clamp(hoverDelay, Self.hoverDelayRange, 0.25) } }
    public var gestures = true
    public var haptics = true
    public var reopen: IslandReopen = .lastPage
    public var hideInFullScreen = false
    public var display: IslandDisplayChoice = .automatic
    public var appPanelInIsland = false
    public var hideMenuBarIcon = false
    public var toolsInIsland = true
    public var clipboardInIsland = true
    public var filesInIsland = true
    public var dragReveal = true
    public var capturesInIsland = true
    public var scratchpadInIsland = true
    public var showInCaptures = true

    // Activity.
    public var atRest: IslandRestContent = .music
    public var coversMenus = true
    public var indicators: Set<IslandIndicatorID> = Set(IslandIndicatorID.allCases)

    // Content.
    public var sectionOrder: [IslandSectionID] = IslandSectionID.allCases
    public var hiddenSections: Set<IslandSectionID> = []
    public var hiddenCards: Set<IslandCardID> = []
    public var controlOrder: [IslandControlID] = IslandControlID.allCases
    public var hiddenControls: Set<IslandControlID> = IslandControlID.hiddenByDefault
    public var showPlayingMusic = true

    // Layout.
    public var floating: IslandFloatingLayout = .standard

    public init() {}

    static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Stored order with unknown and duplicate ids already gone, then any section missing from it.
    public var orderedSections: [IslandSectionID] {
        var seen = Set<IslandSectionID>()
        let stored = sectionOrder.filter { seen.insert($0).inserted }
        return stored + IslandSectionID.allCases.filter { !seen.contains($0) }
    }

    public var orderedControls: [IslandControlID] {
        var seen = Set<IslandControlID>()
        let stored = controlOrder.filter { seen.insert($0).inserted }
        return stored + IslandControlID.allCases.filter { !seen.contains($0) }
    }

    public func isVisible(_ section: IslandSectionID) -> Bool { !hiddenSections.contains(section) }

    public mutating func setVisible(_ section: IslandSectionID, _ visible: Bool) {
        if visible { hiddenSections.remove(section) } else { hiddenSections.insert(section) }
    }

    public mutating func setVisible(_ control: IslandControlID, _ visible: Bool) {
        if visible { hiddenControls.remove(control) } else { hiddenControls.insert(control) }
    }

    public mutating func setIndicator(_ indicator: IslandIndicatorID, _ on: Bool) {
        if on { indicators.insert(indicator) } else { indicators.remove(indicator) }
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case enabled, size, customWidth, customHeight, outline, opening, hoverDelay, gestures, haptics, reopen,
             hideInFullScreen, display, appPanelInIsland, hideMenuBarIcon, toolsInIsland, clipboardInIsland,
             filesInIsland, dragReveal, capturesInIsland, scratchpadInIsland, showInCaptures, atRest, coversMenus,
             indicators, sectionOrder, hiddenSections, hiddenCards, controlOrder, hiddenControls, showPlayingMusic,
             floating
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ current: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? current }
        // Sets and arrays of enums decode element by element so one unknown value cannot void the list.
        func readList<T: RawRepresentable & Decodable>(_ key: CodingKeys) -> [T]? where T.RawValue == String {
            guard let raw = try? c.decodeIfPresent([String].self, forKey: key) else { return nil }
            return raw.compactMap(T.init(rawValue:))
        }
        enabled = read(.enabled, enabled)
        size = read(.size, size)
        // Property observers do not run inside an initializer, so imported values clamp here.
        customWidth = Self.clamp(read(.customWidth, customWidth), Self.customWidthRange, 440)
        customHeight = Self.clamp(read(.customHeight, customHeight), Self.customHeightRange, 480)
        outline = read(.outline, outline)
        opening = read(.opening, opening)
        hoverDelay = Self.clamp(read(.hoverDelay, hoverDelay), Self.hoverDelayRange, 0.25)
        gestures = read(.gestures, gestures)
        haptics = read(.haptics, haptics)
        reopen = read(.reopen, reopen)
        hideInFullScreen = read(.hideInFullScreen, hideInFullScreen)
        display = read(.display, display)
        appPanelInIsland = read(.appPanelInIsland, appPanelInIsland)
        hideMenuBarIcon = read(.hideMenuBarIcon, hideMenuBarIcon)
        toolsInIsland = read(.toolsInIsland, toolsInIsland)
        clipboardInIsland = read(.clipboardInIsland, clipboardInIsland)
        filesInIsland = read(.filesInIsland, filesInIsland)
        dragReveal = read(.dragReveal, dragReveal)
        capturesInIsland = read(.capturesInIsland, capturesInIsland)
        scratchpadInIsland = read(.scratchpadInIsland, scratchpadInIsland)
        showInCaptures = read(.showInCaptures, showInCaptures)
        atRest = read(.atRest, atRest)
        coversMenus = read(.coversMenus, coversMenus)
        showPlayingMusic = read(.showPlayingMusic, showPlayingMusic)
        floating = read(.floating, floating)
        if let list: [IslandIndicatorID] = readList(.indicators) { indicators = Set(list) }
        if let list: [IslandSectionID] = readList(.sectionOrder) { sectionOrder = list }
        if let list: [IslandSectionID] = readList(.hiddenSections) { hiddenSections = Set(list) }
        if let list: [IslandCardID] = readList(.hiddenCards) { hiddenCards = Set(list) }
        if let list: [IslandControlID] = readList(.controlOrder) { controlOrder = list }
        if let list: [IslandControlID] = readList(.hiddenControls) { hiddenControls = Set(list) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(size, forKey: .size)
        try c.encode(customWidth, forKey: .customWidth)
        try c.encode(customHeight, forKey: .customHeight)
        try c.encode(outline, forKey: .outline)
        try c.encode(opening, forKey: .opening)
        try c.encode(hoverDelay, forKey: .hoverDelay)
        try c.encode(gestures, forKey: .gestures)
        try c.encode(haptics, forKey: .haptics)
        try c.encode(reopen, forKey: .reopen)
        try c.encode(hideInFullScreen, forKey: .hideInFullScreen)
        try c.encode(display, forKey: .display)
        try c.encode(appPanelInIsland, forKey: .appPanelInIsland)
        try c.encode(hideMenuBarIcon, forKey: .hideMenuBarIcon)
        try c.encode(toolsInIsland, forKey: .toolsInIsland)
        try c.encode(clipboardInIsland, forKey: .clipboardInIsland)
        try c.encode(filesInIsland, forKey: .filesInIsland)
        try c.encode(dragReveal, forKey: .dragReveal)
        try c.encode(capturesInIsland, forKey: .capturesInIsland)
        try c.encode(scratchpadInIsland, forKey: .scratchpadInIsland)
        try c.encode(showInCaptures, forKey: .showInCaptures)
        try c.encode(atRest, forKey: .atRest)
        try c.encode(coversMenus, forKey: .coversMenus)
        try c.encode(indicators.map(\.rawValue).sorted(), forKey: .indicators)
        try c.encode(sectionOrder.map(\.rawValue), forKey: .sectionOrder)
        try c.encode(hiddenSections.map(\.rawValue).sorted(), forKey: .hiddenSections)
        try c.encode(hiddenCards.map(\.rawValue).sorted(), forKey: .hiddenCards)
        try c.encode(controlOrder.map(\.rawValue), forKey: .controlOrder)
        try c.encode(hiddenControls.map(\.rawValue).sorted(), forKey: .hiddenControls)
        try c.encode(showPlayingMusic, forKey: .showPlayingMusic)
        try c.encode(floating, forKey: .floating)
    }
}
