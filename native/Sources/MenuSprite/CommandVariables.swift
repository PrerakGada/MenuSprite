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

/// Why a command is running. Every command sees it as `MENUSPRITE_TRIGGER`, so a script that keeps a cache of
/// its own can skip it when someone asked for fresh data.
enum CommandTrigger: String, Sendable {
    /// The first run after a board opened or a sprite started (enabled, launched, or its command changed).
    case open
    /// A scheduled run, every `every` seconds after the last one.
    case tick
    /// Asked for again: a Refresh button, a switch re-reading its value after its action, the studio's Run now,
    /// `menusprite refresh`.
    case refresh
    /// A button's or a switch's own command, or a script row's `bash=`.
    case action
    /// An agent's render or `menusprite run`.
    case preview
}

/// Runs the commands behind sprite variables while something needs them: an enabled sprite, an open board,
/// the studio, an agent's render.
///
/// Values (and script rows and script blocks) whose commands share text, `every`, timeout and folder are one
/// run: one process per tick, whose output each reads its own way, the JSON parsed once. Results and chart
/// history stay per source, so two values reading two paths of one `curl` keep their own. A command never
/// runs twice at once: a scheduled run joins one already going, and an asked-for run (Refresh, a switch,
/// Run now) waits for it and then runs once more, shared by every request made meanwhile, so it sees what an
/// action just changed. Runs are killed at their timeout, output is capped, and failures back off (doubling
/// up to ten minutes, never sooner than the command's own interval).
@MainActor
final class CommandVariableRunner {
    private(set) var results: [CommandSource: CommandResult] = [:]
    /// The numbers each source read, oldest first, for board charts. Kept only while the source is
    /// demanded, so a board-only value starts its chart afresh each time the board opens unless it runs
    /// in the background.
    private(set) var history: [CommandSource: [HistoryPoint]] = [:]
    /// Sources whose command is running now, or waiting to run again behind a run already going.
    var running: Set<CommandSource> {
        var sources = Set(waiting.values.joined())
        for (key, flight) in flights { sources.formUnion(flight.requested); sources.formUnion(demand[key] ?? []) }
        return sources
    }
    /// Sources something needs, grouped by the run they share.
    private var demand: [CommandSource.Execution: Set<CommandSource>] = [:]
    private var loops: [CommandSource.Execution: Task<Void, Never>] = [:]
    /// The run going now for each command; anyone else who needs that command takes its output.
    private var flights: [CommandSource.Execution: Flight] = [:]
    /// Sources waiting for a run already going to end, so that the run they get starts after they asked.
    private var waiting: [CommandSource.Execution: Set<CommandSource>] = [:]
    /// Each demanded command's last run, so a value that starts reading a command already running (a board
    /// opening beside the face) is filled at once. Its output is the same storage the results hold.
    private var lastRun: [CommandSource.Execution: CommandResult] = [:]
    private var serial = 0
    var changed: (() -> Void)?

    private struct Flight {
        let serial: Int
        let task: Task<SharedRun, Never>
        var requested: Set<CommandSource>
        /// Its process is being started. Until then it starts after anything asked now, so it is fresh for all.
        var launched = false
    }
    /// One run's output, and what each source attached to it read.
    struct SharedRun: Sendable {
        var raw: CommandResult
        var parsed: [CommandSource: CommandResult]
    }

    nonisolated static let outputLimit = 64 * 1024
    nonisolated static let errorLimit = 8 * 1024
    nonisolated static let historyLimit = 240

