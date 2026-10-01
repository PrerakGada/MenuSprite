import Foundation

/// The conversation between the `menusprite` command (and its MCP server) and the running app.
///
/// One request per connection over a Unix socket the app owns: a compact JSON object and a newline,
/// answered the same way. The app is the only writer of the saved sprites, so every change goes
/// through it. Spec: `docs/agent-authoring.md`.
public enum AgentProtocolVersion {
    public static let current = 1
}

public enum AgentOp: String, Codable, Sendable, CaseIterable {
    case hello, readings, list, get, validate, apply, remove, set, run, render, open, refresh
}

public struct AgentRequest: Codable, Sendable {
    public var v: Int
    public var op: AgentOp
    public var args: JSONValue
    public init(_ op: AgentOp, args: JSONValue = .object([])) { v = AgentProtocolVersion.current; self.op = op; self.args = args }
    public init<T: Encodable>(_ op: AgentOp, _ args: T) throws { self.init(op, args: try JSONValue(encoding: args)) }
}

// Foundation's JSONEncoder and JSONDecoder do not keep object key order, so the wire form of a request and
// a response is built member by member: a spec an agent wrote, or one read back, keeps its order end to end.
extension AgentRequest {
    public var envelope: JSONValue {
        .object([JSONMember("v", .number(Double(v))), JSONMember("op", .string(op.rawValue)), JSONMember("args", args)])
    }
}

extension AgentResponse {
    public init(envelope: JSONValue) throws {
        guard envelope.members != nil else { throw AgentFailure(.internalError, "The answer is not a JSON object.") }
        ok = envelope["ok"]?.bool ?? false
        result = envelope["result"].flatMap { $0.isNull ? Optional<JSONValue>.none : $0 }
        error = try envelope["error"].flatMap { $0.isNull ? nil : try $0.decode(AgentFailure.self) }
        if !ok && error == nil { error = AgentFailure(.internalError, "The app reported a failure without saying why.") }
    }
}

public struct AgentResponse: Codable, Sendable {
    public var ok: Bool
    public var result: JSONValue?
    public var error: AgentFailure?
    public init(result: JSONValue) { ok = true; self.result = result; error = nil }
    public init<T: Encodable>(encoding value: T) throws { self.init(result: try JSONValue(encoding: value)) }
    public init(error: AgentFailure) { ok = false; result = nil; self.error = error }

    /// The result as `T`, or the failure thrown.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if let error { throw error }
        guard let result else { throw AgentFailure(.internalError, "The app sent an empty answer.") }
        return try result.decode(T.self)
    }
}

public struct AgentFailure: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        /// The spec has errors; `diagnostics` says where.
        case invalidSpec
        /// No sprite matches the reference, or more than one does.
        case notFound, ambiguous
        case badRequest
        /// The app is not running and could not be started, or did not answer.
        case unavailable
        case internalError
    }
    public var code: Code
    public var message: String
    public var diagnostics: [SpecDiagnostic]?
    public init(_ code: Code, _ message: String, diagnostics: [SpecDiagnostic]? = nil) {
        self.code = code; self.message = message; self.diagnostics = diagnostics
    }
    public var description: String { message }
}

/// One finding about a spec. `path` points into the document the agent wrote, in the form
/// `board.blocks[2].button`; `hint` suggests the fix ("did you mean cpu.usage?").
public struct SpecDiagnostic: Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public var severity: Severity
    public var path: String
    public var message: String
    public var hint: String?
    public init(_ severity: Severity, _ path: String, _ message: String, hint: String? = nil) {
        self.severity = severity; self.path = path; self.message = message; self.hint = hint
    }
    public static func error(_ path: String, _ message: String, hint: String? = nil) -> Self { .init(.error, path, message, hint: hint) }
    public static func warning(_ path: String, _ message: String, hint: String? = nil) -> Self { .init(.warning, path, message, hint: hint) }
    public var description: String {
        "\(severity.rawValue): \(path.isEmpty ? "(spec)" : path): \(message)" + (hint.map { " — \($0)" } ?? "")
    }
}

// MARK: - Operations

/// `hello`: who is answering.
public struct HelloResult: Codable, Sendable {
    public var app: String
    public var version: String
    public var build: String
    public var protocolVersion: Int
    public var pid: Int32
    public init(app: String, version: String, build: String, protocolVersion: Int = AgentProtocolVersion.current, pid: Int32) {
        self.app = app; self.version = version; self.build = build; self.protocolVersion = protocolVersion; self.pid = pid
    }
}

/// `get`, `remove`, `open`: one sprite by name (case-insensitive), id, or an id prefix of 4+ characters.
public struct SpriteReference: Codable, Sendable {
    public var sprite: String
    public init(sprite: String) { self.sprite = sprite }
}

