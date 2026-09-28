import Foundation

// What crosses the pipe between MenuSprite and the Now Playing adapter running inside /usr/bin/perl:
// one JSON object per line in each direction. The adapter reads and sends; the app decides which
// player to follow (MusicSelection) and validates everything it is told before showing it.

/// A player process, named the way MediaRemote knows it.
public struct MusicSourceKey: Hashable, Sendable, Codable {
    public var pid: Int32
    public var bundleID: String
    public init(pid: Int32, bundleID: String) { self.pid = pid; self.bundleID = bundleID }
}

/// One candidate the adapter read during discovery.
public struct MusicSource: Equatable, Hashable, Sendable {
    public var pid: Int32
    public var bundleID: String
    /// The app to name and open: the owning app for a browser helper, else the player itself.
    public var displayBundleID: String
    public var name: String?
    public var isMusicApp: Bool
    public var isPlaying: Bool
    public var hasTrack: Bool

    public init(pid: Int32, bundleID: String, displayBundleID: String? = nil, name: String? = nil,
                isMusicApp: Bool, isPlaying: Bool, hasTrack: Bool) {
        self.pid = pid; self.bundleID = bundleID; self.displayBundleID = displayBundleID ?? bundleID
        self.name = name; self.isMusicApp = isMusicApp; self.isPlaying = isPlaying; self.hasTrack = hasTrack
    }

    public var key: MusicSourceKey { MusicSourceKey(pid: pid, bundleID: bundleID) }
}

/// Everything one discovery pass found: the system session's owner and every candidate it could read.
public struct MusicDiscovery: Equatable, Sendable {
    public var current: Int32?
    public var sources: [MusicSource]
    public init(current: Int32?, sources: [MusicSource]) { self.current = current; self.sources = sources }
}

/// What the player said it accepts. Nil means the list could not be read: unknown, not "no".
public struct MusicCapabilities: Equatable, Sendable {
    public var canPlay: Bool?
    public var canPause: Bool?
    public var canSeek: Bool?
    public var canSkipNext: Bool?
    public var canSkipPrevious: Bool?
    public init(canPlay: Bool? = nil, canPause: Bool? = nil, canSeek: Bool? = nil, canSkipNext: Bool? = nil, canSkipPrevious: Bool? = nil) {
        self.canPlay = canPlay; self.canPause = canPause; self.canSeek = canSeek
        self.canSkipNext = canSkipNext; self.canSkipPrevious = canSkipPrevious
    }
}

/// How a reply carried the cover.
public enum MusicArtworkPayload: Equatable, Sendable {
    case bytes(Data)
    /// Identical to the adapter's previous emission, so not re-sent.
    case unchanged
    case missing
}

/// The followed player's recording, as read by the adapter.
public struct MusicPlayback: Equatable, Sendable {
    /// Echoes the follow request it answers; a reply for an older request is dropped.
    public var sequence: Int
    public var pid: Int32
    public var bundleID: String
    public var displayBundleID: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double?
    /// Nil when the player shares no position.
    public var elapsed: Double?
    public var rate: Double
    public var isPlaying: Bool
    public var itemID: String?
    public var artwork: MusicArtworkPayload
    public var capabilities: MusicCapabilities
    /// Changes when the player or the recording changes; commands carry it so a gesture can only
    /// reach the recording that was on screen.
    public var revision: String
    /// The adapter may address this player directly (otherwise transport stays off).
    public var direct: Bool

    public init(sequence: Int, pid: Int32, bundleID: String, displayBundleID: String? = nil, title: String,
                artist: String = "", album: String = "", duration: Double? = nil, elapsed: Double? = nil, rate: Double = 1,
                isPlaying: Bool = true, itemID: String? = nil, artwork: MusicArtworkPayload = .missing,
                capabilities: MusicCapabilities = MusicCapabilities(), revision: String, direct: Bool = true) {
        self.sequence = sequence; self.pid = pid; self.bundleID = bundleID; self.displayBundleID = displayBundleID ?? bundleID
        self.title = title; self.artist = artist; self.album = album; self.duration = duration; self.elapsed = elapsed
        self.rate = rate; self.isPlaying = isPlaying; self.itemID = itemID; self.artwork = artwork
        self.capabilities = capabilities; self.revision = revision; self.direct = direct
    }

