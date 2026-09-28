import Foundation

/// The three things the Timer page can run. The raw values are stored: keep them stable.
public enum TimerMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case timer, pomodoro, stopwatch
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .timer: "Timer"
        case .pomodoro: "Pomodoro"
        case .stopwatch: "Stopwatch"
        }
    }
}

/// What a session is doing right now. A plain timer is one countdown; Pomodoro alternates focus and
/// breaks; a stopwatch counts up.
public enum TimerPhase: String, CaseIterable, Sendable, Equatable {
    case countdown, focus, shortBreak, longBreak, stopwatch
    public var title: String {
        switch self {
        case .countdown: "Timer"
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        case .stopwatch: "Stopwatch"
        }
    }
    public var countsDown: Bool { self != .stopwatch }
}

/// A Pomodoro cycle's configuration. Every value is clamped to its range, so a restored or hand-edited
/// preference can never overflow a deadline.
public struct PomodoroPlan: Equatable, Sendable {
    public static let focusRange = 1...180
    public static let breakRange = 1...60
    public static let sessionRange = 1...24
    public static let standard = PomodoroPlan()

    public var focusMinutes: Int { didSet { focusMinutes = Self.clamp(focusMinutes, Self.focusRange) } }
    public var shortBreakMinutes: Int { didSet { shortBreakMinutes = Self.clamp(shortBreakMinutes, Self.breakRange) } }
    public var longBreakMinutes: Int { didSet { longBreakMinutes = Self.clamp(longBreakMinutes, Self.breakRange) } }
    /// A long break follows every this-many completed focus sessions.
    public var sessionsBeforeLongBreak: Int { didSet { sessionsBeforeLongBreak = Self.clamp(sessionsBeforeLongBreak, Self.sessionRange) } }
    /// The cycle ends when this many focus sessions are complete.
    public var totalSessions: Int { didSet { totalSessions = Self.clamp(totalSessions, Self.sessionRange) } }

    public init(focusMinutes: Int = 25, shortBreakMinutes: Int = 5, longBreakMinutes: Int = 15,
                sessionsBeforeLongBreak: Int = 4, totalSessions: Int = 4) {
        self.focusMinutes = Self.clamp(focusMinutes, Self.focusRange)
        self.shortBreakMinutes = Self.clamp(shortBreakMinutes, Self.breakRange)
        self.longBreakMinutes = Self.clamp(longBreakMinutes, Self.breakRange)
        self.sessionsBeforeLongBreak = Self.clamp(sessionsBeforeLongBreak, Self.sessionRange)
        self.totalSessions = Self.clamp(totalSessions, Self.sessionRange)
    }

    /// Every value the page's menus offer, in order.
    public static let focusChoices = Array(focusRange)
    public static let breakChoices = Array(breakRange)
    public static let sessionChoices = Array(sessionRange)

    /// A phase's length in seconds.
    public func length(of phase: TimerPhase) -> Double {
        switch phase {
        case .focus: Double(focusMinutes) * 60
        case .shortBreak: Double(shortBreakMinutes) * 60
        case .longBreak: Double(longBreakMinutes) * 60
        case .countdown, .stopwatch: 0
        }
    }

    static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }
}

/// What a completion announces: "Time is up" or, at the last focus of a cycle, "Pomodoro complete".
public struct TimerCompletion: Equatable, Sendable {
    public var phase: TimerPhase
    public var endsCycle: Bool
    public var title: String { endsCycle ? "Pomodoro complete" : "Time is up" }
    public var detail: String { phase.title }
}

