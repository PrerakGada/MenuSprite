import Darwin
import Foundation

/// Where a command writes and what it reads. The binary uses the real streams; tests capture them.
struct Console: Sendable {
    var write: @Sendable (String) -> Void
    var writeError: @Sendable (String) -> Void
    var readInput: @Sendable () -> Data

    static let standard = Console(
        write: { StandardStream.write($0, to: STDOUT_FILENO) },
        writeError: { StandardStream.write($0, to: STDERR_FILENO) },
        readInput: { FileHandle.standardInput.readDataToEndOfFile() })
}

enum StandardStream {
    /// Writes every byte with write(2). `FileHandle.write` raises an Objective-C exception when the reader
    /// has gone (an MCP client that quit); here that is just `false`.
    @discardableResult
    static func write(_ text: String, to descriptor: Int32) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, $0.count - offset) }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }
}

/// Runs another program and collects what it printed (both streams). Injected so `setup` can be tested
/// without touching a real agent's configuration.
struct ProcessRunner: Sendable {
    var run: @Sendable (_ executable: String, _ arguments: [String]) -> (status: Int32, output: String)

    static let system = ProcessRunner { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
