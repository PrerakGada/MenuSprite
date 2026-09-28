import Foundation

/// The media keys the island reads, by the key code macOS puts in a system-defined event.
public enum IslandMediaKey {
    public static let volumeUp = 0
    public static let volumeDown = 1
    public static let brightnessUp = 2
    public static let brightnessDown = 3
    public static let mute = 7
    public static let play = 16
    public static let illuminationUp = 21
    public static let illuminationDown = 22
    public static let illuminationToggle = 23

    public static let volumeKeys: Set<Int> = [volumeUp, volumeDown, mute]
    public static let brightnessKeys: Set<Int> = [brightnessUp, brightnessDown]
    public static let illuminationKeys: Set<Int> = [illuminationUp, illuminationDown, illuminationToggle]
}

/// One media-key event decoded from a system-defined (subtype 8) event's `data1`: the key code in
/// bits 16–31, the state in bits 8–15 (0x0A down, 0x0B up) and the repeat flag in bit 0.
public struct IslandMediaKeyEvent: Equatable, Sendable {
    public enum State: Equatable, Sendable { case down, up, unknown }

    public var code: Int
    public var state: State
    public var isRepeat: Bool

    public init(code: Int, state: State, isRepeat: Bool = false) {
        self.code = code
        self.state = state
        self.isRepeat = isRepeat
    }

    public init(data1: Int) {
        code = (data1 >> 16) & 0xFFFF
        switch (data1 >> 8) & 0xFF {
        case 0x0A: state = .down
        case 0x0B: state = .up
        default: state = .unknown
        }
        isRepeat = data1 & 0x1 != 0
    }

    /// The `data1` a synthesised event of this key needs.
    public var data1: Int {
        let flags = state == .up ? 0x0B : 0x0A
        return (code << 16) | (flags << 8) | (isRepeat ? 1 : 0)
    }
}

/// The modifiers held with a media key.
public struct IslandKeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = IslandKeyModifiers(rawValue: 1 << 0)
    public static let control = IslandKeyModifiers(rawValue: 1 << 1)
    public static let option = IslandKeyModifiers(rawValue: 1 << 2)
    public static let shift = IslandKeyModifiers(rawValue: 1 << 3)

    /// Command or Control, or Option without Shift (which opens the matching settings pane), belong to macOS.
    public var leavesKeyToSystem: Bool {
        contains(.command) || contains(.control) || (contains(.option) && !contains(.shift))
    }

    /// Option and Shift together ask for a quarter step, as macOS's own keys do.
    public var isFine: Bool { contains(.option) && contains(.shift) }
}

/// Who owns a held media key. Ownership is decided at key-down only: the island never takes over a
/// native repeat midway, and never hands half of a press it took back to macOS. An owned key's
/// repeats and key-up stay with the island even when conditions change mid-hold.
public struct IslandKeyGate: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Leave the event to macOS.
        case pass
        /// Drop the event and do nothing else.
        case consume
        /// Drop the event and act on it.
        case act(isRepeat: Bool)
    }

    public private(set) var owned: Set<Int> = []

    public init() {}

    /// - Parameters:
    ///   - canStart: a fresh press may be taken now.
    ///   - canContinue: an owned key may still act; otherwise its repeats are swallowed until key-up.
    public mutating func decide(_ event: IslandMediaKeyEvent, canStart: Bool, canContinue: Bool) -> Decision {
        switch event.state {
        case .unknown:
            return .pass
        case .up:
            return owned.remove(event.code) != nil ? .consume : .pass
        case .down where event.isRepeat:
            guard owned.contains(event.code) else { return .pass }
            return canContinue ? .act(isRepeat: true) : .consume
        case .down:
            guard canStart else {
                owned.remove(event.code)
                return .pass
            }
            owned.insert(event.code)
            return .act(isRepeat: false)
        }
    }

    public mutating func reset() { owned.removeAll() }
}
