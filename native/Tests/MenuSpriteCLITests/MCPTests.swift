import AgentProtocol
import Foundation
import Testing
@testable import MenuSpriteCLI

private func server(_ app: FakeApp?, folder: String) -> MCPServer {
    var client = AppClient(environment: ["MENUSPRITE_SOCKET": app?.path ?? FakeApp.socketPath()])
    client.startupLimit = 0.2
    return MCPServer(tools: MCPTools(client: client, temporaryDirectory: URL(fileURLWithPath: folder, isDirectory: true)), version: "9.9 (99)")
}

private func request(_ id: Int, _ method: String, _ params: JSONValue? = nil) -> JSONValue {
    .object(pairs: [("jsonrpc", "2.0"), ("id", .number(Double(id))), ("method", .string(method)), ("params", params)])
}

private func call(_ id: Int, _ tool: String, _ arguments: JSONValue) -> JSONValue {
    request(id, "tools/call", .object([JSONMember("name", .string(tool)), JSONMember("arguments", arguments)]))
}

@Test func initializeNegotiatesTheProtocolVersion() throws {
    let mcp = server(nil, folder: try scratchFolder())
    for version in MCPServer.supportedVersions {
        let answer = mcp.handle(request(1, "initialize", .object([JSONMember("protocolVersion", .string(version))])))
        #expect(answer?["result"]?["protocolVersion"]?.string == version)
    }
    let unknown = try #require(mcp.handle(request(2, "initialize", .object([JSONMember("protocolVersion", "2099-01-01")]))))
    #expect(unknown["result"]?["protocolVersion"]?.string == "2025-06-18")
    #expect(mcp.handle(request(3, "initialize"))?["result"]?["protocolVersion"]?.string == "2025-06-18")
    let result = try #require(unknown["result"])
    #expect(unknown["jsonrpc"]?.string == "2.0")
    #expect(unknown["id"] == 2)
    #expect(result["serverInfo"]?["name"]?.string == "menusprite")
    #expect(result["serverInfo"]?["version"]?.string == "9.9 (99)")
    #expect(result["capabilities"]?["tools"] != nil)
    #expect(result["capabilities"]?["resources"] != nil)
    #expect(result["instructions"]?.string?.contains("get_guide") == true)
}

@Test func toolsListOffersEveryToolWithAnObjectSchema() throws {
    let answer = try #require(server(nil, folder: try scratchFolder()).handle(request(1, "tools/list")))
    let tools = try #require(answer["result"]?["tools"]?.items)
    #expect(tools.compactMap { $0["name"]?.string } == ["get_guide", "list_examples", "get_example", "list_readings", "list_sprites", "get_sprite",
                                                        "validate_sprite", "apply_sprite", "preview_sprite", "test_command", "refresh_sprite",
                                                        "set_sprite", "remove_sprite", "open_board"])
    for tool in tools {
        #expect(tool["inputSchema"]?["type"]?.string == "object", "\(tool["name"]?.string ?? "")")
        #expect(tool["inputSchema"]?["properties"]?.members != nil)
        #expect((tool["description"]?.string?.count ?? 0) > 40)
    }
    let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0["name"]!.string!, $0) })
    #expect(byName["apply_sprite"]?["inputSchema"]?["required"] == ["spec"])
    #expect(byName["test_command"]?["inputSchema"]?["required"] == ["command"])
    #expect(byName["set_sprite"]?["inputSchema"]?["properties"]?.keys == ["sprite", "enabled", "menu_bar", "side"])
    #expect(byName["preview_sprite"]?["inputSchema"]?["properties"]?.keys == ["sprite", "spec", "appearance", "board", "values"])
    #expect(byName["apply_sprite"]?["inputSchema"]?["properties"]?.keys == ["spec", "preview", "dry_run", "appearance", "values"])
    #expect(byName["test_command"]?["inputSchema"]?["properties"]?["files"]?["type"] == "object")
    #expect(byName["remove_sprite"]?["annotations"]?["destructiveHint"] == true)
    #expect(byName["list_sprites"]?["annotations"]?["readOnlyHint"] == true)
    // Drawing a draft runs its commands, so no tool that runs the user's commands claims to be read-only or closed.
    for name in ["preview_sprite", "apply_sprite", "test_command", "refresh_sprite"] {
        #expect(byName[name]?["annotations"]?["readOnlyHint"] == false, "\(name)")
        #expect(byName[name]?["annotations"]?["openWorldHint"] == true, "\(name)")
    }
    #expect(byName["preview_sprite"]?["annotations"]?["idempotentHint"] == false)
    #expect(byName["validate_sprite"]?["annotations"]?["openWorldHint"] == false)
}

