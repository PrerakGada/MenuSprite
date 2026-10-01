import AgentProtocol
import Foundation

/// `menusprite mcp`: the Model Context Protocol over stdio. JSON-RPC 2.0, one message per line; only protocol
/// messages ever reach standard output. Nothing touches the app until a tool needs it, so an agent that
/// starts the server but never builds a sprite never starts MenuSprite.
final class MCPServer: @unchecked Sendable {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let preferredVersion = "2025-06-18"

    static let instructions = """
        MenuSprite is a native macOS menu-bar app. Each menu-bar item is a sprite: a small face in the menu bar plus \
        a board, the panel a click opens. Sprites show system readings (CPU, memory, battery, network, fans, AI usage \
        limits…) and the output of the user's own shell commands and CLI tools; a board can be a whole dashboard drawn \
        from a script's JSON. These tools create and change sprites for the user without editing any code: MenuSprite \
        handles permissions, scheduling, resource limits and rendering; you design the experience. \
        Call get_guide once before writing a spec and follow it; list_examples and get_example give complete sprites \
        to start from. Then: find reading ids with list_readings, try shell commands and draft scripts with \
        test_command (files runs a draft's scripts before saving), write the spec, save it with apply_sprite (it \
        returns diagnostics, what each value and script block showed, and preview images in dark and light mode), \
        look at the images and iterate until it is right. Pass values (stand-ins such as {"free": 12}) to \
        apply_sprite or preview_sprite to see each branch of your rules without making it happen. To change an \
        existing sprite, get_sprite it, edit the spec and apply_sprite it again. Ask the user before remove_sprite.
        """

    let tools: MCPTools
    let version: String
    private let lock = NSLock()
    private var cancelled: Set<JSONValue> = []

    init(tools: MCPTools, version: String) {
        self.tools = tools
        self.version = version
    }

    /// Reads messages until the input ends, answering each. Tool calls and resource reads run concurrently,
    /// so a ping is not stuck behind a slow preview; when the input ends, calls still in flight finish and are
    /// answered before this returns (so `printf … | menusprite mcp` works).
    ///
    /// Every answer goes out whole, one at a time: a preview's images run to megabytes, a pipe takes at most
    /// 64 KiB per write, and two answers written at once from different threads would interleave mid-line
    /// and leave the client a stream it cannot parse.
    func serve(readLine: () -> String?, write unguarded: @escaping @Sendable (String) -> Void) {
        let writing = NSLock()
        let write: @Sendable (String) -> Void = { message in writing.withLock { unguarded(message) } }
        let group = DispatchGroup()
        while let line = readLine() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let message: JSONValue
            do { message = try JSONValue.parse(text) }
            catch {
                write(Self.failure(id: .null, code: -32700, "Parse error: \(error)").serialized())
                continue
            }
            if case .array(let batch) = message {
                // JSON-RPC batches (protocol 2025-03-26) are answered together, in order.
                let answers = batch.compactMap { handle($0) }
                if !answers.isEmpty { write(JSONValue.array(answers).serialized()) }
                continue
            }
            let method = message["method"]?.string
            if message["id"] != nil, method == "tools/call" || method == "resources/read" {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    if let answer = self.handle(message), !self.wasCancelled(message["id"]) { write(answer.serialized()) }
                }
            } else if let answer = handle(message) {
                write(answer.serialized())
            }
        }
        group.wait()
    }

    /// One message's answer, or nil for a notification (or a stray response, since this server sends no requests).
    func handle(_ message: JSONValue) -> JSONValue? {
        guard case .object = message else { return Self.failure(id: .null, code: -32600, "Invalid request: expected an object.") }
        let id = message["id"]
        guard let method = message["method"]?.string else {
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.failure(id: id ?? .null, code: -32600, "Invalid request: no method.")
        }
        let params = message["params"] ?? .object([])
        guard let id else {
            if method == "notifications/cancelled", let request = params["requestId"] {
                lock.withLock { _ = cancelled.insert(request) }
            }
            return nil
        }
        switch method {
        case "initialize":
            return Self.success(id: id, initialize(params))
        case "ping":
            return Self.success(id: id, .object([]))
        case "tools/list":
            return Self.success(id: id, .object([JSONMember("tools", MCPTools.definitions)]))
        case "tools/call":
            guard let name = params["name"]?.string else { return Self.failure(id: id, code: -32602, "tools/call needs a tool name.") }
            guard MCPTools.names.contains(name) else { return Self.failure(id: id, code: -32602, "Unknown tool: \(name).") }
            return Self.success(id: id, tools.call(name, params["arguments"] ?? .object([])))
        case "resources/list":
            return Self.success(id: id, .object([JSONMember("resources", MCPTools.resources)]))
        case "resources/templates/list":
            return Self.success(id: id, .object([JSONMember("resourceTemplates", .array([]))]))
        case "resources/read":
            guard let uri = params["uri"]?.string, let contents = MCPTools.readResource(uri) else {
                return Self.failure(id: id, code: -32002, "Resource not found: \(params["uri"]?.string ?? "(no uri)").")
            }
            return Self.success(id: id, .object([JSONMember("contents", .array([contents]))]))
        case "prompts/list":
            return Self.success(id: id, .object([JSONMember("prompts", .array([]))]))
        default:
            return Self.failure(id: id, code: -32601, "Method not found: \(method).")
        }
    }

    /// The client's protocol version when this server speaks it, else the one it prefers; the client then
    /// decides whether it can go on.
    static func negotiate(_ requested: String?) -> String {
        requested.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? preferredVersion
    }

    private func initialize(_ params: JSONValue) -> JSONValue {
        .object([
            JSONMember("protocolVersion", .string(Self.negotiate(params["protocolVersion"]?.string))),
            JSONMember("capabilities", .object([
                JSONMember("tools", .object([JSONMember("listChanged", false)])),
                JSONMember("resources", .object([JSONMember("subscribe", false), JSONMember("listChanged", false)])),
            ])),
            JSONMember("serverInfo", .object([JSONMember("name", "menusprite"), JSONMember("title", "MenuSprite"), JSONMember("version", .string(version))])),
            JSONMember("instructions", .string(Self.instructions)),
        ])
    }

    private func wasCancelled(_ id: JSONValue?) -> Bool {
        guard let id else { return false }
        return lock.withLock { cancelled.remove(id) != nil }
    }

    static func success(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object([JSONMember("jsonrpc", "2.0"), JSONMember("id", id), JSONMember("result", result)])
    }

    static func failure(id: JSONValue, code: Int, _ message: String) -> JSONValue {
        .object([JSONMember("jsonrpc", "2.0"), JSONMember("id", id),
                 JSONMember("error", .object([JSONMember("code", .number(Double(code))), JSONMember("message", .string(message))]))])
    }
}
