import Foundation

/// This session's mirrored notifications, newest first, in memory only. The first complete read
/// after attaching is a baseline: banners already on screen are remembered as seen, never added or
/// announced. After that each unseen notification is added once; repeated reads of the same screen
/// never announce it again, and a dismissed one never comes back.
public struct NotificationInbox: Sendable, Equatable {
    public static let capacity = 50
    public static let seenLimit = 200

    public private(set) var mirrors: [NotificationMirror] = []
    public private(set) var hasBaseline = false
    private(set) var seen: [NotificationKey] = []
    private var nextID = 1

    public init() {}

    /// Applies one complete read. Returns the new arrivals still in the inbox, oldest first.
    @discardableResult
    public mutating func apply(_ snapshot: [NotificationSnapshotItem], at date: Date) -> [NotificationMirror] {
        let claims = Dictionary(grouping: snapshot.compactMap(\.nativeID), by: { $0 }).mapValues(\.count)
        var targets: [Int: NotificationLiveTarget] = [:]
        var arrivals: [Int] = []
        for item in snapshot {
            let target = NotificationLiveTarget(element: item.element, canPress: item.canPress, closeAction: item.closeAction,
                                                isPersistent: item.isPersistent,
                                                isAmbiguous: item.nativeID.map { (claims[$0] ?? 0) > 1 } ?? false)
            if let index = mirrors.firstIndex(where: { targets[$0.id] == nil && $0.key.identifies(item) }) {
                // A rebuilt view keeps the notification: follow its new element.
                mirrors[index].key.element = item.element
                if mirrors[index].source == nil { mirrors[index].source = item.source }
                targets[mirrors[index].id] = target
                continue
            }
            if let index = seen.firstIndex(where: { $0.identifies(item) }) {
                seen[index].element = item.element
                continue
            }
            seen.append(NotificationKey(item))
            guard hasBaseline else { continue }
            let mirror = NotificationMirror(id: nextID, key: NotificationKey(item), source: item.source, receivedAt: date, live: target)
            nextID += 1
            mirrors.insert(mirror, at: 0)
            targets[mirror.id] = target
            arrivals.append(mirror.id)
        }
        for index in mirrors.indices { mirrors[index].live = targets[mirrors[index].id] }
        hasBaseline = true
        if mirrors.count > Self.capacity { mirrors.removeLast(mirrors.count - Self.capacity) }
        if seen.count > Self.seenLimit {
            seen.removeAll { key in !snapshot.contains { key.identifies($0) } }
        }
        return arrivals.compactMap { id in mirrors.first { $0.id == id } }
    }

    /// Removes a mirror from the inbox (not from Notification Center). It stays seen.
    public mutating func dismiss(_ id: Int) { mirrors.removeAll { $0.id == id } }

    /// Empties the inbox; everything stays seen, so nothing on screen reappears.
    public mutating func removeAll() { mirrors.removeAll() }

    /// Notification Center restarted: its banners are new elements. Keep the messages, drop their
    /// native targets, and take a new baseline.
    public mutating func rebaseline() {
        hasBaseline = false
        for index in mirrors.indices { mirrors[index].live = nil }
    }

    /// Lock, suspension, the section switched off, Accessibility withdrawn: forget everything.
    public mutating func reset() {
        mirrors.removeAll()
        seen.removeAll()
        hasBaseline = false
    }

    public func mirror(_ id: Int) -> NotificationMirror? { mirrors.first { $0.id == id } }
}

/// Checks made against a fresh complete read immediately before acting on a native banner.
public enum NotificationValidation {
    /// The one item a mirror's key still identifies. Missing, duplicated or ambiguously claimed
    /// notifications give nothing, so no action can land on the wrong banner.
    public static func match(_ key: NotificationKey, in snapshot: [NotificationSnapshotItem]) -> NotificationSnapshotItem? {
        let matches = snapshot.filter { key.identifies($0) }
        guard matches.count == 1, let item = matches.first else { return nil }
        if let id = item.nativeID, snapshot.count(where: { $0.nativeID == id }) > 1 { return nil }
        return item
    }

    /// The item to press for Open: matched in the fresh read and still exposing AXPress there. A
    /// capability remembered from an earlier read never counts, and custom actions are never used.
    public static func pressable(_ key: NotificationKey, in snapshot: [NotificationSnapshotItem]) -> NotificationSnapshotItem? {
        guard let item = match(key, in: snapshot), item.canPress else { return nil }
        return item
    }

    /// The root's own close action: the one custom action whose name line is exactly
    /// `Name:<Close>` in Notification Center's language. "Close All" and group actions never match,
    /// and two matches are as good as none.
    public static func closeAction(in actions: [String], localizedClose: String) -> String? {
        let wanted = "Name:" + localizedClose
        let hits = actions.filter { action in
            action.split(whereSeparator: \.isNewline).contains { $0 == wanted }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// What may be closed: a transient banner with exactly one close action. Persistent alerts
    /// (alarms, reminders) are never closed.
    public static func closable(_ item: NotificationSnapshotItem) -> String? {
        item.isPersistent ? nil : item.closeAction
    }
}
