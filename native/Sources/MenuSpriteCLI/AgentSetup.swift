import AgentProtocol
import Foundation

/// `menusprite setup <agent>`: registers `menusprite mcp` with an agent, by the path that stays put (the
/// command inside the installed app), so a rebuild or a moved checkout does not break the agent. Config
/// files are merged, never replaced: other servers and settings stay as they were, a file that does not
/// parse is left alone, and the previous file is copied aside first.
struct AgentSetup: Sendable {
    enum Agent: String, CaseIterable, Sendable {
        case claude, codex, cursor, claudeDesktop = "claude-desktop", antigravity

        init?(name: String) {
            switch name.lowercased() {
            case "claude", "claude-code", "claudecode": self = .claude
            case "codex": self = .codex
            case "cursor": self = .cursor
            case "claude-desktop", "desktop", "claudedesktop": self = .claudeDesktop
            case "antigravity", "anti-gravity": self = .antigravity
            default: return nil
            }
        }
    }

    struct Outcome: Equatable, Sendable {
        var agent: String
        var changed: Bool
        var file: String?
        var message: String
    }

    var home: URL
    var environment: [String: String]
    var binaryPath: String
    var processRunner: ProcessRunner
    var now: @Sendable () -> Date = { Date() }

    static let overview = """
        Register MenuSprite's MCP server with an agent:
          menusprite setup claude          Claude Code (runs claude mcp add, user scope)
          menusprite setup codex           Codex (~/.codex/config.toml)
          menusprite setup cursor          Cursor (~/.cursor/mcp.json)
          menusprite setup claude-desktop  Claude Desktop (claude_desktop_config.json)
          menusprite setup antigravity     Antigravity (prints what to paste)
        Add --print to see the change without making it.
        ChatGPT's desktop app takes only remote connectors; there, use the menusprite command itself.

        """

    /// The command inside the installed app: this one when it runs from an app in an Applications folder, else
    /// ~/Applications' or /Applications' copy, else this binary's resolved path (with a note, since a build
    /// folder or a staging bundle moves or is cleaned).
    static func stableBinary(home: URL, executable: URL?, fileManager: FileManager = .default) -> (path: String, note: String?) {
        if let executable, executable.path.contains(".app/Contents/Helpers/"), executable.path.contains("/Applications/") { return (executable.path, nil) }
        let installed = [home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")]
            .map { $0.appendingPathComponent("MenuSprite.app/Contents/Helpers/menusprite").path }
        if let path = installed.first(where: fileManager.isExecutableFile(atPath:)) { return (path, nil) }
        let path = executable?.path ?? "menusprite"
        return (path, "MenuSprite.app with its menusprite command is not installed, so this registers \(path), which stops working if that build is moved or cleaned.")
    }

    func run(agent name: String, printOnly: Bool) throws -> Outcome {
        guard let agent = Agent(name: name) else {
            throw CommandError("Unknown agent “\(name)”: use claude, codex, cursor, claude-desktop or antigravity.")
        }
        switch agent {
        case .claude: return try claude(printOnly: printOnly)
        case .codex: return try codex(printOnly: printOnly)
        case .cursor:
            return try mergeJSON(agent: agent, file: home.appendingPathComponent(".cursor/mcp.json"), label: "Cursor",
                                 after: "Cursor loads it from Settings → MCP; reload there if it does not appear.", printOnly: printOnly)
        case .claudeDesktop:
            return try mergeJSON(agent: agent, file: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
                                 label: "Claude Desktop", after: "Quit and reopen Claude Desktop to load it.", printOnly: printOnly)
        case .antigravity:
            let file = home.appendingPathComponent(".gemini/antigravity/mcp_config.json").path
            return Outcome(agent: agent.rawValue, changed: false, file: file, message: """
                In Antigravity, open the agent panel's … menu → MCP Servers → Manage MCP Servers → View raw config \
                (\(file)) and merge this into it, then refresh the server list:

                \(snippet)

                """)
        }
    }

    var entry: JSONValue { .object([JSONMember("command", .string(binaryPath)), JSONMember("args", ["mcp"])]) }

    var snippet: String {
        JSONValue.object([JSONMember("mcpServers", .object([JSONMember("menusprite", entry)]))]).serialized(pretty: true)
    }

    private func claude(printOnly: Bool) throws -> Outcome {
        let arguments = ["mcp", "add", "--scope", "user", "menusprite", "--", binaryPath, "mcp"]
        let printed = (["claude"] + arguments).map(Self.shellQuoted).joined(separator: " ")
        if printOnly { return Outcome(agent: "claude", changed: false, file: nil, message: "Register MenuSprite with Claude Code:\n  \(printed)\n") }
        guard let claude = find("claude") else {
            return Outcome(agent: "claude", changed: false, file: nil, message: "Claude Code's claude command is not on PATH. Once it is, run:\n  \(printed)\n")
        }
        var (status, output) = processRunner.run(claude, arguments)
        var replaced = false
        if status != 0, output.contains("already exists") {
            // Ours by name: replace it so a moved binary is picked up.
            _ = processRunner.run(claude, ["mcp", "remove", "--scope", "user", "menusprite"])
            (status, output) = processRunner.run(claude, arguments)
            replaced = true
        }
        guard status == 0 else {
            throw CommandError("claude mcp add failed (exit \(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))\nThe command was: \(printed)")
        }
        return Outcome(agent: "claude", changed: true, file: nil, message: """
            \(replaced ? "Replaced" : "Registered") MenuSprite in Claude Code (user scope): \(binaryPath) mcp
            Start a new Claude Code session and ask it to build a sprite.

            """)
    }

    private func codex(printOnly: Bool) throws -> Outcome {
        let folder = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".codex")
        let file = folder.appendingPathComponent("config.toml").resolvingSymlinksInPath()
        let block = "[mcp_servers.menusprite]\ncommand = \(Self.tomlString(binaryPath))\nargs = [\"mcp\"]\n"
        if printOnly { return Outcome(agent: "codex", changed: false, file: file.path, message: "Add this to \(file.path):\n\n\(block)") }
        let existing = FileManager.default.contents(atPath: file.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if Self.hasCodexServer(existing) {
            return Outcome(agent: "codex", changed: false, file: file.path,
                           message: "\(file.path) already has [mcp_servers.menusprite]; it was left as it is. It should read:\n\n\(block)")
        }
        let backup = try backUp(file)
        var updated = existing
        if !updated.isEmpty { updated += updated.hasSuffix("\n") ? "\n" : "\n\n" }
        updated += block
        try write(updated, to: file)
        return Outcome(agent: "codex", changed: true, file: file.path,
                       message: "Added [mcp_servers.menusprite] to \(file.path)\(backup.map { " (previous file: \($0))" } ?? ""). Start a new Codex session to use it.\n")
    }

    private func mergeJSON(agent: Agent, file: URL, label: String, after: String, printOnly: Bool) throws -> Outcome {
        let file = file.resolvingSymlinksInPath()
        if printOnly {
            return Outcome(agent: agent.rawValue, changed: false, file: file.path,
                           message: "Merge this into \(file.path) (keep any other servers under \"mcpServers\"):\n\n\(snippet)\n")
        }
        var document = JSONValue.object([])
        if let data = FileManager.default.contents(atPath: file.path),
           !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { document = try JSONValue.parse(data) }
            catch { throw CommandError("\(file.path) is not valid JSON (\(error)); it was left alone. Fix it, or add this by hand:\n\n\(snippet)") }
            guard case .object = document else { throw CommandError("\(file.path) is not a JSON object; it was left alone. Add this by hand:\n\n\(snippet)") }
        }
        var servers = document["mcpServers"] ?? .object([])
        guard case .object = servers else { throw CommandError("\"mcpServers\" in \(file.path) is not an object; it was left alone.") }
        if servers["menusprite"] == entry {
            return Outcome(agent: agent.rawValue, changed: false, file: file.path, message: "\(label) already has MenuSprite registered in \(file.path).\n")
        }
        let replacing = servers["menusprite"] != nil
        servers.set("menusprite", entry)
        document.set("mcpServers", servers)
        let backup = try backUp(file)
        try write(document.serialized(pretty: true) + "\n", to: file)
        return Outcome(agent: agent.rawValue, changed: true, file: file.path, message: """
            \(replacing ? "Updated" : "Added") MenuSprite in \(file.path)\(backup.map { " (previous file: \($0))" } ?? ""). \(after)

            """)
    }