/// One timer, Pomodoro cycle or stopwatch, measured on a clock that keeps counting through sleep.
/// Times are seconds on that clock. A countdown keeps an absolute deadline and a stopwatch the instant
/// it read zero, so a reading is always one subtraction from "now" and can never drift. Only one
/// session exists at a time; it lives in memory and is never saved.
public struct TimerSession: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Countdown: the deadline. Stopwatch: the instant it read zero.
        case running(anchor: Double)
        /// The frozen remaining (countdown) or elapsed (stopwatch) seconds.
        case paused(reading: Double)
        case finished
    }

    /// The longest countdown: three hours.
    public static let maximumLength: Double = 10_800
    public static let minuteRange = 1...180

    public let mode: TimerMode
    public private(set) var phase: TimerPhase
    /// The current phase's full length in seconds; zero for a stopwatch.
    public private(set) var length: Double
    public private(set) var state: State
    /// The configuration a Pomodoro cycle started with; later preference changes never reach it.
    public let plan: PomodoroPlan?
    public private(set) var completedFocuses = 0

    private init(mode: TimerMode, phase: TimerPhase, length: Double, state: State, plan: PomodoroPlan?) {
        self.mode = mode; self.phase = phase; self.length = length; self.state = state; self.plan = plan
    }

    /// A countdown's length for the ruler's minutes: 0 becomes one minute, anything past three hours
    /// becomes three hours.
    public static func countdownLength(minutes: Int) -> Double {
        Double(min(max(minutes, minuteRange.lowerBound), minuteRange.upperBound)) * 60
    }

    public static func countdown(minutes: Int, at now: Double) -> TimerSession? {
        guard now.isFinite else { return nil }
        let length = countdownLength(minutes: minutes)
        return TimerSession(mode: .timer, phase: .countdown, length: length, state: .running(anchor: now + length), plan: nil)
    }

    public static func pomodoro(_ plan: PomodoroPlan, at now: Double) -> TimerSession? {
        guard now.isFinite else { return nil }
        let length = plan.length(of: .focus)
        return TimerSession(mode: .pomodoro, phase: .focus, length: length, state: .running(anchor: now + length), plan: plan)
    }

    public static func stopwatch(at now: Double) -> TimerSession? {
        guard now.isFinite else { return nil }
        return TimerSession(mode: .stopwatch, phase: .stopwatch, length: 0, state: .running(anchor: now), plan: nil)
    }

    public var isRunning: Bool { if case .running = state { true } else { false } }
    public var isPaused: Bool { if case .paused = state { true } else { false } }
    public var isFinished: Bool { state == .finished }

    /// The deadline of a running countdown.
    public var deadline: Double? {
        guard phase.countsDown, case .running(let anchor) = state else { return nil }
        return anchor
    }

    /// Remaining seconds for a countdown (negative once overdue, NaN for an unreadable clock), elapsed
    /// seconds for a stopwatch (never negative).
    public func reading(at now: Double) -> Double {
        switch state {
        case .running(let anchor):
            guard now.isFinite else { return .nan }
            return phase.countsDown ? anchor - now : max(0, now - anchor)
        case .paused(let reading): return reading
        case .finished: return 0
        }
    }

    /// "Is it due?": completes a running countdown whose deadline has passed, exactly once. A stopwatch
    /// never completes on its own.
    public mutating func complete(at now: Double) -> TimerCompletion? {
        guard let deadline, now.isFinite, now >= deadline else { return nil }
        return finish()
    }

    /// Freezes the reading. A countdown paused at or after its deadline completes instead of storing a
    /// zero-length pause. Paused and finished sessions, and an unreadable clock, change nothing.
    public mutating func pause(at now: Double) -> TimerCompletion? {
        guard case .running = state, now.isFinite else { return nil }
        if phase.countsDown, let deadline, now >= deadline { return finish() }
        state = .paused(reading: reading(at: now))
        return nil
    }

    /// Continues from exactly the frozen reading, whatever time has passed meanwhile.
    @discardableResult
    public mutating func resume(at now: Double) -> Bool {
        guard case .paused(let reading) = state, now.isFinite else { return false }
        state = .running(anchor: phase.countsDown ? now + reading : now - reading)
        return true
    }

    /// Whether the last focus of a Pomodoro cycle has finished.
    public var endsCycle: Bool {
        guard let plan, mode == .pomodoro else { return false }
        return completedFocuses >= plan.totalSessions
    }

    /// The phase the person can start after a finished Pomodoro phase; nil for anything else, and once
    /// the cycle is over. A long break follows every `sessionsBeforeLongBreak` completed focuses.
    public var nextPhase: TimerPhase? {
        guard isFinished, let plan, mode == .pomodoro, !endsCycle else { return nil }
        if phase == .focus {
            return completedFocuses % plan.sessionsBeforeLongBreak == 0 ? .longBreak : .shortBreak
        }
        return .focus
    }

    /// Starts the next Pomodoro phase. Never automatic: the person presses it, so a long sleep cannot
    /// run through phases nobody took.
    @discardableResult
    public mutating func startNextPhase(at now: Double) -> Bool {
        guard let next = nextPhase, let plan, now.isFinite else { return false }
        phase = next
        length = plan.length(of: next)
        state = .running(anchor: now + length)
        return true
    }

    /// "Session N of M": the focus under way, or the one just finished.
    public var sessionNumber: Int {
        guard let plan else { return 0 }
        let current = phase == .focus && !isFinished ? completedFocuses + 1 : completedFocuses
        return min(max(current, 1), plan.totalSessions)
    }

    /// The page's title for this session.
    public var title: String {
        guard isFinished, phase.countsDown else { return phase.title }
        return endsCycle ? "Pomodoro complete" : "Time is up"
    }

    private mutating func finish() -> TimerCompletion {
        state = .finished
        if phase == .focus { completedFocuses += 1 }
        return TimerCompletion(phase: phase, endsCycle: endsCycle)
    }
}

/// The one place a session lives. Starting while one exists is refused, so a second click can never
/// replace a running timer.
public struct TimerSlot: Equatable, Sendable {
    public private(set) var session: TimerSession?

    public init() {}

    @discardableResult
    public mutating func start(_ new: TimerSession?) -> Bool {
        guard session == nil, let new else { return false }
        session = new
        return true
    }

    /// Changes the session in place; nil when there is none.
    public mutating func update<Result>(_ change: (inout TimerSession) -> Result) -> Result? {
        guard var copy = session else { return nil }
        let result = change(&copy)
        session = copy
        return result
    }

    /// Cancel or Done: the whole session goes, Pomodoro progress included.
    public mutating func dismiss() { session = nil }
}
