import CoreServices
import Foundation
import IslandKit

/// Where the agents keep what the island reads. Symlinked dotfile setups resolve to real paths so
/// file events match.
struct AgentPaths: Sendable {
    var claudeSessions: URL
    var claudeProjects: URL
    var codexSessions: URL

    static var standard: AgentPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AgentPaths(claudeSessions: canonical(home.appendingPathComponent(".claude/sessions", isDirectory: true)),
                          claudeProjects: canonical(home.appendingPathComponent(".claude/projects", isDirectory: true)),
                          codexSessions: canonical(home.appendingPathComponent(".codex/sessions", isDirectory: true)))
    }

    /// The real path, as file events report it (`resolvingSymlinksInPath` drops `/private`, which
    /// events keep). A missing folder keeps its name.
    static func canonical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}

struct AgentActivityConfiguration: Equatable, Sendable {
    var agents: Set<AgentKind>
    /// Something on screen shows live tokens or cost: poll working logs every 2 s instead of 10.
    var hot: Bool
}

/// Follows which Claude Code and Codex turns are working, on its own serial queue.
///
/// Claude Code says itself when a session is busy (its registry, watched with file events), so a
/// Claude transcript is read only while its session is busy: that turn's own bytes once, bounded,
/// then only what is appended. Codex has no registry: its session logs modified in the last day are
/// checked by size, and only the ones holding an open task or written in the last half hour are read.
/// Everything here runs on `queue`; results go to the main thread through the two callbacks.
final class AgentActivityEngine: @unchecked Sendable {
    typealias Publish = @Sendable (AgentActivitySnapshot) -> Void
    typealias Finish = @Sendable (AgentFinishedTurn) -> Void
    typealias Pricing = @Sendable (String, AgentTokens) -> Double?

    static let mainInterval: Double = 30
    static let discoveryInterval: TimeInterval = 300
    static let codexHotWindow: TimeInterval = 1800
    static let codexCandidateWindow: TimeInterval = 86_400
    static let turnReadCap: UInt64 = 16 << 20
    static let subagentReadCap: UInt64 = 4 << 20

    private let queue = DispatchQueue(label: "in.prerakgada.MenuSprite.island.agents", qos: .utility)
    private let paths: AgentPaths
    private let publish: Publish
    private let finish: Finish
    private let price: Pricing

    // Everything below is touched on `queue` only.
    private var configuration: AgentActivityConfiguration
    private var running = false
    /// History read at start is never news; only what happens after the first pass is.
    private var armed = false
    private var stream: FSEventStreamRef?
    private var mainTimer: DispatchSourceTimer?
    private var hotTimer: DispatchSourceTimer?
    private var hotInterval: Double = 0
    private var registry: [String: (modified: Date, record: ClaudeRegistryRecord?)] = [:]
    private var claude: [String: ClaudeSessionState] = [:]
    private var codex: [String: CodexFileState] = [:]
    private var lastDiscovery = Date.distantPast
    private var lastActivity: [AgentKind: Date] = [:]
    private var published: AgentActivitySnapshot?

    init(paths: AgentPaths, configuration: AgentActivityConfiguration, publish: @escaping Publish,
         finish: @escaping Finish, price: @escaping Pricing) {
        self.paths = paths
        self.configuration = configuration
        self.publish = publish
        self.finish = finish
        self.price = price
    }

    func start() { queue.async { self.begin() } }
    func update(_ configuration: AgentActivityConfiguration) { queue.async { self.apply(configuration) } }
    func stop() { queue.async { self.end() } }

    // MARK: Lifecycle

