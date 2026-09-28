import Foundation

/// Decides when a reading is a new song worth a notice. It remembers the last song per player, so
/// another player standing in between tracks is a new song for neither, and a player's first song
/// after the reader starts (or changes source) only records where it is.
public struct MusicTrackChangeDetector: Equatable, Sendable {
    struct Song: Equatable, Sendable {
        var title: String
        var artist: String?
        func matches(_ other: Song) -> Bool {
            title == other.title && (artist == nil || other.artist == nil || artist == other.artist)
        }
    }

    private var songs: [String: Song] = [:]

    public init() {}

    /// The reader stopped or restarted: every player's next reading only records.
    public mutating func reset() { songs.removeAll() }

    /// Returns true when this reading moves `player` on to a different song. `player` is the
    /// bundle id, else the pid. A paused reading of a new song is not recorded, so the song counts
    /// once it plays (some players report the next song paused for a moment).
    public mutating func observe(player: String, title: String, artist: String, playing: Bool) -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return false }
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let song = Song(title: cleanTitle, artist: cleanArtist.isEmpty ? nil : cleanArtist)
        guard let previous = songs[player] else {
            songs[player] = song
            return false
        }
        if previous.matches(song) {
            if previous.artist == nil, song.artist != nil { songs[player] = song }
            return false
        }
        guard playing else { return false }
        songs[player] = song
        return true
    }
}

/// Which cover to show while recordings change. The adapter re-sends a cover only when its bytes
/// change, and players often publish a new title before its artwork, so:
/// - metadata-only updates of the same recording keep the cover;
/// - a different player starts clean;
/// - a new recording gets a 1.5 s grace in which the previous cover stays; identical bytes on the new
///   recording become its own cover only if no missing-artwork reply arrives within that grace;
/// - the grace never moves with repeated missing-artwork replies.
public struct MusicArtworkTracker<Cover: Equatable & Sendable>: Sendable {
    public static var grace: Double { 1.5 }

    public enum Input: Sendable {
        case cover(Cover)
        case unchanged
        case missing
    }

    public private(set) var shown: Cover?
    public private(set) var deadline: Double?
    private var player: MusicSourceKey?
    private var recording: String?
    private var lastEmitted: Cover?
    private var identical = false
    private var missingSeen = false

    public init() {}

    public mutating func receive(_ input: Input, player: MusicSourceKey, recording: String, now: Double) {
        var cover: Cover?
        switch input {
        case .cover(let value): cover = value; lastEmitted = value
        case .unchanged: cover = lastEmitted
        case .missing: cover = nil
        }
        if player != self.player {
            self.player = player
            self.recording = recording
            shown = cover
            deadline = nil
            return
        }
        if recording == self.recording {
            if let cover {
                if cover != shown { shown = cover; deadline = nil }
            } else if deadline != nil {
                missingSeen = true
            }
            return
        }
        self.recording = recording
        if let cover, cover != shown {
            shown = cover
            deadline = nil
            return
        }
        guard shown != nil else { deadline = nil; return }
        deadline = now + Self.grace
        identical = cover != nil
        missingSeen = cover == nil
    }

    /// Settles a grace that ran out: the repeated cover becomes the new recording's own, or the
    /// previous cover goes.
    public mutating func expire(now: Double) {
        guard let deadline, now >= deadline else { return }
        if !identical || missingSeen { shown = nil }
        self.deadline = nil
    }

    /// Forget everything (the reader stopped or the source changed).
    public mutating func reset() { self = MusicArtworkTracker() }
}

/// The glow colour taken from a cover's average colour. Grey or black covers get none; the rest are
/// stretched to one range so every cover glows with the same strength.
public enum MusicTint {
    public static func from(red: Double, green: Double, blue: Double) -> (red: Double, green: Double, blue: Double)? {
        let channels = [red, green, blue]
        guard channels.allSatisfy(\.isFinite), let high = channels.max(), let low = channels.min() else { return nil }
        guard high > 0.05, (high - low) / high >= 0.12 else { return nil }
        let span = high - low
        func stretch(_ value: Double) -> Double { 0.06 + (value - low) / span * 0.86 }
        return (stretch(red), stretch(green), stretch(blue))
    }
}