@Test func pingNotificationsAndUnknownMethods() throws {
    let mcp = server(nil, folder: try scratchFolder())
    #expect(mcp.handle(request(7, "ping")) == .object([JSONMember("jsonrpc", "2.0"), JSONMember("id", 7), JSONMember("result", .object([]))]))
    #expect(mcp.handle(.object([JSONMember("jsonrpc", "2.0"), JSONMember("method", "notifications/initialized")])) == nil)
    #expect(mcp.handle(request(8, "sampling/whatever"))?["error"]?["code"] == -32601)
    #expect(mcp.handle(request(9, "prompts/list"))?["result"]?["prompts"] == [])
    #expect(mcp.handle(call(10, "no_such_tool", .object([])))?["error"]?["code"] == -32602)
    // A response to a request this server never sent is ignored; something that is not a message is refused.
    #expect(mcp.handle(.object([JSONMember("jsonrpc", "2.0"), JSONMember("id", 3), JSONMember("result", .object([]))])) == nil)
    #expect(mcp.handle(.string("hello"))?["error"]?["code"] == -32600)
    // Ids may be strings.
    #expect(mcp.handle(.object([JSONMember("jsonrpc", "2.0"), JSONMember("id", "abc"), JSONMember("method", "ping")]))?["id"] == "abc")
}

@Test func resourcesServeTheGuideAndSchema() throws {
    let mcp = server(nil, folder: try scratchFolder())
    let list = try #require(mcp.handle(request(1, "resources/list"))?["result"]?["resources"]?.items)
    #expect(list.compactMap { $0["uri"]?.string } == ["menusprite://guide", "menusprite://schema"] + AgentExamples.all.map { "menusprite://examples/\($0.name)" })
    let guide = mcp.handle(request(2, "resources/read", .object([JSONMember("uri", "menusprite://guide")])))
    #expect(guide?["result"]?["contents"]?[0]?["text"]?.string == AgentGuide.markdown)
    #expect(guide?["result"]?["contents"]?[0]?["mimeType"]?.string == "text/markdown")
    let schema = mcp.handle(request(3, "resources/read", .object([JSONMember("uri", "menusprite://schema")])))
    #expect(try JSONValue.parse(schema?["result"]?["contents"]?[0]?["text"]?.string ?? "") == (try JSONValue.parse(SpecSchema.json)))
    #expect(mcp.handle(request(4, "resources/read", .object([JSONMember("uri", "menusprite://nope")])))?["error"]?["code"] == -32002)
}

@Test func serveWritesOneLinePerMessage() throws {
    let mcp = server(nil, folder: try scratchFolder())
    var lines = [request(1, "initialize").serialized(), "", "{oops", request(2, "ping").serialized(),
                 #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                 JSONValue.array([request(3, "ping"), request(4, "ping")]).serialized(),
                 call(5, "get_guide", .object([])).serialized()]
    let output = Capture()
    mcp.serve(readLine: { lines.isEmpty ? nil : lines.removeFirst() }, write: { output.console.write($0 + "\n") })
    let written = output.out.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    #expect(written.count == 5)
    let messages = try written.map { try JSONValue.parse($0) }
    #expect(messages[0]["id"] == 1)
    #expect(messages[1]["id"] == .null)
    #expect(messages[1]["error"]?["code"] == -32700)
    #expect(messages[2]["id"] == 2)
    #expect(messages[3].items?.compactMap { $0["id"] } == [3, 4])
    #expect(messages[4]["result"]?["content"]?[0]?["text"]?.string == AgentGuide.markdown.trimmingCharacters(in: .newlines))
    #expect(messages[4]["result"]?["isError"] == false)
}

