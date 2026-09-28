import Foundation

/// At most one engine build per row in flight. A build that finishes after the output environment
/// changed (the tokens were invalidated) is discarded, so a late build can never add a second tap of
/// the same app (which would play its sound twice).
///
/// Creating a tap or an aggregate device can hang on a wedged HAL, so every build also has a
/// deadline: one still running `deadline` seconds after it began is given up (the app keeps playing
/// untouched), its slot is freed, and if it ever does finish its result is refused like any late build.
public struct MixerBuildTokens: Sendable {
    public static let deadline: TimeInterval = 5

    public struct Token: Hashable, Sendable {
        public let row: String
        let id: UInt64
        let generation: UInt64
    }

    /// What a build's deadline check finds.
    public enum Deadline: Equatable, Sendable {
        /// The build already finished, was invalidated or replaced: nothing to do.
        case settled
        /// Still running inside its deadline; check again after this many seconds.
        case wait(TimeInterval)
        /// Still running past its deadline: it has been given up.
        case expired
    }

    private var generation: UInt64 = 0
    private var next: UInt64 = 0
    private var inFlight: [String: (id: UInt64, started: TimeInterval)] = [:]

    public init() {}

    /// A token for a new build, or nil while one for this row is still in flight.
    public mutating func begin(_ row: String, now: TimeInterval) -> Token? {
        guard inFlight[row] == nil else { return nil }
        next += 1
        inFlight[row] = (next, now)
        return Token(row: row, id: next, generation: generation)
    }

    /// Whether a finished build may install. Always frees its own slot, never a newer build's; a build
    /// given up at its deadline no longer owns a slot and may never install.
    public mutating func finish(_ token: Token) -> Bool {
        let current = inFlight[token.row]?.id == token.id
        if current { inFlight[token.row] = nil }
        return current && token.generation == generation
    }

    /// Gives up a build that outlived its deadline. A clock that jumped backwards restarts the window.
    public mutating func checkDeadline(_ token: Token, now: TimeInterval) -> Deadline {
        guard let flight = inFlight[token.row], flight.id == token.id, token.generation == generation else { return .settled }
        guard now >= flight.started else {
            inFlight[token.row] = (flight.id, now)
            return .wait(Self.deadline)
        }
        let elapsed = now - flight.started
        guard elapsed >= Self.deadline else { return .wait(Self.deadline - elapsed) }
        inFlight[token.row] = nil
        return .expired
    }

    public func isBuilding(_ row: String) -> Bool { inFlight[row] != nil }

    /// Every build in flight becomes stale and new builds may start at once.
    public mutating func invalidateAll() {
        generation += 1
        inFlight.removeAll()
    }
}

/// What an engine was built for: the app's audio objects and the device it renders to.
public struct MixerEngineConfiguration: Hashable, Sendable {
    public var objects: [UInt32]
    public var device: String

    public init(objects: [UInt32], device: String) {
        self.objects = objects.sorted()
        self.device = device
    }
}

/// Fail-open recovery: an engine that stopped rendering gets one replacement; if that same
/// configuration dies again the app is left untapped (playing normally) until the person changes its
/// level or route, or its audio objects change.
public struct MixerRecovery: Sendable {
    private var deaths: [String: (configuration: MixerEngineConfiguration, count: Int)] = [:]

    public init() {}

    public func mayBuild(_ row: String, _ configuration: MixerEngineConfiguration) -> Bool {
        guard let death = deaths[row], death.configuration == configuration else { return true }
        return death.count < 2
    }

    public mutating func recordDeath(_ row: String, _ configuration: MixerEngineConfiguration) {
        if let death = deaths[row], death.configuration == configuration {
            deaths[row] = (configuration, death.count + 1)
        } else {
            deaths[row] = (configuration, 1)
        }
    }

    /// A build that never finished is not retried: the app stays untapped until the person changes its
    /// level or route, or its audio objects change (another hung build would only park another worker).
    public mutating func recordHang(_ row: String, _ configuration: MixerEngineConfiguration) {
        deaths[row] = (configuration, 2)
    }

    /// An explicit change by the person re-enables the path.
    public mutating func reset(_ row: String) { deaths[row] = nil }
    public mutating func resetAll() { deaths.removeAll() }
}

/// Whether an engine is still being driven. A muted-when-tapped tap silences the app for as long as
/// its reader runs, so an aggregate that stops rendering (after sleep, or a device renegotiation)
/// would leave the app mute: while the app plays, the render counter must move within the window.
public struct MixerRenderCheck: Sendable {
    public static let window: TimeInterval = 1.5

