import AgentProtocol
import Foundation
import Testing
@testable import MenuSpriteCLI

@Test func listPrintsAnAlignedTable() throws {
    let app = try FakeApp { _ in FakeApp.ok(encoding: ListResult(sprites: [sampleSprite])) }
    defer { app.stop() }
    let folder = try scratchFolder(), capture = Capture()
    #expect(cli(app, capture, folder: folder).run(["list"]) == 0)
    let lines = capture.out.split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    #expect(lines[0].hasPrefix("NAME        ID        STATE  SIDE   BOARD   VALUES"))
    #expect(lines[1].hasPrefix("GitHub PRs  3f2a9c1e  shown  right  custom  prs, repo"))
    #expect(app.requests == [.object([JSONMember("v", 1), JSONMember("op", "list"), JSONMember("args", .object([]))])])
}

@Test func getPrintsTheSpecInTheAppsKeyOrder() throws {
    let spec = try JSONValue.parse(sampleSpecText)
    let app = try FakeApp { _ in FakeApp.ok(.object([JSONMember("spec", spec)])) }
    defer { app.stop() }
    let folder = try scratchFolder(), capture = Capture()
    #expect(cli(app, capture, folder: folder).run(["get", "GitHub", "PRs"]) == 0)
    // JSONDecoder would scramble these; the envelope is read member by member.
    #expect(try JSONValue.parse(capture.out).keys == ["menusprite", "name", "icon", "values", "board", "files"])
    #expect(app.requests.first?["args"]?["sprite"]?.string == "GitHub PRs")
}

@Test func applySendsTheSpecAsWrittenAndReportsWhatHappened() throws {
    let app = try FakeApp { request in
        FakeApp.ok(encoding: ApplyResult(created: true, saved: true, sprite: sampleSprite,
                                         diagnostics: [.warning("values[0].every", "Every 5 minutes is slow for a face value", hint: "use 60")],
                                         spec: request["args"]?["spec"] ?? .null))
    }
    defer { app.stop() }
    let folder = try scratchFolder(), capture = Capture()
    try sampleSpecText.write(toFile: folder + "/prs.json", atomically: true, encoding: .utf8)
    #expect(cli(app, capture, folder: folder).run(["apply", "prs.json"]) == 0)
    let sent = try #require(app.requests.first)
    #expect(sent["op"]?.string == "apply")
    #expect(sent["args"]?["spec"] == (try JSONValue.parse(sampleSpecText)))
    #expect(sent["args"]?["spec"]?.keys == ["menusprite", "name", "icon", "values", "board", "files"])
    #expect(sent["args"]?["dryRun"] == nil)
    #expect(capture.out.contains("Created “GitHub PRs” (id 3f2a9c1e-5b7d-4e2a-9c1e-000000000001): in the menu bar, on the right."))
    #expect(capture.out.contains("Warnings:\n  values[0].every: Every 5 minutes is slow for a face value — use 60\n"))
    #expect(capture.out.contains("Commands it runs:\n  gh pr list --json number --jq length\n  python3 prs.py\n"))
    #expect(capture.err.isEmpty)
}

@Test func anInvalidSpecExitsOneWithItsDiagnosticsOnStandardError() throws {
    let app = try FakeApp { _ in
        FakeApp.failure(AgentFailure(.invalidSpec, "The spec has 1 error.", diagnostics: [
            .error("board.blocks[2].button", "A button needs one action", hint: "add run, open, app, copy or refresh")]))
    }
    defer { app.stop() }
    let folder = try scratchFolder(), capture = Capture(input: sampleSpecText)
    #expect(cli(app, capture, folder: folder).run(["apply", "-"]) == 1)
    #expect(capture.out.isEmpty)
    #expect(capture.err == "menusprite: The spec has 1 error.\nErrors:\n  board.blocks[2].button: A button needs one action — add run, open, app, copy or refresh\n")

    let json = Capture(input: sampleSpecText)
    #expect(cli(app, json, folder: folder).run(["apply", "-", "--json"]) == 1)
    let failure = try JSONValue.parse(json.err)
    #expect(failure["ok"] == false)
    #expect(failure["error"]?["code"]?.string == "invalidSpec")
    #expect(failure["error"]?["diagnostics"]?[0]?["path"]?.string == "board.blocks[2].button")
}

