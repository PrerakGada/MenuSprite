import Foundation

/// Where an app's sound goes: its chosen output while that device is present, else the system
/// default, flagged so the column can say the chosen one is missing without forgetting it.
public struct MixerTarget: Equatable, Sendable {
    public var uid: String?
    public var routeMissing: Bool

    public init(route: String?, available: Set<String>, defaultOutput: String?) {
        if let route, available.contains(route) {
            uid = route
            routeMissing = false
        } else {
            uid = defaultOutput
            routeMissing = route != nil
        }
    }
}

/// Whether an app gets an engine (a tap, a private aggregate device and a render callback). Only an
/// app the person actually adjusted: a saved level other than 100 %, or a saved route that lands on a
/// device other than the system default. Everything else plays untouched and bit-perfect.
public enum MixerEnginePolicy {
    public static func needsEngine(hasAudio: Bool, target: MixerTarget, defaultOutput: String?,
                                   savedGain: Double?, savedRoute: String?) -> Bool {
        guard hasAudio, let uid = target.uid else { return false }
        let turned = savedGain.map { !MixerLevel.isUnity($0) } ?? false
        let routed = savedRoute != nil && uid != defaultOutput
        return turned || routed
    }
}

/// Which apps the page lists and in what base order.
public enum MixerListing {
    public static let finderBundleID = "com.apple.finder"

    /// Hidden apps are left out entirely (and so never tapped); rows with no identity are always listed.
    public static func isHidden(storageKey: String?, hidden: [String: String], showsFinder: Bool) -> Bool {
        guard let key = storageKey else { return false }
        if key == finderBundleID { return !showsFinder }
        return hidden[key] != nil
    }

    /// Hiding the Finder is its own switch; the hidden map never carries it.
    public static func hide(storageKey: String, name: String, in hidden: inout [String: String], showsFinder: inout Bool) {
        if storageKey == finderBundleID { showsFinder = false } else { hidden[storageKey] = name }
    }

    /// The Finder keeps a row (Quick Look plays through it) before it has ever made a sound, and never twice.
    public static func withFinder(_ apps: [MixerApp], showsFinder: Bool, finderPID: Int32?) -> [MixerApp] {
        guard showsFinder, !apps.contains(where: { $0.id == finderBundleID }) else { return apps }
        return apps + [MixerApp(id: finderBundleID, storageKey: finderBundleID, name: "Finder", bundleID: finderBundleID,
                                pid: finderPID ?? 0, objects: [], isPlaying: false, isBypassed: false)]
    }

    /// With "Hide inactive apps" on, an app still shows while it plays, is not at 100 % or is routed.
    public static func isShown(playing: Bool, gain: Double, routed: Bool, hideInactive: Bool) -> Bool {
        guard hideInactive else { return true }
        return playing || !MixerLevel.isUnity(gain) || routed
    }

    /// By display name (localized, case-insensitive), equal names by id, so the order is stable.
    public static func alphabetical(_ apps: [MixerApp]) -> [MixerApp] {
        apps.sorted { a, b in
            switch a.name.localizedCaseInsensitiveCompare(b.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.id < b.id
            }
        }
    }
}

/// An output or input device as the mixer's menus and routes need it.
public struct MixerDevice: Hashable, Sendable {
    public var uid: String
    public var name: String
    public var isDefault: Bool

    public init(uid: String, name: String, isDefault: Bool) {
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
    }

    /// The default first, then by name, identical names by UID.
    public static func ordered(_ devices: [MixerDevice]) -> [MixerDevice] {
        devices.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            switch a.name.localizedCaseInsensitiveCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.uid < b.uid
            }
        }
    }

    /// A saved device UID: trimmed; empty, or containing control characters, is not a UID.
    public static func cleanUID(_ uid: String?) -> String? {
        guard let trimmed = uid?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }

    /// Saved routes keep only entries whose app key and device UID are both valid.
    public static func cleanRoutes(_ routes: [String: String]) -> [String: String] {
        var clean: [String: String] = [:]
        for (key, uid) in routes {
            guard let key = MixerIdentity.clean(key), let uid = cleanUID(uid) else { continue }
            clean[key] = uid
        }
        return clean
    }
}
