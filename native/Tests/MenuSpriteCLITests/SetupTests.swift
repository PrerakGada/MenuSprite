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
    #expect(try tool.run(agent: "antigravity", printOnly: false).message.contains(".gemini/antigravity/mcp_config.json"))
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