@Test func applyWithPreviewDrawsTheSavedSpriteIntoAnAbsoluteFolder() throws {
    let app = try FakeApp { request in
        request["op"]?.string == "render" ? fakeRender(request)
            : FakeApp.ok(encoding: ApplyResult(created: false, saved: true, sprite: sampleSprite, diagnostics: [], spec: .null))
    }
    defer { app.stop() }
    let folder = try scratchFolder(), capture = Capture(input: sampleSpecText)
    #expect(cli(app, capture, folder: folder).run(["apply", "-", "--preview", "shots"]) == 0)
    let render = try #require(app.requests("render").first)
    #expect(render["args"]?["directory"]?.string == folder + "/shots")
    #expect(render["args"]?["sprite"]?.string == sampleSprite.id)
    #expect(render["args"]?["spec"] == nil)
    #expect(capture.out.contains("Updated “GitHub PRs”"))
    #expect(capture.out.contains("Pictures:\n  face   dark  \(folder)/shots/face-dark.png   120×44\n"))
    #expect(capture.out.contains("repo  no value  — gh: not logged in"))
    #expect(capture.out.contains("Notes:\n  - The board's script block printed nothing.\n"))
}

@Test func aDryRunPreviewDrawsTheDraftAndSavesNothing() throws {
    let app = try FakeApp { request in
        request["op"]?.string == "render" ? fakeRender(request)
            : FakeApp.ok(encoding: ApplyResult(created: true, saved: false, sprite: sampleSprite, diagnostics: [], spec: .null))
    }
    defer { app.stop() }
    let folder = try scratchFolder(), capture = Capture(input: sampleSpecText)
    #expect(cli(app, capture, folder: folder).run(["apply", "-", "--dry-run", "--preview", folder + "/p"]) == 0)
    #expect(app.requests("apply").first?["args"]?["dryRun"] == true)
    let render = try #require(app.requests("render").first)
    #expect(render["args"]?["sprite"] == nil)
    #expect(render["args"]?["spec"]?.keys.first == "menusprite")
    #expect(capture.out.hasPrefix("Dry run: “GitHub PRs” is valid and would be created. Nothing was saved.\n"))
}

@Test func aJSONSlipIsCaughtHereWithItsLineAndColumn() throws {
    let app = try FakeApp { _ in FakeApp.ok(.null) }
    defer { app.stop() }
    let folder = try scratchFolder(), capture = Capture()
    try "{\n  \"menusprite\": 1,\n}\n".write(toFile: folder + "/bad.json", atomically: true, encoding: .utf8)
    #expect(cli(app, capture, folder: folder).run(["validate", "bad.json"]) == 1)
    #expect(capture.err.contains("bad.json: Not valid JSON at line 3, column 1"))
    #expect(cli(app, capture, folder: folder).run(["apply", "missing.json"]) == 1)
    #expect(capture.err.contains("Cannot read missing.json."))
    #expect(app.requests.isEmpty)
}

@Test func jsonPrintsTheRawResult() throws {
    let readings = ReadingsResult(readings: [ReadingInfo(id: "cpu.usage", name: "CPU usage", short: "CPU", group: "CPU", unit: "%", value: "12%", number: 12)])
    let app = try FakeApp { _ in FakeApp.ok(encoding: readings) }
    defer { app.stop() }
    let folder = try scratchFolder()
    let json = Capture()
    #expect(cli(app, json, folder: folder).run(["readings", "cpu", "--sample", "--json"]) == 0)
    #expect(try JSONValue.parse(json.out).decode(ReadingsResult.self).readings == readings.readings)
    #expect(canonical(app.requests.first?["args"]) == .object([JSONMember("query", "cpu"), JSONMember("sample", true)]))
    let human = Capture()
    #expect(cli(app, human, folder: folder).run(["readings", "--sample"]) == 0)
    #expect(human.out == "ID         NAME       UNIT  GROUP  VALUE\ncpu.usage  CPU usage  %     CPU    12%\n")
}

@Test func aSandboxSocketIsNeverAnsweredByLaunchingTheApp() throws {
    let launches = Capture()
    var client = AppClient(environment: ["MENUSPRITE_SOCKET": FakeApp.socketPath()]) { launches.console.write("launched"); return .started }
    client.startupLimit = 0.2
    let capture = Capture()
    let code = CLI(environment: [:], console: capture.console, client: client).run(["list"])
    #expect(code == 2)
    #expect(capture.err.contains("MENUSPRITE_SOCKET is set"))
    #expect(launches.out.isEmpty)
}

