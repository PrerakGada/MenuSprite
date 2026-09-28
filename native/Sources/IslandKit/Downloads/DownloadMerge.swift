import Foundation

/// A transfer a browser publishes through the system's file-progress channel (the one Finder draws
/// its progress bars from), as the watcher last read it.
public struct DownloadTransfer: Hashable, Sendable {
    /// Where the publisher says the file is now.
    public var url: URL
    public var fraction: Double?
    /// Bytes received so far, when known.
    public var bytes: Int64?
    public var isPaused: Bool
    public var firstSeen: Date

    public init(url: URL, fraction: Double?, bytes: Int64?, isPaused: Bool, firstSeen: Date) {
        self.url = url; self.fraction = fraction; self.bytes = bytes; self.isPaused = isPaused; self.firstSeen = firstSeen
    }

    /// The file this transfer becomes.
    public var finalURL: URL { DownloadNaming.finalURL(for: url) }
}

/// A browser's in-progress file found at the folder's top level.
public struct DownloadPartial: Hashable, Sendable {
    /// The `.crdownload` or `.part` file, or Safari's `.download` bundle.
    public var url: URL
    public var kind: DownloadPartialKind
    /// The growing file (Safari's payload inside the bundle), when it exists.
    public var identity: DownloadFileIdentity?
    public var modified: Date

    public init(url: URL, kind: DownloadPartialKind, identity: DownloadFileIdentity?, modified: Date) {
        self.url = url; self.kind = kind; self.identity = identity; self.modified = modified
    }

    public var finalURL: URL { DownloadNaming.finalURL(for: url) }
    public var size: Int64? { identity?.isRegular == true ? identity?.size : nil }
}

/// A visible file or folder at the folder's top level.
public struct DownloadFolderEntry: Hashable, Sendable {
    public var url: URL
    /// Added to the folder, else created, else last modified.
    public var date: Date
    public var isDirectory: Bool

    public init(url: URL, date: Date, isDirectory: Bool) {
        self.url = url; self.date = date; self.isDirectory = isDirectory
    }
}

/// A download proven finished (see `DownloadProof`).
public struct DownloadCompletion: Hashable, Sendable {
    public var url: URL
    public var date: Date
    public var identity: DownloadFileIdentity

    public init(url: URL, date: Date, identity: DownloadFileIdentity) {
        self.url = url; self.date = date; self.identity = identity
    }
}

/// One card on the Downloads page.
public struct DownloadItem: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        /// `active` while bytes are still arriving: a live, unpaused publication, or a partial written
        /// to in the last two minutes.
        case inProgress(fraction: Double?, bytes: Int64?, active: Bool)
        case saved
    }

    /// The final path: each path appears once.
    public var path: String
    public var name: String
    /// What Show in Finder selects (the partial while in progress).
    public var revealURL: URL
    public var date: Date
    public var isDirectory: Bool
    public var status: Status

    public var id: String { path }

    public var isActive: Bool {
        if case .inProgress(_, _, true) = status { return true }
        return false
    }

    public var fraction: Double? {
        if case .inProgress(let fraction, _, _) = status { return fraction }
        return nil
    }
}

/// How the page's list is put together from what the watcher saw.
public enum DownloadMerge {
    /// A partial counts as active while it was written to this recently.
    public static let activeWindow: TimeInterval = 120
    /// The newest files handed to the main thread from a crowded folder.
    public static let listLimit = 200
    public static let partialLimit = 32
    public static let publicationLimit = 32
    /// Just-finished items kept, and for how long after the latest completion.
    public static let finishedLimit = 5
    public static let finishedLifetime: TimeInterval = 15

    public static func isActive(_ partial: DownloadPartial, now: Date) -> Bool {
        now.timeIntervalSince(partial.modified) < activeWindow
    }

    /// When the next active partial stops being active, so one timer can re-evaluate then.
    public static func nextExpiry(of partials: [DownloadPartial], now: Date) -> Date? {
        partials.map { $0.modified.addingTimeInterval(activeWindow) }.filter { $0 > now }.min()
    }

