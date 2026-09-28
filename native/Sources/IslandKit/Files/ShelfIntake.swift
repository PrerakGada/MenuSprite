import Foundation

/// What one dragged pasteboard item offers, already read from the platform pasteboard.
public struct ShelfPasteboardItem: Sendable, Equatable {
    /// A real file URL (file-reference URLs already resolved to a path).
    public var fileURL: URL?
    /// A file promise (Mail attachments, browser downloads, Photos).
    public var isPromise: Bool
    public var hasGIF: Bool
    public var hasImage: Bool
    /// A URL that is not a file URL.
    public var url: URL?
    public var text: String?

    public init(fileURL: URL? = nil, isPromise: Bool = false, hasGIF: Bool = false, hasImage: Bool = false,
                url: URL? = nil, text: String? = nil) {
        self.fileURL = fileURL
        self.isPromise = isPromise
        self.hasGIF = hasGIF
        self.hasImage = hasImage
        self.url = url
        self.text = text
    }
}

/// How the shelf will take one pasteboard item.
public enum ShelfCandidate: Sendable, Equatable {
    case file(URL)
    /// Delivered later by the promising app, then copied into private storage.
    case promise
    /// GIF data, stored as a .gif.
    case gif
    /// Other image data, converted to PNG.
    case image
    case link(URL)
    case text(String)
}

/// The acceptance order for dropped content. Per item: a real file, a file promise, GIF data, other
/// image data (so a browser image stays an image, not a link), a web link titled by its host, then
/// non-blank text. Items the shelf cannot use are skipped; files are taken once per drop.
public enum ShelfIntake {
    public static func candidate(for item: ShelfPasteboardItem) -> ShelfCandidate? {
        if let file = item.fileURL, file.isFileURL { return .file(file.standardizedFileURL) }
        if item.isPromise { return .promise }
        if item.hasGIF { return .gif }
        if item.hasImage { return .image }
        if let url = item.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil {
            return .link(url)
        }
        if let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(text) }
        return nil
    }

    /// The whole drop in order, with repeated files dropped.
    public static func plan(_ items: [ShelfPasteboardItem]) -> [ShelfCandidate] {
        var seen = Set<String>()
        return items.compactMap(candidate(for:)).filter { candidate in
            guard case .file(let url) = candidate else { return true }
            return seen.insert(url.path).inserted
        }
    }
}

/// Safety rules for files arriving from a promise.
public enum ShelfPromiseRules {
    /// A delivered file is taken only when it came without an error, is not a symbolic link, has a
    /// real name, and sits inside the folder it was promised into.
    public static func accepts(_ url: URL, folder: URL, isSymlink: Bool, failed: Bool) -> Bool {
        guard !failed, !isSymlink, url.isFileURL else { return false }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else { return false }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return parent.count >= base.count && Array(parent.prefix(base.count)) == base
    }
}

/// A drop whose parts arrive at different times (promised files, images being converted), kept in
/// the order they were dropped. Each slot is either ready or waits for a known number of files.
/// Cancelling wins over any delivery still queued.
public struct ShelfArrivals<Value: Sendable>: Sendable {
    public enum Slot: Sendable {
        case ready([Value])
        case waiting(expected: Int)
    }

    private var ready: [[Value]]
    private var outstanding: [Int]
    public private(set) var failures = 0
    public private(set) var isCancelled = false

    public init(_ slots: [Slot]) {
        ready = slots.map { if case .ready(let values) = $0 { return values }; return [] }
        outstanding = slots.map { if case .waiting(let expected) = $0 { return max(0, expected) }; return 0 }
    }

    /// Leaves the drop will hold if everything arrives, for the capacity check before accepting.
    public var plannedCount: Int { ready.reduce(0) { $0 + $1.count } + outstanding.reduce(0, +) }

    /// Records one arrival (nil when it failed). Returns false when it was ignored: cancelled, an
    /// unknown slot, or more arrivals than the slot expected.
    @discardableResult
    public mutating func deliver(_ value: Value?, to slot: Int) -> Bool {
        guard !isCancelled, outstanding.indices.contains(slot), outstanding[slot] > 0 else { return false }
        outstanding[slot] -= 1
        if let value { ready[slot].append(value) } else { failures += 1 }
        return true
    }

    public var isComplete: Bool { isCancelled || outstanding.allSatisfy { $0 == 0 } }

    /// Everything that arrived, in drop order.
    public var values: [Value] { isCancelled ? [] : ready.flatMap { $0 } }

    public mutating func cancel() { isCancelled = true }

    /// Gives up on anything still missing (the promising app never delivered); it counts as failed.
    public mutating func finishWaiting() {
        failures += outstanding.reduce(0, +)
        outstanding = outstanding.map { _ in 0 }
    }
}
