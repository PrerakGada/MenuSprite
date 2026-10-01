import AgentProtocol
import Darwin
import Foundation

/// The `menusprite` verbs. Everything that touches sprites goes through the running app; the guide, schema,
/// help and setup work without it. Human output by default, the raw answer with `--json`, errors on
/// standard error, and the exit statuses in `ExitStatus`.
struct CLI: Sendable {
    var console: Console
    var environment: [String: String]
    var client: AppClient
    var processRunner: ProcessRunner
    var currentDirectory: String

    init(environment: [String: String], console: Console = .standard, client: AppClient? = nil,
         processRunner: ProcessRunner = .system, currentDirectory: String = FileManager.default.currentDirectoryPath) {
        self.environment = environment
        self.console = console
        self.client = client ?? AppClient(environment: environment)
        self.processRunner = processRunner
        self.currentDirectory = currentDirectory
    }

    func run(_ arguments: [String]) -> Int32 {
        do {
            let invocation = try Arguments.parse(arguments)
            if invocation.verb == "help" { return try help(invocation.words.first) }
            if invocation.has("help"), let verb = Arguments.verb(named: invocation.verb) { console.write(Help.text(for: verb)); return ExitStatus.ok }
            return try perform(invocation, json: invocation.json)
        } catch let failure as AgentFailure {
            report(failure, json: arguments.contains("--json"))
            return failure.code == .unavailable ? ExitStatus.unavailable : ExitStatus.failure
        } catch let error as UsageError {
            let usage = error.verb.flatMap(Arguments.verb(named:)).map { "Usage: menusprite \($0.usage)\n" } ?? "Run menusprite help for the commands.\n"
            console.writeError("menusprite: \(error.message)\n\(usage)")
            return ExitStatus.failure
        } catch let error as CommandError {
            console.writeError("menusprite: \(error.message)\n")
            return error.status
        } catch {
            console.writeError("menusprite: \(error)\n")
            return ExitStatus.failure
        }
    }

    private func perform(_ invocation: Invocation, json: Bool) throws -> Int32 {
        switch invocation.verb {
        case "guide":
            if json { emit(.object([JSONMember("guide", .string(AgentGuide.markdown))])) } else { console.write(line(AgentGuide.markdown)) }
            return ExitStatus.ok
        case "schema":
            if let schema = try? JSONValue.parse(SpecSchema.json) { console.write(schema.serialized(pretty: !json) + "\n") }
            else { console.write(line(SpecSchema.json)) }
            return ExitStatus.ok
        case "readings": return try readings(invocation, json: json)
        case "list":
            let raw = try client.result(.list)
            if json { emit(raw); return ExitStatus.ok }
            let sprites = try Envelope.decode(raw, as: ListResult.self).sprites
            console.write(sprites.isEmpty ? "No sprites yet. Write a spec (menusprite guide) and run: menusprite apply <file>\n" : Format.sprites(sprites))
            return ExitStatus.ok
        case "get":
            let raw = try client.result(.get, try Envelope.arguments(SpriteReference(sprite: invocation.joined)))
            emit(json ? raw : raw["spec"] ?? raw)
            // Standard output stays the spec alone, so it can be saved and applied back.
            if !json, let notes = (try? Envelope.decode(raw, as: GetResult.self))?.notes, !notes.isEmpty { console.writeError(Format.notes(notes)) }
            return ExitStatus.ok
        case "validate": return try validate(invocation, json: json)
        case "apply": return try apply(invocation, json: json)
        case "preview": return try preview(invocation, json: json)
        case "run": return try runCommand(invocation, json: json)
        case "refresh":
            let raw = try client.result(.refresh, try Envelope.arguments(SpriteReference(sprite: invocation.joined)), timeout: AppClient.renderTimeout)
            if json { emit(raw) } else { console.write(Format.refresh(try Envelope.decode(raw, as: RefreshResult.self), sprite: invocation.joined)) }
            return ExitStatus.ok
        case "examples":
            guard let name = invocation.words.first else {
                if json {
                    emit(.array(AgentExamples.all.map { .object([JSONMember("name", .string($0.name)), JSONMember("summary", .string($0.summary))]) }))
                } else { console.write(Format.examples(AgentExamples.all).replacingOccurrences(of: "get_example (or menusprite examples <name>)", with: "menusprite examples <name>")) }
                return ExitStatus.ok
            }
            guard let example = AgentExamples.named(name) else { throw MCPTools.unknownExample(name) }
            console.write(MCPTools.exampleText(example) + "\n")
            return ExitStatus.ok
        case "remove":
            let raw = try client.result(.remove, try Envelope.arguments(SpriteReference(sprite: invocation.joined)))
            if json { emit(raw) } else { console.write("Removed \(try Envelope.decode(raw, as: RemoveResult.self).removed).\n") }
            return ExitStatus.ok
        case "enable", "disable", "show", "hide", "side": return try set(invocation, json: json)
        case "open":
            let raw = try client.result(.open, try Envelope.arguments(SpriteReference(sprite: invocation.joined)))
            let result = try Envelope.decode(raw, as: OpenResult.self)
            if json { emit(raw) } else { console.write(line(result.message)) }
            return result.opened ? ExitStatus.ok : ExitStatus.failure
        case "mcp": return mcp()
        case "setup": return try setup(invocation, json: json)
        case "version": return version(json: json)
        default: throw UsageError("Unknown command “\(invocation.verb)”.")
        }
    }

