import Foundation

/// Decides which observed output readings raise the volume notice. Starting is silent (it records a
/// baseline); a new output, or the same one reconnecting, starts a new lifetime whose first reading
/// is silent; readings from an older lifetime are ignored. Changes the island made itself are
/// expected, so their echo is silent, and while the island is open its own controls keep the header
/// quiet for a second.
public struct IslandVolumeFeedback: Sendable {
    /// How long the open island's own adjustment keeps the header title in place.
    public static let ownWindow: TimeInterval = 1
    /// Listener bursts fold into one read this long after the last callback.
    public static let readDelay: TimeInterval = 0.03

    public struct Reading: Equatable, Sendable {
        public var lifetime: Int
        /// nil when the output has no settable volume.
        public var level: Double?
        public var muted: Bool

        public init(lifetime: Int, level: Double?, muted: Bool) {
            self.lifetime = lifetime
            self.level = level
            self.muted = muted
        }
    }

    private struct State: Equatable, Sendable {
        var percent: Int?
        var muted: Bool
        init(level: Double?, muted: Bool) {
            percent = level.map(IslandLevelReadout.percent)
            self.muted = muted
        }
    }

    public private(set) var isObserving = false
    private var lifetime: Int?
    private var baseline: State?
    private var ownAdjustment: TimeInterval?

    public init() {}

    public mutating func start(lifetime: Int) {
        isObserving = true
        self.lifetime = lifetime
        baseline = nil
        ownAdjustment = nil
    }

    public mutating func stop() {
        isObserving = false
        lifetime = nil
        baseline = nil
        ownAdjustment = nil
    }

    /// The output listeners moved (another device, or a reconnect): the next reading is a new baseline.
    public mutating func outputChanged(lifetime: Int) {
        self.lifetime = lifetime
        baseline = nil
    }

    /// The island wrote this state itself. `own` marks the open island's own controls.
    public mutating func expect(level: Double?, muted: Bool, own: Bool, now: TimeInterval) {
        guard isObserving else { return }
        baseline = State(level: level, muted: muted)
        if own { ownAdjustment = now }
    }

    /// A handled volume key always shows, even when the level did not change (up at 100%).
    public mutating func keyPressed(level: Double?, muted: Bool) -> Bool {
        guard isObserving else { return false }
        baseline = State(level: level, muted: muted)
        return true
    }

    /// Whether this reading should raise the notice.
    public mutating func receive(_ reading: Reading, isOpen: Bool, now: TimeInterval) -> Bool {
        guard isObserving, reading.lifetime == lifetime else { return false }
        let state = State(level: reading.level, muted: reading.muted)
        guard let old = baseline else {
            baseline = state
            return false
        }
        guard state != old else { return false }
        baseline = state
        if isOpen, let ownAdjustment, now - ownAdjustment <= Self.ownWindow { return false }
        return true
    }
}

/// Output writes: at most one in flight; newer requests fold into one pending write (the newest
/// level wins, and a mute after a level keeps both). Each request is bound to the device and the
/// listener lifetime it was made for, so a queued write never lands on a new output. Every waiter
/// settles exactly once: with its write, or as discarded.
public struct IslandOutputWriteQueue: Sendable {
    public struct Request: Equatable, Sendable {
        public var device: UInt32
        public var lifetime: Int
        public var volume: Double?
        public var muted: Bool?
        public var waiters: [Int]

        public init(device: UInt32, lifetime: Int, volume: Double?, muted: Bool?, waiters: [Int]) {
            self.device = device
            self.lifetime = lifetime
            self.volume = volume
            self.muted = muted
            self.waiters = waiters
        }
    }

    public struct Submission: Equatable, Sendable {
        /// Start writing this now.
        public var start: Request?
        /// Waiters whose requests will never be written.
        public var discarded: [Int] = []
    }

    public private(set) var inFlight: Request?
    public private(set) var pending: Request?

    public init() {}

    /// Whether readings of this lifetime should be ignored: a write for it is queued or running, so an
    /// older reading cannot pull a slider back.
    public func isBusy(lifetime: Int) -> Bool {
        inFlight?.lifetime == lifetime || pending?.lifetime == lifetime
    }

    public mutating func submit(_ request: Request) -> Submission {
        var request = request
        // Non-finite levels never reach the driver.
        if let volume = request.volume { request.volume = volume.isFinite ? min(1, max(0, volume)) : nil }
        guard request.volume != nil || request.muted != nil else { return Submission(discarded: request.waiters) }
        guard inFlight != nil else {
            inFlight = request
            return Submission(start: request)
        }
        var discarded: [Int] = []
        if var queued = pending, queued.device == request.device, queued.lifetime == request.lifetime {
            queued.volume = request.volume ?? queued.volume
            queued.muted = request.muted ?? queued.muted
            queued.waiters += request.waiters
            pending = queued
        } else {
            discarded = pending?.waiters ?? []
            pending = request
        }
        return Submission(discarded: discarded)
    }

    /// The in-flight write finished. The pending one starts only if it still belongs to the current lifetime.
    public mutating func finish(currentLifetime: Int) -> Submission {
        inFlight = nil
        guard let next = pending else { return Submission() }
        pending = nil
        guard next.lifetime == currentLifetime else { return Submission(discarded: next.waiters) }
        inFlight = next
        return Submission(start: next)
    }

    /// The driver stopped answering: the running and queued writes are given up. Returns every waiter.
    public mutating func abandon() -> [Int] {
        let waiters = (inFlight?.waiters ?? []) + (pending?.waiters ?? [])
        inFlight = nil
        pending = nil
        return waiters
    }

    /// The output moved: a pending write for an older lifetime is dropped.
    public mutating func invalidate(currentLifetime: Int) -> [Int] {
        guard let queued = pending, queued.lifetime != currentLifetime else { return [] }
        pending = nil
        return queued.waiters
    }
}
