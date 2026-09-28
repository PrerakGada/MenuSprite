import Foundation

/// Which tiles are selected. Transient: never saved, pruned whenever the shelf changes.
public struct ShelfSelection: Sendable, Equatable {
    public private(set) var selected: Set<UUID> = []
    /// The last plainly clicked tile, where a Shift-click range starts.
    public private(set) var anchor: UUID?

    public init() {}

    public var isEmpty: Bool { selected.isEmpty }
    public var count: Int { selected.count }
    public func contains(_ id: UUID) -> Bool { selected.contains(id) }

    /// A click toggles the tile. Shift-click adds every tile from the anchor to this one, in the
    /// strip's reading order.
    public mutating func click(_ id: UUID, extending: Bool, order: [UUID]) {
        if extending, let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            selected.formUnion(order[min(from, to)...max(from, to)])
            return
        }
        if selected.remove(id) == nil { selected.insert(id) }
        anchor = id
    }

    /// ⌘A: every visible tile.
    public mutating func selectAll(_ order: [UUID]) {
        selected = Set(order)
        anchor = order.first
    }

    /// Esc.
    public mutating func clear() {
        selected = []
        anchor = nil
    }

    /// Keeps only tiles that are still visible.
    public mutating func prune(to visible: [UUID]) {
        let valid = Set(visible)
        selected.formIntersection(valid)
        if let anchor, !valid.contains(anchor) { self.anchor = nil }
    }
}

/// The strip's measurements. Tiles fill each column top to bottom, then flow to the next column.
public enum ShelfLayout {
    public static let tileWidth: CGFloat = 78
    public static let tileHeight: CGFloat = 88
    public static let spacing: CGFloat = 8
    public static let footerHeight: CGFloat = 28
    public static let footerGap: CGFloat = 8
    public static let bottomInset: CGFloat = 10

    /// One tile row, the gap, the footer and the bottom inset.
    public static let minimumPageHeight: CGFloat = tileHeight + footerGap + footerHeight + bottomInset

    /// How many 88-pt rows fit: 140 → 1, 194 → 2, 0 → 1.
    public static func rows(height: CGFloat) -> Int {
        max(1, Int(((height + spacing) / (tileHeight + spacing)).rounded(.down)))
    }

    /// How many 78-pt columns fit: 276 → 3.
    public static func columns(width: CGFloat) -> Int {
        max(1, Int(((width + spacing) / (tileWidth + spacing)).rounded(.down)))
    }

    /// The strip's height inside a page of `pageHeight`.
    public static func stripHeight(pageHeight: CGFloat) -> CGFloat {
        max(tileHeight, pageHeight - footerGap - footerHeight - bottomInset)
    }
}

/// What a drag out of the shelf may do, as a platform-neutral option set.
public struct ShelfDragOperations: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let copy = ShelfDragOperations(rawValue: 1)
    public static let move = ShelfDragOperations(rawValue: 2)
}

public enum ShelfDragRules {
    /// Inside MenuSprite: move. Outside: copy, plus move only when dragged items leave the shelf
    /// afterwards and nothing pinned is in the drag, so a pinned or kept file is never moved away.
    public static func operations(withinApp: Bool, removeAfterDrop: Bool, containsPinned: Bool) -> ShelfDragOperations {
        if withinApp { return .move }
        return removeAfterDrop && !containsPinned ? [.copy, .move] : .copy
    }

    /// Whether the island collapses after a drag that started in it: only for a drop another app
    /// accepted, not a merge, with "Close after dropping" on, the island not pinned, and the island
    /// still the one the drag started from.
    public static func collapsesAfterDrop(accepted: Bool, merged: Bool, closeAfterDrop: Bool,
                                          pinned: Bool, sameIsland: Bool) -> Bool {
        accepted && !merged && closeAfterDrop && !pinned && sameIsland
    }