    // MARK: - Verbs

    private func help(_ name: String?) throws -> Int32 {
        guard let name else { console.write(Help.general); return ExitStatus.ok }
        guard let verb = Arguments.verb(named: name) else { throw UsageError("Unknown command “\(name)”.") }
        console.write(Help.text(for: verb))
        return ExitStatus.ok
    }

    private func readings(_ invocation: Invocation, json: Bool) throws -> Int32 {
        let query = invocation.words.isEmpty ? nil : invocation.joined
        let raw = try client.result(.readings, try Envelope.arguments(ReadingsArgs(query: query, sample: invocation.has("sample") ? true : nil)))
        if json { emit(raw); return ExitStatus.ok }
        let result = try Envelope.decode(raw, as: ReadingsResult.self)
        let readings = result.readings
        console.write(readings.isEmpty ? (query.map { "No readings match “\($0)”.\n" } ?? "No readings.\n") : Format.readings(readings, sampled: result.sampled == true))
        return ExitStatus.ok
    }

    private func validate(_ invocation: Invocation, json: Bool) throws -> Int32 {
        let spec = try loadSpec(invocation.words[0])
        let raw = try client.result(.validate, try Envelope.arguments(SpecArgs(spec: .null), spec: spec))
        let result = try Envelope.decode(raw, as: ValidateResult.self)
        if json { emit(raw) }
        else if result.valid { console.write("Valid.\n" + Format.diagnostics(result.diagnostics)) }
        else { console.writeError("The spec is not valid; nothing was saved.\n" + Format.diagnostics(result.diagnostics)) }
        return result.valid ? ExitStatus.ok : ExitStatus.failure
    }

    private func apply(_ invocation: Invocation, json: Bool) throws -> Int32 {
        let spec = try loadSpec(invocation.words[0])
        let dryRun = invocation.has("dry-run")
        let previewDirectory = try invocation.option("preview").map { try prepareDirectory($0) }
        let values = try standIns(invocation)
        if previewDirectory == nil, values != nil || appearance(invocation) != nil {
            throw UsageError("--value, --dark, --light and --both change the preview pictures; add --preview <dir>.", verb: "apply")
        }
        let raw = try client.result(.apply, try Envelope.arguments(SpecArgs(spec: .null, dryRun: dryRun ? true : nil), spec: spec))
        let result = try Envelope.decode(raw, as: ApplyResult.self)
        let hasErrors = result.diagnostics.contains { $0.severity == .error }
        var output = raw
        var preview: RenderResult?
        var previewProblem: AgentFailure?
        if let previewDirectory, result.saved || (dryRun && !hasErrors) {
            // A dry run draws the draft; otherwise the sprite as it was just saved. Both appearances unless
            // asked: a colour that reads well on a dark bar can wash out on a light one.
            let args = RenderArgs(sprite: dryRun ? nil : result.sprite.id, directory: previewDirectory,
                                  appearance: appearance(invocation) ?? "both", values: values)
            do {
                let rendered = try client.result(.render, try Envelope.arguments(args, spec: dryRun ? Optional(spec) : nil), timeout: AppClient.renderTimeout)
                output.set("preview", rendered)
                preview = try Envelope.decode(rendered, as: RenderResult.self)
            } catch let failure as AgentFailure {
                previewProblem = failure
                output.set("previewError", Envelope.failure(failure)["error"])
            }
        }
        if json { emit(output) }
        else {
            let summary = Format.apply(result, dryRun: dryRun, failedBlocks: preview?.failedBlocks.count ?? 0)
            if result.saved || dryRun && !hasErrors { console.write(summary + (preview.map { Format.render($0) } ?? "")) } else { console.writeError(summary) }
        }
        if let previewProblem { console.writeError("The preview failed: \(previewProblem.message)\n" + Format.diagnostics(previewProblem.diagnostics ?? [])) }
        return result.saved || (dryRun && !hasErrors) ? ExitStatus.ok : ExitStatus.failure
    }

