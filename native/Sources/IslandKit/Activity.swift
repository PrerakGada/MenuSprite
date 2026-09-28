import Foundation

/// A live activity that can take the closed island. Declared in priority order.
public enum IslandActivityKind: String, CaseIterable, Codable, Sendable, Comparable, Identifiable {
    case timer, downloads, agents, calendar, music
    public var id: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var title: String {
        switch self {
        case .timer: "Timer"
        case .downloads: "Downloads"
        case .agents: "AI Agents"
        case .calendar: "Calendar"
        case .music: "Music"
        }
    }

    public var symbol: String {
        switch self {
        case .timer: "timer"
        case .downloads: "arrow.down.circle"
        case .agents: "sparkles"
        case .calendar: "calendar"
        case .music: "music.note"
        }
    }

    /// The page an activity opens.
    public var section: IslandSectionID {
        switch self {
        case .timer: .timer
        case .downloads: .downloads
        case .agents: .agents
        case .calendar: .calendar
        case .music: .music
        }
    }
}

/// Which activity the closed island shows when several are live. Automatic priority unless the
/// person picked one; a pick lasts only while that activity stays live. Only the timer shares: its
/// left wing can carry one companion, chosen explicitly.
public struct IslandActivityChoice: Equatable, Sendable {
    public private(set) var chosen: IslandActivityKind?
    public private(set) var companion: IslandActivityKind?

    public init() {}

    /// Companions a timer can carry right now: downloads in any state; agents and music only while
    /// the timer runs (a paused or finished timer keeps its own status mark).
    public static func companions(live: Set<IslandActivityKind>, timerRunning: Bool) -> [IslandActivityKind] {
        guard live.contains(.timer) else { return [] }
        var result: [IslandActivityKind] = []
        if live.contains(.downloads) { result.append(.downloads) }
        if timerRunning, live.contains(.agents) { result.append(.agents) }
        if timerRunning, live.contains(.music) { result.append(.music) }
        return result
    }

    /// Forgets a choice whose activity ended, and a companion that is no longer eligible.
    public mutating func reconcile(live: Set<IslandActivityKind>, timerRunning: Bool) {
        if let chosen, !live.contains(chosen) { self.chosen = nil; companion = nil }
        if !live.contains(.timer) { companion = nil }
        if let companion, !Self.companions(live: live, timerRunning: timerRunning).contains(companion) {
            self.companion = nil
        }
    }

    /// The person picked a single activity. A late click on one that is no longer live is ignored.
    public mutating func choose(_ kind: IslandActivityKind, live: Set<IslandActivityKind>) {
        guard live.contains(kind) else { return }
        chosen = kind
        companion = nil
    }

    /// The person picked "Timer + X". Unsupported pairs leave the current choice alone.
    public mutating func combine(_ kind: IslandActivityKind, live: Set<IslandActivityKind>, timerRunning: Bool) {
        guard Self.companions(live: live, timerRunning: timerRunning).contains(kind) else { return }
        chosen = .timer
        companion = kind
    }

    /// What to show: the chosen activity when live, else the highest-priority live one, plus the
    /// timer's companion when one was combined.
    public func resolve(live: Set<IslandActivityKind>, timerRunning: Bool) -> (primary: IslandActivityKind, companion: IslandActivityKind?)? {
        var copy = self
        copy.reconcile(live: live, timerRunning: timerRunning)
        let primary = copy.chosen ?? IslandActivityKind.allCases.first(where: live.contains)
        guard let primary else { return nil }
        return (primary, primary == .timer ? copy.companion : nil)
    }
}

/// The kinds of transient notice, with their priority and how long each stays up.
public enum IslandNoticeKind: String, CaseIterable, Sendable, Equatable {
    case volume, brightness, keyboardLight
    case capture, timerFinished
    case battery, accessory, notification, agent
    case clipboard, downloadComplete, newTrack

    public var priority: Int {
        switch self {
        case .volume, .brightness, .keyboardLight: 3
        case .capture, .timerFinished: 2
        case .battery, .accessory, .notification, .agent: 1
        case .clipboard, .downloadComplete, .newTrack: 0
        }
    }

    public var duration: Double {
        switch self {
        case .volume, .brightness, .keyboardLight: 1.6
        case .capture: 12
        case .timerFinished: 6
        case .battery, .accessory: 4
        case .notification: 3
        case .agent: 5
        case .clipboard: 2.5
        case .downloadComplete: 6
        case .newTrack: 3
        }
    }

    public var isLevel: Bool { self == .volume || self == .brightness || self == .keyboardLight }

    /// The page a click on this notice opens.
    public var section: IslandSectionID {
        switch self {
        case .downloadComplete: .downloads
        case .timerFinished: .timer
        case .accessory: .system
        case .notification: .notifications
        case .clipboard: .clipboard
        case .agent: .agents
        case .newTrack: .music
        case .volume, .brightness, .keyboardLight, .battery, .capture: .controls
        }
    }

    /// A new notice replaces the current one when its priority is at least as high; lower ones are
    /// dropped, not queued.
    public func replaces(_ current: IslandNoticeKind?) -> Bool {
        guard let current else { return true }
        return priority >= current.priority
    }
}

/// Wing widths for notices, from measured text widths.
public enum IslandNoticeWings {
    public static let level: CGFloat = 80
    public static let notification: CGFloat = 190

    /// A text notice: symbol plus title on the left, detail on the right, reading from the island's ends.
    public static func text(titleWidth: CGFloat, detailWidth: CGFloat, cameraGap: CGFloat, maximum: CGFloat = 240) -> CGFloat {
        min(maximum, max(88, ceil(max(titleWidth + 26, detailWidth)) + 16 + cameraGap))
    }
}
