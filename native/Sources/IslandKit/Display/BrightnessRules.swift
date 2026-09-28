import Foundation

/// The brightness keys on top of the shared ownership gate. They are taken only while the island
/// shows brightness notices, so a hidden island leaves macOS its own keys and overlay.
public struct IslandBrightnessKeyGate: Sendable {
    public struct Conditions: Equatable, Sendable {
        /// The brightness indicator is wanted (which needs "Control displays").
        public var routed: Bool
        /// The island currently shows notices (not hidden in full screen or until hover).
        public var showsNotices: Bool
        /// A display the keys can step.
        public var hasTarget: Bool

        public init(routed: Bool, showsNotices: Bool, hasTarget: Bool) {
            self.routed = routed
            self.showsNotices = showsNotices
            self.hasTarget = hasTarget
        }
    }

    public enum Outcome: Equatable, Sendable {
        case pass
        case consume
        case step(up: Bool, fine: Bool)
    }

    private var gate = IslandKeyGate()

    public init() {}

    public mutating func handle(_ event: IslandMediaKeyEvent, modifiers: IslandKeyModifiers, conditions: Conditions) -> Outcome {
        guard IslandMediaKey.brightnessKeys.contains(event.code) else { return .pass }
        let canContinue = conditions.routed && conditions.hasTarget
        let canStart = canContinue && conditions.showsNotices && !modifiers.leavesKeyToSystem
        switch gate.decide(event, canStart: canStart, canContinue: canContinue) {
        case .pass: return .pass
        case .consume: return .consume
        case .act: return .step(up: event.code == IslandMediaKey.brightnessUp, fine: modifiers.isFine)
        }
    }

    public mutating func reset() { gate.reset() }
}

public enum IslandBrightnessStep {
    public static let coarse = 1.0 / 16
    public static let fine = 1.0 / 64

    public static func apply(current: Double, up: Bool, fine: Bool) -> Double {
        let start = current.isFinite ? min(1, max(0, current)) : 0
        let step = fine ? Self.fine : coarse
        return min(1, max(0, start + (up ? step : -step)))
    }
}

/// Keyboard-light keys are observed, never taken: a native illumination key-down (repeats included)
/// schedules one read of the level macOS set, shortly after.
public enum IslandKeyboardLightKeys {
    public static let readDelay: TimeInterval = 0.08

    public static func triggersRead(_ event: IslandMediaKeyEvent, modifiers: IslandKeyModifiers) -> Bool {
        IslandMediaKey.illuminationKeys.contains(event.code) && event.state == .down && !modifiers.leavesKeyToSystem
    }
}

/// When the display indicators can work, and the reasons shown when they cannot.
public enum IslandDisplayRouting {
    public static let controlDisplaysReason = "Enable “Control displays” in its settings."
    public static let noKeyboardBacklightReason = "Keyboard backlight control is unavailable on this Mac."

    /// Brightness notices need "Control displays"; keyboard-light notices only need a backlight.
    public static func brightnessReason(controlDisplays: Bool) -> String? {
        controlDisplays ? nil : controlDisplaysReason
    }

    public static func keyboardLightReason(hasBacklight: Bool) -> String? {
        hasBacklight ? nil : noKeyboardBacklightReason
    }
}

/// An external monitor's level across key steps. A step after a pause reads the monitor first (its
/// own buttons may have moved it); steps in a burst use the running value; a level set while the
/// monitor was being read wins over the read.
public struct IslandMonitorLevel: Sendable {
    public static let burstWindow: TimeInterval = 2

    public private(set) var level: Double?
    private var lastChange: TimeInterval?
    private var generation = 0

    public init() {}

    public func needsRead(now: TimeInterval) -> Bool {
        guard level != nil, let lastChange else { return true }
        return now - lastChange > Self.burstWindow
    }

    /// Hand the returned token back with the read's result.
    public func beginRead() -> Int { generation }

    /// Returns false (and keeps the newer level) when a level was set after the read began.
    @discardableResult
    public mutating func finishRead(_ value: Double, token: Int, now: TimeInterval) -> Bool {
        guard token == generation else { return false }
        level = value
        lastChange = now
        return true
    }

    /// The island set a level (slider or step). The write always goes out, even when it equals the
    /// last value the island set: the monitor's own buttons may have moved it since.
    public mutating func set(_ value: Double, now: TimeInterval) {
        level = value
        lastChange = now
        generation += 1
    }
}