    private func preview(_ invocation: Invocation, json: Bool) throws -> Int32 {
        if invocation.has("no-face"), invocation.has("no-board") { throw UsageError("--no-face and --no-board leave nothing to draw.", verb: "preview") }
        let target = invocation.joined
        var args = RenderArgs(directory: try prepareDirectory(invocation.option("out") ?? freshDirectory()), appearance: appearance(invocation),
                              face: invocation.has("no-face") ? false : nil, board: invocation.has("no-board") ? false : nil,
                              values: try standIns(invocation))
        var spec: JSONValue?
        if target == "-" || FileManager.default.fileExists(atPath: absolute(target)) { spec = try loadSpec(target) }
        else if target.lowercased().hasSuffix(".json") { throw CommandError("No such file: \(target)") }
        else { args.sprite = target }
        let raw = try client.result(.render, try Envelope.arguments(args, spec: spec), timeout: AppClient.renderTimeout)
        if json { emit(raw) } else { console.write(Format.render(try Envelope.decode(raw, as: RenderResult.self), headline: true)) }
        return ExitStatus.ok
    }

    /// --dark, --light, --both (or --dark --light), or nil for the default.
    private func appearance(_ invocation: Invocation) -> String? {
        invocation.has("both") || (invocation.has("dark") && invocation.has("light")) ? "both"
            : invocation.has("light") ? "light" : invocation.has("dark") ? "dark" : nil
    }

