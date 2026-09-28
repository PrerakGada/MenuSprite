import Foundation

/// The outcome of one selection pass.
public struct MusicSelectionResult: Equatable, Sendable {
    /// The player to follow, or nil for "nothing playing".
    public var follow: MusicSourceKey?
    /// The chooser's rows: sources with a track, plus the chosen one while it waits for its next track.
    public var listed: [MusicSource]
    /// The manual choice's pid while one exists (even while it bridges).
    public var chosenPID: Int32?
    public var isBridging: Bool
    /// When the selection must be evaluated again even if nothing else happens (a bridge expiring).
    public var nextDeadline: Double?
}

/// Which player the island follows. Automatic follows playing music apps first (other apps only
/// when opted in); a manual choice wins while its player has a track, and survives a short gap
/// between tracks (a browser clearing its session between videos) for five seconds.
///
/// Times are monotonic seconds (system uptime), so a clock change cannot stretch a wait.
public struct MusicSelection: Equatable, Sendable {
    public static let bridgeSeconds: Double = 5

    public private(set) var chosen: MusicSourceKey?
    public private(set) var bridgeDeadline: Double?
    /// The player followed by the previous pass; it wins ties.
    public private(set) var followed: MusicSourceKey?

    public init() {}

    /// Picks a source by hand, or Automatic with nil. Returns false when that changes nothing
    /// (choosing the source already in effect, or Automatic while automatic).
    @discardableResult
    public mutating func choose(_ key: MusicSourceKey?) -> Bool {
        guard key != chosen else { return false }
        chosen = key
        bridgeDeadline = nil
        return true
    }

    /// Forgets the previously followed player (the reader stopped).
    public mutating func forgetFollowed() { followed = nil }

    /// Players the adapter must read even when MediaRemote does not list them.
    public var extraCandidates: [MusicSourceKey] {
        var keys: [MusicSourceKey] = []
        if let chosen { keys.append(chosen) }
        if let followed, followed != chosen { keys.append(followed) }
        return keys
    }

    /// One pass over a discovery. `alive` answers whether a process still runs with that bundle id.
    public mutating func resolve(_ discovery: MusicDiscovery, includeOthers: Bool, now: Double,
                                 alive: (MusicSourceKey) -> Bool) -> MusicSelectionResult {
        let byPID = Dictionary(discovery.sources.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var chosenSource: MusicSource?

        // Maintain the manual choice first.
        if let key = chosen {
            let listed = byPID[key.pid]
            let expired = bridgeDeadline.map { now >= $0 } ?? false
            if !alive(key) || (listed != nil && listed?.bundleID != key.bundleID) || (expired && listed?.hasTrack != true) {
                chosen = nil
                bridgeDeadline = nil
            } else if let listed {
                // A track seen again ends the wait; losing it starts one (never moved while it runs).
                if listed.hasTrack { bridgeDeadline = nil } else if bridgeDeadline == nil { bridgeDeadline = now + Self.bridgeSeconds }
                chosenSource = listed
            }
        }

        let bridging = chosenSource.map { !$0.hasTrack } ?? false
        var listed = discovery.sources.filter(\.hasTrack)
        if bridging, let chosenSource, !listed.contains(where: { $0.pid == chosenSource.pid }) { listed.append(chosenSource) }
        listed = Array(listed.sorted { $0.pid < $1.pid }.prefix(MusicWire.maxSources))

        var follow: MusicSourceKey?
        if let chosenSource, chosenSource.hasTrack {
            follow = chosenSource.key
        } else if chosen != nil, !bridging {
            // A choice that is neither playing nor bridging shows no stale controls.
            follow = nil
        } else {
            follow = automatic(discovery, includeOthers: includeOthers)
        }
        followed = follow
        return MusicSelectionResult(follow: follow, listed: listed, chosenPID: chosen?.pid, isBridging: bridging,
                                    nextDeadline: bridging ? bridgeDeadline : nil)
    }

    private func automatic(_ discovery: MusicDiscovery, includeOthers: Bool) -> MusicSourceKey? {
        let sources = discovery.sources.filter(\.hasTrack)
        func pick(_ candidates: [MusicSource]) -> MusicSourceKey? {
            guard !candidates.isEmpty else { return nil }
            if let followed, let match = candidates.first(where: { $0.key == followed }) { return match.key }
            if let current = discovery.current, let match = candidates.first(where: { $0.pid == current }) { return match.key }
            return candidates.min { $0.pid < $1.pid }?.key
        }
        if let key = pick(sources.filter { $0.isMusicApp && $0.isPlaying }) { return key }
        if includeOthers, let key = pick(sources.filter {
            !$0.isMusicApp && $0.isPlaying && ($0.pid == discovery.current || $0.key == followed)
        }) { return key }
        if let key = pick(sources.filter(\.isMusicApp)) { return key }
        if includeOthers, let current = discovery.current, let match = sources.first(where: { $0.pid == current }) { return match.key }
        return nil
    }
}

/// "Music app" means: its category is music, or it (or its owning app) is Music, iTunes or Spotify.
public enum MusicAppCategory {
    public static let knownPlayers: Set<String> = ["com.apple.Music", "com.apple.iTunes", "com.spotify.client"]

    public static func isMusicApp(bundleID: String, parentBundleID: String?, category: String?) -> Bool {
        if category == "public.app-category.music" { return true }
        if knownPlayers.contains(bundleID) { return true }
        if let parentBundleID, knownPlayers.contains(parentBundleID) { return true }
        return bundleID.hasPrefix("com.spotify.client.")
    }
}
