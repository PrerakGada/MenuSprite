import Foundation

/// Where a tool opens: its island page, or its own window.
public enum IslandToolRoute: Equatable, Sendable {
    case island, window
}

/// What the clipboard-history shortcut does.
public enum ClipboardRouting {
    public enum ShortcutAction: Equatable, Sendable {
        case openPage, closeIsland, toggleWindow
    }

    /// The island page only when the island is on, "Where Clipboard opens" says Dynamic Island and
    /// the section is shown; otherwise the history window. A hidden section never hides the history.
    public static func route(_ settings: IslandSettings) -> IslandToolRoute {
        settings.enabled && settings.clipboardInIsland && settings.isVisible(.clipboard) ? .island : .window
    }

    /// Toggles the island page (a second press collapses the island); the window when the island is
    /// not the destination or cannot take the page right now.
    public static func shortcut(_ settings: IslandSettings, islandAccepts: Bool, pageShowing: Bool) -> ShortcutAction {
        guard route(settings) == .island, islandAccepts else { return .toggleWindow }
        return pageShowing ? .closeIsland : .openPage
    }
}

/// Why the "Copied" indicator cannot show, in the order the person would fix it.
public enum ClipboardIndicatorBlocker: Equatable, Sendable {
    /// "Keep clipboard history" is off.
    case historyOff
    /// macOS asks (or refuses) before MenuSprite reads what other apps copy.
    case pasteboardAccess
    /// The Clipboard section is hidden on the Content tab.
    case sectionHidden

    /// Nil when the indicator can show: history kept, reading allowed, and the section shown.
    public static func check(historyOn: Bool, readingAllowed: Bool, sectionVisible: Bool) -> ClipboardIndicatorBlocker? {
        if !historyOn { return .historyOff }
        if !readingAllowed { return .pasteboardAccess }
        if !sectionVisible { return .sectionHidden }
        return nil
    }
}

/// What activating an entry does (click, Return, ⌘1–⌘9).
public enum ClipboardActivation: Equatable, Sendable {
    /// Write it, bring the remembered app forward and send ⌘V.
    case paste
    /// Write it only; there is nowhere to paste.
    case copy
    /// Write it only, and say that pasting needs Accessibility (MenuSprite never asks for it here).
    case copyNeedsAccessibility
    /// The remembered app has quit: write it and beep.
    case copyTargetGone

    public enum Target: Equatable, Sendable { case none, running, terminated }

    public static func decide(trusted: Bool, target: Target) -> ClipboardActivation {
        switch target {
        case .none: return .copy
        case .terminated: return .copyTargetGone
        case .running: return trusted ? .paste : .copyNeedsAccessibility
        }
    }
}

/// One representation written back to a pasteboard.
public enum ClipboardRepresentation: Equatable, Sendable {
    case string(String)
    case data(Data, type: String)
    case fileURLs([URL])
}

/// A pasteboard as the write sequence sees it, so the sequence can be tested with a fake.
public protocol ClipboardWritable {
    /// Clears the pasteboard and returns its new change count.
    func clear() -> Int
    func write(_ representation: ClipboardRepresentation) -> Bool
    var changeCount: Int { get }
}

/// Writes an entry back: nothing is touched if the deadline passed before the clear; a required
/// representation that fails reports failure and skips the optional ones; an optional one (TIFF,
/// RTF) that fails still counts as written.
public enum ClipboardWriteSequence {
    public enum Outcome: Equatable, Sendable {
        case written(changeCount: Int)
        case failed
        case expired
    }

    public static func perform(required: [ClipboardRepresentation], optional: [ClipboardRepresentation],
                               on pasteboard: some ClipboardWritable, expired: () -> Bool) -> Outcome {
        guard !required.isEmpty else { return .failed }
        guard !expired() else { return .expired }
        _ = pasteboard.clear()
        for representation in required where !pasteboard.write(representation) { return .failed }
        for representation in optional { _ = pasteboard.write(representation) }
        return .written(changeCount: pasteboard.changeCount)
    }
}