    /// `--value id=value`, repeated, as the render's stand-in values. The value is read as JSON when it is
    /// JSON (12, true, "12" for the text 12) and as plain text otherwise (Running, on track).
    func standIns(_ invocation: Invocation) throws -> JSONValue? {
        let pairs = invocation.list("value")
        guard !pairs.isEmpty else { return nil }
        var members: [JSONMember] = []
        for pair in pairs {
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                throw UsageError("--value takes id=value, such as --value free=12 or --value session.pace=over; not “\(pair)”.", verb: invocation.verb)
            }
            let id = String(pair[..<equals]).trimmingCharacters(in: .whitespaces)
            let text = String(pair[pair.index(after: equals)...])
            var value = JSONValue.string(text)
            if let parsed = try? JSONValue.parse(text) {
                switch parsed {
                case .number, .bool, .string, .null: value = parsed
                default: break
                }
            }
            members.removeAll { $0.key == id }
            members.append(JSONMember(id, value))
        }
        return .object(members)
    }

    private func runCommand(_ invocation: Invocation, json: Bool) throws -> Int32 {
        let parse = invocation.option("parse")
        if let parse, !["text", "number", "json"].contains(parse) { throw UsageError("--parse is text, number or json.", verb: "run") }
        var timeout: Double?
        if let text = invocation.option("timeout") {
            guard let seconds = Double(text), seconds > 0 else { throw UsageError("--timeout is a number of seconds.", verb: "run") }
            timeout = seconds
        }
        if invocation.option("sprite") != nil, invocation.option("files") != nil {
            throw UsageError("--sprite runs in a saved sprite's folder and --files with a draft's files; give one.", verb: "run")
        }
        let args = RunArgs(command: invocation.joined, parse: parse, path: invocation.option("path"), timeout: timeout, sprite: invocation.option("sprite"),
                           files: try invocation.option("files").map(draftFiles))
        let raw = try client.result(.run, try Envelope.arguments(args), timeout: max(AppClient.standardTimeout, (timeout ?? 10) + 20))
        let result = try Envelope.decode(raw, as: RunResult.self)
        if json { emit(raw) } else { console.write(Format.run(result)) }
        return result.problem == nil ? ExitStatus.ok : ExitStatus.failure
    }

    private func set(_ invocation: Invocation, json: Bool) throws -> Int32 {
        var args = SetArgs(sprite: invocation.joined)
        switch invocation.verb {
        case "enable": args.enabled = true
        case "disable": args.enabled = false
        case "show": args.menuBar = true
        case "hide": args.menuBar = false
        default:
            guard let side = invocation.words.last?.lowercased(), side == "left" || side == "right" else {
                throw UsageError("The side is left or right.", verb: "side")
            }
            args.sprite = invocation.words.dropLast().joined(separator: " ")
            args.side = side
        }
        let raw = try client.result(.set, try Envelope.arguments(args))
        if json { emit(raw) } else { console.write(Format.sprite(try Envelope.decode(raw, as: SpriteResult.self).sprite)) }
        return ExitStatus.ok
    }

    private func mcp() -> Int32 {
        // A client that quits mid-answer closes the pipe; that ends the server quietly instead of by signal.
        signal(SIGPIPE, SIG_IGN)
        let server = MCPServer(tools: MCPTools(client: client, temporaryDirectory: temporaryDirectory), version: CLIVersion.current)
        server.serve(readLine: { Swift.readLine(strippingNewline: true) }) { message in
            if !StandardStream.write(message + "\n", to: STDOUT_FILENO) { exit(ExitStatus.ok) }
        }
        return ExitStatus.ok
    }

    private func setup(_ invocation: Invocation, json: Bool) throws -> Int32 {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.homeDirectoryForCurrentUser
        guard let name = invocation.words.first else { console.write(AgentSetup.overview); return ExitStatus.ok }
        let binary = AgentSetup.stableBinary(home: home, executable: CLIVersion.executable)
        let setup = AgentSetup(home: home, environment: environment, binaryPath: binary.path, processRunner: processRunner)
        let outcome = try setup.run(agent: name, printOnly: invocation.has("print"))
        let message = (binary.note.map { "Note: \($0)\n" } ?? "") + outcome.message
        if json {
            emit(.object(pairs: [("agent", .string(outcome.agent)), ("command", .string(binary.path)), ("changed", .bool(outcome.changed)),
                                 ("file", outcome.file.map(JSONValue.string)), ("message", .string(message))]))
        } else {
            console.write(message)
        }
        return ExitStatus.ok
    }

    private func version(json: Bool) -> Int32 {
        // Never starts the app: asking for a version should not change what is running.
        let app = try? client.result(.hello, timeout: 5, launchIfNeeded: false)
        if json { emit(.object([JSONMember("menusprite", .string(CLIVersion.current)), JSONMember("app", app ?? .null)])); return ExitStatus.ok }
        var text = "menusprite \(CLIVersion.current)\n"
        if let app, let hello = try? Envelope.decode(app, as: HelloResult.self) {
            text += "\(hello.app) \(hello.version) (\(hello.build)), protocol \(hello.protocolVersion), pid \(hello.pid)\n"
        } else {
            text += "MenuSprite.app: not answering (not running, or too old for agents)\n"
        }
        console.write(text)
        return ExitStatus.ok
    }

    // MARK: - Helpers

    /// Reads a spec from a file or standard input and checks the JSON here, so a syntax slip is reported with
    /// its line and column before anything is sent.
    func loadSpec(_ source: String) throws -> JSONValue {
        let label = source == "-" ? "standard input" : source
        let data: Data
        if source == "-" { data = console.readInput() }
        else {
            guard let contents = FileManager.default.contents(atPath: absolute(source)) else { throw CommandError("Cannot read \(source).") }
            data = contents
        }
        guard !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandError("\(label) is empty; expected a sprite spec (JSON).")
        }
        do { return try JSONValue.parse(data) }
        catch let error as JSONParseError { throw CommandError("\(label): \(error.description)") }
    }

    /// The `files` of a draft spec (a file, or - for standard input), for `run --files`.
    func draftFiles(_ source: String) throws -> [String: String] {
        let spec = try loadSpec(source)
        guard let members = spec["files"]?.members else {
            throw CommandError("\(source == "-" ? "The spec on standard input" : source) has no \"files\" to run with.")
        }
        var files: [String: String] = [:]
        for member in members {
            guard let text = member.value.string else { throw CommandError("files.\(member.key) in \(source) is not text.") }
            files[member.key] = text
        }
        return files
    }

    /// A path made absolute against the caller's folder: the app runs elsewhere, so a relative path would
    /// land in the wrong place.
    func absolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? (expanded as NSString).standardizingPath
            : ((currentDirectory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    func prepareDirectory(_ path: String) throws -> String {
        let directory = absolute(path)
        do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        catch { throw CommandError("Cannot create \(directory): \(error.localizedDescription)") }
        return directory
    }

    var temporaryDirectory: URL {
        URL(fileURLWithPath: environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory(), isDirectory: true)
    }

    func freshDirectory() -> String { MCPTools.freshDirectory(in: temporaryDirectory) }

    private func emit(_ value: JSONValue) { console.write(value.serialized(pretty: true) + "\n") }

    private func line(_ text: String) -> String { text.hasSuffix("\n") ? text : text + "\n" }

    private func report(_ failure: AgentFailure, json: Bool) {
        if json { console.writeError(Envelope.failure(failure).serialized(pretty: true) + "\n"); return }
        console.writeError("menusprite: \(failure.message)\n" + Format.diagnostics(failure.diagnostics ?? []))
    }
}