@Test func startsTheAppAndWaitsForItsSocket() throws {
    let path = FakeApp.socketPath()
    let started = Capture()
    var client = AppClient(environment: [:]) {
        started.console.write("launch ")
        // The app takes a moment to open its socket.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let app = try? FakeApp(path: path) { _ in FakeApp.ok(encoding: ListResult(sprites: [])) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { app?.stop() }
        }
        return .started
    }
    client.socketPath = path
    client.pollInterval = 0.05
    client.startupLimit = 5
    #expect(client.mayLaunch)
    let capture = Capture()
    #expect(CLI(environment: [:], console: capture.console, client: client).run(["list"]) == 0)
    #expect(capture.out.hasPrefix("No sprites yet."))
    #expect(started.out == "launch ")
}

@Test func aMissingOrSilentAppIsExitTwoWithWhatToDo() throws {
    var missing = AppClient(environment: [:]) { .notInstalled }
    missing.socketPath = FakeApp.socketPath()
    let notInstalled = Capture()
    #expect(CLI(environment: [:], console: notInstalled.console, client: missing).run(["list"]) == 2)
    #expect(notInstalled.err.contains("brew install --cask prerakgada/tap/menusprite"))

    var silent = AppClient(environment: [:]) { .started }
    silent.socketPath = FakeApp.socketPath()
    silent.pollInterval = 0.05
    silent.startupLimit = 0.3
    let quiet = Capture()
    #expect(CLI(environment: [:], console: quiet.console, client: silent).run(["list"]) == 2)
    #expect(quiet.err.contains("running but not answering"))

    // version never starts the app.
    var counting = AppClient(environment: [:]) { Issue.record("version started the app"); return .started }
    counting.socketPath = FakeApp.socketPath()
    let version = Capture()
    #expect(CLI(environment: [:], console: version.console, client: counting).run(["version"]) == 0)
    #expect(version.out.contains("not answering"))
}

@Test func runShowsTheValueAndExitsOneWithoutOne() throws {
    let app = try FakeApp { request in
        let command = request["args"]?["command"]?.string ?? ""
        return command.hasPrefix("echo")
            ? FakeApp.ok(encoding: RunResult(text: "3", number: 3, output: "3\n", error: "", status: 0, problem: nil, elapsed: 0.02))
            : FakeApp.ok(encoding: RunResult(text: nil, number: nil, output: "", error: "zsh: command not found: ghx\n", status: 127,
                                             problem: "The command exited with status 127.", elapsed: 0.01))
    }
    defer { app.stop() }
    let folder = try scratchFolder()
    let good = Capture()
    #expect(cli(app, good, folder: folder).run(["run", "echo", "3", "--parse", "number", "--timeout", "45"]) == 0)
    #expect(good.out.hasPrefix("value   3\nnumber  3\nstatus  exit 0 · 0.02 s\noutput:\n  3\n"))
    let sent = try #require(app.requests.first?["args"])
    #expect(sent["command"]?.string == "echo 3")
    #expect(sent["parse"]?.string == "number")
    #expect(sent["timeout"]?.number == 45)
    let bad = Capture()
    #expect(cli(app, bad, folder: folder).run(["run", "ghx pr list"]) == 1)
    #expect(bad.out.contains("No value.\n"))
    #expect(bad.out.contains("stderr:\n  zsh: command not found: ghx\n"))
    #expect(cli(app, bad, folder: folder).run(["run", "x", "--parse", "yaml"]) == 1)
    #expect(cli(app, bad, folder: folder).run(["run", "x", "--timeout", "soon"]) == 1)
}

@Test func switchesAndSideSendOnlyWhatChanges() throws {
    let app = try FakeApp { request in
        var sprite = sampleSprite
        if let side = request["args"]?["side"]?.string { sprite.side = side }
        if let shown = request["args"]?["menuBar"]?.bool { sprite.menuBar = shown }
        return FakeApp.ok(encoding: SpriteResult(sprite: sprite))
    }
    defer { app.stop() }
    let folder = try scratchFolder(), capture = Capture()
    let tool = cli(app, capture, folder: folder)
    #expect(tool.run(["side", "GitHub", "PRs", "LEFT"]) == 0)
    #expect(tool.run(["hide", "3f2a"]) == 0)
    #expect(tool.run(["enable", "3f2a"]) == 0)
    #expect(app.requests.map { canonical($0["args"]) } == [
        .object([JSONMember("side", "left"), JSONMember("sprite", "GitHub PRs")]),
        .object([JSONMember("menuBar", false), JSONMember("sprite", "3f2a")]),
        .object([JSONMember("enabled", true), JSONMember("sprite", "3f2a")]),
    ])
    #expect(capture.out.contains("“GitHub PRs” (3f2a9c1e): in the menu bar, on the left strip; custom board.\n"))
    #expect(capture.out.contains("running, hidden from the menu bar"))
}