    public var key: MusicSourceKey { MusicSourceKey(pid: pid, bundleID: bundleID) }
    public var hasPosition: Bool { elapsed != nil }
}

public enum MusicReply: Equatable, Sendable {
    case sources(MusicDiscovery)
    case playback(MusicPlayback)
    /// The followed player has nothing to show.
    case empty(sequence: Int)
    case result(id: Int, ok: Bool)
    /// The adapter reported a failure; treated as no reply.
    case error(String)
}

public enum MusicTransportAction: String, Sendable, CaseIterable {
    case play, pause, toggle, next, previous
}

/// A message to the adapter.
public enum MusicCommand: Equatable, Sendable {
    /// Which player to follow, plus players to keep reading even if MediaRemote stops listing them
    /// (the manual choice and the previously followed one).
    case target(sequence: Int, follow: MusicSourceKey?, extra: [MusicSourceKey])
    case transport(id: Int, action: MusicTransportAction, pid: Int32, revision: String)
    case seek(id: Int, pid: Int32, revision: String, position: Double)
}

public enum MusicWire {
    public static let maxCommandBytes = 2048
    /// 12 MiB of artwork as base64 plus room for the rest of the line.
    public static let maxReplyBytes = 17 * 1024 * 1024
    public static let maxArtworkBytes = 12 * 1024 * 1024
    public static let maxSources = 16
    public static let maxPosition: Double = 604_800

    // MARK: Validation shared by both directions