    /// The newest `limit` values by date, newest first.
    public static func newest<T>(_ values: [T], limit: Int, date: (T) -> Date) -> [T] {
        Array(values.sorted { date($0) > date($1) }.prefix(limit))
    }

    /// Publications first, then partials no publication represents, then folder entries, then
    /// just-finished items; each final path once. Active transfers lead, and everything else follows
    /// newest first, so an abandoned partial does not sit on top for ever.
    public static func items(transfers: [DownloadTransfer], partials: [DownloadPartial], files: [DownloadFolderEntry],
                             finished: [DownloadCompletion], now: Date) -> [DownloadItem] {
        var seen = Set<String>()
        var result: [DownloadItem] = []
        func add(_ item: DownloadItem, also other: String? = nil) {
            guard !seen.contains(item.path) else { return }
            seen.insert(item.path)
            if let other { seen.insert(other) }
            result.append(item)
        }
        for transfer in transfers.sorted(by: { $0.firstSeen > $1.firstSeen }) {
            let final = transfer.finalURL
            add(DownloadItem(path: final.path, name: final.lastPathComponent, revealURL: transfer.url, date: transfer.firstSeen,
                             isDirectory: false,
                             status: .inProgress(fraction: transfer.fraction, bytes: transfer.bytes, active: !transfer.isPaused)),
                also: transfer.url.path)
        }
        for partial in partials.sorted(by: { $0.modified > $1.modified }) where !seen.contains(partial.url.path) {
            let final = partial.finalURL
            add(DownloadItem(path: final.path, name: final.lastPathComponent, revealURL: partial.url, date: partial.modified,
                             isDirectory: false,
                             status: .inProgress(fraction: nil, bytes: partial.size, active: isActive(partial, now: now))),
                also: partial.url.path)
        }
        for file in files {
            add(DownloadItem(path: file.url.path, name: file.url.lastPathComponent, revealURL: file.url, date: file.date,
                             isDirectory: file.isDirectory, status: .saved))
        }
        for completion in finished {
            add(DownloadItem(path: completion.url.path, name: completion.url.lastPathComponent, revealURL: completion.url,
                             date: completion.date, isDirectory: false, status: .saved))
        }
        let active = result.filter(\.isActive)
        let rest = result.filter { !$0.isActive }.sorted { $0.date > $1.date }
        return active + rest
    }

    /// Whether a completion is news: a file already reported (same path, same file) is not announced twice.
    public static func isNew(_ completion: DownloadCompletion, in finished: [DownloadCompletion]) -> Bool {
        !finished.contains { $0.url.path == completion.url.path && $0.identity.isSameFile(as: completion.identity) }
    }

    /// The just-finished list after a completion: newest first, one per path, at most five.
    public static func adding(_ completion: DownloadCompletion, to finished: [DownloadCompletion]) -> [DownloadCompletion] {
        let others = finished.filter { $0.url.path != completion.url.path }
        return Array(([completion] + others).prefix(finishedLimit))
    }
}

/// Collapses a burst of changes into one batch of work. The first change after a flush asks the caller
/// to schedule one; later changes only replace the value waiting for their key, so a thousand changes
/// become one batch carrying the final values.
public struct DownloadBatch<Key: Hashable, Value> {
    public private(set) var pending: [Key: Value] = [:]
    private var scheduled = false

    public init() {}

    /// Records a change. Returns true when the caller should schedule a flush.
    public mutating func record(_ value: Value, for key: Key) -> Bool {
        pending[key] = value
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    /// Takes one key's waiting value out of the batch, for evidence that must not wait (unpublishing).
    public mutating func take(_ key: Key) -> Value? { pending.removeValue(forKey: key) }

    /// Everything waiting, once; the next change schedules a new flush.
    public mutating func flush() -> [Key: Value] {
        scheduled = false
        defer { pending = [:] }
        return pending
    }
}

extension DownloadBatch: Sendable where Key: Sendable, Value: Sendable {}