@Test func previewTellsAFileFromASpriteName() throws {
    let app = try FakeApp { request in fakeRender(request, kinds: ["face"]) }
    defer { app.stop() }
    let folder = try scratchFolder(), capture = Capture()
    try sampleSpecText.write(toFile: folder + "/draft.json", atomically: true, encoding: .utf8)
    let tool = cli(app, capture, folder: folder)
    #expect(tool.run(["preview", "draft.json", "--light", "--no-board"]) == 0)
    #expect(tool.run(["preview", "GitHub", "PRs", "--both", "--out", "here"]) == 0)
    #expect(tool.run(["preview", "nothing.json"]) == 1)
    #expect(tool.run(["preview", "x", "--no-face", "--no-board"]) == 1)
    let renders = app.requests("render").compactMap { $0["args"] }
    #expect(renders.count == 2)
    #expect(renders[0]["spec"]?["name"]?.string == "GitHub PRs")
    #expect(renders[0]["sprite"] == nil)
    #expect(renders[0]["appearance"]?.string == "light")
    #expect(renders[0]["board"] == false)
    #expect(renders[0]["directory"]?.string?.hasPrefix(folder + "/menusprite-preview-") == true)
    #expect(renders[1]["sprite"]?.string == "GitHub PRs")
    #expect(renders[1]["appearance"]?.string == "both")
    #expect(renders[1]["directory"]?.string == folder + "/here")
    #expect(FileManager.default.fileExists(atPath: folder + "/here"))
    #expect(capture.err.contains("No such file: nothing.json"))
}

@Test func appFailuresMapToExitStatuses() throws {
    let app = try FakeApp { request in
        switch request["op"]?.string {
        case "remove": FakeApp.failure(AgentFailure(.notFound, "No sprite matches “Nope”."))
        case "open": FakeApp.ok(encoding: OpenResult(opened: false, message: "“PRs” is hidden from the menu bar, so its board cannot open."))
        default: .object([JSONMember("ok", false)])
        }
    }
    defer { app.stop() }
    let folder = try scratchFolder(), capture = Capture()
    let tool = cli(app, capture, folder: folder)
    #expect(tool.run(["remove", "Nope"]) == 1)
    #expect(capture.err.contains("menusprite: No sprite matches “Nope”.\n"))
    #expect(tool.run(["open", "PRs"]) == 1)
    #expect(capture.out.contains("cannot open"))
    #expect(tool.run(["list"]) == 1)
    #expect(capture.err.contains("does not understand"))
}

@Test func guideAndSchemaNeedNoApp() throws {
    let capture = Capture()
    var client = AppClient(environment: [:]) { Issue.record("started the app"); return .started }
    client.socketPath = FakeApp.socketPath()
    let tool = CLI(environment: [:], console: capture.console, client: client)
    #expect(tool.run(["guide"]) == 0)
    #expect(capture.out.hasPrefix(AgentGuide.markdown))
    #expect(tool.run(["schema", "--json"]) == 0)
    #expect(capture.out.contains(try JSONValue.parse(SpecSchema.json).serialized()))
    #expect(tool.run(["help", "apply"]) == 0)
    #expect(tool.run(["help", "nope"]) == 1)
}

@Test func anUnknownErrorCodeStillShowsItsMessage() throws {
    let reply = try JSONValue.parse(#"{"ok":false,"error":{"code":"conflict","message":"The sprite changed in the studio meanwhile.","diagnostics":[{"severity":"warning","path":"name","message":"m"}]}}"#)
    do { _ = try Envelope.result(of: reply); Issue.record("no failure") }
    catch let failure as AgentFailure {
        #expect(failure.message == "The sprite changed in the studio meanwhile.")
        #expect(failure.diagnostics == [.warning("name", "m")])
    }
}

@Test func previewAndApplySendStandInValuesAndAppearance() throws {
    let app = try FakeApp { request in
        request["op"]?.string == "render" ? fakeRender(request)
            : FakeApp.ok(encoding: ApplyResult(created: false, saved: true, sprite: sampleSprite, diagnostics: [], spec: .null))
    }
    defer { app.stop() }
    let folder = try scratchFolder()
    #expect(cli(app, Capture(), folder: folder).run(["preview", "GitHub", "PRs", "--value", "prs=12", "--value", "state=Running",
                                                       "--value", "label=\"12\"", "--value", "awake=true", "--value", "session.pace=on track"]) == 0)
    let render = try #require(app.requests("render").last?["args"])
    #expect(render["sprite"]?.string == "GitHub PRs")
    #expect(render["values"] == .object([JSONMember("prs", 12), JSONMember("state", "Running"), JSONMember("label", "12"),
                                         JSONMember("awake", true), JSONMember("session.pace", "on track")]))
    #expect(render["appearance"] == nil)

    // apply --preview draws both appearances unless told otherwise.
    #expect(cli(app, Capture(input: sampleSpecText), folder: folder).run(["apply", "-", "--preview", "p"]) == 0)
    #expect(app.requests("render").last?["args"]?["appearance"]?.string == "both")
    #expect(cli(app, Capture(input: sampleSpecText), folder: folder).run(["apply", "-", "--preview", "p", "--dark", "--value", "prs=0"]) == 0)
    #expect(app.requests("render").last?["args"]?["appearance"]?.string == "dark")
    #expect(app.requests("render").last?["args"]?["values"] == .object([JSONMember("prs", 0)]))

    // Stand-ins only change pictures, so without --preview they are a mistake worth saying.
    let lost = Capture(input: sampleSpecText)
    #expect(cli(app, lost, folder: folder).run(["apply", "-", "--value", "prs=1"]) == 1)
    #expect(lost.err.contains("add --preview <dir>"))
    let malformed = Capture()
    #expect(cli(app, malformed, folder: folder).run(["preview", "PRs", "--value", "prs"]) == 1)
    #expect(malformed.err.contains("--value takes id=value"))
    #expect(app.requests("apply").count == 2)
}

