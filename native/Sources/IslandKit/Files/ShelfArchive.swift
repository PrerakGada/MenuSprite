import Foundation

/// Names for "Create ZIP", following Finder: the item's full name plus ".zip", then " 2", " 3"…
public enum ShelfArchiveNaming {
    public static func name(for input: URL) -> String {
        let base = input.standardizedFileURL.lastPathComponent
        return (base.isEmpty || base == "/" ? "Archive" : base) + ".zip"
    }

    /// `name` when free, otherwise "<stem> 2.zip", "<stem> 3.zip"…
    public static func unique(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let stem = name.hasSuffix(".zip") ? String(name.dropLast(4)) : name
        var number = 2
        while taken("\(stem) \(number).zip") { number += 1 }
        return "\(stem) \(number).zip"
    }

    /// One ZIP per input in `folder`, unique on disk and among themselves.
    public static func destinations(for inputs: [URL], in folder: URL, exists: (URL) -> Bool) -> [URL] {
        var chosen = Set<String>()
        return inputs.map { input in
            let name = unique(name(for: input)) { candidate in
                chosen.contains(candidate.lowercased()) || exists(folder.appendingPathComponent(candidate))
            }
            chosen.insert(name.lowercased())
            return folder.appendingPathComponent(name)
        }
    }
}

public enum ShelfArchiveRefusal: Error, Equatable, Sendable {
    case noInputs
    case remote
    case root
    /// The archive would land inside one of the items it archives.
    case insideSource(String)

    public var message: String {
        switch self {
        case .noInputs: "Choose at least one file."
        case .remote: "Only files on this Mac can be zipped."
        case .root: "The whole disk can't be zipped."
        case .insideSource(let name): "A ZIP can't be saved inside “\(name)”, which it would contain."
        }
    }
}

public enum ShelfArchiveCheck {
    /// Refuses remote inputs, the root folder, and any destination inside an input. Containment is
    /// decided by file identity, so a case-insensitive spelling or a symbolic link cannot put an
    /// archive inside its own source. Saving beside a selected file is fine.
    public static func refusal(inputs: [URL], destinations: [URL], fileManager: FileManager = .default) -> ShelfArchiveRefusal? {
        guard !inputs.isEmpty, inputs.count == destinations.count else { return .noInputs }
        for input in inputs {
            guard input.isFileURL else { return .remote }
            if input.standardizedFileURL.resolvingSymlinksInPath().path == "/" { return .root }
        }
        guard destinations.allSatisfy(\.isFileURL) else { return .remote }
        for destination in destinations {
            let folder = destination.deletingLastPathComponent().resolvingSymlinksInPath()
            for input in inputs {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: input.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                var relationship = FileManager.URLRelationship.other
                guard (try? fileManager.getRelationship(&relationship, ofDirectoryAt: input.resolvingSymlinksInPath(),
                                                        toItemAt: folder)) != nil else { continue }
                if relationship == .contains || relationship == .same { return .insideSource(input.lastPathComponent) }
            }
        }
        return nil
    }
}

/// Creates ZIPs one input at a time with `ditto`, off the main thread. Each archive is written to a
/// private staging folder on the destination's volume and then installed with an exclusive rename,
/// so an existing file is never replaced and a cancelled job never leaves a partial archive. Only
/// one child process runs at a time across all jobs. A job runs once: after a stop it cannot restart,
/// and a job stopped while queued never starts its process.
public final class ShelfArchiveJob: @unchecked Sendable {
    public struct Tool: Sendable {
        public var executable: URL
        public var arguments: @Sendable (_ input: URL, _ output: URL, _ isDirectory: Bool) -> [String]

        public init(executable: URL, arguments: @escaping @Sendable (URL, URL, Bool) -> [String]) {
            self.executable = executable
            self.arguments = arguments
        }

        public static let ditto = Tool(executable: URL(fileURLWithPath: "/usr/bin/ditto")) { input, output, isDirectory in
            ["-c", "-k", "--sequesterRsrc"] + (isDirectory ? ["--keepParent"] : []) + [input.path, output.path]
        }
    }

    public enum Outcome: Sendable, Equatable {
        case finished([URL])
        case cancelled([URL])
        case failed(String, [URL])
    }

    public let inputs: [URL]
    public let destinations: [URL]
    private let tool: Tool
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var child: Process?
    /// How long a cancelled child gets to leave after SIGTERM before SIGKILL.
    public static let gracePeriod: TimeInterval = 0.5
    private static let queue = DispatchQueue(label: "in.prerakgada.MenuSprite.shelf-archive", qos: .userInitiated)

    public init(inputs: [URL], destinations: [URL], tool: Tool = .ditto) {
        self.inputs = inputs
        self.destinations = destinations
        self.tool = tool
    }

    public var isStopped: Bool { lock.withLock { stopped } }

    public func start(progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void,
                      completion: @escaping @Sendable (Outcome) -> Void) {
        let refused: Bool = lock.withLock {
            defer { started = true }
            return started || stopped
        }
        if refused { completion(.cancelled([])); return }
        Self.queue.async { [self] in completion(run(progress: progress)) }
    }

    /// Cancel: SIGTERM now, SIGKILL if the child is still there after the grace period.
    public func cancel() {
        let running: Process? = lock.withLock {
            stopped = true
            return child
        }
        guard let running, running.isRunning else { return }
        kill(running.processIdentifier, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.gracePeriod) { [self] in
            lock.withLock { if child === running, running.isRunning { kill(running.processIdentifier, SIGKILL) } }
        }
    }

    /// Stops at once (quit, island off): SIGKILL immediately, without waiting for any later turn.
    public func stopNow() {
        lock.withLock {
            stopped = true
            if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    private func run(progress: @Sendable (Int, Int) -> Void) -> Outcome {
        let fileManager = FileManager.default
        var produced: [URL] = []
        for (index, input) in inputs.enumerated() {
            let destination = destinations[index]
            if isStopped { return .cancelled(produced) }
            let staging: URL
            do {
                staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: destination.deletingLastPathComponent(), create: true)
            } catch {
                return .failed("Couldn't prepare “\(destination.lastPathComponent)”.", produced)
            }
            defer { try? fileManager.removeItem(at: staging) }
            let staged = staging.appendingPathComponent(destination.lastPathComponent)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
                return .failed("“\(input.lastPathComponent)” no longer exists.", produced)
            }
            let process = Process()
            process.executableURL = tool.executable
            process.arguments = tool.arguments(input, staged, isDirectory.boolValue)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let launched: Bool = lock.withLock {
                guard !stopped else { return false }
                guard (try? process.run()) != nil else { return false }
                child = process
                return true
            }
            guard launched else {
                return isStopped ? .cancelled(produced) : .failed("Couldn't start the archiver.", produced)
            }
            process.waitUntilExit()
            lock.withLock { child = nil }
            if isStopped { return .cancelled(produced) }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                return .failed("Couldn't zip “\(input.lastPathComponent)”.", produced)
            }
            guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                let exists = errno == EEXIST
                return .failed(exists ? "“\(destination.lastPathComponent)” already exists, so it was left as it was."
                                      : "Couldn't save “\(destination.lastPathComponent)”.", produced)
            }
            produced.append(destination)
            progress(produced.count, inputs.count)
        }
        return .finished(produced)
    }
}
