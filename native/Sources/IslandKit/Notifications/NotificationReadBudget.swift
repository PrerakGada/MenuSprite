import Foundation

/// Hard limits on one read of Notification Center's tree. Exceeding any of them discards the whole
/// read: a partial tree must never become the inbox or authorise an action.
public struct NotificationReadLimits: Equatable, Sendable {
    public var deadline: TimeInterval = 0.8
    public var nodes = 384
    public var depth = 10
    public var children = 64
    public var windows = 32

    public static let standard = NotificationReadLimits()
    public init() {}
}

/// Why a read produced no snapshot.
public enum NotificationReadFailure: Error, Equatable, Sendable {
    case deadline, tooManyNodes, tooDeep, tooManyChildren, tooManyWindows
    /// An attribute could not be read (timeout, element gone, unexpected type).
    case unreadable(String)
    /// Whether Notification Center itself is open could not be established.
    case focusUnreadable
    /// The reader was detached, the section switched off or Accessibility withdrawn mid-read.
    case cancelled
}

/// Counts one read against its limits. Each read (a refresh, the validation before an action)
/// gets its own budget, so a heavy refresh cannot starve the check that follows it.
public struct NotificationReadBudget: Sendable {
    public let limits: NotificationReadLimits
    public private(set) var nodes = 0
    private let start: TimeInterval
    private let clock: @Sendable () -> TimeInterval

    public init(limits: NotificationReadLimits = .standard,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.limits = limits
        self.clock = clock
        self.start = clock()
    }

    /// Call once per element read, with its depth below the window (the window is 0).
    public mutating func visit(depth: Int) throws(NotificationReadFailure) {
        try checkTime()
        nodes += 1
        if nodes > limits.nodes { throw .tooManyNodes }
        if depth > limits.depth { throw .tooDeep }
    }

    /// Call with an element's child count before descending into them.
    public func check(children: Int, depth: Int) throws(NotificationReadFailure) {
        if children > limits.children { throw .tooManyChildren }
        if children > 0, depth + 1 > limits.depth { throw .tooDeep }
    }

    public func check(windows: Int) throws(NotificationReadFailure) {
        if windows > limits.windows { throw .tooManyWindows }
    }

    public func checkTime() throws(NotificationReadFailure) {
        if clock() - start > limits.deadline { throw .deadline }
    }
}

/// Whether Notification Center has a focused window: the person opened it, and its history must
/// not be imported as new messages.
public enum NotificationFocus: Equatable, Sendable {
    case none, focused, unreadable

    /// Nil means read on; otherwise the read stops here (a skip for an open Notification Center,
    /// a failure when the state is unknown, never "closed" by default).
    public var stop: NotificationReadOutcome? {
        switch self {
        case .none: nil
        case .focused: .skipped
        case .unreadable: .failed(.focusUnreadable)
        }
    }
}

/// The result of one read.
public enum NotificationReadOutcome: Equatable, Sendable {
    case complete([NotificationSnapshotItem])
    /// Notification Center is open; nothing was read.
    case skipped
    case failed(NotificationReadFailure)
}
