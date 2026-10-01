import AgentProtocol
import Darwin
import Foundation

/// Serves the `menusprite` command and its MCP server over a Unix socket: one request per connection, a
/// newline-terminated JSON object each way (`AgentProtocol`).
///
/// Nothing runs at rest. A read source on the listening socket wakes only when a client connects; each
/// connection is read and answered on a background queue, and only the request itself runs on the main
/// actor, where the store lives, so the main thread never waits on a socket. The socket is created 0600
/// and a peer of another user is closed unanswered. Spec: `docs/agent-authoring.md`.
final class AgentServer: @unchecked Sendable {
    typealias Handler = @Sendable (AgentOp, JSONValue) async -> AgentResponse

    let path: String
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "in.prerakgada.MenuSprite.agent-accept", qos: .userInitiated)
    private static let ioQueue = DispatchQueue(label: "in.prerakgada.MenuSprite.agent-io", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    /// The socket file this server made, so stopping never unlinks a file another instance made since.
    private var boundFile: (device: dev_t, inode: ino_t)?

    /// How long a client may take to send its request.
    static let readTimeout: TimeInterval = 10
    static let writeTimeout: TimeInterval = 10

    init(path: String = AgentSocket.path, handler: @escaping Handler) {
        self.path = path; self.handler = handler
    }

    struct StartFailure: Error, CustomStringConvertible { let description: String }

    /// Binds and listens. Refuses (rather than stealing the path) when another process already answers there.
    func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard !AgentSocket.isListening(path: path) else { throw StartFailure(description: "Another MenuSprite already answers at \(path).") }
            guard (existing.st_mode & S_IFMT) == S_IFSOCK else { throw StartFailure(description: "\(path) exists and is not a socket.") }
            unlink(path)
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StartFailure(description: "Could not open a socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var address: sockaddr_un
        do { address = try AgentSocket.address(for: path) } catch { close(descriptor); throw StartFailure(description: "\(error)") }
        // The mask makes the file 0600 from the moment it exists; chmod below only restates it.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw StartFailure(description: "Could not bind \(path): \(reason)")
        }
        chmod(path, 0o600)
        var made = stat()
        if lstat(path, &made) == 0 { boundFile = (made.st_dev, made.st_ino) }
        guard listen(descriptor, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor); unlink(path)
            throw StartFailure(description: "Could not listen at \(path): \(reason)")
        }
        // Non-blocking, so one wake-up can drain every pending connection and then stop.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(descriptor) }
        source.setCancelHandler { close(descriptor) }
        lock.withLock { self.source = source }
        source.resume()
    }

    /// Stops listening and removes the socket file, if it is still the one this server made.
    func stop() {
        let source: DispatchSourceRead? = lock.withLock { defer { self.source = nil }; return self.source }
        source?.cancel()
        var current = stat()
        if let boundFile, lstat(path, &current) == 0, current.st_dev == boundFile.device, current.st_ino == boundFile.inode {
            unlink(path)
        }
        boundFile = nil
    }

    var isRunning: Bool { lock.withLock { source != nil } }

    private func acceptPending(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        // A connection inherits the listener's non-blocking flag on macOS; the reads below poll anyway,
        // but blocking writes keep a slow reader from turning into a spin.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
        let handler = self.handler
        Self.ioQueue.async {
            let request = Result { try Self.readRequest(client) }
            Task {
                let response: AgentResponse
                switch request {
                case .success(let (op, args)): response = await handler(op, args)
                case .failure(let error): response = AgentResponse(error: Self.failure(error))
                }
                Self.ioQueue.async {
                    try? AgentSocket.writeAll(client, Self.encode(response), timeout: Self.writeTimeout)
                    close(client)
                }
            }
        }
    }

    /// The op and its arguments. The arguments stay a `JSONValue` with their key order, so a spec reads
    /// back in the order the agent wrote it.
    static func readRequest(_ client: Int32) throws -> (AgentOp, JSONValue) {
        try decode(AgentSocket.readMessage(client, timeout: readTimeout))
    }

    static func decode(_ data: Data) throws -> (AgentOp, JSONValue) {
        let document: JSONValue
        do { document = try JSONValue.parse(data) } catch { throw AgentFailure(.badRequest, "The request is not JSON. \(error)") }
        guard document.members != nil else { throw AgentFailure(.badRequest, "A request is a JSON object: {\"v\":1,\"op\":\"…\",\"args\":{…}}.") }
        if let version = document["v"]?.number, Int(version) > AgentProtocolVersion.current {
            throw AgentFailure(.badRequest, "This MenuSprite speaks protocol \(AgentProtocolVersion.current) and the request uses \(Int(version)). Update MenuSprite.")
        }
        guard let name = document["op"]?.string else { throw AgentFailure(.badRequest, "The request names no op.") }
        guard let op = AgentOp(rawValue: name) else {
            throw AgentFailure(.badRequest, "Unknown op “\(name)”. Known ops: \(AgentOp.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let args = document["args"] ?? .object([])
        if args.isNull { return (op, .object([])) }
        guard args.members != nil else { throw AgentFailure(.badRequest, "“args” must be an object, not \(args.typeName).") }
        return (op, args)
    }

    /// Written by hand rather than through `JSONEncoder`, so the result's members keep their order.
    static func encode(_ response: AgentResponse) -> Data {
        var members = [JSONMember("ok", .bool(response.ok))]
        if let result = response.result { members.append(JSONMember("result", result)) }
        if let error = response.error {
            members.append(JSONMember("error", (try? JSONValue(encoding: error))
                ?? .object([JSONMember("code", .string(error.code.rawValue)), JSONMember("message", .string(error.message))])))
        }
        return Data((JSONValue.object(members).serialized() + "\n").utf8)
    }

    static func failure(_ error: any Error) -> AgentFailure {
        (error as? AgentFailure) ?? AgentFailure(.internalError, "\(error)")
    }
}
