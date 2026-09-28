import Foundation

/// When the music reader (the perl child process) runs. This is the resource contract: the reader
/// runs only while something visible, or an enabled activity or notice, needs it.
public struct MusicReaderDemand: Equatable, Sendable {
    public var islandRunning = false
    /// The Now Playing section is shown in the island.
    public var sectionShown = false
    /// The Now Playing page is on screen (not a settings preview).
    public var musicPageVisible = false
    /// The Controls page is on screen with the Now Playing card.
    public var playbackCardVisible = false
    /// "Hidden until hover": nothing rests or notifies, so nothing may run in the background.
    public var hiddenUntilHover = false
    /// The island is hidden for a full-screen app and closed.
    public var hiddenForFullScreen = false
    /// Playing music may take the closed island (see `MusicActivityGate`).
    public var restingMusic = false
    /// The New track indicator is routed.
    public var newTrackNotices = false

    public init() {}

    public var shouldRun: Bool {
        guard islandRunning, sectionShown else { return false }
        if musicPageVisible || playbackCardVisible { return true }
        guard !hiddenUntilHover, !hiddenForFullScreen else { return false }
        return restingMusic || newTrackNotices
    }
}

public enum MusicActivityGate {
    /// Playing music takes the closed island only while the island is on, the Now Playing section
    /// is shown, At rest is not Nothing and "Show music while playing" is on.
    public static func allowsCompactMusic(_ settings: IslandSettings, sectionShown: Bool) -> Bool {
        settings.enabled && sectionShown && settings.atRest != .nothing && settings.showPlayingMusic
    }

    /// Whether the reader should run for the closed island's sake, the reader rule's background half.
    public static func demand(_ settings: IslandSettings, sectionShown: Bool, newTrackAvailable: Bool) -> (resting: Bool, notices: Bool) {
        (allowsCompactMusic(settings, sectionShown: sectionShown),
         settings.enabled && settings.indicators.contains(.newTrack) && newTrackAvailable)
    }
}

/// Restarts after an unexpected adapter exit: 1 s, then 2 s, then give up (the empty state shows).
/// An adapter that ran for more than a minute earns a fresh budget.
public struct MusicRestartBudget: Equatable, Sendable {
    public static let freshAfter: Double = 60
    public private(set) var retries = 0

    public init() {}

    public mutating func exited(afterRunning seconds: Double) -> Double? {
        if seconds > Self.freshAfter { retries = 0 }
        guard retries < 2 else { return nil }
        retries += 1
        return Double(retries)
    }

    public mutating func reset() { retries = 0 }
}

public enum MusicTime {
    /// `m:ss`, or `h:mm:ss` from one hour.
    public static func format(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// The position to draw: the reading, advanced by the time since it was read while playing,
    /// clamped to the recording.
    public static func position(elapsed: Double, readAt: Double, now: Double, playing: Bool, rate: Double, duration: Double?) -> Double {
        let advanced = elapsed + (playing ? max(0, now - readAt) * max(0, rate) : 0)
        let upper = (duration ?? 0) > 0 ? duration! : .greatestFiniteMagnitude
        return min(max(0, advanced), upper)
    }
}

/// Which transport message a play/pause press sends. Radio players that honour only discrete Play
/// and Pause get those; everything else, and an unanswered capability query, keeps Toggle.
public enum MusicPlayPause {
    public static func action(rate: Double, capabilities: MusicCapabilities) -> MusicTransportAction {
        if rate > 0, capabilities.canPause == true { return .pause }
        if rate <= 0, capabilities.canPlay == true { return .play }
        return .toggle
    }
}

/// A timeline drag. The thumb follows the pointer without seeking; one seek goes out on release.
/// The released thumb stays where it was dropped until a reading lands within 2 s of it, or for at
/// most 1 s, then follows playback again. Any change of recording cancels it.
public struct MusicScrub: Equatable, Sendable {
    public static let settleDistance: Double = 2
    public static let settleTime: Double = 1

    public let revision: String
    public private(set) var value: Double
    public private(set) var releasedAt: Double?

    public init(revision: String, value: Double) { self.revision = revision; self.value = value }

    public var isDragging: Bool { releasedAt == nil }

    public mutating func move(to value: Double) { if isDragging { self.value = value } }

    public mutating func release(at time: Double) { if releasedAt == nil { releasedAt = time } }

    /// Whether the thumb should still show the scrub value, given the latest reading (its position
    /// and when it was read).
    public func holds(position: Double?, readAt: Double?, revision: String?, now: Double) -> Bool {
        guard revision == self.revision else { return false }
        guard let releasedAt else { return true }
        if let position, let readAt, readAt > releasedAt, abs(position - value) <= Self.settleDistance { return false }
        return now - releasedAt < Self.settleTime
    }
}
