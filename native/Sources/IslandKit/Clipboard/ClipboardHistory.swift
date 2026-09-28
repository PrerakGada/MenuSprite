import Foundation

/// The clipboard history as an ordered list: every pinned entry first, then the recent ones, newest
/// first. All rules about adding, trimming, pinning and reordering live here so they can be tested
/// without a pasteboard.
public struct ClipboardHistory: Equatable, Sendable {
    /// What all entries share, pinned first, then the newest.
    public struct Budgets: Equatable, Sendable {
        /// Text and paths, measured as escaped JSON: 64 MiB.
        public var text: Int
        /// Stored images and rich text, so Unlimited still has a bound on disk: 1 GiB.
        public var assets: Int
        public init(text: Int, assets: Int) { self.text = text; self.assets = assets }
        public static let standard = Budgets(text: 64 * 1024 * 1024, assets: 1024 * 1024 * 1024)
    }

    public private(set) var entries: [ClipboardEntry]

    public init(entries: [ClipboardEntry] = []) {
        // Restore the one invariant a hand-edited or older file might break: pinned entries lead.
        self.entries = entries.filter(\.isPinned) + entries.filter { !$0.isPinned }
    }

    public var pinnedCount: Int { entries.lazy.filter(\.isPinned).count }
    public var hasRecent: Bool { entries.contains { !$0.isPinned } }

    public func entry(_ id: UUID) -> ClipboardEntry? { entries.first { $0.id == id } }

    /// What `record` did.
    public enum Recorded: Equatable, Sendable {
        /// A new entry was added.
        case added(UUID)
        /// An earlier copy of the same thing moved to the top of its group, keeping its id and pin.
        case moved(UUID)
        /// Nothing fits beside the pinned entries, so the copy was not kept.
        case dropped
    }

    /// Adds a copy. A duplicate moves the existing entry to the top of its group, keeping its id and
    /// pin, and takes the newer rich text; anything new goes on top of the recent group. Then trims.
    @discardableResult
    public mutating func record(_ entry: ClipboardEntry, limit: ClipboardLimit, budgets: Budgets = .standard) -> Recorded {
        if let index = entries.firstIndex(where: { $0.duplicates(entry) }) {
            var existing = entries.remove(at: index)
            existing.lastUsed = entry.lastUsed
            if entry.kind == .text, entry.rich != nil { existing.rich = entry.rich }
            insertAtTopOfGroup(existing)
            trim(limit: limit, budgets: budgets)
            return .moved(existing.id)
        }
        var fresh = entry
        fresh.pinnedAt = nil
        insertAtTopOfGroup(fresh)
        trim(limit: limit, budgets: budgets)
        return self.entry(fresh.id) == nil ? .dropped : .added(fresh.id)
    }

    /// Marks an entry as just used (pasted or copied again from the list): it moves to the top of its group.
    public mutating func touch(_ id: UUID, at date: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.lastUsed = date
        insertAtTopOfGroup(entry)
    }

    /// Keeps at most `limit` unpinned entries, then the text and asset budgets (pinned first, then
    /// newest). Returns what was removed.
    @discardableResult
    public mutating func trim(limit: ClipboardLimit, budgets: Budgets = .standard) -> [ClipboardEntry] {
        var removed: [ClipboardEntry] = []
        var text = 0
        var assets = 0
        var recent = 0
        var kept: [ClipboardEntry] = []
        kept.reserveCapacity(entries.count)
        for entry in entries {
            if entry.isPinned {
                text += entry.storageBytes
                assets += entry.assetBytes
                kept.append(entry)
                continue
            }
            let fitsCount: Bool
            switch limit {
            case .count(let maximum): fitsCount = recent < maximum
            case .unlimited: fitsCount = true
            }
            let fitsText = text + entry.storageBytes <= budgets.text
            let fitsAssets = assets + entry.assetBytes <= budgets.assets
            if fitsCount && fitsText && fitsAssets {
                recent += 1
                text += entry.storageBytes
                assets += entry.assetBytes
                kept.append(entry)
            } else {
                removed.append(entry)
            }
        }
        entries = kept
        return removed
    }

    /// Pins an entry at the top of the pinned group. A pin that would not fit the budgets on its own
    /// with the other pins is refused (returns false), so pinned entries can never be trimmed.
    @discardableResult
    public mutating func pin(_ id: UUID, at date: Date, budgets: Budgets = .standard) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        guard !entries[index].isPinned else { return true }
        let pinned = entries.filter(\.isPinned)
        let text = pinned.reduce(0) { $0 + $1.storageBytes } + entries[index].storageBytes
        let assets = pinned.reduce(0) { $0 + $1.assetBytes } + entries[index].assetBytes
        guard text <= budgets.text, assets <= budgets.assets else { return false }
        var entry = entries.remove(at: index)
        entry.pinnedAt = date
        insertAtTopOfGroup(entry)
        return true
    }

    /// Unpins an entry; it rejoins the recent group in order of when it was last used.
    public mutating func unpin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isPinned else { return }
        var entry = entries.remove(at: index)
        entry.pinnedAt = nil
        let position = entries.firstIndex { !$0.isPinned && $0.lastUsed < entry.lastUsed } ?? entries.count
        entries.insert(entry, at: position)
    }

    /// Whether an entry can move one place within its own group (pinned or recent).
    public func canMove(_ id: UUID, up: Bool) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let neighbour = up ? index - 1 : index + 1
        guard entries.indices.contains(neighbour) else { return false }
        return entries[neighbour].isPinned == entries[index].isPinned
    }

    public mutating func move(_ id: UUID, up: Bool) {
        guard canMove(id, up: up), let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.swapAt(index, up ? index - 1 : index + 1)
    }

    public mutating func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Removes every unpinned entry.
    public mutating func clearRecent() {
        entries.removeAll { !$0.isPinned }
    }

    /// Removes everything, pinned included.
    public mutating func clearAll() {
        entries.removeAll()
    }

    private mutating func insertAtTopOfGroup(_ entry: ClipboardEntry) {
        let position = entry.isPinned ? 0 : (entries.firstIndex { !$0.isPinned } ?? entries.count)
        entries.insert(entry, at: position)
    }
}