    /// What runs on a schedule. `previews` are the sources only an agent's render wants: a command that starts
    /// for them alone runs as `preview`, and one already running gets a run for them, so the picture is not
    /// drawn from output older than the request.
    func setDemand(_ sources: Set<CommandSource>, previews: Set<CommandSource> = []) {
        let wanted = Set(sources.map(\.normalized).filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let previews = Set(previews.map(\.normalized))
        let previous = demand
        demand = Dictionary(grouping: wanted, by: \.execution).mapValues(Set.init)
        for (key, task) in loops where demand[key] == nil { task.cancel(); loops[key] = nil }
        // Keep only results something still asks for, so an edited command does not linger.
        results = results.filter { wanted.contains($0.key) }
        history = history.filter { wanted.contains($0.key) }
        lastRun = lastRun.filter { demand[$0.key] != nil }
        var filled = false
        for (key, members) in demand {
            guard loops[key] != nil else {
                loops[key] = loop(key, first: members.isSubset(of: previews) ? .preview : .open)
                continue
            }
            let added = members.subtracting(previous[key] ?? [])
            guard !added.isEmpty else { continue }
            // A value joining a command that already runs reads its last output now instead of a whole interval later.
            if let raw = lastRun[key] {
                let reader = CommandOutputReader(raw.output)
                for source in added { record(Self.read(raw, for: source, reader: reader), for: source) }
                filled = true
            }
            if !added.isDisjoint(with: previews) {
                Task { [weak self] in _ = await self?.shared(key, added, trigger: .preview, fresh: false) }
            }
        }
        if filled { changed?() }
    }

    /// The latest result for a command as a value would read it, and its numbers so far (charts).
    func result(for source: CommandSource) -> CommandResult? { results[source.normalized] }
    func points(for source: CommandSource) -> [HistoryPoint] { history[source.normalized] ?? [] }
    /// Whether this source's command is running, or waiting to run again, now.
    func isRunning(_ source: CommandSource) -> Bool {
        let key = source.execution
        return flights[key] != nil || waiting[key] != nil
    }

    /// Runs one command now, outside its schedule. A run of it whose process already started may not see what
    /// the caller just changed (a switch's action), so it is waited for and the command runs once more; every
    /// request made meanwhile shares that run, and requests made in one turn share one process. `fresh: false`
    /// takes the run going instead.
    @discardableResult
    func run(_ source: CommandSource, trigger: CommandTrigger = .refresh, fresh: Bool = true) async -> CommandResult {
        let source = source.normalized
        let run = await shared(source.execution, [source], trigger: trigger, fresh: fresh)
        return run.parsed[source] ?? Self.read(run.raw, for: source, reader: CommandOutputReader(run.raw.output))
    }

    /// Runs these commands now, side by side, one process per shared command, and returns when all have
    /// finished. Each source gets its own reading of its command's output.
    @discardableResult
    func run(_ sources: [CommandSource], trigger: CommandTrigger = .refresh, fresh: Bool = true) async -> [CommandSource: CommandResult] {
        let wanted = sources.map(\.normalized).filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let runs = Dictionary(grouping: wanted, by: \.execution).map { key, members in
            (Set(members), Task { await self.shared(key, Set(members), trigger: trigger, fresh: fresh) })
        }
        var collected: [CommandSource: CommandResult] = [:]
        for (members, task) in runs {
            let run = await task.value
            let reader = CommandOutputReader(run.raw.output)
            for source in members { collected[source] = run.parsed[source] ?? Self.read(run.raw, for: source, reader: reader) }
        }
        return collected
    }

    func stopAll() { for task in loops.values { task.cancel() }; loops = [:] }

    // MARK: Shared runs

    private func loop(_ key: CommandSource.Execution, first: CommandTrigger) -> Task<Void, Never> {
        Task { [weak self] in
            var failures = 0, trigger = first
            while !Task.isCancelled {
                guard let run = await self?.shared(key, [], trigger: trigger, fresh: false), !Task.isCancelled else { return }
                // A run failed when the command did, or when none of the values could read what it printed.
                let failed = run.raw.problem != nil || (!run.parsed.isEmpty && run.parsed.values.allSatisfy { $0.problem != nil })
                failures = failed ? failures + 1 : 0
                trigger = .tick
                do { try await Task.sleep(for: .seconds(CommandSource.delay(interval: key.interval, failures: failures))) } catch { return }
            }
        }
    }

    /// The run these sources get: the one going (when `fresh` is false), or one whose process starts after this
    /// call, which a run not launched yet (asked for a moment ago, in this same turn) still is.
    private func shared(_ key: CommandSource.Execution, _ sources: Set<CommandSource>, trigger: CommandTrigger, fresh: Bool) async -> SharedRun {
        if fresh, let going = flights[key], going.launched {
            waiting[key, default: []].formUnion(sources); changed?()
            _ = await going.task.value
        }
        // Whatever is going now either launches after this request or is the run a scheduled tick joins.
        if var flight = flights[key] {
            flight.requested.formUnion(sources); flights[key] = flight
            return await flight.task.value
        }
        return await start(key, sources, trigger: trigger).value
    }

    private func start(_ key: CommandSource.Execution, _ sources: Set<CommandSource>, trigger: CommandTrigger) -> Task<SharedRun, Never> {
        serial += 1
        let serial = serial
        let task = Task { [weak self] () -> SharedRun in
            if self?.flights[key]?.serial == serial { self?.flights[key]?.launched = true }
            let raw = await Self.output(of: key.source, stopsAtLimit: true, trigger: trigger)
            return self?.finish(key, serial: serial, raw: raw) ?? SharedRun(raw: raw, parsed: [:])
        }
        flights[key] = Flight(serial: serial, task: task, requested: sources.union(waiting.removeValue(forKey: key) ?? []))
        changed?()
        return task
    }

    /// Hands the output to every source still asking for it: those demanded now and those that asked for this
    /// run. A run that outlived its demand (a board closed while it ran) leaves nothing behind.
    private func finish(_ key: CommandSource.Execution, serial: Int, raw: CommandResult) -> SharedRun {
        var requested: Set<CommandSource> = []
        if let flight = flights[key], flight.serial == serial { requested = flight.requested; flights[key] = nil }
        if demand[key] != nil { lastRun[key] = raw }
        let reader = CommandOutputReader(raw.output)
        var parsed: [CommandSource: CommandResult] = [:]
        for source in requested.union(demand[key] ?? []) {
            let result = Self.read(raw, for: source, reader: reader)
            parsed[source] = result
            record(result, for: source)
        }
        changed?()
        return SharedRun(raw: raw, parsed: parsed)
    }

    private func record(_ result: CommandResult, for source: CommandSource) {
        results[source] = result
        guard result.available, let number = result.number else { return }
        var points = history[source] ?? []
        points.append(HistoryPoint(time: result.finishedAt, value: number))
        if points.count > Self.historyLimit { points.removeFirst(points.count - Self.historyLimit) }
        history[source] = points
    }

    // MARK: Execution

    /// Runs a command once, apart from any schedule and from the shared runs above: `menusprite run`, a board
    /// action. `parse: false` is for actions (buttons, switches, `bash=` rows): they succeed by exiting cleanly
    /// whatever they print, and output past the cap is dropped rather than stopping them halfway. The trigger
    /// defaults to `preview` for a value and `action` otherwise.
    nonisolated static func execute(_ source: CommandSource, parse: Bool = true, trigger: CommandTrigger? = nil) async -> CommandResult {
        let raw = await output(of: source, stopsAtLimit: parse, trigger: trigger ?? (parse ? .preview : .action))
        return parse ? read(raw, for: source, reader: CommandOutputReader(raw.output)) : raw
    }

    /// One run, unread. `stopsAtLimit` kills it once its output passes the cap, since a value cannot use more.
    nonisolated static func output(of source: CommandSource, stopsAtLimit: Bool, trigger: CommandTrigger) async -> CommandResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
            CommandExecution(source: source, stopsAtLimit: stopsAtLimit, trigger: trigger, continuation: continuation).start()
        }
    }

    /// What `source` reads from a run: the run's own problem if it failed, else its parse of the output.
    nonisolated static func read(_ raw: CommandResult, for source: CommandSource, reader: CommandOutputReader) -> CommandResult {
        var result = raw
        guard raw.problem == nil else { return result }
        let value = reader.value(for: source)
        result.text = value.text; result.number = value.number; result.problem = value.problem
        return result
    }

    /// Where a command finds its tools: Homebrew and the usual per-user bins come first, because an app
    /// started by launchd inherits only the system's four directories and `-f` skips the user's profile.
    nonisolated static func searchPath(inherited: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin",
                         "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/go/bin"]
        let rest = (inherited ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
            .filter { !$0.isEmpty && !preferred.contains($0) }
        return (preferred + rest).joined(separator: ":")
    }

    /// What a command sees, the same however MenuSprite was started. launchd gives an app almost nothing while a
    /// shell gives the headless sandbox everything it has, so passing the process's own environment through
    /// would let an agent's preview succeed on a token or PATH entry the real app never sees. Only the user's
    /// identity, locale and SSH agent pass; PATH is the preferred bins before launchd's four.
    /// Set once at launch: MENUSPRITE_CLI (the bundled `menusprite`, so a script that finished a long job can
    /// run `"$MENUSPRITE_CLI" refresh <sprite>` without it being on PATH) and, in the headless sandbox,
    /// MENUSPRITE_SOCKET, so such a script reaches the sandbox rather than the real app.
    nonisolated(unsafe) static var extraEnvironment: [String: String] = [:]

    nonisolated static func baseEnvironment(_ inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let passed: Set = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"]
        var result = inherited.filter { passed.contains($0.key) }
        result["PATH"] = searchPath(inherited: nil)
        result.merge(extraEnvironment) { _, own in own }
        if result["LANG"] == nil && result["LC_ALL"] == nil { result["LANG"] = "en_US.UTF-8" }
        return result
    }

    /// A sprite's own folder when it exists, where its commands run with `SPRITE_DIR` set.
    nonisolated static func existingDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && isDirectory.boolValue ? expanded : nil
    }
}

