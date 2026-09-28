import Foundation

/// One timed line. Blank text marks an instrumental gap that ends the previous verse.
public struct LyricLine: Equatable, Sendable {
    public var time: Double
    public var text: String
    public init(time: Double, text: String) { self.time = time; self.text = text }
}

/// What the lyrics panel has for one recording.
public enum LyricsContent: Equatable, Sendable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
}

public enum LyricsParser {
    public static let maxBytes = 128 * 1024
    public static let maxEntries = 2000
    public static let maxOffsetMilliseconds = 60_000
    public static let maxMinutes = 10_080

    /// Parses LRC text. Nil when the input is over the limits or no timed line has text. Each line may
    /// start with several `[m:ss(.fff)]` tags; every tag makes an entry with the line's text. An
    /// `[offset:N]` line moves every time N ms earlier. Entries past the duration are dropped, times
    /// below zero clamp to zero, and lines sharing a time are joined into one.
    public static func parse(_ text: String, duration: Double? = nil) -> [LyricLine]? {
        guard text.utf8.count <= maxBytes else { return nil }
        var offset = 0.0
        var entries: [LyricLine] = []
        var expandedBytes = 0
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            guard line.hasPrefix("[") else { continue }
            if let value = offsetTag(line) {
                offset = Double(value) / 1000
                continue
            }
            var rest = Substring(line)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                guard let time = timeTag(rest[rest.index(after: rest.startIndex)..<close]) else { break }
                times.append(time)
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let lyric = rest.trimmingCharacters(in: .whitespaces)
            for time in times {
                entries.append(LyricLine(time: time, text: lyric))
                expandedBytes += lyric.utf8.count
                guard entries.count <= maxEntries, expandedBytes <= maxBytes else { return nil }
            }
        }
        var shifted = entries.map { LyricLine(time: max(0, $0.time - offset), text: $0.text) }
        if let duration, duration > 0 { shifted.removeAll { $0.time > duration } }
        // Stable sort by time, then join lines that share a time.
        let sorted = shifted.enumerated().sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
        var lines: [LyricLine] = []
        for entry in sorted.map(\.element) {
            if let last = lines.last, last.time == entry.time {
                let parts = [last.text, entry.text].filter { !$0.isEmpty }
                lines[lines.count - 1].text = parts.joined(separator: "\n")
            } else {
                lines.append(entry)
            }
        }
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
        return lines
    }

    /// Whether a text has any timing tag at all (a plain-text import never invents timing).
    public static func hasTiming(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return false }
            return timeTag(trimmed[trimmed.index(after: trimmed.startIndex)..<close]) != nil
        }
    }

    static func offsetTag(_ line: String) -> Int? {
        let lower = line.lowercased()
        guard lower.hasPrefix("[offset:"), lower.hasSuffix("]") else { return nil }
        let body = line.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)
        guard let value = Int(body), abs(value) <= maxOffsetMilliseconds else { return nil }
        return value
    }

    static func timeTag(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy(\.isASCII), parts[0].allSatisfy(\.isNumber),
              let minutes = Int(parts[0]), minutes <= maxMinutes else { return nil }
        let secondsText = parts[1]
        guard !secondsText.isEmpty, secondsText.allSatisfy({ $0 == "." || ($0.isASCII && $0.isNumber) }),
              let seconds = Double(secondsText), seconds >= 0, seconds < 60 else { return nil }
        return Double(minutes) * 60 + seconds
    }
}

public enum LyricsTimeline {
    public static let offsetStep = 0.25
    public static let offsetLimit = 10.0
    /// Redraws land just after a boundary so rounding never leaves the old verse lit.
    static let nudge = 0.002

    public static func isValidOffset(_ offset: Double) -> Bool { offset.isFinite && abs(offset) <= offsetLimit }

