import Foundation

/// Tokens a turn has spent, by response. Repeats of one response merge to its final counts, so a
/// streamed reply (logged once per block) or one seen in two files counts once.
public struct AgentTurnSpend: Equatable, Sendable {
    private struct Entry: Equatable, Sendable { var model: String; var tokens: AgentTokens }
    private var entries: [String: Entry] = [:]
    public private(set) var total = AgentTokens()
    public private(set) var byModel: [String: AgentTokens] = [:]

    public init() {}

    public var responseCount: Int { entries.count }

    public mutating func add(key: String, model: String, tokens: AgentTokens) {
        let previous = entries[key]
        let merged = previous.map { $0.tokens.merged(with: tokens) } ?? tokens
        let owner = previous?.model ?? model
        guard merged != previous?.tokens else { return }
        entries[key] = Entry(model: owner, tokens: merged)
        let old = previous?.tokens ?? AgentTokens()
        total = total - old + merged
        byModel[owner] = (byModel[owner] ?? AgentTokens()) - old + merged
    }
}

extension AgentTokens {
    static func - (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input - rhs.input, cacheWrite5m: lhs.cacheWrite5m - rhs.cacheWrite5m,
             cacheWrite1h: lhs.cacheWrite1h - rhs.cacheWrite1h, cacheRead: lhs.cacheRead - rhs.cacheRead,
             output: lhs.output - rhs.output)
    }
}

/// Follows one Claude Code transcript's turns from its lines. Claude Code's registry says when a
/// session is busy; the transcript says how a turn ended (a finished reply, an interruption, an API
/// error) and, for versions without a registry status, whether one is open at all.
public struct ClaudeTurnTracker: Equatable, Sendable {
    public enum End: Equatable, Sendable { case completed, silent }

    public private(set) var isOpen = false
    public private(set) var openedAt: Date?
    public private(set) var lastEnd: End?
    public private(set) var endedAt: Date?
    public private(set) var lastActivity: Date?
    /// The session's own model: a subagent's reply never changes it.
    public private(set) var model: String?
    public private(set) var title: String?
    private var titleIsCustom = false

    public init() {}

    public mutating func apply(_ event: ClaudeLogEvent) {
        switch event {
        case .response(let response):
            touch(response.time)
            guard !response.isSidechain else { return }
            if !response.model.isEmpty { model = response.model }
            switch response.stop {
            case .completed: close(.completed, at: response.time)
            case .failed: close(.silent, at: response.time)
            case .working: if !isOpen { open(at: response.time) }
            }
        case .prompt(let time):
            touch(time)
            if !isOpen { open(at: time) }
        case .interrupted(let time):
            touch(time)
            close(.silent, at: time)
        case .activity(let time):
            touch(time)
        case .title(let text, let isCustom):
            if isCustom || !titleIsCustom { title = text; titleIsCustom = titleIsCustom || isCustom }
        }
    }

    private mutating func open(at time: Date?) {
        isOpen = true
        openedAt = time
        lastEnd = nil
        endedAt = nil
    }

    private mutating func close(_ end: End, at time: Date?) {
        isOpen = false
        lastEnd = end
        endedAt = time
    }

    private mutating func touch(_ time: Date?) {
        guard let time else { return }
        lastActivity = max(lastActivity ?? time, time)
    }
}

/// Follows one Codex session log: its tasks, their spend, and how each ended.
public struct CodexTurnTracker: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Finished, with Codex's own measured duration when it logged one.
        case completed(duration: Double?)
        case aborted
    }

    /// A task that just ended, as `apply` reports it.
    public struct Ended: Equatable, Sendable {
        public var outcome: Outcome
        public var startedAt: Date?
        public var endedAt: Date?
        public var spend: AgentTurnSpend
        public var model: String?
    }

    public private(set) var isOpen = false
    public private(set) var openedAt: Date?
    public private(set) var model: String?
    public private(set) var directory: String?
    public private(set) var lastActivity: Date?
    public private(set) var spend = AgentTurnSpend()
    /// Once a log carries per-response records, its running totals are never counted again.
    public private(set) var sawRecords = false
    private var lastTotal: AgentTokens?
    private var totalsCount = 0

    public init() {}

    /// Applies one line. Returns the task it ended, if it ended one.
    @discardableResult
    public mutating func apply(_ event: CodexLogEvent) -> Ended? {
        switch event {
        case .session(let directory):
            if let directory { self.directory = directory }
        case .context(let model, let directory):
            if let model { self.model = model }
            if let directory { self.directory = directory }
        case .usage(let key, let tokens, let time):
            touch(time)
            sawRecords = true
            if countsTowardTurn(time) { spend.add(key: key, model: model ?? "", tokens: tokens) }
        case .totals(let last, let total, let time):
            touch(time)
            guard !sawRecords else { return nil }
            // Growth since the previous total is one response; the logged last response is preferred.
            let response = last ?? total.map { $0 - (lastTotal ?? AgentTokens()) }
            if let total { lastTotal = total }
            totalsCount += 1
            if let response, response.total > 0, countsTowardTurn(time) {
                spend.add(key: "total:\(totalsCount)", model: model ?? "", tokens: response)
            }
        case .started(let time):
            touch(time)
            isOpen = true
            openedAt = time
            spend = AgentTurnSpend()
        case .completed(let time, let duration):
            touch(time)
            return end(.completed(duration: duration), at: time)
        case .aborted(let time):
            touch(time)
            return end(.aborted, at: time)
        }
        return nil
    }

    private mutating func end(_ outcome: Outcome, at time: Date?) -> Ended? {
        guard isOpen else { return nil }
        let ended = Ended(outcome: outcome, startedAt: openedAt, endedAt: time, spend: spend, model: model)
        isOpen = false
        openedAt = nil
        spend = AgentTurnSpend()
        return ended
    }

    private func countsTowardTurn(_ time: Date?) -> Bool {
        guard isOpen else { return false }
        guard let time, let openedAt else { return true }
        return time >= openedAt.addingTimeInterval(-1)
    }

    private mutating func touch(_ time: Date?) {
        guard let time else { return }
        lastActivity = max(lastActivity ?? time, time)
    }
}

/// The timing rules every agent follows.
public enum AgentTurnRules {
    /// A turn quiet this long stops showing as working; new activity brings it back.
    public static let quietLimit: TimeInterval = 600
    /// A turn that ended longer ago than this before it was read is not news.
    public static let newsWindow: TimeInterval = 300
    /// A quiet Claude turn (a killed session can leave one) is dropped after an hour; Codex after six.
    public static func waitingLimit(_ agent: AgentKind) -> TimeInterval { agent == .claude ? 3600 : 6 * 3600 }
    /// Only responses at or after a turn's start (less a second) belong to it.
    public static let startSlack: TimeInterval = 1

    /// Working: the turn is open and something was written within the quiet limit.
    public static func isWorking(open: Bool, lastActivity: Date?, now: Date) -> Bool {
        guard open, let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) <= quietLimit
    }

    /// Whether a finished turn gets a "finished" notice: it completed (not interrupted, aborted or an
    /// API error), lasted at least the chosen minimum, reporting was armed after the first read, and
    /// it ended recently enough to be news.
    public static func announcesFinish(completed: Bool, duration: Double, minimum: Double, endedAt: Date?,
                                       now: Date, armed: Bool) -> Bool {
        guard completed, armed, duration >= AgentOptions.clampMinimum(minimum) else { return false }
        guard let endedAt else { return true }
        return now.timeIntervalSince(endedAt) <= newsWindow
    }
}
