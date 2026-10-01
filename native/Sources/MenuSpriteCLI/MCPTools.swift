import AgentProtocol
import Foundation

/// The MCP tools: the CLI's verbs worded for a model. Each call opens its own socket connection. Results are
/// text an agent can act on (diagnostics as `path: message — hint`, what each value showed) plus the
/// rendered PNGs as images, so the agent sees what it built.
struct MCPTools: Sendable {
    var client: AppClient
    var temporaryDirectory: URL

    struct Tool: Sendable {
        var name: String
        var title: String
        var description: String
        /// The input JSON Schema, written as JSON so it reads like what the client receives.
        var schema: String
        var readOnly: Bool
        var destructive = false
        var idempotent = false
        /// Runs the user's own commands, which may reach anything (the network, other apps); a client may ask
        /// before such a call.
        var openWorld = false
    }

    private static let spriteProperty = #""sprite":{"type":"string","description":"The sprite's name (any case), id, or an id prefix of at least 4 characters."}"#
    private static let specProperty = #""spec":{"type":"object","description":"A sprite spec, version 1, as a JSON object: {\"menusprite\": 1, \"name\": …, \"values\": […], \"face\": …, \"rules\": […], \"board\": {…}, \"files\": {…}}. The format is in get_guide."}"#
    private static let valuesProperty = #""values":{"type":"object","description":"Stand-in values for the pictures only, by value id: {\"free\": 12, \"state\": \"Running\", \"awake\": true, \"session.pace\": \"over\"}. A number or text replaces the value (formatted as the live one would be); null draws it as missing (a failed command, to see the is-missing branch); id.pace sets a Claude/Codex limit's pace (on track, ahead, over). Use it to see each branch of your rules and each state of the board without making it happen. Values with a stand-in are not run."}"#
    private static let appearanceProperty = #""appearance":{"type":"string","enum":["dark","light","both","system"],"description":"Which menu bar and board appearance to draw: dark, light, both, or system (the Mac's current one)."}"#