    // MARK: - Helpers

    /// Copies an existing file aside with a timestamp before it is changed; nil when there was nothing to keep.
    private func backUp(_ file: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = file.path + ".menusprite-backup-" + formatter.string(from: now())
        do { try FileManager.default.copyItem(atPath: file.path, toPath: backup) }
        catch { throw CommandError("Could not back up \(file.path) before changing it: \(error.localizedDescription)") }
        return backup
    }

    private func write(_ text: String, to file: URL) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch { throw CommandError("Could not write \(file.path): \(error.localizedDescription)") }
    }

    /// An executable on PATH, or where the agents' installers usually put it.
    func find(_ name: String) -> String? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let usual = [home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".claude/local").path, "/opt/homebrew/bin", "/usr/local/bin"]
        return (path + usual).map { ($0 as NSString).appendingPathComponent(name) }.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// Whether the config already names a `menusprite` server in any of TOML's three spellings: its own table,
    /// a key inside `[mcp_servers]`, or a dotted key. Appending a second one would make the file fail to parse.
    /// Spaces and quotes are ignored, and so is a comment after a header or a key.
    static func hasCodexServer(_ toml: String) -> Bool {
        var table = ""
        for line in toml.split(whereSeparator: \.isNewline) {
            let compact = tomlCompact(String(line))
            if compact.hasPrefix("[") {
                // The header is everything up to its closing bracket; what follows can only be a comment.
                let close = compact.hasPrefix("[[") ? compact.range(of: "]]")?.upperBound : compact.firstIndex(of: "]").map(compact.index(after:))
                table = close.map { String(compact[..<$0]) } ?? compact
                if table == "[mcp_servers.menusprite]" || table.hasPrefix("[mcp_servers.menusprite.") { return true }
            } else if table == "[mcp_servers]", compact.hasPrefix("menusprite=") || compact.hasPrefix("menusprite.") {
                return true
            } else if table.isEmpty, compact.hasPrefix("mcp_servers.menusprite=") || compact.hasPrefix("mcp_servers.menusprite.") {
                return true
            }
        }
        return false
    }

    /// A TOML line without its comment (a `#` outside quotes), spaces or quotes.
    static func tomlCompact(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" && open == "\"" { escaped = true } else if character == open { quote = nil; continue }
                if quote != nil, character != " " { result.append(character) }
                continue
            }
            switch character {
            case "#": return result
            case "\"", "'": quote = character
            case " ", "\t": break
            default: result.append(character)
            }
        }
        return result
    }

    static func tomlString(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\t": quoted += "\\t"
            default: if scalar.value < 0x20 { quoted += String(format: "\\u%04X", scalar.value) } else { quoted.unicodeScalars.append(scalar) }
            }
        }
        return quoted + "\""
    }

    static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:=@+,")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