@Test func applySpriteReturnsTextAndPreviewImages() throws {
    let app = try FakeApp { request in
        request["op"]?.string == "render" ? fakeRender(request)
            : FakeApp.ok(encoding: ApplyResult(created: true, saved: true, sprite: sampleSprite, diagnostics: [], spec: .null))
    }
    defer { app.stop() }
    let folder = try scratchFolder()
    let answer = try #require(server(app, folder: folder).handle(call(1, "apply_sprite", .object([JSONMember("spec", try JSONValue.parse(sampleSpecText))]))))
    let result = try #require(answer["result"])
    #expect(result["isError"] == false)
    let content = try #require(result["content"]?.items)
    #expect(content.count == 3)
    let text = content[0]["text"]?.string ?? ""
    #expect(content[0]["type"]?.string == "text")
    #expect(text.hasPrefix("Created “GitHub PRs”"))
    #expect(text.contains("Commands it runs:\n  gh pr list --json number --jq length"))
    #expect(text.contains("repo  no value  — gh: not logged in"))
    #expect(content[1]["type"]?.string == "image")
    #expect(content[1]["mimeType"]?.string == "image/png")
    let face = try #require(Data(base64Encoded: content[1]["data"]?.string ?? ""))
    #expect(face == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array("face".utf8)))
    // The saved sprite is drawn, in both appearances, into a fresh folder under the temporary directory.
    let render = try #require(app.requests("render").first?["args"])
    #expect(render["sprite"]?.string == sampleSprite.id)
    #expect(render["appearance"]?.string == "both")
    #expect(render["values"] == nil)
    #expect(render["directory"]?.string?.hasPrefix(folder + "/menusprite-preview-") == true)
    #expect(app.requests("apply").first?["args"]?["spec"]?.keys.first == "menusprite")
}

@Test func applySpriteFailuresAreToolErrorsWithDiagnostics() throws {
    let app = try FakeApp { _ in
        FakeApp.failure(AgentFailure(.invalidSpec, "The spec has 1 error.", diagnostics: [.error("values[0].reading", "Unknown reading “cpu”", hint: "did you mean cpu.usage?")]))
    }
    defer { app.stop() }
    let mcp = server(app, folder: try scratchFolder())
    let result = mcp.handle(call(1, "apply_sprite", .object([JSONMember("spec", try JSONValue.parse(sampleSpecText)), JSONMember("preview", false)])))?["result"]
    #expect(result?["isError"] == true)
    #expect(result?["content"]?[0]?["text"]?.string == "The spec has 1 error.\nErrors:\n  values[0].reading: Unknown reading “cpu” — did you mean cpu.usage?")
    #expect(app.requests("render").isEmpty)
}

@Test func aSpecMayArriveAsTextAndBrokenTextSaysWhere() throws {
    let app = try FakeApp { request in
        FakeApp.ok(encoding: ValidateResult(valid: true, diagnostics: [], spec: request["args"]?["spec"]))
    }
    defer { app.stop() }
    let mcp = server(app, folder: try scratchFolder())
    let good = mcp.handle(call(1, "validate_sprite", .object([JSONMember("spec", .string(sampleSpecText))])))?["result"]
    #expect(good?["isError"] == false)
    #expect(good?["content"]?[0]?["text"]?.string == "Valid.")
    #expect(app.requests.first?["args"]?["spec"] == (try JSONValue.parse(sampleSpecText)))
    let broken = mcp.handle(call(2, "validate_sprite", .object([JSONMember("spec", .string("{\"menusprite\": 1,\n\"name\": 'x'}"))])))?["result"]
    #expect(broken?["isError"] == true)
    #expect(broken?["content"]?[0]?["text"]?.string?.contains("line 2, column 9") == true)
    let missing = mcp.handle(call(3, "validate_sprite", .object([])))?["result"]
    #expect(missing?["content"]?[0]?["text"]?.string?.contains("“spec” is required") == true)
    #expect(app.requests.count == 1)
}

@Test func toolArgumentsAreReadLeniently() throws {
    let app = try FakeApp { request in
        if request["op"]?.string == "run" {
            return FakeApp.ok(encoding: RunResult(text: "5", number: 5, output: "5\n", error: "", status: 0, problem: nil, elapsed: 0.1))
        }
        return FakeApp.ok(encoding: SpriteResult(sprite: sampleSprite))
    }
    defer { app.stop() }
    let mcp = server(app, folder: try scratchFolder())
    let run = mcp.handle(call(1, "test_command", .object([JSONMember("command", "echo 5"), JSONMember("timeout", "30"), JSONMember("parse", "number")])))?["result"]
    #expect(run?["isError"] == false)
    #expect(run?["content"]?[0]?["text"]?.string?.hasPrefix("value   5\nnumber  5\n") == true)
    #expect(app.requests("run").first?["args"]?["timeout"] == 30)
    let set = mcp.handle(call(2, "set_sprite", .object([JSONMember("sprite", "PRs"), JSONMember("menu_bar", "false"), JSONMember("side", "Left")])))?["result"]
    #expect(set?["isError"] == false)
    #expect(canonical(app.requests("set").first?["args"]) == .object([JSONMember("menuBar", false), JSONMember("side", "left"), JSONMember("sprite", "PRs")]))
    let nothing = mcp.handle(call(3, "set_sprite", .object([JSONMember("sprite", "PRs")])))?["result"]
    #expect(nothing?["isError"] == true)
    let wrong = mcp.handle(call(4, "set_sprite", .object([JSONMember("sprite", "PRs"), JSONMember("side", "up")])))?["result"]
    #expect(wrong?["content"]?[0]?["text"]?.string == "side is left or right.")
    let both = mcp.handle(call(5, "preview_sprite", .object([JSONMember("sprite", "PRs"), JSONMember("spec", .object([]))])))?["result"]
    #expect(both?["content"]?[0]?["text"]?.string?.contains("not both or neither") == true)
    #expect(app.requests.count == 2)
}