    static let tools: [Tool] = [
        Tool(name: "get_guide", title: "Read the MenuSprite authoring guide",
             description: "Read this first. Returns the MenuSprite authoring guide (Markdown): the sprite spec format (values from system readings, shell commands or fixed text; the menu-bar face; rules; the board a click opens, including boards drawn from a script's JSON) with worked examples. Write specs only after reading it.",
             schema: #"{"type":"object","properties":{}}"#, readOnly: true, idempotent: true),
        Tool(name: "list_examples", title: "List example sprites",
             description: "List the example sprites that ship with MenuSprite: each one's name and what it shows. Read one with get_example and start from it.",
             schema: #"{"type":"object","properties":{}}"#, readOnly: true, idempotent: true),
        Tool(name: "get_example", title: "Read an example sprite",
             description: "Return one example sprite as a complete spec (JSON, with its files), to read or adapt and pass to apply_sprite.",
             schema: #"{"type":"object","properties":{"name":{"type":"string","description":"The example's name, as list_examples gives it."}},"required":["name"]}"#,
             readOnly: true, idempotent: true),
        Tool(name: "list_readings", title: "List system readings",
             description: "List the system readings a sprite can show (CPU, memory, network, disks, battery and power, fans and temperatures, Claude/Codex usage limits…): id, name, unit and group. Use the id as a value's \"reading\" in a spec. sample=true adds each reading's current value, or why it has none.",
             schema: #"{"type":"object","properties":{"query":{"type":"string","description":"Only readings whose id, name or group contains these words, e.g. \"battery\"."},"sample":{"type":"boolean","description":"Include each reading's current value, or why it has none (takes about a second)."}}}"#,
             readOnly: true, idempotent: true),
        Tool(name: "list_sprites", title: "List sprites",
             description: "List the user's sprites: name, id, whether it is on and shown in the menu bar, its side, whether its board is custom or the classic panel, its values, and every command it runs.",
             schema: #"{"type":"object","properties":{}}"#, readOnly: true, idempotent: true),
        Tool(name: "get_sprite", title: "Read a sprite as a spec",
             description: "Read one sprite as a spec (JSON, with the files its spec wrote; files its scripts wrote are not part of it). Start here to change an existing sprite: edit the spec and pass it to apply_sprite.",
             schema: #"{"type":"object","properties":{\#(spriteProperty)},"required":["sprite"]}"#, readOnly: true, idempotent: true),
        Tool(name: "validate_sprite", title: "Check a sprite spec",
             description: "Check a sprite spec without saving or running anything. Returns every error and warning as 'path: message — hint'.",
             schema: #"{"type":"object","properties":{\#(specProperty)},"required":["spec"]}"#, readOnly: true, idempotent: true),
        Tool(name: "apply_sprite", title: "Create or replace a sprite",
             description: "Save a sprite from a spec. It replaces the sprite with the same id, else the same name (any case), else creates a new one, and the menu bar changes at once. Returns the diagnostics, the commands the sprite will run, what each value showed, what each script block drew (or the end of its error output), and preview images of the menu-bar face and the board, drawn in both dark and light mode with live values (its commands run once to draw them). Look at the images and iterate. dry_run checks and previews without saving; values draws stand-ins instead of live values.",
             schema: #"{"type":"object","properties":{\#(specProperty),"preview":{"type":"boolean","description":"Return preview images (default true)."},"dry_run":{"type":"boolean","description":"Check and preview without saving (default false)."},\#(appearanceProperty),\#(valuesProperty)},"required":["spec"]}"#,
             readOnly: false, idempotent: true, openWorld: true),
        Tool(name: "preview_sprite", title: "Preview a sprite",
             description: "Draw a saved sprite, or a draft spec without saving it, as images: the menu-bar face (on a dark and/or light bar) and the board a click opens, with live values. Drawing runs the sprite's commands and scripts once on this Mac (a draft's files in a temporary folder). Also says what each value showed or why it has none (a failing command, an unknown reading), and what each script block drew. Give sprite or spec; values draws stand-ins instead of live values.",
             schema: #"{"type":"object","properties":{\#(spriteProperty),\#(specProperty),\#(appearanceProperty),"board":{"type":"boolean","description":"Also draw the board (default true)."},\#(valuesProperty)}}"#,
             readOnly: false, openWorld: true),
        Tool(name: "test_command", title: "Test a shell command as a value",
             description: "Run a shell command exactly as a sprite's command value would (zsh with Homebrew and the user's tool folders on PATH, a timeout, output capped) and show its output, exit status and the value it parses to. Use it to check a command, or a draft's script (with files), before putting it in a spec.",
             schema: #"{"type":"object","properties":{"command":{"type":"string","description":"The command line, run with /bin/zsh -f -c."},"parse":{"type":"string","enum":["text","number","json"],"description":"text = first line, number = first number, json = the value at path (default text)."},"path":{"type":"string","description":"With parse json: a dotted path such as data.items.0.name."},"timeout":{"type":"number","minimum":1,"maximum":60,"description":"Seconds before it is killed (default 10)."},"sprite":{"type":"string","description":"Run in this saved sprite's folder, as its own commands do (so its files are found)."},"files":{"type":"object","description":"A draft's files, as a spec's \"files\" ({\"name.py\": \"content\"}): the command runs in a temporary folder holding them, with SPRITE_DIR set, removed afterwards. Use it to try a script before the sprite is saved."}},"required":["command"]}"#,
             readOnly: false, openWorld: true),
        Tool(name: "refresh_sprite", title: "Run a sprite's commands again",
             description: "Run every command of a saved sprite again now (its values, script rows and script blocks; commands see MENUSPRITE_TRIGGER=refresh) and say what each value shows afterwards. The menu bar updates at once instead of at each value's next turn.",
             schema: #"{"type":"object","properties":{\#(spriteProperty)},"required":["sprite"]}"#, readOnly: false, openWorld: true),
        Tool(name: "set_sprite", title: "Switch, show, hide or move a sprite",
             description: "Switch a sprite on or off, show or hide it in the menu bar, or move it to the left strip or the right side, without rewriting its spec.",
             schema: #"{"type":"object","properties":{\#(spriteProperty),"enabled":{"type":"boolean","description":"On (values run, it can show) or off."},"menu_bar":{"type":"boolean","description":"Shown in the menu bar."},"side":{"type":"string","enum":["left","right"],"description":"left = the strip over the frontmost app's menus; right = beside the system items."}},"required":["sprite"]}"#,
             readOnly: false, idempotent: true),
        Tool(name: "remove_sprite", title: "Delete a sprite",
             description: "Delete a sprite; its folder of files goes to the Trash. Ask the user first.",
             schema: #"{"type":"object","properties":{\#(spriteProperty)},"required":["sprite"]}"#, readOnly: false, destructive: true),
        Tool(name: "open_board", title: "Open a sprite's board on screen",
             description: "Pop the sprite's board open on the user's screen, as if they clicked it. Use it to show the user the finished result.",
             schema: #"{"type":"object","properties":{\#(spriteProperty)},"required":["sprite"]}"#, readOnly: false, idempotent: true),
    ]

    static let names = Set(tools.map(\.name))

    static let definitions: JSONValue = .array(tools.map { tool in
        .object([
            JSONMember("name", .string(tool.name)),
            JSONMember("title", .string(tool.title)),
            JSONMember("description", .string(tool.description)),
            JSONMember("inputSchema", (try? JSONValue.parse(tool.schema)) ?? .object([JSONMember("type", "object")])),
            JSONMember("annotations", .object([
                JSONMember("title", .string(tool.title)), JSONMember("readOnlyHint", .bool(tool.readOnly)),
                JSONMember("destructiveHint", .bool(tool.destructive)), JSONMember("idempotentHint", .bool(tool.idempotent)),
                JSONMember("openWorldHint", .bool(tool.openWorld)),
            ])),
        ])
    })

    static var resources: JSONValue {
        .array([
            .object([JSONMember("uri", "menusprite://guide"), JSONMember("name", "guide"), JSONMember("title", "MenuSprite authoring guide"),
                     JSONMember("description", "How to write a sprite spec: values, face, rules and boards, with examples."), JSONMember("mimeType", "text/markdown")]),
            .object([JSONMember("uri", "menusprite://schema"), JSONMember("name", "schema"), JSONMember("title", "Sprite spec JSON Schema"),
                     JSONMember("description", "The JSON Schema of the sprite spec, version 1."), JSONMember("mimeType", "application/schema+json")]),
        ] + AgentExamples.all.map { example in
            .object([JSONMember("uri", .string(exampleURI(example.name))), JSONMember("name", .string("example-\(example.name)")),
                     JSONMember("title", .string("Example sprite: \(example.name)")), JSONMember("description", .string(example.summary)),
                     JSONMember("mimeType", "application/json")])
        })
    }

    static func exampleURI(_ name: String) -> String { "menusprite://examples/\(name)" }

    static func readResource(_ uri: String) -> JSONValue? {
        let (mimeType, text): (String, String)
        switch uri {
        case "menusprite://guide": (mimeType, text) = ("text/markdown", AgentGuide.markdown)
        case "menusprite://schema": (mimeType, text) = ("application/schema+json", (try? JSONValue.parse(SpecSchema.json).serialized(pretty: true)) ?? SpecSchema.json)
        default:
            let prefix = exampleURI("")
            guard uri.hasPrefix(prefix), let example = AgentExamples.named(String(uri.dropFirst(prefix.count))) else { return nil }
            (mimeType, text) = ("application/json", exampleText(example))
        }
        return .object([JSONMember("uri", .string(uri)), JSONMember("mimeType", .string(mimeType)), JSONMember("text", .string(text))])
    }

    /// An example's spec, pretty-printed in its own key order.
    static func exampleText(_ example: AgentExamples.Example) -> String {
        (try? JSONValue.parse(example.json).serialized(pretty: true)) ?? example.json
    }

    /// A new folder for one render's PNGs. They are left for the system to clean from the temporary folder, so
    /// the paths in a result stay valid while the agent works.
    static func freshDirectory(in temporary: URL) -> String {
        temporary.appendingPathComponent("menusprite-preview-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true).path
    }

    // MARK: - Calls

    /// What a call returns: text, then the images in the order the text lists them.
    struct Output {
        var text: String
        var images: [String] = []
        var isError = false

        static func failure(_ failure: AgentFailure) -> Output {
            Output(text: failure.message + "\n" + Format.diagnostics(failure.diagnostics ?? []), isError: true)
        }

        var json: JSONValue {
            var content: [JSONValue] = []
            var text = self.text
            var images: [JSONValue] = []
            for path in self.images {
                guard let data = FileManager.default.contents(atPath: path) else { text += "(Could not read \(path).)\n"; continue }
                images.append(.object([JSONMember("type", "image"), JSONMember("data", .string(data.base64EncodedString())), JSONMember("mimeType", "image/png")]))
            }
            content.append(.object([JSONMember("type", "text"), JSONMember("text", .string(text.trimmingCharacters(in: .newlines)))]))
            content += images
            return .object([JSONMember("content", .array(content)), JSONMember("isError", .bool(isError))])
        }
    }

    func call(_ name: String, _ arguments: JSONValue) -> JSONValue {
        let output: Output
        do {
            let arguments = ToolArguments(value: arguments)
            switch name {
            case "get_guide": output = Output(text: AgentGuide.markdown)
            case "list_examples": output = Output(text: Format.examples(AgentExamples.all))
            case "get_example":
                let name = try arguments.string("name")
                guard let example = AgentExamples.named(name) else { throw Self.unknownExample(name) }
                output = Output(text: Self.exampleText(example))
            case "list_readings": output = try listReadings(arguments)
            case "list_sprites":
                let sprites = try Envelope.decode(try client.result(.list), as: ListResult.self).sprites
                output = Output(text: sprites.isEmpty ? "No sprites yet." : Format.sprites(sprites) + commandList(sprites))
            case "get_sprite":
                let raw = try client.result(.get, try Envelope.arguments(SpriteReference(sprite: try arguments.string("sprite"))))
                let notes = (try? Envelope.decode(raw, as: GetResult.self).notes) ?? nil
                output = Output(text: (raw["spec"] ?? raw).serialized(pretty: true) + "\n" + Format.notes(notes ?? []))
            case "validate_sprite":
                let raw = try client.result(.validate, try Envelope.arguments(SpecArgs(spec: .null), spec: try arguments.spec()))
                let result = try Envelope.decode(raw, as: ValidateResult.self)
                output = Output(text: (result.valid ? "Valid.\n" : "Not valid.\n") + Format.diagnostics(result.diagnostics), isError: !result.valid)
            case "apply_sprite": output = try apply(arguments)
            case "preview_sprite": output = try preview(arguments)
            case "test_command": output = try testCommand(arguments)
            case "refresh_sprite":
                let sprite = try arguments.string("sprite")
                let raw = try client.result(.refresh, try Envelope.arguments(SpriteReference(sprite: sprite)), timeout: AppClient.renderTimeout)
                output = Output(text: Format.refresh(try Envelope.decode(raw, as: RefreshResult.self), sprite: sprite))
            case "set_sprite": output = try set(arguments)
            case "remove_sprite":
                let raw = try client.result(.remove, try Envelope.arguments(SpriteReference(sprite: try arguments.string("sprite"))))
                output = Output(text: "Removed \(try Envelope.decode(raw, as: RemoveResult.self).removed).")
            case "open_board":
                let raw = try client.result(.open, try Envelope.arguments(SpriteReference(sprite: try arguments.string("sprite"))))
                let result = try Envelope.decode(raw, as: OpenResult.self)
                output = Output(text: result.message, isError: !result.opened)
            default: output = Output(text: "Unknown tool \(name).", isError: true)
            }
        } catch let failure as AgentFailure {
            output = .failure(failure)
        } catch {
            output = Output(text: "\(error)", isError: true)
        }
        return output.json
    }

    private func listReadings(_ arguments: ToolArguments) throws -> Output {
        let query = try arguments.optionalString("query")
        let args = ReadingsArgs(query: query, sample: try arguments.bool("sample"))
        let result = try Envelope.decode(try client.result(.readings, try Envelope.arguments(args)), as: ReadingsResult.self)
        return Output(text: result.readings.isEmpty ? "No readings match “\(query ?? "")”." : Format.readings(result.readings, sampled: result.sampled == true))
    }

    private func apply(_ arguments: ToolArguments) throws -> Output {
        let spec = try arguments.spec()
        let dryRun = try arguments.bool("dry_run") ?? false
        // Both appearances unless asked otherwise: a colour that reads well on a dark bar can wash out on a
        // light one, and an agent looks only at the pictures it is given.
        let appearance = try appearance(arguments) ?? "both"
        let values = try arguments.values()
        let raw = try client.result(.apply, try Envelope.arguments(SpecArgs(spec: .null, dryRun: dryRun ? true : nil), spec: spec))
        let result = try Envelope.decode(raw, as: ApplyResult.self)
        let hasErrors = result.diagnostics.contains { $0.severity == .error }
        let isError = hasErrors || !(result.saved || dryRun)
        guard try arguments.bool("preview") ?? true, result.saved || (dryRun && !hasErrors) else {
            return Output(text: Format.apply(result, dryRun: dryRun), isError: isError)
        }
        do {
            let render = try render(RenderArgs(sprite: dryRun ? nil : result.sprite.id, directory: Self.freshDirectory(in: temporaryDirectory),
                                               appearance: appearance, values: values),
                                    spec: dryRun ? Optional(spec) : nil)
            return Output(text: Format.apply(result, dryRun: dryRun, failedBlocks: render.failedBlocks.count) + Format.render(render),
                          images: render.files.map(\.path), isError: isError)
        } catch let failure as AgentFailure {
            return Output(text: Format.apply(result, dryRun: dryRun) + "The preview failed: \(failure.message)\n" + Format.diagnostics(failure.diagnostics ?? []),
                          isError: isError)
        }
    }

    private func preview(_ arguments: ToolArguments) throws -> Output {
        let sprite = try arguments.optionalString("sprite")
        let hasSpec = arguments.value["spec"].map { !$0.isNull } ?? false
        guard (sprite != nil) != hasSpec else { throw AgentFailure(.badRequest, "Give either sprite (a saved sprite) or spec (a draft), not both or neither.") }
        let args = RenderArgs(sprite: sprite, directory: Self.freshDirectory(in: temporaryDirectory), appearance: try appearance(arguments),
                              board: try arguments.bool("board"), values: try arguments.values())
        let result = try render(args, spec: hasSpec ? Optional(try arguments.spec()) : nil)
        return Output(text: Format.render(result, headline: true), images: result.files.map(\.path))
    }

    private func appearance(_ arguments: ToolArguments) throws -> String? {
        let appearance = try arguments.optionalString("appearance")?.lowercased()
        if let appearance, !["dark", "light", "both", "system"].contains(appearance) { throw AgentFailure(.badRequest, "appearance is dark, light, both or system.") }
        return appearance
    }

    private func render(_ args: RenderArgs, spec: JSONValue?) throws -> RenderResult {
        try FileManager.default.createDirectory(atPath: args.directory, withIntermediateDirectories: true)
        let raw = try client.result(.render, try Envelope.arguments(args, spec: spec), timeout: AppClient.renderTimeout)
        return try Envelope.decode(raw, as: RenderResult.self)
    }

    private func testCommand(_ arguments: ToolArguments) throws -> Output {
        let parse = try arguments.optionalString("parse")
        if let parse, !["text", "number", "json"].contains(parse) { throw AgentFailure(.badRequest, "parse is text, number or json.") }
        let timeout = try arguments.number("timeout")
        let args = RunArgs(command: try arguments.string("command"), parse: parse, path: try arguments.optionalString("path"),
                           timeout: timeout, sprite: try arguments.optionalString("sprite"), files: try arguments.files())
        let raw = try client.result(.run, try Envelope.arguments(args), timeout: max(AppClient.standardTimeout, (timeout ?? 10) + 20))
        return Output(text: Format.run(try Envelope.decode(raw, as: RunResult.self), forMCP: true))
    }

    static func unknownExample(_ name: String) -> AgentFailure {
        let names = AgentExamples.all.map(\.name)
        return AgentFailure(.notFound, "No example is called “\(name)”. " + (names.isEmpty ? "No examples are built in." : "Examples: \(names.joined(separator: ", "))."))
    }

    private func set(_ arguments: ToolArguments) throws -> Output {
        let side = try arguments.optionalString("side")?.lowercased()
        if let side, side != "left", side != "right" { throw AgentFailure(.badRequest, "side is left or right.") }
        let args = SetArgs(sprite: try arguments.string("sprite"), enabled: try arguments.bool("enabled"), menuBar: try arguments.bool("menu_bar"), side: side)
        guard args.enabled != nil || args.menuBar != nil || args.side != nil else {
            throw AgentFailure(.badRequest, "Nothing to change: give enabled, menu_bar or side.")
        }
        let raw = try client.result(.set, try Envelope.arguments(args))
        return Output(text: Format.sprite(try Envelope.decode(raw, as: SpriteResult.self).sprite))
    }

    private func commandList(_ sprites: [SpriteSummary]) -> String {
        let lines = sprites.filter { !$0.commands.isEmpty }.map { "  \($0.name): " + $0.commands.joined(separator: " · ") + "\n" }
        return lines.isEmpty ? "" : "Commands:\n" + lines.joined()
    }
}

/// A tool call's arguments, read leniently: models sometimes send `"true"` for true, `"5"` for 5, or a spec
/// as a JSON string, and refusing those only costs a round trip.
struct ToolArguments {
    var value: JSONValue

    func string(_ key: String) throws -> String {
        guard let text = try optionalString(key), !text.isEmpty else { throw AgentFailure(.badRequest, "“\(key)” is required.") }
        return text
    }

    func optionalString(_ key: String) throws -> String? {
        switch value[key] {
        case nil, .null?: return nil
        case .string(let text)?: return text
        case .number(let number)?: return JSONValue.number(number).serialized()
        case let other?: throw AgentFailure(.badRequest, "“\(key)” should be text, not \(other.typeName).")
        }
    }

    func bool(_ key: String) throws -> Bool? {
        switch value[key] {
        case nil, .null?: return nil
        case .bool(let flag)?: return flag
        case .string(let text)? where ["true", "false"].contains(text.lowercased()): return text.lowercased() == "true"
        case let other?: throw AgentFailure(.badRequest, "“\(key)” should be true or false, not \(other.typeName).")
        }
    }

    func number(_ key: String) throws -> Double? {
        switch value[key] {
        case nil, .null?: return nil
        case .number(let number)?: return number
        case .string(let text)? where Double(text) != nil: return Double(text)
        case let other?: throw AgentFailure(.badRequest, "“\(key)” should be a number, not \(other.typeName).")
        }
    }

    /// Stand-in values by value id: an object, or a JSON string holding one.
    func values(_ key: String = "values") throws -> JSONValue? {
        switch value[key] {
        case nil, .null?: return nil
        case .object?: return value[key]
        case .string(let text)?:
            guard let parsed = try? JSONValue.parse(text), case .object = parsed else {
                throw AgentFailure(.badRequest, "“\(key)” is an object of stand-in values by value id, such as {\"free\": 12}.")
            }
            return parsed
        case let other?: throw AgentFailure(.badRequest, "“\(key)” is an object of stand-in values by value id, not \(other.typeName).")
        }
    }

    /// A draft's files: `{"name": "content"}`, a JSON string holding that, or a whole spec (its `files` are used).
    func files(_ key: String = "files") throws -> [String: String]? {
        var object: JSONValue
        switch value[key] {
        case nil, .null?: return nil
        case .object?: object = value[key]!
        case .string(let text)?:
            guard let parsed = try? JSONValue.parse(text), case .object = parsed else {
                throw AgentFailure(.badRequest, "“\(key)” is an object of file names and their text, as a spec's \"files\".")
            }
            object = parsed
        case let other?: throw AgentFailure(.badRequest, "“\(key)” is an object of file names and their text, not \(other.typeName).")
        }
        if object["menusprite"] != nil, let inner = object["files"] { object = inner }
        var files: [String: String] = [:]
        for member in object.members ?? [] {
            guard let text = member.value.string else {
                throw AgentFailure(.badRequest, "“\(key).\(member.key)” should be the file's text, not \(member.value.typeName).")
            }
            files[member.key] = text
        }
        return files
    }

    /// The spec object, or a JSON string holding one (checked here, with its line and column).
    func spec(_ key: String = "spec") throws -> JSONValue {
        switch value[key] {
        case nil, .null?: throw AgentFailure(.badRequest, "“\(key)” is required: the sprite spec as a JSON object (see get_guide).")
        case .object?: return value[key]!
        case .string(let text)?:
            do {
                let parsed = try JSONValue.parse(text)
                guard case .object = parsed else { throw AgentFailure(.badRequest, "“\(key)” must be a JSON object (the sprite spec), not \(parsed.typeName).") }
                return parsed
            } catch let error as JSONParseError {
                throw AgentFailure(.invalidSpec, "“\(key)” is text that is not valid JSON. \(error.description). Pass the spec as a JSON object.")
            }
        case let other?: throw AgentFailure(.badRequest, "“\(key)” must be a JSON object (the sprite spec), not \(other.typeName).")
        }
    }
}