    /// The lit line at a position: the last line whose time is at or before position − offset. A
    /// positive offset delays the lyrics.
    public static func index(_ lines: [LyricLine], position: Double, offset: Double) -> Int? {
        guard isValidOffset(offset), position.isFinite else { return nil }
        let target = position - offset
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= target { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// Wall-clock moments at which the lit line changes, from `position` at `now`, for a timeline
    /// that redraws only at line boundaries. Empty when paused, without a position, at rate 0 or with
    /// an invalid offset; otherwise ends with a far-future entry (SwiftUI may skip a schedule's last).
    public static func schedule(_ lines: [LyricLine], position: Double?, playing: Bool, rate: Double, offset: Double,
                                duration: Double?, now: Date) -> [Date] {
        guard playing, let position, position.isFinite, rate > 0, rate.isFinite, isValidOffset(offset) else { return [] }
        var dates: [Date] = []
        for line in lines {
            let boundary = line.time + offset
            guard boundary > position else { continue }
            if let duration, duration > 0, boundary > duration { break }
            dates.append(now.addingTimeInterval((boundary - position) / rate + nudge))
        }
        dates.append(.distantFuture)
        return dates
    }

    /// One step earlier or later, kept on the quarter-second grid within ±10 s.
    public static func adjust(_ offset: Double, by delta: Double) -> Double {
        let base = isValidOffset(offset) ? offset : 0
        let stepped = ((base + delta) / offsetStep).rounded() * offsetStep
        return min(max(stepped, -offsetLimit), offsetLimit)
    }
}

/// A lookup on lrclib.net for one recording, and the rule for accepting its answer.
public struct LyricsQuery: Equatable, Sendable {
    public static let endpoint = URL(string: "https://lrclib.net/api/get")!
    public static let maxResponseBytes = 128 * 1024

    public let title: String
    public let artist: String
    public let album: String
    public let duration: Int

    /// Nil when the recording lacks a title, artist or album (each at most 1024 bytes) or a duration
    /// of 1…3600 s: that is "not found" without a request.
    public init?(title: String, artist: String, album: String, duration: Double?) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = Self.normalizedAlbum(album)
        guard let duration, duration.isFinite else { return nil }
        let seconds = Int(duration.rounded())
        guard [title, artist, album].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }), (1...3600).contains(seconds) else { return nil }
        self.title = title; self.artist = artist; self.album = album; self.duration = seconds
    }

    /// Apple Music names singles and EPs "Album - Single"; LRCLIB does not.
    public static func normalizedAlbum(_ album: String) -> String {
        let trimmed = album.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Single", " - EP"] where trimmed.lowercased().hasSuffix(suffix.lowercased()) {
            return String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    /// The request URL: metadata travels as query items only.
    public var url: URL {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist),
                                 URLQueryItem(name: "album_name", value: album), URLQueryItem(name: "duration", value: String(duration))]
        return components.url!
    }

    /// An answer counts only for this exact recording: same title, artist and album (ignoring case)
    /// and a length within 2 s.
    public func accepts(_ response: LyricsResponse) -> Bool {
        func same(_ a: String?, _ b: String) -> Bool {
            guard let a else { return false }
            return a.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(b, options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        }
        guard let length = response.duration, length.isFinite else { return false }
        return same(response.trackName, title) && same(response.artistName, artist)
            && same(response.albumName.map(Self.normalizedAlbum), album) && abs(length - Double(duration)) <= 2
    }

    /// What an accepted answer provides; nil when it has nothing usable ("not found").
    public func content(of response: LyricsResponse) -> LyricsContent? {
        guard accepts(response) else { return nil }
        if response.instrumental == true { return .instrumental }
        if let synced = response.syncedLyrics, let lines = LyricsParser.parse(synced, duration: Double(duration)) { return .synced(lines) }
        if let plain = response.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty { return .plain(plain) }
        return nil
    }
}

/// LRCLIB's answer, as far as the island reads it.
public struct LyricsResponse: Decodable, Equatable, Sendable {
    public var trackName: String?
    public var artistName: String?
    public var albumName: String?
    public var duration: Double?
    public var instrumental: Bool?
    public var plainLyrics: String?
    public var syncedLyrics: String?

    public init(trackName: String?, artistName: String?, albumName: String?, duration: Double?, instrumental: Bool? = nil,
                plainLyrics: String? = nil, syncedLyrics: String? = nil) {
        self.trackName = trackName; self.artistName = artistName; self.albumName = albumName; self.duration = duration
        self.instrumental = instrumental; self.plainLyrics = plainLyrics; self.syncedLyrics = syncedLyrics
    }
}
