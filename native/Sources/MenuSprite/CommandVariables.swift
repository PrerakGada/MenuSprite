import Foundation
import SystemMonitoring

/// One run of a command variable: what it printed, what that parsed to, and how it ended.
struct CommandResult: Equatable, Sendable {
    var text: String?
    var number: Double?
    /// Bounded raw output, shown in the studio so a parse can be checked against it.
    var output: String
    var errorOutput: String
    var status: Int32?
    /// Why there is no value: a timeout, a non-zero exit, output that did not parse.
    var problem: String?
    var elapsed: Double
    var finishedAt: Date
    var available: Bool { problem == nil && (text != nil || number != nil) }
}

/// Runs the commands behind sprite variables while something needs them: an enabled sprite, or the
/// studio showing one. One loop per distinct command, never overlapping itself, killed at its timeout,
/// with output capped and repeated failures backed off (doubling, up to ten minutes).
@MainActor
final class CommandVariableRunner {
    private(set) var results: [CommandSource: CommandResult] = [:]
    private(set) var running: Set<CommandSource> = []
    private var loops: [CommandSource: Task<Void, Never>] = [:]
    var changed: (() -> Void)?

    nonisolated static let outputLimit = 64 * 1024
    nonisolated static let errorLimit = 8 * 1024
    nonisolated static let maximumBackoff: Double = 600

    func setDemand(_ sources: Set<CommandSource>) {
        let wanted = Set(sources.map(\.normalized).filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        for (source, task) in loops where !wanted.contains(source) { task.cancel(); loops[source] = nil }
        for source in wanted where loops[source] == nil {
            loops[source] = Task { [weak self] in
                var failures = 0
                while !Task.isCancelled {
                    guard let self else { return }
                    let result = await self.run(source)
                    guard !Task.isCancelled else { return }
                    failures = result.problem == nil ? 0 : failures + 1
                    let wait = failures == 0 ? source.interval
                        : min(Self.maximumBackoff, max(source.interval, source.interval * pow(2, Double(min(failures, 8)))))
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                }
            }
        }
        // Keep only results something still asks for, so an edited command does not linger.
        results = results.filter { wanted.contains($0.key) }
    }

    /// Runs once now (the studio's Run button), outside the schedule.
    @discardableResult
    func run(_ source: CommandSource) async -> CommandResult {
        let source = source.normalized
        running.insert(source); changed?()
        let result = await Self.execute(source)
        running.remove(source)
        results[source] = result
        changed?()
        return result
    }

    func stopAll() { for task in loops.values { task.cancel() }; loops = [:] }

    // MARK: Execution

    nonisolated static func execute(_ source: CommandSource) async -> CommandResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
            CommandExecution(source: source, continuation: continuation).start()
        }
    }

    nonisolated static func parse(_ result: inout CommandResult, source: CommandSource) {
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch source.output {
        case .text:
            guard !trimmed.isEmpty else { result.problem = "Printed nothing"; return }
            // The menu bar holds one line.
            let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
            result.text = String(line.prefix(120))
            result.number = Double(line.trimmingCharacters(in: .whitespaces))
        case .number:
            guard let number = firstNumber(in: trimmed) else { result.problem = "No number in the output"; return }
            result.number = number
        case .json:
            guard let data = trimmed.data(using: .utf8),
                  let document = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                result.problem = "Output is not JSON"; return
            }
            guard let value = jsonValue(document, path: source.path) else { result.problem = "No “\(source.path)” in the JSON"; return }
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { result.number = number.doubleValue }
            else if let string = value as? String { result.text = String(string.prefix(120)); result.number = Double(string) }
            else if let flag = value as? Bool { result.text = flag ? "true" : "false" }
            else { result.problem = "“\(source.path)” is not a number or text" }
        }
    }

    nonisolated static func firstNumber(in text: String) -> Double? {
        guard let range = text.range(of: #"-?\d+(?:[.,]\d+)?"#, options: .regularExpression) else { return nil }
        return Double(text[range].replacingOccurrences(of: ",", with: "."))
    }

    nonisolated static func jsonValue(_ document: Any, path: String) -> Any? {
        var current: Any = document
        for key in path.split(separator: ".").map(String.init) where !key.isEmpty {
            if let object = current as? [String: Any], let next = object[key] { current = next }
            else if let array = current as? [Any], let index = Int(key), array.indices.contains(index) { current = array[index] }
            else { return nil }
        }
        return current
    }
}

/// One command run: output collected to a cap from background readers, a timeout that terminates and
/// then kills, and a single resumption of the caller once the process has ended.
private final class CommandExecution: @unchecked Sendable {
    private let source: CommandSource
    private let continuation: CheckedContinuation<CommandResult, Never>
    private let process = Process()
    private let started = Date()
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    private var overflowed = false, timedOut = false, finished = false
    private let readers = DispatchGroup()

    init(source: CommandSource, continuation: CheckedContinuation<CommandResult, Never>) {
        self.source = source; self.continuation = continuation
    }

    func start() {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -f skips the user's rc files: predictable and fast. Homebrew is added to PATH instead.
        process.arguments = ["-f", "-c", source.command]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        read(out.fileHandleForReading, isOutput: true)
        read(err.fileHandleForReading, isOutput: false)
        process.terminationHandler = { [self] ended in
            let status = ended.terminationStatus
            // A child that kept the pipe open is not waited for beyond a second.
            DispatchQueue.global(qos: .utility).async { [self] in
                _ = readers.wait(timeout: .now() + 1)
                finish(status)
            }
        }
        do { try process.run() } catch {
            try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
            finish(nil); return
        }
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + source.timeout) { [self] in
            guard process.isRunning else { return }
            lock.withLock { timedOut = true }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private func read(_ handle: FileHandle, isOutput: Bool) {
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let limit = isOutput ? CommandVariableRunner.outputLimit : CommandVariableRunner.errorLimit
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                let full: Bool = lock.withLock {
                    if isOutput {
                        stdout.append(chunk.prefix(max(0, limit - stdout.count)))
                        if stdout.count >= limit { overflowed = true }
                        return overflowed
                    }
                    stderr.append(chunk.prefix(max(0, limit - stderr.count)))
                    return false
                }
                if full, process.isRunning { process.terminate() }
            }
            readers.leave()
        }
    }

    private func finish(_ status: Int32?) {
        let state: (Data, Data, Bool, Bool)? = lock.withLock {
            if finished { return nil }
            finished = true
            return (stdout, stderr, overflowed, timedOut)
        }
        guard let (out, err, overflowed, expired) = state else { return }
        var result = CommandResult(output: String(decoding: out, as: UTF8.self), errorOutput: String(decoding: err, as: UTF8.self),
                                   status: status, elapsed: Date().timeIntervalSince(started), finishedAt: Date())
        if expired { result.problem = "Stopped after \(Int(source.timeout)) s" }
        else if overflowed { result.problem = "Output passed \(CommandVariableRunner.outputLimit / 1024) KiB and was stopped" }
        else if let status, status != 0 { result.problem = "Exited with status \(status)" }
        else if status == nil { result.problem = "Could not start /bin/zsh" }
        if result.problem == nil { CommandVariableRunner.parse(&result, source: source) }
        continuation.resume(returning: result)
    }
}
