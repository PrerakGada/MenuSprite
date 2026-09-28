import Foundation
import IslandKit

/// One Claude Code session the engine is following: busy by the registry, or any session of a
/// Claude Code too old to say.
struct ClaudeSessionState {
    var record: ClaudeRegistryRecord
    var transcriptURL: URL?
    var transcript: AgentLogCursor?
    var tracker = ClaudeTurnTracker()
    var spend = AgentTurnSpend()
    var subagents: [String: AgentLogCursor] = [:]
    var subagentFolderModified: Date?
    var subagentActivity: Date?
    var probedActivity: Date?
    var searchedAt: Date?
    /// Part of the turn was written before the look-back limit, so its spend is a minimum.
    var partial = false

    init(record: ClaudeRegistryRecord) { self.record = record }

    var isBusy: Bool { record.isBusy }

    /// When the turn began: Claude Code's own busy time, or the transcript's for older versions.
    var turnStart: Date? { record.status == nil ? tracker.openedAt : record.statusChangedAt }

    var title: String? { record.userTitle ?? tracker.title }

    func lastActivity() -> Date? {
        [turnStart, tracker.lastActivity, subagentActivity, probedActivity].compactMap { $0 }.max()
    }

    /// The start of a turn that is working now, or nil.
    func workingStart(now: Date) -> Date? {
        guard let start = turnStart else { return nil }
        let open = record.status == nil ? tracker.isOpen : record.isBusy
        return AgentTurnRules.isWorking(open: open, lastActivity: lastActivity(), now: now) ? start : nil
    }

    mutating func apply(_ event: ClaudeLogEvent, fromSubagent: Bool) {
        if fromSubagent {
            // A subagent's work counts toward its parent's turn but never opens or ends it.
            switch event {
            case .response(let response): count(response); touch(response.time)
            case .activity(let time): touch(time)
            case .prompt(let time), .interrupted(let time): touch(time)
            case .title: break
            }
            return
        }
        let openedBefore = tracker.openedAt
        tracker.apply(event)
        if record.status == nil, tracker.isOpen, tracker.openedAt != openedBefore { spend = AgentTurnSpend() }
        if case .response(let response) = event { count(response) }
    }

    private mutating func count(_ response: AgentResponse) {
        guard response.tokens.total > 0 else { return }
        if let start = turnStart, let time = response.time, time < start.addingTimeInterval(-AgentTurnRules.startSlack) { return }
        spend.add(key: response.key, model: response.model, tokens: response.tokens)
    }

    private mutating func touch(_ time: Date?) {
        guard let time else { return }
        subagentActivity = max(subagentActivity ?? time, time)
    }
}

/// One Codex session log the engine is following.
struct CodexFileState {
    var cursor: AgentLogCursor?
    var tracker = CodexTurnTracker()
    /// Files named with an underscore are side threads: they never own a turn.
    var isSideThread: Bool
    var partial = false
}
