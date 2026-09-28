import Foundation

/// The person's order of mixer columns. Alphabetical until they move something; then every app they
/// have seen keeps a remembered slot, including apps that are closed or hidden right now, so an app
/// coming back lands where it was. Pinned apps lead and are ordered among themselves; nothing moves
/// across the pin boundary except pinning and unpinning.
public struct MixerArrangement: Codable, Equatable, Sendable {
    /// Every arranged storage key, in order.
    public private(set) var slots: [String]
    public private(set) var pinned: Set<String>

    public init(slots: [String] = [], pinned: Set<String> = []) {
        var seen = Set<String>()
        self.slots = slots.compactMap { MixerIdentity.clean($0) }.filter { seen.insert($0).inserted }
        self.pinned = Set(pinned.compactMap { MixerIdentity.clean($0) }).intersection(self.slots)
    }

    private enum CodingKeys: String, CodingKey { case slots, pinned }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(slots: try container.decode([String].self, forKey: .slots),
                  pinned: Set(try container.decodeIfPresent([String].self, forKey: .pinned) ?? []))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slots, forKey: .slots)
        try container.encode(slots.filter { pinned.contains($0) }, forKey: .pinned)
    }

    /// Reads a stored arrangement; anything that is not valid arrangement data gives the default.
    public static func decode(_ stored: Any?) -> MixerArrangement {
        guard let data = stored as? Data, let value = try? JSONDecoder().decode(MixerArrangement.self, from: data) else {
            return MixerArrangement()
        }
        return value
    }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public var isArranged: Bool { !slots.isEmpty }

    public func isPinned(_ key: String) -> Bool { pinned.contains(key) }

    /// The display order of `apps`: pinned first, then the rest; each group by remembered slot, apps
    /// without a slot (new apps, and apps with no stable identity) after the arranged ones, alphabetically.
    public func order(_ apps: [MixerApp]) -> [MixerApp] {
        let alphabetical = MixerListing.alphabetical(apps)
        let rank = Dictionary(uniqueKeysWithValues: slots.enumerated().map { ($1, $0) })
        func group(_ pinnedGroup: Bool) -> [MixerApp] {
            let members = alphabetical.filter { app in app.storageKey.map { pinned.contains($0) } == true ? pinnedGroup : !pinnedGroup }
            let arranged = members.filter { $0.storageKey.flatMap { rank[$0] } != nil }
                .sorted { rank[$0.storageKey!]! < rank[$1.storageKey!]! }
            return arranged + members.filter { $0.storageKey.flatMap { rank[$0] } == nil }
        }
        return group(true) + group(false)
    }

    /// Moves `key` next to `target` in the list the person sees (`visible`, in display order), keeping
    /// every other remembered slot. Missing keys, a move onto itself and a move across the pin
    /// boundary change nothing; a move never pins or unpins.
    public mutating func move(_ key: String, beside target: String, after: Bool, visible: [String]) {
        guard key != target, visible.contains(key), visible.contains(target), isPinned(key) == isPinned(target) else { return }
        var list = materialized(visible)
        list.removeAll { $0 == key }
        guard let index = list.firstIndex(of: target) else { return }
        list.insert(key, at: after ? index + 1 : index)
        slots = list
    }

    /// Move Left / Move Right: past the neighbour in the same group, if there is one.
    public mutating func step(_ key: String, forward: Bool, visible: [String]) {
        guard let neighbour = neighbour(of: key, forward: forward, visible: visible) else { return }
        move(key, beside: neighbour, after: forward, visible: visible)
    }

    /// Whether Move Left (or Right) can do anything for `key`.
    public func canStep(_ key: String, forward: Bool, visible: [String]) -> Bool {
        neighbour(of: key, forward: forward, visible: visible) != nil
    }

    private func neighbour(of key: String, forward: Bool, visible: [String]) -> String? {
        guard let index = visible.firstIndex(of: key) else { return nil }
        let candidates = forward ? Array(visible[(index + 1)...]) : Array(visible[..<index].reversed())
        return candidates.first.flatMap { isPinned($0) == isPinned(key) ? $0 : nil }
    }

    /// Pinning puts the app at the end of the pinned group.
    public mutating func pin(_ key: String, visible: [String]) {
        guard !isPinned(key), MixerIdentity.clean(key) != nil else { return }
        var list = materialized(visible)
        list.removeAll { $0 == key }
        let lastPinned = list.lastIndex { pinned.contains($0) }
        list.insert(key, at: lastPinned.map { $0 + 1 } ?? 0)
        slots = list
        pinned.insert(key)
    }

    /// Unpinning affects only this app, which keeps its remembered slot among the unpinned ones.
    public mutating func unpin(_ key: String) { pinned.remove(key) }

    /// Remembered slots plus any visible app not yet arranged, placed after the arranged ones in the
    /// order the person sees them.
    private func materialized(_ visible: [String]) -> [String] {
        var list = slots
        for key in visible where !list.contains(key) { list.append(key) }
        return list
    }
}
