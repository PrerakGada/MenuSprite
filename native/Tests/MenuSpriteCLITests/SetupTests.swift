import AgentProtocol
import Foundation
import Testing
@testable import MenuSpriteCLI

private let binary = "/Users/example/Applications/MenuSprite.app/Contents/Helpers/menusprite"

private func setup(home: String, environment: [String: String] = [:], runner: ProcessRunner = ProcessRunner { _, _ in
    Issue.record("ran a program"); return (1, "")
}) -> AgentSetup {
    AgentSetup(home: URL(fileURLWithPath: home, isDirectory: true), environment: environment, binaryPath: binary, processRunner: runner,
               now: { Date(timeIntervalSince1970: 1_790_000_000) })
}

@Test func cursorKeepsOtherServersAndSettingsAndBacksUp() throws {
    let home = try scratchFolder()
    let file = home + "/.cursor/mcp.json"
    try FileManager.default.createDirectory(atPath: home + "/.cursor", withIntermediateDirectories: true)
    try #"{"theme": "dark", "mcpServers": {"other": {"command": "x", "args": []}}}"#.write(toFile: file, atomically: true, encoding: .utf8)
    let outcome = try setup(home: home).run(agent: "cursor", printOnly: false)
    #expect(outcome.changed)
    let document = try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: file)))
    #expect(document.keys == ["theme", "mcpServers"])
    #expect(document["mcpServers"]?.keys == ["other", "menusprite"])
    #expect(document["mcpServers"]?["menusprite"] == .object([JSONMember("command", .string(binary)), JSONMember("args", ["mcp"])]))
    let backups = try FileManager.default.contentsOfDirectory(atPath: home + "/.cursor").filter { $0.hasPrefix("mcp.json.menusprite-backup-") }
    #expect(backups.count == 1)
    #expect(outcome.message.contains("previous file:"))
    // Running it again changes nothing.
    let again = try setup(home: home).run(agent: "cursor", printOnly: false)
    #expect(!again.changed)
    #expect(again.message.contains("already has MenuSprite registered"))
}

@Test func claudeDesktopGetsAFileWhenThereIsNone() throws {
    let home = try scratchFolder()
    let outcome = try setup(home: home).run(agent: "claude-desktop", printOnly: false)
    let file = home + "/Library/Application Support/Claude/claude_desktop_config.json"
    #expect(outcome.file == file)
    #expect(try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: file)))["mcpServers"]?["menusprite"]?["args"] == ["mcp"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: home + "/Library/Application Support/Claude") == ["claude_desktop_config.json"])
    #expect(outcome.message.contains("Quit and reopen Claude Desktop"))
}

@Test func aConfigThatDoesNotParseIsLeftAlone() throws {
    let home = try scratchFolder()
    let file = home + "/.cursor/mcp.json"
    try FileManager.default.createDirectory(atPath: home + "/.cursor", withIntermediateDirectories: true)
    try "{ \"mcpServers\": { // comment\n } }".write(toFile: file, atomically: true, encoding: .utf8)
    #expect(throws: CommandError.self) { try setup(home: home).run(agent: "cursor", printOnly: false) }
    #expect(try String(contentsOfFile: file, encoding: .utf8) == "{ \"mcpServers\": { // comment\n } }")
    #expect(try FileManager.default.contentsOfDirectory(atPath: home + "/.cursor") == ["mcp.json"])
}