/// `readings`: the catalog, optionally filtered, and optionally sampled once so every value is current.
public struct ReadingsArgs: Codable, Sendable {
    public var query: String?
    public var sample: Bool?
    public init(query: String? = nil, sample: Bool? = nil) { self.query = query; self.sample = sample }
}

public struct ReadingInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var short: String
    public var group: String
    public var unit: String
    /// The current value as the menu bar would write it, when one has been sampled.
    public var value: String?
    public var number: Double?
    public var detail: String?
    /// Why a sampled reading has no value now ("Not signed in.", "No battery"), so a blank is never silent.
    public var problem: String?
    public init(id: String, name: String, short: String, group: String, unit: String, value: String? = nil, number: Double? = nil,
                detail: String? = nil, problem: String? = nil) {
        self.id = id; self.name = name; self.short = short; self.group = group; self.unit = unit
        self.value = value; self.number = number; self.detail = detail; self.problem = problem
    }
}

public struct ReadingsResult: Codable, Sendable {
    public var readings: [ReadingInfo]
    /// True when the readings were sampled for this answer, so a reading without a value is a problem
    /// worth showing rather than one nobody asked about.
    public var sampled: Bool?
    public init(readings: [ReadingInfo], sampled: Bool? = nil) { self.readings = readings; self.sampled = sampled }
}

/// A saved sprite at a glance.
public struct SpriteSummary: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var icon: String
    public var enabled: Bool
    public var menuBar: Bool
    /// "left" or "right".
    public var side: String
    /// "custom" for a designed board, "classic" for the built-in panel.
    public var board: String
    /// The ids of its values.
    public var values: [String]
    /// Every command the sprite runs: values, script blocks, buttons and toggles.
    public var commands: [String]
    public init(id: String, name: String, icon: String, enabled: Bool, menuBar: Bool, side: String, board: String, values: [String], commands: [String]) {
        self.id = id; self.name = name; self.icon = icon; self.enabled = enabled; self.menuBar = menuBar
        self.side = side; self.board = board; self.values = values; self.commands = commands
    }
}

public struct ListResult: Codable, Sendable {
    public var sprites: [SpriteSummary]
    public init(sprites: [SpriteSummary]) { self.sprites = sprites }
}

public struct GetResult: Codable, Sendable {
    public var spec: JSONValue
    /// Files in the sprite's folder the spec does not carry, and why (a script's own output, too large).
    public var notes: [String]?
    public init(spec: JSONValue, notes: [String]? = nil) { self.spec = spec; self.notes = notes }
}

public struct SpecArgs: Codable, Sendable {
    public var spec: JSONValue
    /// Apply only: check and report without saving.
    public var dryRun: Bool?
    public init(spec: JSONValue, dryRun: Bool? = nil) { self.spec = spec; self.dryRun = dryRun }
}

public struct ValidateResult: Codable, Sendable {
    public var valid: Bool
    public var diagnostics: [SpecDiagnostic]
    /// The spec as it would be saved and read back (defaults dropped, colours normalised), when valid.
    public var spec: JSONValue?
    public init(valid: Bool, diagnostics: [SpecDiagnostic], spec: JSONValue?) { self.valid = valid; self.diagnostics = diagnostics; self.spec = spec }
}

public struct ApplyResult: Codable, Sendable {
    public var created: Bool
    public var saved: Bool
    public var sprite: SpriteSummary
    public var diagnostics: [SpecDiagnostic]
    public var spec: JSONValue
    public init(created: Bool, saved: Bool, sprite: SpriteSummary, diagnostics: [SpecDiagnostic], spec: JSONValue) {
        self.created = created; self.saved = saved; self.sprite = sprite; self.diagnostics = diagnostics; self.spec = spec
    }
}

/// `set`: switches that do not need a whole spec.
public struct SetArgs: Codable, Sendable {
    public var sprite: String
    public var enabled: Bool?
    public var menuBar: Bool?
    /// "left" or "right".
    public var side: String?
    public init(sprite: String, enabled: Bool? = nil, menuBar: Bool? = nil, side: String? = nil) {
        self.sprite = sprite; self.enabled = enabled; self.menuBar = menuBar; self.side = side
    }
}

public struct SpriteResult: Codable, Sendable {
    public var sprite: SpriteSummary
    public init(sprite: SpriteSummary) { self.sprite = sprite }
}

public struct RemoveResult: Codable, Sendable {
    public var removed: String
    public init(removed: String) { self.removed = removed }
}

/// `run`: a command exactly as a value would run it.
public struct RunArgs: Codable, Sendable {
    public var command: String
    /// "text", "number" or "json".
    public var parse: String?
    public var path: String?
    public var timeout: Double?
    /// Run inside this sprite's folder, as its own commands do.
    public var sprite: String?
    /// Run inside a temporary folder holding these files (a draft spec's `files`), with `SPRITE_DIR` set.
    public var files: [String: String]?
    public init(command: String, parse: String? = nil, path: String? = nil, timeout: Double? = nil, sprite: String? = nil,
                files: [String: String]? = nil) {
        self.command = command; self.parse = parse; self.path = path; self.timeout = timeout; self.sprite = sprite; self.files = files
    }
}

