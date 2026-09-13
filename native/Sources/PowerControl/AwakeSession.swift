import Foundation

public struct AwakeSession: Sendable {
    public private(set) var manual = false
    public private(set) var deadline: Date?
    public private(set) var sleeping = false
    public var sessionActive = true
    public init() {}
    public mutating func start(duration: TimeInterval, now: Date = Date()) {
        manual = true; deadline = duration > 0 ? now.addingTimeInterval(duration) : nil
    }
    public mutating func cancelManual() { manual = false; deadline = nil }
    public mutating func expire(now: Date = Date()) {
        if let deadline, now >= deadline { cancelManual() }
    }
    public mutating func sleep() { cancelManual(); sleeping = true }
    public mutating func wake() { sleeping = false }
    public func pauseReason(locked: Bool, pauseWhenLocked: Bool, acOnly: Bool, externalPower: Bool?) -> String? {
        if sleeping { return "Paused during sleep" }
        if !sessionActive { return "Paused in an inactive user session" }
        if locked && pauseWhenLocked { return "Paused while locked" }
        if acOnly && externalPower != true { return "Waiting for power" }
        return nil
    }
}
