import Foundation

/// A file the shelf holds by reference: the path it had when shelved plus a bookmark that finds it
/// again after a rename or move. `owned` files live in MenuSprite's private shelf storage (image data
/// with no file behind it, received file promises) and are deleted some time after they leave.
public struct ShelfFile: Codable, Sendable, Hashable {
    public var path: String
    public var bookmark: Data?
    public var owned: Bool

    public init(path: String, bookmark: Data? = nil, owned: Bool = false) {
        self.path = path
        self.bookmark = bookmark
        self.owned = owned
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }
}

/// What one shelf tile holds.
public enum ShelfContent: Sendable, Hashable {
    case file(ShelfFile)
    /// Plain text, at most `Shelf.textLimit` characters.
    case text(String)
    /// An http(s) address.
    case link(URL)
    /// Several things dropped together, in their original order.
    case pile([ShelfItem])
}

/// One tile on the shelf. Piles nest at most `Shelf.maxDepth` levels.
public struct ShelfItem: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var content: ShelfContent
    /// Pinned items survive "Remove items after dropping" and Clear all.
    public var pinned: Bool

    public init(id: UUID = UUID(), content: ShelfContent, pinned: Bool = false) {
        self.id = id
        self.content = content
        self.pinned = pinned
    }

    public var children: [ShelfItem] {
        if case .pile(let children) = content { return children }
        return []
    }

    public var isPile: Bool { if case .pile = content { return true }; return false }

    public var file: ShelfFile? { if case .file(let file) = content { return file }; return nil }

    /// Files, texts and links count one each; a pile counts its leaves.
    public var leafCount: Int { isPile ? children.reduce(0) { $0 + $1.leafCount } : 1 }

    /// This item's leaves in order (itself when it is not a pile).
    public var leaves: [ShelfItem] { isPile ? children.flatMap(\.leaves) : [self] }

    /// Whether this item or anything inside it is pinned.
    public var containsPinned: Bool { pinned || children.contains { $0.containsPinned } }

    public var title: String {
        switch content {
        case .file(let file): file.name
        case .text(let text): ShelfTitles.text(text)
        case .link(let url): ShelfTitles.link(url)
        case .pile(let children): children.count == 1 ? "1 item" : "\(leafCount) items"
        }
    }
}

public enum ShelfTitles {
    public static let textTitleLimit = 48

    /// The first non-blank line, at most 48 characters including the ellipsis.
    public static func text(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard line.count > textTitleLimit else { return line }
        return String(line.prefix(textTitleLimit - 1)) + "…"
    }

    public static func link(_ url: URL) -> String { url.host() ?? url.absoluteString }
}

/// The outcome of adding a drop to the shelf.
public enum ShelfAddResult: Equatable, Sendable {
    /// Added as one tile (a pile when the drop held several things).
    case added(UUID)
    /// Nothing usable was in the drop.
    case empty
    /// The drop would take the shelf past its capacity; nothing was added.
    case full
}

/// The shelf's ordered items and every rule that changes them. Selection and pile expansion are
/// transient and live with the view; this value is what gets saved.
public struct Shelf: Sendable, Equatable {
    public static let capacity = 200
    public static let maxDepth = 4
    public static let textLimit = 200_000

    public private(set) var items: [ShelfItem]

    public init(items: [ShelfItem] = []) { self.items = items.map { Self.limited($0, depth: 1) } }

    public var isEmpty: Bool { items.isEmpty }
    public var leafCount: Int { items.reduce(0) { $0 + $1.leafCount } }

    /// Whether `incoming` more leaves fit: 199 + 1 does, 200 + 1 and 199 + 2 do not.
    public func canAccept(_ incoming: Int) -> Bool { incoming > 0 && leafCount + incoming <= Self.capacity }

    /// Adds one drop. Several things become one ordered pile; a single thing is its own tile.
    @discardableResult
    public mutating func add(_ drop: [ShelfContent]) -> ShelfAddResult {
        let leaves = drop.map { ShelfItem(content: $0) }
        guard !leaves.isEmpty else { return .empty }
        let count = leaves.reduce(0) { $0 + $1.leafCount }
        guard canAccept(count) else { return .full }
        let item = leaves.count == 1 ? leaves[0] : ShelfItem(content: .pile(leaves))
        items.append(Self.limited(item, depth: 1))
        return .added(item.id)
    }

    public func item(_ id: UUID) -> ShelfItem? { Self.find(id, in: items) }

    /// The leaves of the given tiles, in shelf order, each once.
    public func leaves(of ids: Set<UUID>) -> [ShelfItem] {
        var seen = Set<UUID>()
        var result: [ShelfItem] = []
        func walk(_ list: [ShelfItem], chosen: Bool) {
            for item in list {
                let take = chosen || ids.contains(item.id)
                if item.isPile { walk(item.children, chosen: take) }
                else if take, seen.insert(item.id).inserted { result.append(item) }
            }
        }
        walk(items, chosen: false)
        return result
    }