/// One command run: output collected to a cap from background readers, a timeout that terminates and
/// then kills, and a single resumption of the caller once the process has ended.
private final class CommandExecution: @unchecked Sendable {
    private let source: CommandSource
    /// A value is stopped once its output passes the cap; an action keeps running and the rest is dropped.
    private let stopsAtLimit: Bool
    private let trigger: CommandTrigger
    private let continuation: CheckedContinuation<CommandResult, Never>
    private let process = Process()
    private let started = Date()
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    private var overflowed = false, timedOut = false, finished = false, missingFolder = false
    private let readers = DispatchGroup()

    init(source: CommandSource, stopsAtLimit: Bool, trigger: CommandTrigger, continuation: CheckedContinuation<CommandResult, Never>) {
        self.source = source; self.stopsAtLimit = stopsAtLimit; self.trigger = trigger; self.continuation = continuation
    }

    func start() {
        // A sprite whose folder has gone (deleted by hand, a sync tool) must not quietly run its scripts from
        // the home folder instead: `python3 prs.py` would fail there or, worse, find another file.
        if let wanted = source.directory, !wanted.isEmpty, CommandVariableRunner.existingDirectory(wanted) == nil {
            lock.withLock { missingFolder = true }
            finish(nil)
            return
        }
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -f skips the user's rc files: predictable and fast. Homebrew and the per-user bins are added to PATH instead.
        process.arguments = ["-f", "-c", source.command]
        var environment = CommandVariableRunner.baseEnvironment()
        if let directory = CommandVariableRunner.existingDirectory(source.directory) {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            environment["SPRITE_DIR"] = directory
        } else {
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            environment["SPRITE_DIR"] = nil
        }
        environment["MENUSPRITE_TRIGGER"] = trigger.rawValue
        process.environment = environment
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
                        return overflowed && stopsAtLimit
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
        let state: (Data, Data, Bool, Bool, Bool)? = lock.withLock {
            if finished { return nil }
            finished = true
            return (stdout, stderr, overflowed, timedOut, missingFolder)
        }
        guard let (out, err, overflowed, expired, missing) = state else { return }
        var result = CommandResult(output: String(decoding: out, as: UTF8.self), errorOutput: String(decoding: err, as: UTF8.self),
                                   status: status, elapsed: Date().timeIntervalSince(started), finishedAt: Date())
        if expired { result.problem = "Stopped after \(Int(source.timeout)) s" }
        else if overflowed && stopsAtLimit { result.problem = "Output passed \(CommandVariableRunner.outputLimit / 1024) KiB and was stopped" }
        else if let status, status != 0 { result.problem = "Exited with status \(status)" }
        else if missing { result.problem = "The sprite's folder is missing; apply its spec again to restore its files" }
        else if status == nil { result.problem = "Could not start /bin/zsh" }
        continuation.resume(returning: result)
    }
}
