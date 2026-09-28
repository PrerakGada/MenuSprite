import Foundation

/// One input device as the microphone mute sees it.
public struct IslandMicDevice: Equatable, Sendable {
    public var uid: String
    public var name: String
    public var isAggregate: Bool
    /// The input mute switch, or nil when the device has none.
    public var muteSwitch: Bool?
    /// Readable input volume scalars by element (0 is the main element, then channels 1 and 2).
    public var levels: [UInt32: Float]

    public init(uid: String, name: String, isAggregate: Bool = false, muteSwitch: Bool? = nil, levels: [UInt32: Float] = [:]) {
        self.uid = uid
        self.name = name
        self.isAggregate = isAggregate
        self.muteSwitch = muteSwitch
        self.levels = levels
    }
}

/// What the island did to one device, so it can undo exactly that.
public enum IslandMicClaim: Codable, Equatable, Sendable {
    case muteSwitch
    /// The levels saved before setting them to 0, by element (only those above the silent level).
    case levels([UInt32: Float])
}

/// Everything the microphone mute has claimed, persisted so a crash can never strand a muted mic.
public struct IslandMicMuteRecord: Codable, Equatable, Sendable {
    public var claims: [String: IslandMicClaim] = [:]
    public init(claims: [String: IslandMicClaim] = [:]) { self.claims = claims }
}

/// The rules of muting every microphone and putting each one back as it was.
public enum IslandMicMuteRules {
    public static let silentLevel: Float = 0.01
    public static let fallbackLevel: Float = 0.75
    /// Private aggregate devices MenuSprite may create itself are named with this prefix.
    public static let ownDevicePrefix = "MenuSprite"

    /// Only MenuSprite's own aggregate devices are left out of a sweep.
    public static func isOwnAggregate(_ device: IslandMicDevice) -> Bool {
        device.isAggregate && device.name.hasPrefix(ownDevicePrefix)
    }

    /// Mute switch on, or every readable level at or below the silent level.
    public static func isSilent(_ device: IslandMicDevice) -> Bool {
        if device.muteSwitch == true { return true }
        return !device.levels.isEmpty && device.levels.values.allSatisfy { $0 <= silentLevel }
    }

    public enum MutePlan: Equatable, Sendable {
        /// Already silent: leave it. It stays claimed only if the island already held it, so a mic the
        /// person muted themselves is never opened by the island later.
        case leave(keepClaim: Bool)
        case setSwitch
        /// Save these levels, then set every level to 0; claim only if the device really went silent.
        case zeroLevels(saved: [UInt32: Float])
    }

    public static func mutePlan(for device: IslandMicDevice, alreadyClaimed: Bool) -> MutePlan {
        if isSilent(device) { return .leave(keepClaim: alreadyClaimed) }
        if device.muteSwitch != nil { return .setSwitch }
        return .zeroLevels(saved: device.levels.filter { $0.value > silentLevel })
    }

    public enum UnmutePlan: Equatable, Sendable {
        /// Absent or unreadable (mid-reconnect): keep the claim for when it returns.
        case keepClaim
        case clearSwitch
        case restore([UInt32: Float])
        /// The device is audible already (the person turned it up): forget the saved level.
        case dropClaim
    }

    /// `device` is nil when the device is absent or could not be read.
    public static func unmutePlan(claim: IslandMicClaim, device: IslandMicDevice?) -> UnmutePlan {
        guard let device else { return .keepClaim }
        switch claim {
        case .muteSwitch:
            return device.muteSwitch == nil ? .dropClaim : .clearSwitch
        case .levels(let saved):
            if device.levels.values.contains(where: { $0 > silentLevel }) { return .dropClaim }
            if !saved.isEmpty { return .restore(saved) }
            // Nothing was saved: bring every channel it has back to a sensible level.
            let elements = device.levels.isEmpty ? [0] : Array(device.levels.keys)
            return .restore(Dictionary(uniqueKeysWithValues: elements.map { ($0, fallbackLevel) }))
        }
    }

    /// Which devices an unmute touches: only the claimed ones. A record that cannot be read touches
    /// nothing, so a microphone muted elsewhere is never opened by the island.
    public static func unmuteTargets(record: IslandMicMuteRecord?) -> [String] {
        record?.claims.keys.sorted() ?? []
    }

    /// What the microphones really are after a sweep, judged from the devices themselves, never from
    /// the request. Aggregates follow their member devices, so they do not count on their own.
    public static func verdict(requested: Bool, present: [IslandMicDevice], claimed: Set<String>) -> IslandMicMuteVerdict {
        let counted = present.filter { !$0.isAggregate }
        if requested { return counted.allSatisfy(isSilent) ? .muted : .partlyMuted }
        return counted.contains { claimed.contains($0.uid) } ? .stillMuted : .live
    }
}

/// The microphones' real state, as the tile shows it.
public enum IslandMicMuteVerdict: Equatable, Sendable {
    /// Unmute asked for, and every microphone the island closed is open again.
    case live
    /// Mute asked for, and every present microphone is silent.
    case muted
    /// Mute asked for, but at least one present microphone is still live.
    case partlyMuted
    /// Unmute asked for, but a present microphone the island closed could not be opened.
    case stillMuted

    /// The request was carried out on every present device.
    public var isApplied: Bool { self == .live || self == .muted }
}

/// The requested mute state and the sweep generation. A device change re-asserts the state the
/// person last asked for, and only the newest sweep may publish.
public struct IslandMicMuteIntent: Sendable {
    public private(set) var requested = false
    public private(set) var generation = 0

    public init() {}

    public mutating func request(_ muted: Bool) -> Int {
        requested = muted
        generation += 1
        return generation
    }

    public mutating func deviceChanged() -> (muted: Bool, generation: Int) {
        generation += 1
        return (requested, generation)
    }

    public func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    /// Device listeners run while muted, while claims are outstanding, or while the last sweep did not
    /// fully apply, so the next device change retries it.
    public static func needsListeners(requested: Bool, claims: Int, applied: Bool) -> Bool {
        requested || claims > 0 || !applied
    }
}
