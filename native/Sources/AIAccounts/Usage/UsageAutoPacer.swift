import Foundation

/// The "Auto" refresh mode: how long to wait before asking a provider for usage again, decided from
/// what the last answers showed rather than from a fixed number.
///
/// - **Idle backs off.** Every answer identical to the one before moves one step up the ladder
///   (2 → 5 → 10 → 15 → 30 → 60 minutes): if nothing is being used there is nothing new to read.
/// - **Activity is fast.** A jump of two points or more in any limit, a window that reset, or a
///   different account snaps back to the first step. A one-point drift holds the current step.
/// - **A nearly full limit is watched closely.** At 95% of the 5-hour session or the weekly window the
///   steps start at one minute (so auto-switching reacts in time) and relax only after five quiet
///   minutes; at 90% they start at two. The weekly window counts too since 10 Oct 2026: a weekly wall
///   stops every session as surely as a session wall.
/// - **At 98% it is read every two minutes and does not relax** for half an hour, even when the figure
///   holds still: auto-switch moves at 99%, and a quiet minute at 98% says nothing about the next one.
///   (10 Oct 2026, Prerak: "check every 2 min after it reaches 98 and switch as soon as it hits 99".) Sitting at the ceiling for hours does not turn into hundreds of requests.
/// - **A known reset is a known change.** When the session window resets before the next planned
///   check, the check moves to just after the reset.
/// - ⌘R restarts the ladder at the first step, whatever the last answer said.
///
/// Never below a minute: the Claude endpoint answers repeated requests with a cooldown of half an hour.
struct UsageAutoPacer: Sendable {
    static let normal: [TimeInterval] = [120, 300, 600, 900, 1800, 3600]
    static let warm: [TimeInterval] = [120, 120, 120, 300, 600]
    static let hot: [TimeInterval] = [60, 60, 60, 60, 60, 120, 120, 120, 300]
    static let critical: [TimeInterval] = Array(repeating: 120, count: 15) + [300]
    static let warmPercent = 90.0
    static let hotPercent = 95.0
    static let criticalPercent = 98.0
    /// A change of this many points in any limit counts as real use.
    static let activePoints = 2.0
    static let minimum: TimeInterval = 30

    private(set) var step = 0
    private var previous: [String: Double]?
    private var previousResets: [String: Date] = [:]
    private var restarted = false

    /// Records an answer and returns how long it may be reused.
    mutating func observe(_ snapshot: UsageSnapshot, now: Date) -> TimeInterval {
        let readings = Dictionary(snapshot.windows.map { ($0.id, $0.usedPercent) }, uniquingKeysWith: max)
        let resets = Dictionary(snapshot.windows.compactMap { window in window.resetsAt.map { (window.id, $0) } },
                                uniquingKeysWith: { first, _ in first })
        if restarted || previous == nil {
            step = 0
        } else if let previous, Self.isActivity(from: previous, to: readings, previousResets: previousResets, resets: resets) {
            step = 0
        } else if let previous, previous.allSatisfy({ readings[$0.key] == $0.value }) {
            step += 1
        }
        restarted = false
        previous = readings
        previousResets = resets
        return Self.interval(step: step, snapshot: snapshot, now: now)
    }

    /// ⌘R: the next answer starts the ladder over.
    mutating func restart() { restarted = true }

    static func interval(step: Int, snapshot: UsageSnapshot, now: Date) -> TimeInterval {
        let session = snapshot.window("session")
        let percent = max(session?.usedPercent ?? 0, snapshot.window("weekly")?.usedPercent ?? 0)
        let ladder = percent >= criticalPercent ? critical : percent >= hotPercent ? hot : percent >= warmPercent ? warm : normal
        var wait = ladder[min(max(0, step), ladder.count - 1)]
        if let reset = session?.resetsAt {
            let untilReset = reset.timeIntervalSince(now)
            if untilReset > 0, untilReset + 5 < wait { wait = max(minimum, untilReset + 5) }
        }
        return wait
    }

    private static func isActivity(from previous: [String: Double], to current: [String: Double],
                                   previousResets: [String: Date], resets: [String: Date]) -> Bool {
        if Set(previous.keys) != Set(current.keys) { return true }
        for (id, value) in current where abs(value - (previous[id] ?? value)) >= activePoints { return true }
        for (id, date) in resets {
            if let before = previousResets[id], abs(date.timeIntervalSince(before)) > 60 { return true }
        }
        return false
    }
}