@Test func codexGetsOneBlockAppended() throws {
    let home = try scratchFolder()
    let codexHome = home + "/codex-home"
    try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
    try "model = \"gpt-5\"\n[mcp_servers.other]\ncommand = \"x\"".write(toFile: codexHome + "/config.toml", atomically: true, encoding: .utf8)
    let first = try setup(home: home, environment: ["CODEX_HOME": codexHome]).run(agent: "codex", printOnly: false)
    #expect(first.changed)
    #expect(try String(contentsOfFile: codexHome + "/config.toml", encoding: .utf8) == """
        model = "gpt-5"
        [mcp_servers.other]
        command = "x"

        [mcp_servers.menusprite]
        command = "\(binary)"
        args = ["mcp"]

        """)
    let second = try setup(home: home, environment: ["CODEX_HOME": codexHome]).run(agent: "codex", printOnly: false)
    #expect(!second.changed)
    #expect(!FileManager.default.fileExists(atPath: home + "/.codex"))
    #expect(AgentSetup.hasCodexServer("  [ mcp_servers.\"menusprite\" ]\n"))
    #expect(!AgentSetup.hasCodexServer("[mcp_servers.menusprite-old]"))
    #expect(AgentSetup.hasCodexServer("[mcp_servers]\nmenusprite = { command = \"x\" }\n"))
    #expect(AgentSetup.hasCodexServer("mcp_servers.menusprite.command = \"x\"\n"))
    #expect(AgentSetup.hasCodexServer("[mcp_servers.menusprite.env]\nA = \"1\"\n"))
    #expect(!AgentSetup.hasCodexServer("[profiles]\nmenusprite = 1\n"))
    // A comment after a header or a key is not part of it.
    #expect(AgentSetup.hasCodexServer("[mcp_servers.menusprite] # added by hand\ncommand = \"/old\"\n"))
    #expect(AgentSetup.hasCodexServer("[mcp_servers] # servers\nmenusprite = { command = \"x\" } # mine\n"))
    #expect(AgentSetup.hasCodexServer("mcp_servers.menusprite.command = \"x\" # c\n"))
    #expect(!AgentSetup.hasCodexServer("# [mcp_servers.menusprite]\n[other]\n"))
    #expect(!AgentSetup.hasCodexServer("[mcp_servers]\nother = \"#menusprite\"\n"))
    #expect(AgentSetup.hasCodexServer("[[profiles]] # list\n[mcp_servers.\"menusprite\"]#x\n"))
    #expect(AgentSetup.tomlString("C:\\a \"b\"") == #""C:\\a \"b\"""#)
}

@Test func claudeRunsMcpAddAndReplacesItsOwnEntry() throws {
    let home = try scratchFolder()
    let bin = home + "/bin"
    try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: bin + "/claude", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    let calls = Capture()
    let runner = ProcessRunner { executable, arguments in
        calls.console.write(([executable] + arguments).joined(separator: " ") + "\n")
        let adds = calls.out.components(separatedBy: " mcp add ").count - 1
        return arguments[1] == "add" && adds == 1 ? (1, "MCP server menusprite already exists in user config") : (0, "ok")
    }
    let outcome = try setup(home: home, environment: ["PATH": bin], runner: runner).run(agent: "claude-code", printOnly: false)
    #expect(calls.out == """
        \(bin)/claude mcp add --scope user menusprite -- \(binary) mcp
        \(bin)/claude mcp remove --scope user menusprite
        \(bin)/claude mcp add --scope user menusprite -- \(binary) mcp

        """)
    #expect(outcome.message.hasPrefix("Replaced MenuSprite in Claude Code (user scope)"))
}

@Test func printOnlyNeverWritesOrRuns() throws {
    let home = try scratchFolder()
    let tool = setup(home: home)
    for agent in AgentSetup.Agent.allCases {
        let outcome = try tool.run(agent: agent.rawValue, printOnly: true)
        #expect(!outcome.changed)
        #expect(outcome.message.contains(binary))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: home).isEmpty)
    #expect(try tool.run(agent: "claude", printOnly: true).message == "Register MenuSprite with Claude Code:\n  claude mcp add --scope user menusprite -- \(binary) mcp\n")
    #expect(throws: CommandError.self) { try tool.run(agent: "chatgpt", printOnly: true) }
    #expect(AgentSetup.shellQuoted("/Users/a b/menusprite") == "'/Users/a b/menusprite'")
}

@Test func theRegisteredPathIsTheInstalledApps() throws {
    let home = try scratchFolder()
    let loose = URL(fileURLWithPath: "/tmp/build/MenuSpriteCLI")
    let fallback = AgentSetup.stableBinary(home: URL(fileURLWithPath: home), executable: loose)
    #expect(fallback.path == loose.path)
    #expect(fallback.note != nil)
    let helpers = home + "/Applications/MenuSprite.app/Contents/Helpers"
    try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: helpers + "/menusprite", contents: Data(), attributes: [.posixPermissions: 0o755])
    let installed = AgentSetup.stableBinary(home: URL(fileURLWithPath: home), executable: loose)
    #expect(installed.path == helpers + "/menusprite")
    #expect(installed.note == nil)
    let inside = URL(fileURLWithPath: "/Applications/MenuSprite.app/Contents/Helpers/menusprite")
    #expect(AgentSetup.stableBinary(home: URL(fileURLWithPath: home), executable: inside).path == inside.path)
    // A staging bundle in a build folder is not where the app lives: the installed copy wins.
    let staging = URL(fileURLWithPath: "/Users/example/Developer/MenuSprite/native/.build/MenuSprite.app/Contents/Helpers/menusprite")
    #expect(AgentSetup.stableBinary(home: URL(fileURLWithPath: home), executable: staging).path == helpers + "/menusprite")
}

@Test func setupThroughTheCommandUsesHOME() throws {
    let home = try scratchFolder()
    let capture = Capture()
    let tool = CLI(environment: ["HOME": home, "MENUSPRITE_SOCKET": FakeApp.socketPath()], console: capture.console)
    #expect(tool.run(["setup", "cursor", "--print", "--json"]) == 0)
    let answer = try JSONValue.parse(capture.out)
    #expect(answer["agent"]?.string == "cursor")
    #expect(answer["file"]?.string == home + "/.cursor/mcp.json")
    #expect(answer["changed"] == false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: home).isEmpty)
    #expect(tool.run(["setup"]) == 0)
    #expect(capture.out.contains("menusprite setup claude-desktop"))
}

@Test func eachAgentGetsItsOwnFileInItsOwnShape() throws {
    let home = try scratchFolder()
    let tool = setup(home: home)
    func json(_ path: String) throws -> JSONValue { try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: home + path))) }
    let plain = JSONValue.object([JSONMember("command", .string(binary)), JSONMember("args", ["mcp"])])

    // Copilot: the shape `copilot mcp add` writes, a local server allowed every tool.
    #expect(try tool.run(agent: "copilot", printOnly: false).changed)
    #expect(try json("/.copilot/mcp-config.json")["mcpServers"]?["menusprite"] == .object([
        JSONMember("type", "local"), JSONMember("command", .string(binary)), JSONMember("args", ["mcp"]), JSONMember("tools", ["*"])]))

    // Gemini CLI keeps everything else in settings.json.
    try FileManager.default.createDirectory(atPath: home + "/.gemini/config", withIntermediateDirectories: true)
    try #"{"theme": "Dracula", "security": {"auth": {"selectedType": "oauth-personal"}}}"#.write(toFile: home + "/.gemini/settings.json", atomically: true, encoding: .utf8)
    #expect(try tool.run(agent: "gemini", printOnly: false).changed)
    #expect(try json("/.gemini/settings.json").keys == ["theme", "security", "mcpServers"])
    #expect(try json("/.gemini/settings.json")["mcpServers"]?["menusprite"] == plain)

    // Antigravity (app and agy) reads ~/.gemini/config/mcp_config.json, which starts as an empty file.
    try Data().write(to: URL(fileURLWithPath: home + "/.gemini/config/mcp_config.json"))
    let antigravity = try tool.run(agent: "agy", printOnly: false)
    #expect(antigravity.changed && antigravity.file == home + "/.gemini/config/mcp_config.json")
    #expect(try json("/.gemini/config/mcp_config.json")["mcpServers"]?["menusprite"] == plain)

    // Kimi Code: KIMI_CODE_HOME, else ~/.kimi-code.
    #expect(try tool.run(agent: "kimi", printOnly: false).file == home + "/.kimi-code/mcp.json")
    let elsewhere = try scratchFolder()
    #expect(try setup(home: home, environment: ["KIMI_CODE_HOME": elsewhere]).run(agent: "kimi-code", printOnly: false).file == elsewhere + "/mcp.json")

    // Grok: the table `grok mcp add --scope user` writes, appended once.
    try FileManager.default.createDirectory(atPath: home + "/.grok", withIntermediateDirectories: true)
    try "[ui]\nscreen_mode = \"minimal\"\n".write(toFile: home + "/.grok/config.toml", atomically: true, encoding: .utf8)
    #expect(try tool.run(agent: "grok", printOnly: false).changed)
    let grok = try String(contentsOfFile: home + "/.grok/config.toml", encoding: .utf8)
    #expect(grok == "[ui]\nscreen_mode = \"minimal\"\n\n[mcp_servers.menusprite]\ncommand = \"\(binary)\"\nargs = [\"mcp\"]\nenabled = true\n")
    #expect(try !tool.run(agent: "grok", printOnly: false).changed)
}

@Test func setupAllSkipsWhatIsNotInstalledAndKeepsGoing() throws {
    let home = try scratchFolder()
    // Only Kimi's folder exists, and Cursor's config does not parse.
    try FileManager.default.createDirectory(atPath: home + "/.kimi-code", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: home + "/.cursor", withIntermediateDirectories: true)
    try "{ not json".write(toFile: home + "/.cursor/mcp.json", atomically: true, encoding: .utf8)
    let tool = setup(home: home, environment: ["PATH": ""], runner: ProcessRunner { _, _ in (0, "") })
    let outcomes = tool.runAll(printOnly: false)
    #expect(outcomes.map(\.agent) == AgentSetup.Agent.allCases.map(\.rawValue))
    #expect(outcomes.first { $0.agent == "kimi" }?.changed == true)
    #expect(outcomes.first { $0.agent == "cursor" }?.message.contains("not valid JSON") == true)
    // Whatever this Mac lacks (agents' commands are also looked for in the usual folders) is skipped, never written.
    for outcome in outcomes where !tool.installed(AgentSetup.Agent(rawValue: outcome.agent)!) {
        #expect(outcome.message.contains("not installed") && !outcome.changed)
    }
}
