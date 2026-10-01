import AgentProtocol
import Darwin
import Foundation

/// Talks to the running app over its socket (one request per connection), starting the app first when
/// nothing answers. The app is the only writer of the saved sprites, so every change goes through it.
struct AppClient: Sendable {
    enum LaunchOutcome: Sendable, Equatable { case started, notInstalled, failed(String) }

    static let bundleIdentifier = "in.prerakgada.MenuSprite"
    static let installHint = "Install it with: brew install --cask prerakgada/tap/menusprite"
    static let standardTimeout: TimeInterval = 30
    /// A render samples the readings and runs every command once before drawing, so it gets far longer.
    static let renderTimeout: TimeInterval = 90

    var socketPath: String
    /// False when `MENUSPRITE_SOCKET` names the socket: a sandbox or a test, where starting the real app
    /// would add items to the person's menu bar.
    var mayLaunch: Bool
    var launch: @Sendable () -> LaunchOutcome
    var startupLimit: TimeInterval = 15
    var pollInterval: TimeInterval = 0.25

    init(environment: [String: String], launch: @escaping @Sendable () -> LaunchOutcome = AppClient.openApp) {
        if let override = environment["MENUSPRITE_SOCKET"], !override.isEmpty {
            socketPath = override
            mayLaunch = false
        } else {
            socketPath = AgentSocket.supportDirectory.appendingPathComponent("agent.sock").path
            mayLaunch = true
        }
        self.launch = launch
    }

    /// Sends one request and returns its result, or throws the app's failure.
    func result(_ op: AgentOp, _ args: JSONValue = .object([]), timeout: TimeInterval = AppClient.standardTimeout,
                launchIfNeeded: Bool = true) throws -> JSONValue {
        let body = Envelope.request(op, args).serialized()
        guard body.utf8.count < AgentSocket.messageLimit else {
            throw AgentFailure(.badRequest, "The request is larger than \(AgentSocket.messageLimit / 1024 / 1024) MiB; keep a sprite's files smaller.")
        }
        let descriptor = try connection(launchIfNeeded: launchIfNeeded)
        defer { close(descriptor) }
        try AgentSocket.writeAll(descriptor, Data((body + "\n").utf8), timeout: timeout)
        let reply = try AgentSocket.readMessage(descriptor, timeout: timeout)
        let parsed: JSONValue
        do { parsed = try JSONValue.parse(reply) }
        catch { throw AgentFailure(.internalError, "MenuSprite's answer could not be read: \(error)") }
        return try Envelope.result(of: parsed)
    }

    /// A connected socket. When nothing answers, starts the app (unless this is a sandbox) and keeps trying
    /// every `pollInterval` for up to `startupLimit`; the connection that succeeds is the one used, so
    /// waiting costs no extra connections the app would have to answer.
    func connection(launchIfNeeded: Bool = true) throws -> Int32 {
        if let descriptor = try? AgentSocket.connect(path: socketPath) { return descriptor }
        guard launchIfNeeded else { throw AgentFailure(.unavailable, "MenuSprite is not running.") }
        guard mayLaunch else {
            throw AgentFailure(.unavailable, "Nothing is answering at \(socketPath). MENUSPRITE_SOCKET is set, so MenuSprite is not started automatically.")
        }
        switch launch() {
        case .started: break
        case .notInstalled: throw AgentFailure(.unavailable, "MenuSprite is not installed. \(Self.installHint)")
        case .failed(let reason): throw AgentFailure(.unavailable, "MenuSprite could not be started: \(reason)")
        }
        let deadline = Date().addingTimeInterval(startupLimit)
        repeat {
            Thread.sleep(forTimeInterval: pollInterval)
            if let descriptor = try? AgentSocket.connect(path: socketPath) { return descriptor }
        } while Date() < deadline
        throw AgentFailure(.unavailable, """
            MenuSprite is running but not answering at \(socketPath) after \(Int(startupLimit)) s. This needs a MenuSprite \
            with agent support: update it (brew upgrade --cask prerakgada/tap/menusprite), or quit and reopen it.
            """)
    }

    /// Starts the installed app in the background (`open -g`), never bringing it forward.
    static func openApp() -> LaunchOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-b", bundleIdentifier]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return .failed(error.localizedDescription) }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus == 0 { return .started }
        if message.contains("LSCopyApplicationURLsForBundleIdentifier") || message.contains("Unable to find application") { return .notInstalled }
        return .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The socket's envelope, built and read member by member. `JSONEncoder` and `JSONDecoder` do not keep
/// object key order, so going through them would hand back a spec with `files` before `name`.
enum Envelope {
    static func request(_ op: AgentOp, _ args: JSONValue) -> JSONValue {
        .object([JSONMember("v", .number(Double(AgentProtocolVersion.current))), JSONMember("op", .string(op.rawValue)), JSONMember("args", args)])
    }

    /// Typed arguments, with a spec set in afterwards so its keys stay in the order the agent wrote them.
    /// `JSONValue` is nil-literal expressible, so `cond ? spec : nil` quietly makes `.null`; that is no spec.
    static func arguments<T: Encodable>(_ value: T, spec: JSONValue? = nil) throws -> JSONValue {
        var json = try JSONValue(encoding: value)
        if let spec, !spec.isNull { json.set("spec", spec) }
        return json
    }

    /// A render's arguments: its stand-in values set in afterwards too, so they reach the app (and its notes)
    /// in the order they were given.
    static func arguments(_ render: RenderArgs, spec: JSONValue? = nil) throws -> JSONValue {
        var json = try JSONValue(encoding: render)
        if let values = render.values, !values.isNull { json.set("values", values) }
        if let spec, !spec.isNull { json.set("spec", spec) }
        return json
    }

    static func result(of reply: JSONValue) throws -> JSONValue {
        if reply["ok"]?.bool == true { return reply["result"] ?? .null }
        if let error = reply["error"] {
            if let failure = try? error.decode(AgentFailure.self) { throw failure }
            // A newer app's error code this build does not know still carries its message and diagnostics.
            if let message = error["message"]?.string {
                throw AgentFailure(.internalError, message, diagnostics: try? error["diagnostics"]?.decode([SpecDiagnostic].self))
            }
        }
        throw AgentFailure(.internalError, "MenuSprite sent an answer this command does not understand.")
    }

    static func failure(_ failure: AgentFailure) -> JSONValue {
        .object([JSONMember("ok", false), JSONMember("error", (try? JSONValue(encoding: failure)) ?? .string(failure.message))])
    }

    /// A typed view of a result; a shape this build does not know is the app's fault, not the caller's.
    static func decode<T: Decodable>(_ value: JSONValue, as type: T.Type) throws -> T {
        do { return try value.decode(T.self) }
        catch { throw AgentFailure(.internalError, "MenuSprite's answer has an unexpected shape (\(error)). The app and this command may be from different versions.") }
    }
}
