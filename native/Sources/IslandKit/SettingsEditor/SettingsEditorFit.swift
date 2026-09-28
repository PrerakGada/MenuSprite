import CoreGraphics
import Foundation

/// The four tabs of Settings › Dynamic Island.
public enum IslandSettingsTab: String, CaseIterable, Sendable, Identifiable {
    case layout, content, activity, behavior
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .layout: "Layout"
        case .content: "Content"
        case .activity: "Activity"
        case .behavior: "Behavior"
        }
    }
}

/// Whether the tab row fits as segments beside the open button, or folds into a pop-up menu so it
/// never makes the page wider than its column.
public enum IslandTabRowStyle: Equatable, Sendable { case segmented, menu }

public enum IslandTabRowFit {
    /// What a segment adds around its title (padding and divider).
    public static let segmentPadding: CGFloat = 30
    public static let openButtonWidth: CGFloat = 44
    public static let spacing: CGFloat = 12

    public static func segmentedWidth(titleWidths: [CGFloat]) -> CGFloat {
        titleWidths.reduce(0) { $0 + ceil($1) + segmentPadding }
    }

    public static func style(available: CGFloat, titleWidths: [CGFloat]) -> IslandTabRowStyle {
        segmentedWidth(titleWidths: titleWidths) + spacing + openButtonWidth <= available ? .segmented : .menu
    }
}

/// Where a row's choice control goes: beside the title while the whole row fits on one line, else
/// under the title text; a pop-up menu stands in when even that is too narrow. Never squeezed.
public enum IslandChoiceRowPlacement: Equatable, Sendable {
    case beside
    case underTitle
    case menuUnderTitle
    /// Even the menu is wider than the text column, so it starts under the icon.
    case menuUnderIcon
}

public enum IslandChoiceRowFit {
    public static let spacing: CGFloat = 16

    /// `leading` is the icon and its gap; the title text starts after it.
    public static func placement(available: CGFloat, leading: CGFloat, titleWidth: CGFloat, controlWidth: CGFloat,
                                 menuWidth: CGFloat) -> IslandChoiceRowPlacement {
        let textColumn = available - leading
        if leading + ceil(titleWidth) + spacing + controlWidth <= available { return .beside }
        if controlWidth <= textColumn { return .underTitle }
        if menuWidth <= textColumn { return .menuUnderTitle }
        return .menuUnderIcon
    }
}

/// The Content tab: the sections list, the options column, and the live preview beside them when the
/// page is wide enough, otherwise above the options.
public struct IslandContentEditorLayout: Equatable, Sendable {
    public static let wideListWidth: CGFloat = 216
    public static let narrowListWidth: CGFloat = 196
    public static let spacing: CGFloat = 16
    public static let previewMaxWidth: CGFloat = 560
    public static let stackedPreviewMaxHeight: CGFloat = 280
    /// Page width from which the preview gets a column of its own (a 940-pt window less its margins).
    public static let previewColumnMinimum: CGFloat = 884

    public enum Preview: Equatable, Sendable {
        case column(width: CGFloat)
        case above(maxHeight: CGFloat)
    }

    public var listWidth: CGFloat
    public var optionsWidth: CGFloat
    public var preview: Preview

    public init(pageWidth: CGFloat) {
        let wide = pageWidth >= Self.previewColumnMinimum
        listWidth = wide ? Self.wideListWidth : Self.narrowListWidth
        let remaining = max(0, pageWidth - listWidth - Self.spacing)
        if wide {
            let column = min(Self.previewMaxWidth, floor((remaining - Self.spacing) / 2))
            preview = .column(width: column)
            optionsWidth = remaining - Self.spacing - column
        } else {
            preview = .above(maxHeight: Self.stackedPreviewMaxHeight)
            optionsWidth = remaining
        }
    }

    /// One scale for every section, from the tallest page, so switching sections never moves the layout.
    public static func previewScale(islandWidth: CGFloat, tallestHeight: CGFloat, availableWidth: CGFloat,
                                    maxHeight: CGFloat?) -> CGFloat {
        guard islandWidth > 0, tallestHeight > 0 else { return 1 }
        var scale = min(1, max(0, availableWidth) / islandWidth)
        if let maxHeight { scale = min(scale, maxHeight / tallestHeight) }
        return max(0.1, scale)
    }
}

/// One entry of the "When reopening" menu.
public struct IslandReopenOption: Equatable, Sendable, Identifiable {
    public var value: IslandReopen
    public var title: String
    public var enabled: Bool
    public var id: String { value.storageValue }
}

public enum IslandReopenMenu {
    /// Last page, the app panel, Explore, then every visible section. A saved section that is now
    /// hidden stays listed, disabled, so the menu can still show what is saved.
    public static func options(visible: [IslandSectionID], saved: IslandReopen) -> [IslandReopenOption] {
        var options: [IslandReopenOption] = [
            .init(value: .lastPage, title: "Last page", enabled: true),
            .init(value: .appPanel, title: "Open app panel", enabled: true),
            .init(value: .explore, title: "Explore", enabled: true),
        ]
        options += visible.map { .init(value: .section($0), title: $0.title, enabled: true) }
        if case .section(let id) = saved, !visible.contains(id) {
            options.append(.init(value: saved, title: id.title, enabled: false))
        }
        return options
    }
}

/// When the settings page asks for Accessibility. It only ever checks; the person grants it.
public enum IslandSettingsHints {
    /// The volume, brightness and keyboard-light keys are taken over through Accessibility.
    public static let keyIndicators: Set<IslandIndicatorID> = [.volume, .brightness, .keyboardLight]

    /// Only indicators that are switched on and that this Mac can raise count.
    public static func indicatorsNeedAccessibility(_ settings: IslandSettings, available: Set<IslandIndicatorID>, trusted: Bool) -> Bool {
        settings.enabled && !trusted && !settings.indicators.intersection(available).isDisjoint(with: keyIndicators)
    }

    /// Making room for the menus on a display without a notch needs Accessibility; covering them
    /// ("Show over the menus") and hidden-until-hover do not.
    public static func menuRoomNeedsAccessibility(_ settings: IslandSettings, displayIsNotched: Bool?, trusted: Bool) -> Bool {
        guard settings.enabled, !trusted, let displayIsNotched else { return false }
        return !displayIsNotched && !settings.coversMenus && settings.opening != .hidden
    }
}

public enum IslandSectionOrder {
    /// The order after dragging `moving` onto `target`: it takes the target's place.
    public static func move(_ moving: IslandSectionID, onto target: IslandSectionID, in order: [IslandSectionID]) -> [IslandSectionID] {
        guard moving != target, let from = order.firstIndex(of: moving), let to = order.firstIndex(of: target) else { return order }
        var result = order
        result.remove(at: from)
        result.insert(moving, at: to)
        return result
    }

    /// Moves a section one place up (negative) or down; unchanged at either end.
    public static func shift(_ id: IslandSectionID, by offset: Int, in order: [IslandSectionID]) -> [IslandSectionID] {
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return order }
        var result = order
        result.swapAt(index, index + offset)
        return result
    }
}

/// The floating-button chooser's search, with the same matching as Explore.
public enum IslandActionSearch {
    public static func filter(_ query: String, _ actions: [IslandFloatingAction]) -> [IslandFloatingAction] {
        let words = IslandNavigation.normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return actions }
        return actions.filter { action in
            let haystack = IslandNavigation.normalize(action.title + " " + action.storageValue)
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}
