import Foundation

/// Everything the mixer remembers, keyed by an app's storage key. A level of 100 % is never stored:
/// an app without an entry plays untouched.
public struct MixerPreferences: Equatable, Sendable {
    public var volumes: [String: Double] = [:]
    /// The level an app had when it was muted, restored on unmute.
    public var lastAudible: [String: Double] = [:]
    /// Chosen output device UID per app.
    public var routes: [String: String] = [:]
    /// Hidden apps: storage key → the name to show in "Apps in the list".
    public var hidden: [String: String] = [:]
    public var showsFinder = true
    public var hideInactive = false
    public var arrangement = MixerArrangement()

    public init() {}

    public func gain(_ key: String) -> Double { volumes[key] ?? MixerLevel.unity }

    /// Stores a level; 100 % (±0.5 %) removes the entry; non-finite values change nothing.
    public mutating func setGain(_ gain: Double, for key: String) {
        guard let key = MixerIdentity.clean(key), let value = MixerLevel.clamp(gain, maximum: MixerLevel.appMaximum) else { return }
        volumes[key] = MixerLevel.isUnity(value) ? nil : value
        if value > 0 { lastAudible[key] = nil }
    }

    /// Mute keeps the level to come back to; unmute restores it (100 % when there was none).
    public mutating func toggleMute(_ key: String) {
        let next = MixerMute(gain: gain(key), lastAudible: lastAudible[key]).toggled()
        setGain(next.gain, for: key)
        lastAudible[key] = next.lastAudible
    }

    /// Choosing the system output sends every app there: routes are cleared, levels kept. A switch
    /// that failed changes neither.
    public mutating func outputSwitched(succeeded: Bool) {
        if succeeded { routes.removeAll() }
    }

    public mutating func setRoute(_ uid: String?, for key: String) {
        guard let key = MixerIdentity.clean(key) else { return }
        routes[key] = MixerDevice.cleanUID(uid)
    }

    /// Reads a stored level map, dropping entries that are not finite numbers or sit at 100 %.
    public static func cleanVolumes(_ stored: Any?) -> [String: Double] {
        guard let raw = stored as? [String: Any] else { return [:] }
        var clean: [String: Double] = [:]
        for (key, value) in raw {
            guard let key = MixerIdentity.clean(key), let number = (value as? NSNumber)?.doubleValue,
                  let gain = MixerLevel.clamp(number, maximum: MixerLevel.appMaximum), !MixerLevel.isUnity(gain) else { continue }
            clean[key] = gain
        }
        return clean
    }

    /// Reads a stored string map (routes, hidden names), keeping only non-blank keys and values.
    public static func cleanStrings(_ stored: Any?) -> [String: String] {
        guard let raw = stored as? [String: Any] else { return [:] }
        var clean: [String: String] = [:]
        for (key, value) in raw {
            guard let key = MixerIdentity.clean(key), let text = MixerIdentity.clean(value as? String) else { continue }
            clean[key] = text
        }
        return clean
    }
}