@Test func anUnavailableAppIsAToolErrorNotACrash() throws {
    let mcp = server(nil, folder: try scratchFolder())
    let result = mcp.handle(call(1, "list_sprites", .object([])))?["result"]
    #expect(result?["isError"] == true)
    #expect(result?["content"]?[0]?["text"]?.string?.contains("Nothing is answering") == true)
}

@Test func callsInFlightAreAnsweredAtTheEndOfInputAndCancelledOnesAreNot() throws {
    let app = try FakeApp { request in
        Thread.sleep(forTimeInterval: 0.4)
        return FakeApp.ok(encoding: ListResult(sprites: [sampleSprite]))
    }
    defer { app.stop() }
    let mcp = server(app, folder: try scratchFolder())
    var lines = [call(1, "list_sprites", .object([])).serialized(), call(2, "list_sprites", .object([])).serialized(),
                 #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2,"reason":"user"}}"#,
                 request(3, "ping").serialized()]
    let output = Capture()
    mcp.serve(readLine: { lines.isEmpty ? nil : lines.removeFirst() }, write: { output.console.write($0 + "\n") })
    let messages = try output.out.split(separator: "\n").map { try JSONValue.parse(String($0)) }
    // The ping is not held up behind the slow calls, the first call is answered, the cancelled one is not.
    #expect(messages.compactMap { $0["id"] } == [3, 1])
    #expect(messages[1]["result"]?["content"]?[0]?["text"]?.string?.contains("GitHub PRs") == true)
}