    public enum Verdict: Equatable, Sendable {
        /// The app is silent: nothing to judge, no further checks.
        case idle
        /// Check again after this many seconds.
        case recheck(after: TimeInterval)
        /// Playing, and the counter stood still for the whole window.
        case wedged
    }

    private var observations: [String: (count: UInt64, at: TimeInterval)] = [:]

    public init() {}

    public mutating func evaluate(_ row: String, playing: Bool, count: UInt64, now: TimeInterval) -> Verdict {
        guard playing else {
            observations[row] = nil
            return .idle
        }
        guard let seen = observations[row], seen.count == count, now >= seen.at else {
            observations[row] = (count, now)
            return .recheck(after: Self.window)
        }
        let elapsed = now - seen.at
        if elapsed >= Self.window {
            observations[row] = nil
            return .wedged
        }
        return .recheck(after: Self.window - elapsed)
    }

    public mutating func forget(_ row: String) { observations[row] = nil }
    public mutating func forgetAll() { observations.removeAll() }
}

/// Apps recreate their audio unit between clips, so their audio objects vanish for a moment. A row
/// that lost its objects keeps its engine for a short window and the churn folds into one decision.
public struct MixerObjectGrace: Sendable {
    public static let window: TimeInterval = 0.2

    public enum Decision: Equatable, Sendable {
        /// The row has audio: act on it now.
        case proceed
        /// Keep the engine; decide again after this many seconds.
        case wait(TimeInterval)
        /// The objects stayed away for the whole window: release the engine.
        case release
    }

    private var lostAt: [String: TimeInterval] = [:]

    public init() {}

    public mutating func decide(_ row: String, hasAudio: Bool, now: TimeInterval) -> Decision {
        guard !hasAudio else {
            lostAt[row] = nil
            return .proceed
        }
        guard let since = lostAt[row], now >= since else {
            lostAt[row] = now
            return .wait(Self.window)
        }
        let elapsed = now - since
        if elapsed >= Self.window {
            lostAt[row] = nil
            return .release
        }
        return .wait(Self.window - elapsed)
    }

    public mutating func forgetAll() { lostAt.removeAll() }
}

/// One refresh reads the HAL at a time. A request while reading is remembered and runs once after.
/// Each pass belongs to a generation; when the mixer changes the output itself or stops, the
/// generation moves on and a pass still reading publishes nothing.
public struct MixerRefreshSlot: Sendable {
    public private(set) var generation: UInt64 = 0
    private var reading: UInt64?
    private var repeatRequested = false

    public init() {}

    public var isReading: Bool { reading != nil }

    /// The pass to run now, or nil (remembered) while another is reading.
    public mutating func begin() -> UInt64? {
        guard reading == nil else {
            repeatRequested = true
            return nil
        }
        reading = generation
        return generation
    }

    /// Whether the pass may publish, and whether a remembered request should run now. A pass that
    /// no longer owns the slot publishes nothing and leaves the slot alone.
    public mutating func finish(_ pass: UInt64) -> (publish: Bool, runAgain: Bool) {
        guard reading == pass else { return (false, false) }
        reading = nil
        let again = repeatRequested
        repeatRequested = false
        return (pass == generation, again)
    }

    /// The output changed under a pass: it must not publish what it read.
    public mutating func invalidate() { generation += 1 }

    /// Stop: frees the slot and drops any remembered request.
    public mutating func discard() {
        generation += 1
        reading = nil
        repeatRequested = false
    }
}

/// HAL notifications arrive in bursts. The first refreshes at once; more within the window fold into
/// one trailing refresh at the end of it.
public struct MixerBurst: Sendable {
    public static let window: TimeInterval = 0.2

    public enum Action: Equatable, Sendable {
        case now
        case later(TimeInterval)
        /// A trailing refresh is already scheduled.
        case none
    }

    private var lastRun: TimeInterval?
    private var trailing = false

    public init() {}

    public mutating func request(now: TimeInterval) -> Action {
        if trailing { return .none }
        guard let last = lastRun, now >= last, now - last < Self.window else {
            lastRun = now
            return .now
        }
        trailing = true
        return .later(Self.window - (now - last))
    }

    /// The trailing refresh ran.
    public mutating func fired(now: TimeInterval) {
        trailing = false
        lastRun = now
    }

    public mutating func reset() {
        lastRun = nil
        trailing = false
    }
}