@Test func runWithADraftsFilesSendsThem() throws {
    let app = try FakeApp { _ in FakeApp.ok(encoding: RunResult(text: "1", number: 1, output: "1\n", error: "", status: 0, problem: nil, elapsed: 0.1)) }
    defer { app.stop() }
    let folder = try scratchFolder()
    try sampleSpecText.write(toFile: folder + "/draft.json", atomically: true, encoding: .utf8)
    #expect(cli(app, Capture(), folder: folder).run(["run", "python3 prs.py", "--files", "draft.json"]) == 0)
    #expect(app.requests("run").first?["args"]?["files"] == .object([JSONMember("prs.py", "print(1)\n")]))
    let both = Capture()
    #expect(cli(app, both, folder: folder).run(["run", "x", "--files", "draft.json", "--sprite", "PRs"]) == 1)
    let none = Capture(input: #"{"menusprite":1,"name":"x"}"#)
    #expect(cli(app, none, folder: folder).run(["run", "x", "--files", "-"]) == 1)
    #expect(none.err.contains("has no \"files\""))
    #expect(app.requests("run").count == 1)
}

@Test func refreshAndExamples() throws {
    let app = try FakeApp { _ in FakeApp.ok(encoding: RefreshResult(values: [ValueState(id: "prs", name: "prs", value: nil, problem: "Exited with status 1: gh: not logged in")])) }
    defer { app.stop() }
    let folder = try scratchFolder(), capture = Capture()
    #expect(cli(app, capture, folder: folder).run(["refresh", "GitHub", "PRs"]) == 0)
    #expect(capture.out == "Ran “GitHub PRs”'s commands again.\nValues:\n  prs  no value  — Exited with status 1: gh: not logged in\n")
    #expect(app.requests("refresh").first?["args"]?["sprite"]?.string == "GitHub PRs")

    let list = Capture()
    #expect(cli(app, list, folder: folder).run(["examples"]) == 0)
    if AgentExamples.all.isEmpty { #expect(list.out == "No examples are built in yet.\n") }
    for example in AgentExamples.all {
        let one = Capture()
        #expect(cli(app, one, folder: folder).run(["examples", example.name]) == 0)
        #expect(try JSONValue.parse(one.out) == (try JSONValue.parse(example.json)))
    }
    let missing = Capture()
    #expect(cli(app, missing, folder: folder).run(["examples", "nope"]) == 1)
    #expect(missing.err.contains("No example is called “nope”."))
    #expect(app.requests.count == 1)
}

@Test func sampledReadingsShowWhyAValueIsMissing() throws {
    let app = try FakeApp { _ in
        FakeApp.ok(encoding: ReadingsResult(readings: [
            ReadingInfo(id: "battery.charge", name: "Battery charge", short: "BAT", group: "Battery", unit: "%", problem: "No battery"),
        ], sampled: true))
    }
    defer { app.stop() }
    let folder = try scratchFolder(), capture = Capture()
    #expect(cli(app, capture, folder: folder).run(["readings", "battery", "--sample"]) == 0)
    #expect(capture.out == "ID              NAME            UNIT  GROUP    VALUE\nbattery.charge  Battery charge  %     Battery  – No battery\n")
}
