import Foundation

/// A live Claude Code session as Claude Code itself records it. Only what a row
/// needs to be recognised and cleared is kept; no prompt or message text.
public struct ClaudeCodeSession: Codable, Equatable, Sendable {
    public let sessionID: String
    /// The user's rename if there is one, otherwise Claude Code's own title.
    public let title: String?
    public let directory: String?
    /// Claude Code's own word ("idle", "busy", …), passed through, never guessed.
    public let status: String?
    public let lastActive: Date?
    public let background: Bool
    public init(sessionID: String, title: String?, directory: String?, status: String?, lastActive: Date?, background: Bool = false) {
        self.sessionID = sessionID; self.title = title; self.directory = directory
        self.status = status; self.lastActive = lastActive; self.background = background
    }
    public var isWorking: Bool { status == "busy" }
}

public enum ClaudeCode {
    public static let groupID = "claude-code"
    public static let serviceID = "claude-code:service"
    public static let sessionPrefix = "claude-session:"
    /// The native installer's versioned binaries, and the editor extensions'
    /// `claude` binary. An npm install runs as `node` and is not recognised:
    /// telling it apart would need its command line, which is never read.
    public static func isExecutable(_ path: String) -> Bool {
        path.contains("/.local/share/claude/versions/") || (path.hasPrefix("/") && URL(fileURLWithPath: path).lastPathComponent == "claude")
    }
}

/// Reads Claude Code's own session registry (`~/.claude/sessions/<pid>.json`)
/// and the tail of that session's transcript for its title. Nothing else in a
/// transcript is retained. Results are cached by file date and size, so an open
/// panel re-reads a file only when Claude Code has written to it.
struct ClaudeSessionReader {
    private struct Registered { let started: UInt64; let modified: Date; let session: Record? }
    private struct Record { let id: String; let directory: String?; let name: String?; let nameSource: String?; let status: String?; let updated: Date?; let background: Bool }
    private struct Title { let checked: Double; let size: UInt64; let title: String? }
    private let root: URL
    private var registry: [Int32: Registered] = [:]
    private var titles: [String: Title] = [:]
    private var transcripts: [String: URL] = [:]
    private var missing: [String: Double] = [:]
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)) { self.root = root }

    mutating func retain(_ pids: Set<Int32>) {
        registry = registry.filter { pids.contains($0.key) }
        let live = Set(registry.values.compactMap { $0.session?.id })
        titles = titles.filter { live.contains($0.key) }; transcripts = transcripts.filter { live.contains($0.key) }
        missing = missing.filter { live.contains($0.key) }
    }

    mutating func session(pid: Int32, started: UInt64, startSeconds: UInt64, now: Double = ProcessInfo.processInfo.systemUptime) -> ClaudeCodeSession? {
        let file = root.appendingPathComponent("sessions/\(pid).json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date else { registry[pid] = nil; return nil }
        let record: Record?
        if let cached = registry[pid], cached.started == started, cached.modified == modified { record = cached.session }
        else {
            record = Self.parse(file, pid: pid, startSeconds: startSeconds)
            registry[pid] = Registered(started: started, modified: modified, session: record)
        }
        guard let record else { return nil }
        let title: String?
        if record.nameSource == "user", let name = record.name { title = name }
        else { title = transcriptTitle(record, now: now) ?? (record.nameSource == "auto" ? record.name : nil) }
        return ClaudeCodeSession(sessionID: record.id, title: title, directory: record.directory, status: record.status,
                                 lastActive: record.updated, background: record.background)
    }

    private static func parse(_ file: URL, pid: Int32, startSeconds: UInt64) -> Record? {
        guard let data = try? Data(contentsOf: file), data.count < 65_536,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["pid"] as? NSNumber)?.int32Value == pid, let id = json["sessionId"] as? String, !id.isEmpty else { return nil }
        // A registry file left by an exited session must not label a new process
        // that happens to reuse its PID.
        if startSeconds > 0, let started = (json["startedAt"] as? NSNumber)?.doubleValue,
           abs(started / 1000 - Double(startSeconds)) > 600 { return nil }
        let updated = (json["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        func text(_ key: String) -> String? { (json[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return Record(id: id, directory: text("cwd"), name: text("name"), nameSource: text("nameSource"), status: text("status"),
                      updated: updated, background: text("kind") == "bg")
    }

    private mutating func transcriptTitle(_ record: Record, now: Double) -> String? {
        if let cached = titles[record.id], now - cached.checked < 30 { return cached.title }
        guard let url = transcript(record, now: now),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return titles[record.id]?.title }
        if let cached = titles[record.id], cached.size == size.uint64Value {
            titles[record.id] = Title(checked: now, size: cached.size, title: cached.title); return cached.title
        }
        let found = Self.tailTitle(url, size: size.uint64Value) ?? titles[record.id]?.title
        titles[record.id] = Title(checked: now, size: size.uint64Value, title: found)
        return found
    }

    private mutating func transcript(_ record: Record, now: Double) -> URL? {
        if let known = transcripts[record.id] { return known }
        if let tried = missing[record.id], now - tried < 60 { return nil }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let name = record.id + ".jsonl"
        var candidates: [URL] = []
        if let directory = record.directory {
            let slug = String(directory.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            candidates.append(projects.appendingPathComponent(slug).appendingPathComponent(name))
        }
        // Long or unusual folder names are shortened by Claude Code; look once.
        if !candidates.contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) {
            candidates += folders.map { $0.appendingPathComponent(name) }
        }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { missing[record.id] = now; return nil }
        transcripts[record.id] = url
        return url
    }

    /// Titles are re-appended through a session, so the latest one sits near the
    /// end. Reads at most 256 KiB from the end; a rename outranks the auto title.
    static func tailTitle(_ url: URL, size: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        for window: UInt64 in [65_536, 262_144] {
            try? handle.seek(toOffset: size > window ? size - window : 0)
            guard let data = try? handle.read(upToCount: Int(min(window, size))) else { return nil }
            if let title = title(in: data) { return title }
            if size <= window { break }
        }
        return nil
    }

    static func title(in data: Data) -> String? {
        var automatic: String?
        for line in data.split(separator: 0x0A).reversed() where line.count < 4096 {
            let custom = line.range(of: Data("\"custom-title\"".utf8)) != nil
            guard custom || (automatic == nil && line.range(of: Data("\"ai-title\"".utf8)) != nil),
                  let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if json["type"] as? String == "custom-title", let title = json["customTitle"] as? String, !title.isEmpty { return title }
            if json["type"] as? String == "ai-title", let title = json["aiTitle"] as? String, !title.isEmpty { automatic = automatic ?? title }
        }
        return automatic
    }
}
