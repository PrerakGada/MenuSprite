import Foundation
import Testing
@testable import SystemMonitoring

private let binary = "/Users/test/.local/share/claude/versions/2.1.281"
private func session(_ id: String, _ title: String?, _ directory: String, _ status: String, idleSeconds: Double = 0) -> ProcessContext {
    ProcessContext(workingDirectory: directory, claudeSession: .init(sessionID: id, title: title, directory: directory, status: status,
                                                                    lastActive: Date(timeIntervalSince1970: 1_000_000 - idleSeconds)))
}
private func record(_ pid: Int32, parent: Int32, _ name: String, _ path: String, bytes: UInt64, context: ProcessContext? = nil) -> ProcessMemoryRecord {
    .init(pid: pid, parentPID: parent, userID: 501, started: UInt64(pid), name: name, executablePath: path, bytes: bytes, context: context)
}
private let now = Date(timeIntervalSince1970: 1_000_000)

/// Two terminal sessions (their shell's `login` parent is root and unreadable),
/// each with an MCP child, plus the background daemon and its spare.
private var terminal: [ProcessMemoryRecord] {[
    record(100, parent: 90, "-zsh", "/bin/zsh", bytes: 1),
    record(110, parent: 100, "2.1.281", binary, bytes: 400, context: session("aaaa", "TB Stores stock", "/Users/test/Developer/Gala-ERP", "idle", idleSeconds: 2 * 86_400)),
    record(111, parent: 110, "node", "/usr/local/bin/node", bytes: 60),
    record(120, parent: 100, "2.1.280", binary, bytes: 300, context: session("bbbb", nil, "/Users/test/Developer/NookMail", "busy")),
    record(121, parent: 120, "node", "/usr/local/bin/node", bytes: 40),
    record(130, parent: 1, "2.1.281", binary, bytes: 70),
    record(131, parent: 130, "2.1.281", binary, bytes: 50),
]}

@Test func claudeCodeProcessesMergeIntoOneRowWithASessionPerMember() throws {
    let groups = MemoryAttribution.group(terminal, applications: [])
    let claude = try #require(groups.first { $0.id == ClaudeCode.groupID })
    #expect(claude.bytes == 920 && claude.processCount == 6)
    // The shell that launched them is not Claude Code and stays its own row.
    #expect(groups.contains { $0.processes.map(\.pid) == [100] })
    let members = try #require(claude.members)
    #expect(members.count == 3)
    #expect(members.reduce(UInt64(0)) { $0 + $1.bytes } == claude.bytes)
    #expect(Set(members.flatMap { $0.processes.map(\.pid) }) == Set(claude.processes.map(\.pid)))
    #expect(members.first { $0.processes.contains { $0.pid == 111 } }?.processes.map(\.pid).sorted() == [110, 111])
    #expect(members.first { $0.id == ClaudeCode.serviceID }?.processes.map(\.pid).sorted() == [130, 131])
}

@Test func claudeInAnEditorJoinsClaudeCodeButAnAppItStartsStaysThatApp() {
    let records = [
        record(200, parent: 1, "Code", "/Applications/Visual Studio Code.app/Contents/MacOS/Code", bytes: 10),
        record(201, parent: 200, "claude", "/Users/test/.vscode/extensions/anthropic.claude-code-2.1.278/resources/native-binary/claude", bytes: 300),
        record(202, parent: 201, "Chromium", "/Users/test/Library/Caches/ms-playwright/chromium/Chromium.app/Contents/MacOS/Chromium", bytes: 90),
    ]
    let groups = MemoryAttribution.group(records, applications: [])
    #expect(groups.first { $0.id == ClaudeCode.groupID }?.processes.map(\.pid) == [201])
    #expect(groups.first { $0.name == "Code" || $0.name == "Visual Studio Code" }?.processes.map(\.pid) == [200])
    #expect(groups.first { $0.bundlePath?.hasSuffix("Chromium.app") == true }?.processes.map(\.pid) == [202])
    // A process merely named "Claude" inside an app is that app, not Claude Code.
    #expect(!ClaudeCode.isExecutable("/Applications/Claude.app/Contents/MacOS/Claude"))
}