@Test func standInValuesAndAppearanceReachTheRender() throws {
    let app = try FakeApp { request in
        request["op"]?.string == "render" ? fakeRender(request)
            : FakeApp.ok(encoding: ApplyResult(created: true, saved: false, sprite: sampleSprite, diagnostics: [], spec: .null))
    }
    defer { app.stop() }
    let mcp = server(app, folder: try scratchFolder())
    let values = JSONValue.object([JSONMember("prs", 12), JSONMember("state", "Running"), JSONMember("session.pace", "over")])
    let applied = mcp.handle(call(1, "apply_sprite", .object([JSONMember("spec", try JSONValue.parse(sampleSpecText)), JSONMember("dry_run", true),
                                                              JSONMember("appearance", "light"), JSONMember("values", values)])))?["result"]
    #expect(applied?["isError"] == false)
    let render = try #require(app.requests("render").first?["args"])
    #expect(render["appearance"]?.string == "light")
    #expect(render["values"] == values)
    #expect(render["values"]?.keys == ["prs", "state", "session.pace"])
    #expect(render["spec"]?.keys.first == "menusprite")
    // Values may arrive as JSON text too; a list is refused before anything is drawn.
    _ = mcp.handle(call(2, "preview_sprite", .object([JSONMember("sprite", "PRs"), JSONMember("values", .string(#"{"prs": 0}"#))])))
    #expect(app.requests("render").last?["args"]?["values"] == .object([JSONMember("prs", 0)]))
    let wrong = mcp.handle(call(3, "preview_sprite", .object([JSONMember("sprite", "PRs"), JSONMember("values", [1, 2])])))?["result"]
    #expect(wrong?["isError"] == true)
    #expect(app.requests("render").count == 2)
    let badAppearance = mcp.handle(call(4, "preview_sprite", .object([JSONMember("sprite", "PRs"), JSONMember("appearance", "sepia")])))?["result"]
    #expect(badAppearance?["content"]?[0]?["text"]?.string == "appearance is dark, light, both or system.")
}

@Test func aValidSpecWhoseBoardFailsSaysSoInItsHeadline() throws {
    let failing = BlockReport(path: "board.blocks[2]", kind: "blocks", command: "python3 repos.py", problem: "Exited with status 1",
                              stderr: "File \"$SPRITE_DIR/repos.py\", line 4, in <module>\nKeyError: 'branch'")
    let drawn = BlockReport(path: "board.blocks[3]", kind: "script", command: "python3 prs.py",
                            rows: ["“Waiting (1)”", "“#12 Fix login” → https://github.com/o/r/pull/12", "---", "“Restart” runs `brew services restart x`"])
    let app = try FakeApp { request in
        request["op"]?.string == "render"
            ? FakeApp.ok(encoding: RenderResult(files: [], values: [], diagnostics: [], notes: ["Draft: drawn from the spec without saving it."], blocks: [failing, drawn]))
            : FakeApp.ok(encoding: ApplyResult(created: true, saved: false, sprite: sampleSprite, diagnostics: [], spec: .null))
    }
    defer { app.stop() }
    let mcp = server(app, folder: try scratchFolder())
    let text = mcp.handle(call(1, "apply_sprite", .object([JSONMember("spec", try JSONValue.parse(sampleSpecText)), JSONMember("dry_run", true)])))?["result"]?["content"]?[0]?["text"]?.string ?? ""
    #expect(text.hasPrefix("Dry run: “GitHub PRs” is valid, but 1 board block failed to draw. It would be created; nothing was saved.\n"))
    #expect(text.contains("""
        Failed blocks:
          board.blocks[2] (blocks `python3 repos.py`): Exited with status 1
            stderr ends:
              File "$SPRITE_DIR/repos.py", line 4, in <module>
              KeyError: 'branch'

        """))
    #expect(text.contains("""
        Board blocks:
          board.blocks[3] (script `python3 prs.py`): 3 rows
            “Waiting (1)”
            “#12 Fix login” → https://github.com/o/r/pull/12
            ---
            “Restart” runs `brew services restart x`

        """))
    let preview = mcp.handle(call(2, "preview_sprite", .object([JSONMember("sprite", "PRs")])))?["result"]?["content"]?[0]?["text"]?.string ?? ""
    #expect(preview.hasPrefix("1 board block failed to draw.\nFailed blocks:\n"))
}

@Test func testCommandRunsWithADraftsFiles() throws {
    let app = try FakeApp { _ in FakeApp.ok(encoding: RunResult(text: "42", number: 42, output: "42\n", error: "", status: 0, problem: nil, elapsed: 0.1)) }
    defer { app.stop() }
    let mcp = server(app, folder: try scratchFolder())
    let files = JSONValue.object([JSONMember("v.sh", "echo 42\n")])
    _ = mcp.handle(call(1, "test_command", .object([JSONMember("command", "sh v.sh"), JSONMember("files", files)])))
    #expect(app.requests("run").last?["args"]?["files"] == files)
    // A whole spec is accepted for its files.
    _ = mcp.handle(call(2, "test_command", .object([JSONMember("command", "python3 prs.py"), JSONMember("files", try JSONValue.parse(sampleSpecText))])))
    #expect(app.requests("run").last?["args"]?["files"] == .object([JSONMember("prs.py", "print(1)\n")]))
    let wrong = mcp.handle(call(3, "test_command", .object([JSONMember("command", "x"), JSONMember("files", .object([JSONMember("a.sh", 3)]))])))?["result"]
    #expect(wrong?["isError"] == true)
    #expect(app.requests("run").count == 2)
}

@Test func examplesAreListedAndReadWithoutTheApp() throws {
    let mcp = server(nil, folder: try scratchFolder())
    let list = mcp.handle(call(1, "list_examples", .object([])))?["result"]
    #expect(list?["isError"] == false)
    let text = list?["content"]?[0]?["text"]?.string ?? ""
    if AgentExamples.all.isEmpty { #expect(text == "No examples are built in yet.") }
    for example in AgentExamples.all {
        #expect(text.contains(example.name))
        let read = mcp.handle(call(2, "get_example", .object([JSONMember("name", .string(example.name.uppercased()))])))?["result"]
        #expect(try JSONValue.parse(read?["content"]?[0]?["text"]?.string ?? "") == (try JSONValue.parse(example.json)))
        let resource = mcp.handle(request(3, "resources/read", .object([JSONMember("uri", .string("menusprite://examples/\(example.name)"))])))
        #expect(resource?["result"]?["contents"]?[0]?["mimeType"]?.string == "application/json")
    }
    let missing = mcp.handle(call(4, "get_example", .object([JSONMember("name", "no-such-example")])))?["result"]
    #expect(missing?["isError"] == true)
    #expect(missing?["content"]?[0]?["text"]?.string?.hasPrefix("No example is called “no-such-example”.") == true)
}

@Test func refreshSpriteAndSampledReadingsSayWhatTheyShow() throws {
    let app = try FakeApp { request in
        switch request["op"]?.string {
        case "refresh": return FakeApp.ok(encoding: RefreshResult(values: [ValueState(id: "prs", name: "prs", value: "4", problem: nil)]))
        default:
            return FakeApp.ok(encoding: ReadingsResult(readings: [
                ReadingInfo(id: "cpu.usage", name: "CPU usage", short: "CPU", group: "CPU", unit: "%", value: "12%", number: 12),
                ReadingInfo(id: "ai.claude.session", name: "Claude session", short: "5h", group: "AI", unit: "%", problem: "Not signed in."),
            ], sampled: true))
        }
    }
    defer { app.stop() }
    let mcp = server(app, folder: try scratchFolder())
    let refreshed = mcp.handle(call(1, "refresh_sprite", .object([JSONMember("sprite", "PRs")])))?["result"]?["content"]?[0]?["text"]?.string
    #expect(refreshed == "Ran “PRs”'s commands again.\nValues:\n  prs  4")
    #expect(app.requests("refresh").first?["args"] == .object([JSONMember("sprite", "PRs")]))
    let readings = mcp.handle(call(2, "list_readings", .object([JSONMember("sample", true)])))?["result"]?["content"]?[0]?["text"]?.string ?? ""
    #expect(readings.contains("ai.claude.session  Claude session  %     AI     – Not signed in."))
}

/// Answers written at the same moment from several threads must reach the client whole: a writer that hands
/// bytes over in small pieces and yields between them would interleave two answers if anything let them overlap.
@Test func concurrentAnswersAreWrittenOneAtATime() throws {
    let mcp = server(nil, folder: try scratchFolder())
    final class Sink: @unchecked Sendable { let lock = NSLock(); var inFlight = 0, overlapped = false, written = "" }
    let sink = Sink()
    var lines: [String] = []
    for id in 1...24 {
        lines.append(request(id, "resources/read", .object([JSONMember("uri", "menusprite://guide")])).serialized())
        lines.append(request(100 + id, "ping").serialized())
    }
    mcp.serve(readLine: { lines.isEmpty ? nil : lines.removeFirst() }, write: { message in
        sink.lock.withLock { sink.inFlight += 1; if sink.inFlight > 1 { sink.overlapped = true } }
        let bytes = Array(message.utf8)
        for chunk in stride(from: 0, to: bytes.count, by: 4096) {
            let piece = String(decoding: bytes[chunk..<min(bytes.count, chunk + 4096)], as: UTF8.self)
            sink.lock.withLock { sink.written += piece }
            Thread.sleep(forTimeInterval: 0.0002)
        }
        sink.lock.withLock { sink.written += "\n"; sink.inFlight -= 1 }
    })
    #expect(!sink.overlapped)
    let messages = try sink.written.split(separator: "\n").map { try JSONValue.parse(String($0)) }
    #expect(messages.count == 48)
    #expect(Set(messages.compactMap { $0["id"]?.number.map(Int.init) }) == Set(Array(1...24) + Array(101...124)))
}

/// The same through a real pipe read slowly, as a client that is busy drains it.
@Test func concurrentAnswersStayWholeThroughAPipe() throws {
    let mcp = server(nil, folder: try scratchFolder())
    let pipe = Pipe()
    let descriptor = pipe.fileHandleForWriting.fileDescriptor
    let collected = Capture()
    let reader = Thread {
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            collected.console.write(String(decoding: data, as: UTF8.self))
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    reader.start()
    var lines = (1...16).map { request($0, "resources/read", .object([JSONMember("uri", "menusprite://guide")])).serialized() }
    mcp.serve(readLine: { lines.isEmpty ? nil : lines.removeFirst() }, write: { _ = StandardStream.write($0 + "\n", to: descriptor) })
    try pipe.fileHandleForWriting.close()
    while !reader.isFinished { Thread.sleep(forTimeInterval: 0.01) }
    let messages = try collected.out.split(separator: "\n").map { try JSONValue.parse(String($0)) }
    #expect(messages.count == 16)
    #expect(messages.allSatisfy { $0["result"]?["contents"]?[0]?["text"]?.string == AgentGuide.markdown })
}