public struct RunResult: Codable, Sendable {
    public var text: String?
    public var number: Double?
    public var output: String
    public var error: String
    public var status: Int32?
    /// Why there is no value: a timeout, a non-zero exit, output that did not parse.
    public var problem: String?
    public var elapsed: Double
    public init(text: String?, number: Double?, output: String, error: String, status: Int32?, problem: String?, elapsed: Double) {
        self.text = text; self.number = number; self.output = output; self.error = error
        self.status = status; self.problem = problem; self.elapsed = elapsed
    }
}

/// `render`: a saved sprite, or a draft spec that is not saved, drawn to PNG files in `directory`.
public struct RenderArgs: Codable, Sendable {
    public var sprite: String?
    public var spec: JSONValue?
    public var directory: String
    /// "dark", "light", "both" or "system" (default).
    public var appearance: String?
    public var face: Bool?
    public var board: Bool?
    /// Pixels per point (default 2).
    public var scale: Double?
    /// Stand-in values to draw instead of live ones, by value id: `{"free": 12, "session.pace": "over",
    /// "state": "Running"}`. Lets an agent see each branch of its rules without making it happen.
    public var values: JSONValue?
    public init(sprite: String? = nil, spec: JSONValue? = nil, directory: String, appearance: String? = nil,
                face: Bool? = nil, board: Bool? = nil, scale: Double? = nil, values: JSONValue? = nil) {
        self.sprite = sprite; self.spec = spec; self.directory = directory; self.appearance = appearance
        self.face = face; self.board = board; self.scale = scale; self.values = values
    }
}

public struct RenderedFile: Codable, Sendable, Equatable {
    /// "face" or "board".
    public var kind: String
    /// "dark" or "light".
    public var appearance: String
    public var path: String
    public var width: Int
    public var height: Int
    public init(kind: String, appearance: String, path: String, width: Int, height: Int) {
        self.kind = kind; self.appearance = appearance; self.path = path; self.width = width; self.height = height
    }
}

/// What a value showed when it was drawn, so an agent can tell a blank from a failing command.
public struct ValueState: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var value: String?
    public var problem: String?
    public init(id: String, name: String, value: String?, problem: String?) { self.id = id; self.name = name; self.value = value; self.problem = problem }
}

public struct RenderResult: Codable, Sendable {
    public var files: [RenderedFile]
    public var values: [ValueState]
    public var diagnostics: [SpecDiagnostic]
    /// Things worth knowing about the picture: a block whose command failed, a board that is the classic panel.
    public var notes: [String]
    /// Every board block that runs a command (script rows, script blocks): whether it drew, and what it drew.
    public var blocks: [BlockReport]?
    public init(files: [RenderedFile], values: [ValueState], diagnostics: [SpecDiagnostic], notes: [String], blocks: [BlockReport]? = nil) {
        self.files = files; self.values = values; self.diagnostics = diagnostics; self.notes = notes; self.blocks = blocks
    }
    /// The blocks whose command failed or whose output could not be drawn.
    public var failedBlocks: [BlockReport] { (blocks ?? []).filter { $0.problem != nil } }
}

/// One script-rows or script-blocks block as a render found it: where it is in the spec, why it did not
/// draw, and what its rows and buttons do, so links and commands can be checked without clicking.
public struct BlockReport: Codable, Sendable, Equatable {
    /// Where the block is in the spec: `board.blocks[2]`, `board.blocks[1].card[0]`.
    public var path: String
    /// "script" or "blocks".
    public var kind: String
    public var command: String
    /// Why it drew nothing (or only an error): the exit status, a timeout, output that is not blocks.
    public var problem: String?
    /// The last lines the command wrote to standard error, where a traceback ends in its exception.
    public var stderr: String?
    /// What it drew, one line per row or actionable block: `“#12 Fix login” → https://…`, `“Restart” runs …`.
    public var rows: [String]?
    public init(path: String, kind: String, command: String, problem: String? = nil, stderr: String? = nil, rows: [String]? = nil) {
        self.path = path; self.kind = kind; self.command = command; self.problem = problem; self.stderr = stderr; self.rows = rows
    }
}

/// `refresh`: a sprite's commands run again now (a script that finished a long job can call
/// `menusprite refresh <sprite>`), and what its values show afterwards.
public struct RefreshResult: Codable, Sendable {
    public var values: [ValueState]
    public init(values: [ValueState]) { self.values = values }
}

public struct OpenResult: Codable, Sendable {
    public var opened: Bool
    public var message: String
    public init(opened: Bool, message: String) { self.opened = opened; self.message = message }
}