@Test func sessionRowsNameTheConversationProjectAndIdleTime() throws {
    let claude = try #require(MemoryAttribution.group(terminal, applications: []).first { $0.id == ClaudeCode.groupID })
    let group = ProcessPresentation(consumer: claude, now: now)
    #expect(group.title == "Claude Code" && group.subtitle == "2 sessions · 1 working")
    let members = try #require(claude.members)
    let titled = ProcessPresentation(consumer: try #require(members.first { $0.processes.contains { $0.pid == 110 } }), now: now)
    #expect(titled.title == "TB Stores stock")
    #expect(titled.subtitle == "Gala-ERP · idle 2 d · PID 110")
    #expect(titled.explanation.contains("claude --resume aaaa"))
    let untitled = ProcessPresentation(consumer: try #require(members.first { $0.processes.contains { $0.pid == 120 } }), now: now)
    #expect(untitled.title == "NookMail" && untitled.subtitle == "working · PID 120")
    #expect(ProcessPresentation(consumer: try #require(members.first { $0.id == ClaudeCode.serviceID })).title == "Claude Code background service")
    #expect(ProcessPresentation.idle(since: now.addingTimeInterval(-30), now: now) == "idle")
    #expect(ProcessPresentation.idle(since: now.addingTimeInterval(-600), now: now) == "idle 10 min")
    #expect(ProcessPresentation.idle(since: now.addingTimeInterval(-7200), now: now) == "idle 2 h")
}

@Test func theGroupRowQuitsNothingWhileEachSessionQuitsItsOwnProcesses() throws {
    let claude = try #require(MemoryAttribution.group(terminal, applications: []).first { $0.id == ClaudeCode.groupID })
    let plan = ProcessTermination.plan(for: claude, userID: 501, ownPID: 9999)
    #expect(!plan.canQuit && plan.targets.isEmpty && plan.groupedSessions == 3 && !plan.blockedByOwnership)
    let member = try #require(claude.members?.first { $0.processes.contains { $0.pid == 110 } })
    #expect(ProcessTermination.plan(for: member, userID: 501, ownPID: 9999).targets.map(\.pid) == [110, 111])
}

@Test func membersAreRankedByTheSameReadings() throws {
    let ranked = ProcessActivityRates().rank(MemoryAttribution.group(terminal, applications: []), by: .memory)
    let claude = try #require(ranked.first { $0.id == ClaudeCode.groupID })
    #expect(claude.members.count == 3 && claude.members.map(\.value) == [460, 340, 120])
    #expect(abs(claude.members.reduce(0) { $0 + $1.value } - claude.value) < 0.001)
    #expect(ranked.filter { $0.id != ClaudeCode.groupID }.allSatisfy { $0.members.isEmpty })
}

@Test func readerTakesTitlesFromClaudeCodesOwnFilesAndRejectsAReusedPID() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = "/Users/test/Library/Mobile Documents/com~apple~CloudDocs/work"
    let projects = root.appendingPathComponent("projects/-Users-test-Library-Mobile-Documents-com-apple-CloudDocs-work")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    func register(_ pid: Int32, id: String, startedAt: Double, name: String = "work-a7", source: String = "derived") throws {
        let json: [String: Any] = ["pid": pid, "sessionId": id, "cwd": cwd, "startedAt": startedAt * 1000, "status": "idle",
                                   "updatedAt": 1_790_000_000_000, "name": name, "nameSource": source, "kind": "interactive"]
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("sessions/\(pid).json"))
    }
    // A user message that merely mentions a title type must not be read as one.
    let filler = #"{"type":"user","message":"grep for \"ai-title\" please"}"#
    let lines = [#"{"type":"ai-title","aiTitle":"Old title","sessionId":"s1"}"#, #"{"type":"custom-title","customTitle":"Renamed","sessionId":"s1"}"#,
                 #"{"type":"ai-title","aiTitle":"Newer auto title","sessionId":"s1"}"#, filler]
    try lines.joined(separator: "\n").write(to: projects.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
    try #"{"type":"ai-title","aiTitle":"Only auto","sessionId":"s2"}"#.write(to: projects.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
    try register(10, id: "s1", startedAt: 5_000)
    try register(11, id: "s2", startedAt: 5_000)
    try register(12, id: "s3", startedAt: 5_000, name: "Named by me", source: "user")
    try register(13, id: "s4", startedAt: 1_000)

    var reader = ClaudeSessionReader(root: root)
    let read = reader.session(pid: 10, started: 1, startSeconds: 5_010)
    let first = try #require(read)
    #expect(first.title == "Renamed" && first.directory == cwd && first.status == "idle" && !first.background)
    let r11 = reader.session(pid: 11, started: 1, startSeconds: 5_010); #expect(r11?.title == "Only auto")
    let r12 = reader.session(pid: 12, started: 1, startSeconds: 5_010); #expect(r12?.title == "Named by me")
    // Registered at 1,000 s; the live process started at 5,010 s — a reused PID.
    let r13 = reader.session(pid: 13, started: 1, startSeconds: 5_010); #expect(r13 == nil)
    let r14 = reader.session(pid: 14, started: 1, startSeconds: 5_010); #expect(r14 == nil)
    #expect(ClaudeSessionReader.title(in: Data(filler.utf8)) == nil)
}

@Test func snapshotsWithoutMembersOrSessionsStillDecode() throws {
    let consumer = MemoryAttribution.group([record(1, parent: 0, "node", "/usr/bin/node", bytes: 5)], applications: [])[0]
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(consumer)) as! [String: Any]
    object.removeValue(forKey: "members")
    let decoded = try JSONDecoder().decode(MemoryConsumer.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.members == nil && decoded.bytes == 5)
}

/// Reads this Mac's real Claude Code sessions. Opt-in: prints titles, which are private.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MENUSPRITE_LIVE_PROBE"] == "1"))
func liveClaudeSessionsProbe() async throws {
    let snapshot = await ProcessMemorySampler().sample(applications: [])
    let claude = try #require(snapshot.consumers.first { $0.id == ClaudeCode.groupID })
    let group = claude.presentation
    print("\(group.title) · \(group.subtitle ?? "") · \(claude.bytes / 1_048_576) MiB · \(claude.processCount) processes · rank \(snapshot.consumers.firstIndex { $0.id == claude.id }! + 1)")
    for member in claude.members ?? [] {
        let p = member.presentation
        print("  \(member.bytes / 1_048_576) MiB  \(p.title)  —  \(p.subtitle ?? "")")
    }
    #expect(claude.members?.reduce(UInt64(0)) { $0 + $1.bytes } == claude.bytes)
}