    /// Whether dragged items leave the shelf: only after an accepted drop with the option on.
    public static func removesAfterDrop(accepted: Bool, removeAfterDrop: Bool) -> Bool {
        accepted && removeAfterDrop
    }
}

/// What to do with a shelved file whose path no longer exists.
public enum ShelfFileHealth {
    public enum Verdict: Equatable, Sendable {
        case present
        /// The bookmark found it at a new path: update the item in place.
        case moved(String)
        /// On a disk that is not mounted right now: keep it, it may come back.
        case offline
        /// Gone for good: remove it.
        case gone
    }

    /// `/Volumes/<name>/…` on a volume that is not currently mounted.
    public static func isOnUnmountedVolume(_ path: String, mounted: Set<String>) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return false }
        return !mounted.contains("/Volumes/" + parts[2])
    }

    public static func verdict(path: String, exists: Bool, resolved: String?, mounted: Set<String>) -> Verdict {
        if exists { return .present }
        if let resolved, resolved != path { return .moved(resolved) }
        return isOnUnmountedVolume(path, mounted: mounted) ? .offline : .gone
    }
}

/// Recognises a content drag from global mouse events. A gesture is a content drag only when the
/// drag pasteboard changed since the mouse went down and holds something the shelf can take. When
/// the mouse-down was never seen (window moves on recent macOS), the first dragged event sets the
/// baseline, so a window move is never mistaken for a drag.
public struct ShelfDragGesture: Sendable {
    public private(set) var baseline: Int?
    public private(set) var isContentDrag = false
    private var decided = false

    public init() {}

    public var isActive: Bool { baseline != nil }

    /// Whether the next dragged event still needs the pasteboard's change count.
    public var needsChangeCount: Bool { baseline == nil || !decided }

    public mutating func mouseDown(changeCount: Int) {
        baseline = changeCount
        isContentDrag = false
        decided = false
    }

    /// Returns true once, on the event that recognises the content drag. The type check runs only
    /// when the change count moved, and at most once per gesture.
    public mutating func dragged(changeCount: Int, hasDroppableType: () -> Bool) -> Bool {
        guard let baseline else {
            self.baseline = changeCount
            return false
        }
        guard !decided, changeCount != baseline else { return false }
        decided = true
        isContentDrag = hasDroppableType()
        return isContentDrag
    }

    public mutating func mouseUp() {
        baseline = nil
        isContentDrag = false
        decided = false
    }
}

/// Shaking the pointer while dragging opens the separate shelf: three quick reversals of horizontal
/// direction, each at least `minimumTravel` points, within `window` seconds. MenuSprite's own values.
public struct ShelfShakeDetector: Sendable {
    public var minimumTravel: Double
    public var window: TimeInterval
    public var reversalsNeeded: Int

    private var lastX: Double?
    private var direction = 0
    private var travel: Double = 0
    private var reversals: [TimeInterval] = []

    public init(minimumTravel: Double = 30, window: TimeInterval = 0.6, reversalsNeeded: Int = 3) {
        self.minimumTravel = minimumTravel
        self.window = window
        self.reversalsNeeded = reversalsNeeded
    }

    /// Feeds one pointer position. Returns true once when the shake completes, then starts over.
    public mutating func move(x: Double, at time: TimeInterval) -> Bool {
        defer { lastX = x }
        guard let lastX else { return false }
        let delta = x - lastX
        guard delta != 0 else { return false }
        let heading = delta > 0 ? 1 : -1
        if heading == direction {
            travel += abs(delta)
            return false
        }
        if direction != 0, travel >= minimumTravel {
            reversals.append(time)
            reversals.removeAll { time - $0 > window }
        }
        direction = heading
        travel = abs(delta)
        guard reversals.count >= reversalsNeeded else { return false }
        reset()
        return true
    }

    public mutating func reset() {
        lastX = nil
        direction = 0
        travel = 0
        reversals = []
    }
}
