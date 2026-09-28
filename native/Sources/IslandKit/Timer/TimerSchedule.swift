import Foundation

/// When a running session's clock next needs redrawing: exactly when the displayed second changes,
/// so the first wake after starting, resuming or reopening lands on the next boundary instead of a
/// full second later.
public enum TimerTicks {
    /// Seconds from now until the shown value changes. A countdown shows whole seconds rounded up, so
    /// 298.75 s left changes to 298 in 0.75 s; a stopwatch shows them rounded down, so 12.3 s elapsed
    /// changes in 0.7 s. An unreadable reading asks for an immediate tick; a countdown already at zero
    /// has nothing more to show.
    public static func delay(reading: Double, countsDown: Bool) -> Double? {
        guard reading.isFinite else { return 0 }
        if countsDown {
            guard reading > 0 else { return nil }
            return reading - (reading.rounded(.up) - 1)
        }
        let elapsed = max(0, reading)
        return elapsed.rounded(.down) + 1 - elapsed
    }
}

/// The finished-timer alarm: a sound now and every 2 s, for at most five minutes from when the
/// timer finished, until the person acknowledges it. Turning the sound off or suspending the island
/// silences it without resetting the five minutes; once they are spent nothing restarts it; a new
/// finish starts a fresh five minutes.
public struct TimerAlarm: Equatable, Sendable {
    public static let interval: Double = 2
    public static let limit: Double = 300

    /// What the owner should do with its ringing loop after a `sync`.
    public enum Command: Equatable, Sendable {
        /// Ring now and keep ringing every `interval`.
        case start
        /// Stop the loop and any sound playing.
        case stop
        case none
    }

    /// When the current five minutes began; nil when nothing is waiting to be acknowledged.
    public private(set) var began: Double?
    /// Whether the owner's ringing loop is running.
    public private(set) var isRinging = false

    public init() {}

    /// A timer finished: a fresh five minutes.
    public mutating func arm(at now: Double) {
        began = now.isFinite ? now : nil
    }

    /// Done, Cancel or the next phase: nothing may ring again for this finish.
    @discardableResult
    public mutating func acknowledge() -> Command {
        began = nil
        return stopIfRinging()
    }

    /// Whether `now` falls inside the five minutes.
    public func isWithinLimit(at now: Double) -> Bool {
        guard let began, now.isFinite else { return false }
        return now >= began && now < began + Self.limit
    }

    /// Brings the loop in line with the preference and the island's state. Calling it again with
    /// nothing changed never starts a second loop.
    public mutating func sync(soundOn: Bool, suspended: Bool, now: Double) -> Command {
        let wanted = soundOn && !suspended && isWithinLimit(at: now)
        if wanted {
            guard !isRinging else { return .none }
            isRinging = true
            return .start
        }
        return stopIfRinging()
    }

    /// Called after each ring: seconds until the next, or nil when the next would fall past the five
    /// minutes (the loop then ends by itself).
    public mutating func nextRing(after now: Double) -> Double? {
        guard isRinging, isWithinLimit(at: now + Self.interval) else {
            isRinging = false
            return nil
        }
        return Self.interval
    }

    private mutating func stopIfRinging() -> Command {
        guard isRinging else { return .none }
        isRinging = false
        return .stop
    }
}
