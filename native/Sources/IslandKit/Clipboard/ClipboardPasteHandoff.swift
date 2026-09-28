import Foundation

/// Hands a paste to the app it was meant for. After the entry is written and the target asked to
/// come forward, ⌘V is posted only once the target has been the frontmost app for a short settle,
/// with MenuSprite neither frontmost nor holding the keyboard in one of its own windows. If that
/// does not happen within the timeout, or the target quits, or Accessibility is withdrawn, nothing
/// is posted: the entry stays on the pasteboard for the person to paste themselves.
public struct ClipboardPasteHandoff: Sendable {
    public static let timeout: TimeInterval = 1
    /// How long the target must stay frontmost before ⌘V, so its own window has the keyboard.
    public static let settle: TimeInterval = 0.08
    /// How often the owner checks while a handoff is waiting.
    public static let pollInterval: TimeInterval = 0.02

    public enum GiveUp: Equatable, Sendable {
        /// The target never became the frontmost app in time (slow activation, or focus moved).
        case targetNotFront
        /// The target quit.
        case targetGone
        /// Accessibility was withdrawn; posting keys is no longer allowed.
        case notTrusted
    }

    public enum Step: Equatable, Sendable {
        case wait
        /// Post ⌘V now. Returned at most once.
        case post
        case giveUp(GiveUp)
        /// Already posted or given up; nothing more to do.
        case done
    }

    /// What the owner sees at one check.
    public struct Observation: Equatable, Sendable {
        public var frontmost: Int32?
        /// A MenuSprite window (the island, the history window) still has the keyboard.
        public var ownWindowHasKeyboard: Bool
        public var targetTerminated: Bool
        public var trusted: Bool

        public init(frontmost: Int32?, ownWindowHasKeyboard: Bool, targetTerminated: Bool, trusted: Bool) {
            self.frontmost = frontmost
            self.ownWindowHasKeyboard = ownWindowHasKeyboard
            self.targetTerminated = targetTerminated
            self.trusted = trusted
        }
    }

    public let target: Int32
    public let own: Int32
    public let started: Date
    public private(set) var readySince: Date?
    public private(set) var isFinished = false

    public init(target: Int32, own: Int32, started: Date) {
        self.target = target
        self.own = own
        self.started = started
    }

    public mutating func check(_ observation: Observation, now: Date) -> Step {
        guard !isFinished else { return .done }
        if observation.targetTerminated { return finish(.giveUp(.targetGone)) }
        if !observation.trusted { return finish(.giveUp(.notTrusted)) }
        let ready = observation.frontmost == target && target != own && !observation.ownWindowHasKeyboard
        if ready {
            let since = readySince ?? now
            readySince = since
            if now.timeIntervalSince(since) >= Self.settle, now.timeIntervalSince(started) < Self.timeout {
                return finish(.post)
            }
        } else {
            // Focus moved away (or never arrived): the settle starts again when it comes back.
            readySince = nil
        }
        if now.timeIntervalSince(started) >= Self.timeout { return finish(.giveUp(.targetNotFront)) }
        return .wait
    }

    private mutating func finish(_ step: Step) -> Step {
        isFinished = true
        return step
    }
}
