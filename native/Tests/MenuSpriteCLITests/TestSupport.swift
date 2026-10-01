import AgentProtocol
import Darwin
import Foundation
@testable import MenuSpriteCLI

/// A stand-in for the app's socket: answers each connection's one request with `handler` and keeps what it
/// was sent, so tests can check exactly what the command put on the wire.
final class FakeApp: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let handler: @Sendable (JSONValue) -> JSONValue
    private let lock = NSLock()
    private var stopped = false
    private var received: [JSONValue] = []

    init(path: String = FakeApp.socketPath(), handler: @escaping @Sendable (JSONValue) -> JSONValue) throws {
        self.path = path
        self.handler = handler
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try AgentSocket.address(for: path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            close(listener)
            throw AgentFailure(.internalError, "The fake app could not listen at \(path): \(String(cString: strerror(errno)))")
        }
        Thread.detachNewThread { [self] in serve() }
    }

    var requests: [JSONValue] { lock.withLock { received } }
    func requests(_ op: String) -> [JSONValue] { requests.filter { $0["op"]?.string == op } }

    func stop() {
        lock.withLock { stopped = true }
        unlink(path)
    }

    private func serve() {
        while !lock.withLock({ stopped }) {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let connection = client
            // One thread per connection, as concurrent MCP calls need.
            Thread.detachNewThread { [self] in
                defer { close(connection) }
                guard let data = try? AgentSocket.readMessage(connection, timeout: 5), let request = try? JSONValue.parse(data) else { return }
                lock.withLock { received.append(request) }
                let reply = handler(request)
                try? AgentSocket.writeAll(connection, Data((reply.serialized() + "\n").utf8), timeout: 5)
            }
        }
        close(listener)
    }

    static func socketPath() -> String { NSTemporaryDirectory() + "msc-\(UUID().uuidString.prefix(8)).sock" }

    static func ok(_ result: JSONValue) -> JSONValue { .object([JSONMember("ok", true), JSONMember("result", result)]) }
    static func ok<T: Encodable>(encoding value: T) -> JSONValue { ok(try! JSONValue(encoding: value)) }
    static func failure(_ failure: AgentFailure) -> JSONValue { Envelope.failure(failure) }
}

/// Captures what a command writes, and feeds it standard input.
final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var outText = ""
    private var errorText = ""
    let input: Data

    init(input: String = "") { self.input = Data(input.utf8) }

    var out: String { lock.withLock { outText } }
    var err: String { lock.withLock { errorText } }

    var console: Console {
        Console(write: { text in self.lock.withLock { self.outText += text } },
                writeError: { text in self.lock.withLock { self.errorText += text } },
                readInput: { self.input })
    }
}

/// A fresh folder per test, so parallel tests never share files.
func scratchFolder() throws -> String {
    let path = NSTemporaryDirectory() + "menusprite-cli-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return (path as NSString).resolvingSymlinksInPath
}

func cli(_ app: FakeApp, _ capture: Capture, folder: String) -> CLI {
    CLI(environment: ["MENUSPRITE_SOCKET": app.path, "TMPDIR": folder, "HOME": folder], console: capture.console, currentDirectory: folder)
}

let sampleSprite = SpriteSummary(id: "3f2a9c1e-5b7d-4e2a-9c1e-000000000001", name: "GitHub PRs", icon: "arrow.triangle.pull",
                                 enabled: true, menuBar: true, side: "right", board: "custom", values: ["prs", "repo"],
                                 commands: ["gh pr list --json number --jq length", "python3 prs.py"])

let sampleSpecText = #"{"menusprite":1,"name":"GitHub PRs","icon":"arrow.triangle.pull","values":[{"id":"prs","command":"gh pr list --json number --jq length","every":"5m"}],"board":{"blocks":[{"value":"prs"}]},"files":{"prs.py":"print(1)\n"}}"#

/// Writes a few PNG-signature bytes where the render request asked, as the app would.
func fakeRender(_ request: JSONValue, kinds: [String] = ["face", "board"]) -> JSONValue {
    let directory = request["args"]?["directory"]?.string ?? NSTemporaryDirectory()
    let files = kinds.map { kind -> RenderedFile in
        let path = (directory as NSString).appendingPathComponent("\(kind)-dark.png")
        FileManager.default.createFile(atPath: path, contents: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(kind.utf8)))
        return RenderedFile(kind: kind, appearance: "dark", path: path, width: kind == "face" ? 120 : 720, height: kind == "face" ? 44 : 900)
    }
    return FakeApp.ok(encoding: RenderResult(files: files, values: [ValueState(id: "prs", name: "prs", value: "3", problem: nil),
                                                                   ValueState(id: "repo", name: "repo", value: nil, problem: "gh: not logged in")],
                                             diagnostics: [], notes: ["The board's script block printed nothing."]))
}

/// Objects with their keys sorted, all the way down: for comparing arguments that went through `JSONEncoder`,
/// which does not keep key order.
func canonical(_ value: JSONValue?) -> JSONValue? {
    guard let value else { return nil }
    switch value {
    case .object(let members): return .object(members.sorted { $0.key < $1.key }.map { JSONMember($0.key, canonical($0.value)!) })
    case .array(let items): return .array(items.map { canonical($0)! })
    default: return value
    }
}
