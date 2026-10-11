import AppKit
import AIAccounts
import SystemMonitoring

/// Whether MenuSprite tells Claude Code sessions stopped at a usage limit to carry on after it switches
/// the Claude login. On unless turned off in the AI Accounts board.
enum ResumePreference {
    private static let key = "MenuSprite.ResumeSessionsAfterSwitch"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// A live interactive Claude Code session whose transcript ends at a usage-limit refusal.
struct StoppedClaudeSession: Sendable, Equatable {
    let pid: Int32
    let sessionID: String
    let wall: LimitWall
    /// The session's terminal, e.g. `/dev/ttys004`; nil when it has none.
    let tty: String?
}

/// Finds Claude Code sessions stopped at a usage limit. Reads Claude Code's session registry
/// (`~/.claude/sessions/<pid>.json`) and at most 256 KiB from the end of each idle session's
/// transcript, and only re-reads a transcript whose size changed. Busy sessions are skipped: a
/// session at the wall is idle. Keeps the last reading per transcript and nothing of its text.
actor ClaudeWallScanner {
    private struct Cached { let size: UInt64; let reading: LimitWall.Reading }
    private let root: URL
    private var readings: [String: Cached] = [:]
    private var transcripts: [String: URL] = [:]

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)) {
        self.root = root
    }

    func stoppedSessions() -> [StoppedClaudeSession] {
        let folder = root.appendingPathComponent("sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var found: [StoppedClaudeSession] = []
        var live = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), data.count < 65_536,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 1,
                  let id = json["sessionId"] as? String, !id.isEmpty,
                  json["kind"] as? String == "interactive", json["status"] as? String != "busy",
                  let process = ClaudeProcess(pid: pid),
                  // A registry file left by an exited session must not name a process that reused its PID.
                  let started = (json["startedAt"] as? NSNumber)?.doubleValue, abs(started / 1000 - process.startedAt) < 600
            else { continue }
            live.insert(id)
            guard let transcript = transcript(id, directory: json["cwd"] as? String),
                  case .stopped(let wall) = reading(transcript, id: id) else { continue }
            found.append(StoppedClaudeSession(pid: pid, sessionID: id, wall: wall, tty: process.tty))
        }
        readings = readings.filter { live.contains($0.key) }
        transcripts = transcripts.filter { live.contains($0.key) }
        return found
    }

    private func reading(_ url: URL, id: String) -> LimitWall.Reading {
        guard let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value else { return .undecided }
        if let cached = readings[id], cached.size == size { return cached.reading }
        var result = LimitWall.Reading.undecided
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            for window: UInt64 in [65_536, 262_144] {
                try? handle.seek(toOffset: size > window ? size - window : 0)
                guard let data = try? handle.read(upToCount: Int(min(window, size))) else { break }
                result = LimitWall.read(tail: data)
                if result != .undecided || size <= window { break }
            }
        }
        readings[id] = Cached(size: size, reading: result)
        return result
    }

    /// Claude Code names a project folder after the working directory with every other character
    /// turned into "-"; long names are shortened, so fall back to looking in every folder once.
    private func transcript(_ id: String, directory: String?) -> URL? {
        if let known = transcripts[id] { return known }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let name = id + ".jsonl"
        var candidates: [URL] = []
        if let directory {
            let slug = String(directory.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            candidates.append(projects.appendingPathComponent(slug).appendingPathComponent(name))
        }
        if !candidates.contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) {
            candidates += folders.map { $0.appendingPathComponent(name) }
        }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        transcripts[id] = url
        return url
    }
}

/// What the kernel says about a PID: that it is a Claude Code binary, when it started, and its terminal.
private struct ClaudeProcess {
    let startedAt: Double
    let tty: String?

    init?(pid: Int32) {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              ClaudeCode.isExecutable(String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        startedAt = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        let device = info.kp_eproc.e_tdev
        if device != -1, let name = devname(device, S_IFCHR) { tty = "/dev/" + String(cString: name) } else { tty = nil }
    }
}

/// Types into a terminal session the way a person would, through iTerm2's own scripting. Text first,
/// then Return on its own a moment later, so Claude Code takes the line as typed rather than pasted
/// and the Return submits it. Only iTerm2 is supported: it is where Prerak runs Claude Code, and the
/// only terminal whose scripting can type without running a shell command.
@MainActor
enum TerminalTyper {
    static let iTermBundleID = "com.googlecode.iterm2"

    enum Outcome: Equatable {
        /// The ttys a matching iTerm2 session was found for and typed into.
        case typed(Set<String>)
        case iTermNotRunning
        /// macOS refused the Apple Event: MenuSprite is not allowed to control iTerm2.
        case notAllowed
        case failed(String)
    }

    static func type(_ text: String, into ttys: Set<String>) async -> Outcome {
        guard !ttys.isEmpty else { return .typed([]) }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: iTermBundleID).isEmpty else { return .iTermNotRunning }
        let first = run(script(ttys, write: "\"\(escaped(text))\""))
        guard case .typed(let reached) = first, !reached.isEmpty else { return first }
        try? await Task.sleep(for: .milliseconds(600))
        _ = run(script(reached, write: "(character id 13)"))
        return first
    }

    private static func script(_ ttys: Set<String>, write: String) -> String {
        let list = ttys.sorted().map { "\"\(escaped($0))\"" }.joined(separator: ", ")
        return """
        set targets to {\(list)}
        set reached to {}
        tell application id "\(iTermBundleID)"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        set device to tty of aSession
                        if targets contains device then
                            tell aSession to write text \(write) newline no
                            set end of reached to device
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        set AppleScript's text item delimiters to linefeed
        return reached as text
        """
    }

    private static func run(_ source: String) -> Outcome {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            if let number = error?[NSAppleScript.errorNumber] as? Int, number == -1743 || number == -1744 { return .notAllowed }
            return .failed(error?[NSAppleScript.errorMessage] as? String ?? "iTerm2 did not answer.")
        }
        return .typed(Set((result.stringValue ?? "").split(separator: "\n").map(String.init)))
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
