import Darwin
import Foundation

/// Where the app listens, and the newline-framed reads and writes both ends use.
public enum AgentSocket {
    /// `~/Library/Application Support/MenuSprite/agent.sock`. `MENUSPRITE_SOCKET` overrides it (tests).
    public static var path: String {
        if let override = ProcessInfo.processInfo.environment["MENUSPRITE_SOCKET"], !override.isEmpty { return override }
        return supportDirectory.appendingPathComponent("agent.sock").path
    }

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuSprite", isDirectory: true)
    }

    /// The largest request or response either side accepts.
    public static let messageLimit = 8 * 1024 * 1024

    /// Connects, sends one request and returns the answer. Throws `AgentFailure(.unavailable)` when nothing
    /// listens at the socket.
    public static func send(_ request: AgentRequest, timeout: TimeInterval = 60, path: String = AgentSocket.path) throws -> AgentResponse {
        let descriptor = try connect(path: path)
        defer { close(descriptor) }
        try writeAll(descriptor, Data((request.envelope.serialized() + "\n").utf8), timeout: timeout)
        let reply = try readMessage(descriptor, timeout: timeout)
        do { return try AgentResponse(envelope: JSONValue.parse(reply)) }
        catch { throw AgentFailure(.internalError, "The app's answer could not be read: \(error)") }
    }

    /// True when something accepts connections at the socket.
    public static func isListening(path: String = AgentSocket.path) -> Bool {
        guard let descriptor = try? connect(path: path) else { return false }
        close(descriptor)
        return true
    }

    public static func connect(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AgentFailure(.unavailable, "Could not open a socket: \(String(cString: strerror(errno)))") }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = try address(for: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw AgentFailure(.unavailable, "MenuSprite is not answering at \(path) (\(reason)).")
        }
        return descriptor
    }

    public static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw AgentFailure(.unavailable, "The socket path is too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Writes every byte, waiting while the socket is full.
    public static func writeAll(_ descriptor: Int32, _ data: Data, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                try wait(descriptor, events: Int16(POLLOUT), until: deadline)
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw AgentFailure(.unavailable, "The connection closed while writing (\(String(cString: strerror(errno)))).")
                }
                offset += written
            }
        }
    }

    /// Reads up to the first newline (or the end of the stream), within `limit` bytes.
    public static func readMessage(_ descriptor: Int32, timeout: TimeInterval, limit: Int = AgentSocket.messageLimit) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var message = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try wait(descriptor, events: Int16(POLLIN), until: deadline)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw AgentFailure(.unavailable, "The connection failed while reading (\(String(cString: strerror(errno)))).")
            }
            if count == 0 { break }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                message.append(contentsOf: buffer[..<newline])
                break
            }
            message.append(contentsOf: buffer[..<count])
            if message.count > limit { throw AgentFailure(.badRequest, "The message is larger than \(limit / 1024 / 1024) MiB.") }
        }
        guard !message.isEmpty else { throw AgentFailure(.unavailable, "The connection closed without a message.") }
        return message
    }

    static func wait(_ descriptor: Int32, events: Int16, until deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AgentFailure(.unavailable, "MenuSprite did not answer in time.") }
            var poller = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining, 3600) * 1000))
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw AgentFailure(.unavailable, "Waiting on the connection failed (\(String(cString: strerror(errno)))).") }
        }
    }
}
