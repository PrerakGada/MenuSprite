import Foundation

/// The volume keys on top of the shared ownership gate: which presses the island takes, and what
/// each one does.
public struct IslandVolumeKeyGate: Sendable {
    public struct Conditions: Equatable, Sendable {
        /// The volume indicator is switched on and the island is running.
        public var routed: Bool
        /// The island currently shows notices (not hidden in full screen or until hover).
        public var showsNotices: Bool
        /// The output has a settable volume.
        public var hasVolume: Bool
        /// The output has a mute switch.
        public var hasMute: Bool

        public init(routed: Bool, showsNotices: Bool, hasVolume: Bool, hasMute: Bool) {
            self.routed = routed
            self.showsNotices = showsNotices
            self.hasVolume = hasVolume
            self.hasMute = hasMute
        }
    }

    public enum Outcome: Equatable, Sendable {
        case pass
        case consume
        case step(up: Bool, fine: Bool)
        case toggleMute
    }

    private var gate = IslandKeyGate()

    public init() {}

    public mutating func handle(_ event: IslandMediaKeyEvent, modifiers: IslandKeyModifiers, conditions: Conditions) -> Outcome {
        // Play, brightness and every other key never enter the volume path.
        guard IslandMediaKey.volumeKeys.contains(event.code) else { return .pass }
        let isMute = event.code == IslandMediaKey.mute
        let canContinue = conditions.routed && (isMute ? conditions.hasMute : conditions.hasVolume)
        let canStart = canContinue && conditions.showsNotices && !modifiers.leavesKeyToSystem
        switch gate.decide(event, canStart: canStart, canContinue: canContinue) {
        case .pass: return .pass
        case .consume: return .consume
        case .act(let isRepeat):
            // Mute toggles once per press; its repeats are swallowed so a held key cannot flicker.
            if isMute { return isRepeat ? .consume : .toggleMute }
            return .step(up: event.code == IslandMediaKey.volumeUp, fine: modifiers.isFine)
        }
    }

    public mutating func reset() { gate.reset() }
}

public enum IslandVolumeStep {
    public static let coarse = 1.0 / 16
    public static let fine = 1.0 / 64

    /// One key step. Stepping from muted starts at 0; the result stays within 0…1; raising the level
    /// above 0 also unmutes.
    public static func apply(current: Double, muted: Bool, up: Bool, fine: Bool) -> (volume: Double, unmute: Bool) {
        let start = muted || !current.isFinite ? 0 : current
        let step = fine ? Self.fine : coarse
        let volume = min(1, max(0, start + (up ? step : -step)))
        return (volume, muted && volume > 0)
    }
}

/// How a level reads in notices and cards.
public enum IslandLevelReadout {
    /// Whole percent, clamped to 0…100; anything non-finite reads as 0.
    public static func percent(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((min(1, max(0, value)) * 100).rounded())
    }

    /// Muted shows 0% with the slash symbol.
    public static func volume(level: Double, muted: Bool) -> (symbol: String, value: Double) {
        let value = muted ? 0 : min(1, max(0, level.isFinite ? level : 0))
        return (percent(value) == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", value)
    }
}

/// Names and ordering for audio devices.
public enum IslandAudioNaming {
    private static let headphoneWords = [
        "headphone", "headset", "earphone", "earbud", "airpod", "earpod", "galaxy buds", "pixel buds",
        "beats", "bose qc", "sony wh", "sony wf", "jabra", "soundcore",
    ]

    /// A device is headphones when its name, UID or data source mentions a common headphone word.
    public static func isHeadphones(name: String, uid: String, dataSource: String?) -> Bool {
        let haystack = [name, uid, dataSource ?? ""].joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return headphoneWords.contains { haystack.contains($0) }
    }

    /// Default first, then by name, then by UID so identical names keep a stable order.
    public static func precedes(_ a: (isDefault: Bool, name: String, uid: String),
                                _ b: (isDefault: Bool, name: String, uid: String)) -> Bool {
        if a.isDefault != b.isDefault { return a.isDefault }
        let byName = a.name.localizedCaseInsensitiveCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.uid < b.uid
    }
}
