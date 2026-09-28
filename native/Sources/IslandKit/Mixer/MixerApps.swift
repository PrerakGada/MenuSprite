import Foundation

/// One app as the mixer lists it: every audio process object billed to it, whether any of them is
/// producing sound, and how its volume is remembered.
public struct MixerApp: Identifiable, Hashable, Sendable {
    public var id: String
    /// Where its volume, route and slot are remembered; nil when the app has no stable identity and
    /// its settings last only for this session.
    public var storageKey: String?
    public var name: String
    public var bundleID: String?
    /// The regular app the audio is billed to (used for its icon).
    public var pid: Int32
    /// Core Audio process objects to tap, sorted.
    public var objects: [UInt32]
    public var isPlaying: Bool
    /// Apps that manage their own audio are listed but never tapped.
    public var isBypassed: Bool

    public init(id: String, storageKey: String?, name: String, bundleID: String?, pid: Int32,
                objects: [UInt32], isPlaying: Bool, isBypassed: Bool) {
        self.id = id
        self.storageKey = storageKey
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.objects = objects
        self.isPlaying = isPlaying
        self.isBypassed = isBypassed
    }

    public var hasAudio: Bool { !objects.isEmpty }

    /// Rows with the same id (one app's helpers, found separately) become one row with every object.
    public static func merge(_ apps: [MixerApp]) -> [MixerApp] {
        var order: [String] = []
        var byID: [String: MixerApp] = [:]
        for app in apps {
            if var existing = byID[app.id] {
                existing.objects = Array(Set(existing.objects).union(app.objects)).sorted()
                existing.isPlaying = existing.isPlaying || app.isPlaying
                byID[app.id] = existing
            } else {
                order.append(app.id)
                var first = app
                first.objects = Array(Set(app.objects)).sorted()
                byID[app.id] = first
            }
        }
        return order.compactMap { byID[$0] }
    }
}

/// How a process becomes a row: the bundle identifier when there is one (row and storage key), else
/// the display name as the storage key with a per-process row (so a bare executable keeps its volume
/// across launches, and two same-named processes stay separate rows sharing that volume), else a
/// session-only row. Blank identifiers are not identities.
public struct MixerIdentity: Hashable, Sendable {
    public var rowID: String
    public var storageKey: String?

    public init(bundleID: String?, name: String?, pid: Int32) {
        if let bundle = Self.clean(bundleID) {
            rowID = bundle
            storageKey = bundle
        } else {
            rowID = "process:\(pid)"
            storageKey = Self.clean(name)
        }
    }

    static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Apps a tap would silence outright, so they are listed at 100 % and never tapped: Zoom, and
/// pro-audio hosts that run their own audio engines.
public enum MixerBypass {
    static let zoomNames: Set<String> = ["zoom", "zoom.us", "zoom workplace"]
    static let hostPrefixes = ["com.apple.logic", "com.apple.garageband", "com.apple.mainstage", "com.ableton.",
                               "com.avid.", "com.cockos.reaper", "com.steinberg.", "com.presonus.", "com.bitwig.",
                               "com.image-line.", "com.motu."]

    public static func isBypassed(bundleID: String?, name: String?) -> Bool {
        if let bundle = bundleID?.lowercased() {
            if bundle == "us.zoom.xos" || bundle.hasPrefix("us.zoom.") { return true }
            if hostPrefixes.contains(where: { bundle.hasPrefix($0) }) { return true }
        }
        if let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), zoomNames.contains(name) { return true }
        return false
    }
}

/// Bills an audio process to the regular app responsible for it. Browsers and Electron apps detach
/// their audio helpers from the responsibility chain, so when the responsible process is not a
/// regular app the walk climbs BSD parents (at most `depthCap` levels), first from the responsible
/// process and then from the process itself. Daemons and login items have no regular ancestor and
/// are not listed.
public enum MixerAttribution {
    public static let depthCap = 6

    /// `responsible` returns nil when the lookup fails; `parent` returns nil when the parent cannot be read.
    public static func owner(of pid: Int32, responsible: (Int32) -> Int32?, parent: (Int32) -> Int32?,
                             isRegularApp: (Int32) -> Bool) -> Int32? {
        guard let start = responsible(pid), start > 0 else { return nil }
        if let found = climb(from: start, parent: parent, isRegularApp: isRegularApp) { return found }
        guard start != pid else { return nil }
        return climb(from: pid, parent: parent, isRegularApp: isRegularApp)
    }

    static func climb(from start: Int32, parent: (Int32) -> Int32?, isRegularApp: (Int32) -> Bool) -> Int32? {
        var current = start
        for level in 0...depthCap {
            if isRegularApp(current) { return current }
            guard level < depthCap, let next = parent(current), next > 1, next != current else { return nil }
            current = next
        }
        return nil
    }
}