    private func begin() {
        guard !running else { return }
        running = true
        armed = false
        refreshRegistry()
        discoverCodex(now: Date())
        armed = true
        startStream()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.mainInterval, repeating: Self.mainInterval, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.mainTick() }
        timer.resume()
        mainTimer = timer
        publishIfChanged()
        updateHotTimer()
    }

    private func apply(_ new: AgentActivityConfiguration) {
        let old = configuration
        configuration = new
        guard running else { return }
        if old.agents != new.agents {
            stopStream()
            refreshRegistry()
            discoverCodex(now: Date())
            startStream()
        }
        publishIfChanged()
        updateHotTimer()
    }

    private func end() {
        running = false
        stopStream()
        mainTimer?.cancel(); mainTimer = nil
        hotTimer?.cancel(); hotTimer = nil
        registry = [:]; claude = [:]; codex = [:]
        published = nil
    }

    private func mainTick() {
        guard running else { return }
        let now = Date()
        refreshRegistry()
        for id in Array(claude.keys) { pollClaude(id) }
        for path in Array(codex.keys) { pollCodex(path, now: now) }
        if now.timeIntervalSince(lastDiscovery) >= Self.discoveryInterval { discoverCodex(now: now) }
        publishIfChanged()
        updateHotTimer()
    }

    private func hotTick() {
        guard running else { return }
        let now = Date()
        if configuration.hot { for id in Array(claude.keys) where claude[id]?.isBusy == true { pollClaude(id) } }
        for (path, file) in codex where isHot(file, now: now) { pollCodex(path, now: now) }
        publishIfChanged()
        updateHotTimer()
    }

    /// Polls only while something is live. File events arrive when a log closes, and agents keep
    /// their logs open, so appended work is found by size.
    private func updateHotTimer() {
        let now = Date()
        let needed = running && (claude.values.contains { $0.isBusy && configuration.hot } || codex.values.contains { isHot($0, now: now) })
        let interval = configuration.hot ? 2.0 : 10.0
        guard needed else { hotTimer?.cancel(); hotTimer = nil; return }
        guard hotTimer == nil || hotInterval != interval else { return }
        hotTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 250)))
        timer.setEventHandler { [weak self] in self?.hotTick() }
        timer.resume()
        hotTimer = timer
        hotInterval = interval
    }

    // MARK: File events

    private func startStream() {
        var roots: [String] = []
        if configuration.agents.contains(.claude) { roots.append(paths.claudeSessions.path) }
        if configuration.agents.contains(.codex) { roots.append(paths.codexSessions.path) }
        roots = roots.filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let engine = Unmanaged<AgentActivityEngine>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            let rescan = (0..<count).contains { index in
                let flag = Int(flags[index])
                return flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                               | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped) != 0
            }
            engine.filesChanged(list, rescan: rescan)
        }
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, roots as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Delivered on `queue` by the stream.
    private func filesChanged(_ changed: [String], rescan: Bool) {
        guard running else { return }
        let now = Date()
        let claudeRoot = paths.claudeSessions.path, codexRoot = paths.codexSessions.path
        if rescan || changed.contains(where: { $0.hasPrefix(claudeRoot) }) { refreshRegistry() }
        if rescan {
            discoverCodex(now: now)
        } else {
            for path in changed where path.hasPrefix(codexRoot) && path.hasSuffix(".jsonl") {
                if codex[path] != nil { pollCodex(path, now: now) } else { trackCodex(URL(fileURLWithPath: path), now: now) }
            }
        }
        publishIfChanged()
        updateHotTimer()
    }

    // MARK: Claude Code

    private func refreshRegistry() {
        guard configuration.agents.contains(.claude) else {
            registry = [:]; claude = [:]; lastActivity[.claude] = nil
            return
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: paths.claudeSessions.path)) ?? []).filter { $0.hasSuffix(".json") }
        var present = Set<String>()
        for name in names {
            let url = paths.claudeSessions.appendingPathComponent(name)
            guard let info = AgentLogReader.info(url) else { continue }
            present.insert(name)
            if registry[name]?.modified == info.modified { continue }
            registry[name] = (info.modified, (try? Data(contentsOf: url)).flatMap(ClaudeRegistryRecord.parse))
        }
        registry = registry.filter { present.contains($0.key) }

        var live: [String: ClaudeRegistryRecord] = [:]
        for entry in registry.values {
            guard let record = entry.record, Self.isAlive(record.pid) else { continue }
            if let other = live[record.sessionID], (other.statusChangedAt ?? .distantPast) > (record.statusChangedAt ?? .distantPast) { continue }
            live[record.sessionID] = record
        }
        lastActivity[.claude] = live.values.compactMap(\.statusChangedAt).max() ?? lastActivity[.claude]

        let now = Date()
        for (id, session) in claude {
            guard let record = live[id] else { endClaude(id, at: now, completed: false); continue }
            if session.record.status == nil {
                claude[id]?.record = record
            } else if !record.isBusy {
                endClaude(id, at: record.statusChangedAt ?? now, completed: true)
            } else if record.statusChangedAt != session.turnStart {
                // Idle and busy again between two looks: the earlier turn ended when this one began.
                endClaude(id, at: record.statusChangedAt ?? now, completed: true)
            } else {
                claude[id]?.record = record
            }
        }
        for (id, record) in live where claude[id] == nil && (record.isBusy || record.status == nil) {
            beginClaude(record, now: now)
        }
    }

    private func beginClaude(_ record: ClaudeRegistryRecord, now: Date) {
        var session = ClaudeSessionState(record: record)
        session.searchedAt = now
        if let url = transcriptURL(for: record), let info = AgentLogReader.info(url) { openTranscript(&session, url: url, info: info, now: now) }
        claude[record.sessionID] = session
        pollClaude(record.sessionID)
    }

    /// Where a session's transcript is first read from: the turn's own bytes (bounded) while it is
    /// writing, nothing of the past while it is quiet, the last megabyte for a Claude Code too old to
    /// report a status.
    private func openTranscript(_ session: inout ClaudeSessionState, url: URL, info: AgentFileInfo, now: Date) {
        session.transcriptURL = url
        if session.record.status == nil {
            session.transcript = AgentLogReader.cursor(url, at: info.size > 1 << 20 ? info.size - (1 << 20) : 0, info: info)
        } else if let start = session.turnStart, let last = AgentLogReader.lastTimestamp(url, size: info.size),
                  AgentTurnRules.isWorking(open: true, lastActivity: last, now: now) {
            let (offset, complete) = AgentLogReader.offset(before: start, url: url, size: info.size, cap: Self.turnReadCap)
            session.transcript = AgentLogReader.cursor(url, at: offset, info: info)
            session.partial = session.partial || !complete
        } else {
            session.transcript = AgentLogReader.cursorAtEnd(url, info: info)
            session.probedActivity = AgentLogReader.lastTimestamp(url, size: info.size)
            session.partial = true
        }
    }

    private func pollClaude(_ id: String) {
        guard var session = claude[id] else { return }
        let now = Date()
        if session.transcript == nil, session.searchedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            session.searchedAt = now
            if let url = transcriptURL(for: session.record), let info = AgentLogReader.info(url) {
                openTranscript(&session, url: url, info: info, now: now)
            }
        }
        if var cursor = session.transcript {
            let wasOpen = session.tracker.isOpen
            let exists = AgentLogReader.readAppended(&cursor) { line in
                guard let event = ClaudeLogLine.classify(line) else { return }
                session.apply(event, fromSubagent: false)
            }
            session.transcript = cursor
            if !exists {
                // A log deleted while its turn runs ends the turn silently.
                claude[id] = nil
                return
            }
            if session.record.status == nil, wasOpen, !session.tracker.isOpen { announceTranscriptEnd(session) }
        }
        pollSubagents(&session, now: now)
        claude[id] = session
    }

    /// Subagents' work counts toward their parent's turn. A subagent log still being written, or any
    /// of a working session's, is read from the turn's start (newest first, within one budget); a quiet
    /// session's old subagents are not read at all.
    private func pollSubagents(_ session: inout ClaudeSessionState, now: Date) {
        guard session.isBusy, let transcript = session.transcriptURL, let start = session.turnStart else { return }
        let folder = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        if let folderInfo = directoryInfo(folder), folderInfo.modified != session.subagentFolderModified {
            session.subagentFolderModified = folderInfo.modified
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jsonl") }
            let fresh = names.filter { session.subagents[$0] == nil }.compactMap { name -> (String, URL, AgentFileInfo)? in
                let url = folder.appendingPathComponent(name)
                guard let info = AgentLogReader.info(url), info.modified >= start.addingTimeInterval(-AgentTurnRules.startSlack) else { return nil }
                return (name, url, info)
            }.sorted { $0.2.modified > $1.2.modified }
            var budget = Self.turnReadCap
            for (name, url, info) in fresh {
                let writing = now.timeIntervalSince(info.modified) <= AgentTurnRules.quietLimit
                guard budget > 0, writing || session.workingStart(now: now) != nil else {
                    session.subagents[name] = AgentLogReader.cursorAtEnd(url, info: info)
                    session.partial = true
                    continue
                }
                let (offset, complete) = AgentLogReader.offset(before: start, url: url, size: info.size, cap: min(Self.subagentReadCap, budget))
                budget -= min(budget, info.size - offset)
                session.partial = session.partial || !complete
                session.subagents[name] = AgentLogReader.cursor(url, at: offset, info: info)
                session.subagentActivity = max(session.subagentActivity ?? info.modified, info.modified)
            }
        }
        for name in Array(session.subagents.keys) {
            guard var cursor = session.subagents[name] else { continue }
            let exists = AgentLogReader.readAppended(&cursor) { line in
                guard let event = ClaudeLogLine.classify(line) else { return }
                session.apply(event, fromSubagent: true)
            }
            session.subagents[name] = exists ? cursor : nil
            session.subagentActivity = max(session.subagentActivity ?? cursor.modified, cursor.modified)
        }
    }

    private func directoryInfo(_ url: URL) -> AgentFileInfo? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
              values.isDirectory == true, let modified = values.contentModificationDate else { return nil }
        return AgentFileInfo(size: 0, inode: 0, modified: modified)
    }

    /// The registry left busy: read what was appended so the reply (or interruption) that ended the
    /// turn is seen, then decide whether it is news.
    private func endClaude(_ id: String, at end: Date, completed: Bool) {
        if completed { pollClaude(id) }
        guard let session = claude.removeValue(forKey: id), session.record.status != nil, let start = session.turnStart else { return }
        var finished = completed
        if let ended = session.tracker.endedAt, ended >= start.addingTimeInterval(-AgentTurnRules.startSlack),
           session.tracker.lastEnd == .silent, !session.tracker.isOpen { finished = false }
        // A turn left quiet for longer than a killed session's leftovers is not announced as finished.
        if let last = session.lastActivity(), end.timeIntervalSince(last) > AgentTurnRules.waitingLimit(.claude) { finished = false }
        announce(.claude, session: session, started: start, ended: end, duration: end.timeIntervalSince(start), completed: finished)
    }

    private func announceTranscriptEnd(_ session: ClaudeSessionState) {
        guard let start = session.tracker.openedAt, let end = session.tracker.endedAt else { return }
        announce(.claude, session: session, started: start, ended: end, duration: end.timeIntervalSince(start),
                 completed: session.tracker.lastEnd == .completed)
    }

    private func announce(_ agent: AgentKind, session: ClaudeSessionState, started: Date, ended: Date, duration: Double, completed: Bool) {
        guard configuration.agents.contains(agent) else { return }
        finish(AgentFinishedTurn(agent: agent, duration: duration, endedAt: ended, completed: completed, armed: armed,
                                 cost: cost(session.spend).dollars, title: session.title, project: AgentFormat.projectName(session.record.directory)))
    }

    private func transcriptURL(for record: ClaudeRegistryRecord) -> URL? {
        let name = record.sessionID + ".jsonl"
        if let directory = record.directory {
            let slug = String(directory.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            let url = paths.claudeProjects.appendingPathComponent(slug).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Long or unusual folder names are shortened by Claude Code; look once.
        let folders = (try? FileManager.default.contentsOfDirectory(at: paths.claudeProjects, includingPropertiesForKeys: nil)) ?? []
        return folders.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: Codex

    private func discoverCodex(now: Date) {
        lastDiscovery = now
        guard configuration.agents.contains(.codex) else { codex = [:]; lastActivity[.codex] = nil; return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: paths.codexSessions, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            codex = [:]
            return
        }
        var newest: Date?
        var recent: [String: URL] = [:]
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            newest = max(newest ?? modified, modified)
            if now.timeIntervalSince(modified) <= Self.codexCandidateWindow { recent[url.path] = url }
        }
        lastActivity[.codex] = newest
        for (path, url) in recent where codex[path] == nil { trackCodex(url, now: now) }
        codex = codex.filter { path, file in recent[path] != nil || file.tracker.isOpen }
    }

    private func trackCodex(_ url: URL, now: Date) {
        guard configuration.agents.contains(.codex), let info = AgentLogReader.info(url),
              now.timeIntervalSince(info.modified) <= Self.codexCandidateWindow else { return }
        var file = CodexFileState(isSideThread: url.deletingPathExtension().lastPathComponent.contains("_"))
        if now.timeIntervalSince(info.modified) <= Self.codexHotWindow {
            // Read back to the last task boundary, so an open task and its spend are known.
            let markers: [StaticString] = ["\"task_started\"", "\"task_complete\"", "\"turn_aborted\""]
            let (offset, found) = AgentLogReader.offset(containingLastOf: markers, url: url, size: info.size, cap: Self.turnReadCap)
            file.cursor = AgentLogReader.cursor(url, at: offset, info: info)
            file.partial = !found
        } else {
            file.cursor = AgentLogReader.cursorAtEnd(url, info: info)
        }
        codex[url.path] = file
        pollCodex(url.path, now: now)
    }

    private func pollCodex(_ path: String, now: Date) {
        guard var file = codex[path], var cursor = file.cursor else { return }
        var ended: [CodexTurnTracker.Ended] = []
        let exists = AgentLogReader.readAppended(&cursor) { line in
            guard let event = CodexLogLine.classify(line, includeTotals: !file.tracker.sawRecords) else { return }
            if let end = file.tracker.apply(event) { ended.append(end) }
        }
        guard exists else { codex[path] = nil; return }
        file.cursor = cursor
        codex[path] = file
        lastActivity[.codex] = max(lastActivity[.codex] ?? cursor.modified, cursor.modified)
        guard !file.isSideThread else { return }
        for end in ended {
            let completed: Bool
            let duration: Double?
            switch end.outcome {
            case .completed(let measured):
                completed = true
                if let measured { duration = measured }
                else if let start = end.startedAt, let stop = end.endedAt { duration = stop.timeIntervalSince(start) }
                else { duration = nil }
            case .aborted:
                completed = false
                duration = nil
            }
            guard let duration else { continue }
            finish(AgentFinishedTurn(agent: .codex, duration: duration, endedAt: end.endedAt ?? now, completed: completed, armed: armed,
                                     cost: cost(end.spend).dollars, title: nil, project: AgentFormat.projectName(file.tracker.directory)))
        }
    }

    private func isHot(_ file: CodexFileState, now: Date) -> Bool {
        guard let cursor = file.cursor else { return false }
        if file.tracker.isOpen {
            let last = file.tracker.lastActivity ?? cursor.modified
            return now.timeIntervalSince(last) <= AgentTurnRules.waitingLimit(.codex)
        }
        return now.timeIntervalSince(cursor.modified) <= Self.codexHotWindow
    }

    // MARK: Publishing

    private func publishIfChanged() {
        guard running else { return }
        let now = Date()
        var working: [AgentLiveTurn] = []
        for session in claude.values {
            guard let start = session.workingStart(now: now) else { continue }
            let priced = cost(session.spend)
            working.append(AgentLiveTurn(id: "claude." + session.record.sessionID, agent: .claude, title: session.title,
                                         project: AgentFormat.projectName(session.record.directory), model: session.tracker.model,
                                         startedAt: start, tokens: session.spend.total, cost: priced.dollars,
                                         unpriced: priced.unpriced, partial: session.partial))
        }
        for (path, file) in codex where !file.isSideThread && file.tracker.isOpen {
            guard let cursor = file.cursor,
                  AgentTurnRules.isWorking(open: true, lastActivity: file.tracker.lastActivity ?? cursor.modified, now: now) else { continue }
            let priced = cost(file.tracker.spend)
            working.append(AgentLiveTurn(id: "codex." + path, agent: .codex, title: nil,
                                         project: AgentFormat.projectName(file.tracker.directory), model: file.tracker.model,
                                         startedAt: file.tracker.openedAt ?? cursor.modified, tokens: file.tracker.spend.total,
                                         cost: priced.dollars, unpriced: priced.unpriced, partial: file.partial))
        }
        working.sort { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        var seen = Set<AgentKind>()
        if FileManager.default.fileExists(atPath: paths.claudeProjects.path) || !registry.isEmpty { seen.insert(.claude) }
        if FileManager.default.fileExists(atPath: paths.codexSessions.path) { seen.insert(.codex) }
        let snapshot = AgentActivitySnapshot(loaded: true, working: working,
                                             lastActivity: lastActivity.filter { configuration.agents.contains($0.key) },
                                             seen: seen.intersection(configuration.agents))
        guard snapshot != published else { return }
        published = snapshot
        publish(snapshot)
    }

    /// Dollars at API list prices for what was priced; `unpriced` when some tokens had no rate.
    private func cost(_ spend: AgentTurnSpend) -> (dollars: Double?, unpriced: Bool) {
        var dollars: Double?
        var unpriced = false
        for (model, tokens) in spend.byModel where tokens.total > 0 {
            if let value = price(model, tokens) { dollars = (dollars ?? 0) + value } else { unpriced = true }
        }
        return (dollars, unpriced)
    }
}