    /// Whether anything in the given tiles is pinned, including the piles that hold them.
    public func containsPinned(_ ids: Set<UUID>) -> Bool {
        func walk(_ list: [ShelfItem], pinnedAbove: Bool) -> Bool {
            list.contains { item in
                let pinned = pinnedAbove || item.pinned
                if ids.contains(item.id) { return pinned || item.containsPinned }
                return walk(item.children, pinnedAbove: pinned)
            }
        }
        return walk(items, pinnedAbove: false)
    }

    /// Removes tiles outright, pinned or not (the Remove button).
    public mutating func remove(_ ids: Set<UUID>) {
        items = Self.prune(items) { ids.contains($0.id) ? .drop : .keep }
    }

    /// Clear all: every unpinned leaf goes; pinned items (and pinned piles, whole) stay.
    public mutating func clearAll() {
        items = Self.prune(items) { $0.pinned ? .keepWhole : ($0.isPile ? .keep : .drop) }
    }

    /// After a drag out with "Remove items after dropping": the dragged tiles leave, except what is
    /// pinned (itself, inside it, or the pile around it).
    public mutating func removeAfterDrag(_ ids: Set<UUID>) {
        func sweep(_ list: [ShelfItem], dragged: Bool) -> [ShelfItem] {
            list.compactMap { item in
                if item.pinned { return item }
                let inDrag = dragged || ids.contains(item.id)
                guard item.isPile else { return inDrag ? nil : item }
                return Self.rebuilt(item, children: sweep(item.children, dragged: inDrag))
            }
        }
        items = sweep(items, dragged: false)
    }

    public mutating func setPinned(_ ids: Set<UUID>, _ pinned: Bool) {
        items = Self.map(items) { item in
            var item = item
            if ids.contains(item.id) { item.pinned = pinned }
            return item
        }
    }

    /// Replaces a file's reference in place (a bookmark found it somewhere new).
    public mutating func updateFile(_ id: UUID, _ file: ShelfFile) {
        items = Self.map(items) { item in
            guard item.id == id, item.file != nil else { return item }
            var item = item
            item.content = .file(file)
            return item
        }
    }

    /// Owned payloads referenced by the shelf, so storage can tell which ones are orphans.
    public var ownedPaths: Set<String> {
        Set(items.flatMap(\.leaves).compactMap { $0.file?.owned == true ? $0.file?.path : nil })
    }

    // MARK: Helpers

    private enum Verdict { case keep, keepWhole, drop }

    private static func prune(_ list: [ShelfItem], _ verdict: (ShelfItem) -> Verdict) -> [ShelfItem] {
        list.compactMap { item in
            switch verdict(item) {
            case .drop: return nil
            case .keepWhole: return item
            case .keep:
                guard item.isPile else { return item }
                return rebuilt(item, children: prune(item.children, verdict))
            }
        }
    }

    /// A pile after some of its children left: gone when empty, the child itself when one is left.
    private static func rebuilt(_ pile: ShelfItem, children: [ShelfItem]) -> ShelfItem? {
        switch children.count {
        case 0: return nil
        case 1 where !pile.pinned:
            return children[0]
        default:
            var pile = pile
            pile.content = .pile(children)
            return pile
        }
    }

    private static func map(_ list: [ShelfItem], _ transform: (ShelfItem) -> ShelfItem) -> [ShelfItem] {
        list.map { item in
            var item = transform(item)
            if item.isPile { item.content = .pile(map(item.children, transform)) }
            return item
        }
    }

    private static func find(_ id: UUID, in list: [ShelfItem]) -> ShelfItem? {
        for item in list {
            if item.id == id { return item }
            if let found = find(id, in: item.children) { return found }
        }
        return nil
    }

    /// Piles deeper than `maxDepth` are flattened into their parent; text is capped.
    private static func limited(_ item: ShelfItem, depth: Int) -> ShelfItem {
        var item = item
        switch item.content {
        case .text(let text) where text.count > textLimit:
            item.content = .text(String(text.prefix(textLimit)))
        case .pile(let children):
            if depth >= maxDepth {
                item.content = .pile(children.flatMap(\.leaves))
            } else {
                item.content = .pile(children.map { limited($0, depth: depth + 1) })
            }
        default: break
        }
        return item
    }
}

/// One visible tile in the strip: an item, and the pile it sits in when that pile is expanded.
public struct ShelfTile: Sendable, Hashable, Identifiable {
    public var item: ShelfItem
    public var parent: UUID?
    public var isExpanded: Bool
    public var id: UUID { item.id }
}

extension Shelf {
    /// The strip's tiles in reading order. An expanded pile shows its own tile followed by its children.
    public func tiles(expanded: Set<UUID>) -> [ShelfTile] {
        var result: [ShelfTile] = []
        func walk(_ list: [ShelfItem], parent: UUID?) {
            for item in list {
                let open = item.isPile && expanded.contains(item.id)
                result.append(ShelfTile(item: item, parent: parent, isExpanded: open))
                if open { walk(item.children, parent: item.id) }
            }
        }
        walk(items, parent: nil)
        return result
    }
}