    /// Identifiers (bundle ids, item ids): non-empty, at most 512 bytes, no NUL.
    public static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.utf8.contains(0)
    }

    public static func isValidRevision(_ value: String) -> Bool { UUID(uuidString: value) != nil }

    /// Trimmed, without control or newline characters, at most `limit` characters.
    public static func cleanText(_ value: String?, limit: Int = 300) -> String {
        guard let value else { return "" }
        let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return String(text.prefix(limit))
    }

    static func clampTime(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(0, value), maxPosition)
    }

    // MARK: Commands

    /// The command as one newline-terminated line, or nil when it carries an invalid identifier,
    /// a non-finite position or would exceed the size limit (the UI then releases its pending state).
    public static func encode(_ command: MusicCommand) -> Data? {
        var object: [String: Any]
        switch command {
        case let .target(sequence, follow, extra):
            object = ["cmd": "target", "seq": sequence]
            if let follow {
                guard follow.pid > 0, isValidIdentifier(follow.bundleID) else { return nil }
                object["follow"] = ["pid": follow.pid, "bundle": follow.bundleID]
            }
            let valid = extra.filter { $0.pid > 0 && isValidIdentifier($0.bundleID) }.prefix(4)
            object["extra"] = valid.map { ["pid": $0.pid, "bundle": $0.bundleID] }
        case let .transport(id, action, pid, revision):
            guard pid > 0, isValidRevision(revision) else { return nil }
            object = ["cmd": action.rawValue, "id": id, "pid": pid, "revision": revision.lowercased()]
        case let .seek(id, pid, revision, position):
            guard pid > 0, isValidRevision(revision), position.isFinite, (0...maxPosition).contains(position) else { return nil }
            object = ["cmd": "seek", "id": id, "pid": pid, "revision": revision.lowercased(), "position": position]
        }
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        data.append(0x0A)
        return data.count <= maxCommandBytes ? data : nil
    }

    // MARK: Replies

    /// Decodes one reply line. Malformed replies, wrong types (a pid sent as a boolean), invalid
    /// identities and oversized source lists decode to nil and are ignored.
    public static func decode(_ line: Data) -> MusicReply? {
        guard line.count <= maxReplyBytes, let wire = try? JSONDecoder().decode(WireReply.self, from: line) else { return nil }
        switch wire.type {
        case "sources":
            let list = wire.sources ?? []
            guard list.count <= maxSources, Set(list.map(\.pid)).count == list.count else {
                return .sources(MusicDiscovery(current: validPID(wire.current), sources: []))
            }
            let sources = list.compactMap { entry -> MusicSource? in
                guard entry.pid > 0, let bundle = entry.bundle, isValidIdentifier(bundle), bundle.count <= 255 else { return nil }
                let display = entry.display.flatMap { isValidIdentifier($0) && $0.count <= 255 ? $0 : nil }
                let name = cleanText(entry.name, limit: 256)
                return MusicSource(pid: entry.pid, bundleID: bundle, displayBundleID: display, name: name.isEmpty ? nil : name,
                                   isMusicApp: entry.music ?? false, isPlaying: entry.playing ?? false, hasTrack: entry.track ?? false)
            }
            return .sources(MusicDiscovery(current: validPID(wire.current), sources: sources.sorted { $0.pid < $1.pid }))
        case "playback":
            guard let sequence = wire.seq else { return nil }
            if wire.empty == true { return .empty(sequence: sequence) }
            guard let pid = validPID(wire.pid), let bundle = wire.bundle, isValidIdentifier(bundle), bundle.count <= 255,
                  let revision = wire.revision, isValidRevision(revision) else { return nil }
            let title = cleanText(wire.title)
            guard !title.isEmpty else { return .empty(sequence: sequence) }
            let display = wire.display.flatMap { isValidIdentifier($0) && $0.count <= 255 ? $0 : nil } ?? bundle
            let rate = wire.rate.map { $0.isFinite ? min(max(0, $0), 16) : 1 } ?? 1
            let item = wire.item.flatMap { isValidIdentifier($0) ? $0 : nil }
            let artwork: MusicArtworkPayload
            if let encoded = wire.artwork, let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= maxArtworkBytes {
                artwork = .bytes(bytes)
            } else if wire.artworkUnchanged == true {
                artwork = .unchanged
            } else {
                artwork = .missing
            }
            return .playback(MusicPlayback(
                sequence: sequence, pid: pid, bundleID: bundle, displayBundleID: display, title: title,
                artist: cleanText(wire.artist), album: cleanText(wire.album), duration: clampTime(wire.duration),
                elapsed: clampTime(wire.elapsed), rate: rate, isPlaying: wire.playing ?? (rate > 0), itemID: item,
                artwork: artwork,
                capabilities: MusicCapabilities(canPlay: wire.canPlay, canPause: wire.canPause, canSeek: wire.canSeek,
                                                canSkipNext: wire.canNext, canSkipPrevious: wire.canPrevious),
                revision: revision.lowercased(), direct: wire.direct ?? false))
        case "result":
            guard let id = wire.id else { return nil }
            return .result(id: id, ok: wire.ok ?? false)
        case "error":
            return .error(cleanText(wire.message))
        default:
            return nil
        }
    }

    static func validPID(_ value: Int32?) -> Int32? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private struct WireSource: Decodable {
        var pid: Int32
        var bundle: String?
        var display: String?
        var name: String?
        var music: Bool?
        var playing: Bool?
        var track: Bool?
    }

    private struct WireReply: Decodable {
        var type: String
        var seq: Int?
        var id: Int?
        var ok: Bool?
        var message: String?
        var current: Int32?
        var sources: [WireSource]?
        var empty: Bool?
        var pid: Int32?
        var bundle: String?
        var display: String?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var rate: Double?
        var playing: Bool?
        var item: String?
        var artwork: String?
        var artworkUnchanged: Bool?
        var canPlay: Bool?
        var canPause: Bool?
        var canSeek: Bool?
        var canNext: Bool?
        var canPrevious: Bool?
        var revision: String?
        var direct: Bool?
    }
}

/// Splits a byte stream into lines. A partial line waits for more bytes; a line over the limit is
/// dropped up to its newline only, so what follows it still arrives; a long unterminated frame is
/// discarded without keeping the growing input.
public struct MusicLineFramer: Sendable {
    public let limit: Int
    private var buffer = Data()
    private var discarding = false

    public init(limit: Int) { self.limit = limit }

    public mutating func append(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var rest = data[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let piece = rest[rest.startIndex..<newline]
            rest = rest[rest.index(after: newline)...]
            if discarding || buffer.count + piece.count > limit {
                discarding = false
                buffer.removeAll(keepingCapacity: false)
                continue
            }
            buffer.append(piece)
            if !buffer.isEmpty { lines.append(buffer) }
            buffer = Data()
        }
        if discarding { return lines }
        if buffer.count + rest.count > limit {
            discarding = true
            buffer.removeAll(keepingCapacity: false)
        } else {
            buffer.append(rest)
        }
        return lines
    }
}
