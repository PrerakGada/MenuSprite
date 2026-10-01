import AgentProtocol
import AIAccounts
import AppKit
import Combine
import Foundation
import SpriteSpec
import SystemMonitoring

/// What the agent service needs from wherever it runs: the real app, or the headless sandbox that tests
/// it without touching the menu bar, the saved sprites or the preferences.
@MainActor
struct AgentHost {
    /// Who answers `hello`.
    var name: String
    var power: PowerStore?
    /// Where sprites' own folders live.
    var spritesRoot: URL
    var side: (UUID) -> SpriteSide
    var setSide: (UUID, SpriteSide) -> Void
    /// Pops a sprite's board open from its menu-bar item; nil where there is no menu bar.
    var toggleBoard: ((UUID) -> NSView?)?
    /// What happens to a removed sprite's folder: the Trash in the app (returning where it went, so the
    /// Sprites window's Undo can bring it back), deletion in the sandbox (nil).
    var discard: (URL) -> URL?
    /// Why AI limits have no value here, when they never can (the sandbox reads no logins).
    var aiOffline: String? = nil

    /// The running app: sides from the left strip's placement, boards from the menu bar.
    static func app(power: PowerStore, toggleBoard: @escaping (UUID) -> NSView?) -> AgentHost {
        AgentHost(name: "MenuSprite", power: power, spritesRoot: SpriteFolders.root,
                  side: { SpritePlacement.shared.isLeft($0) ? .left : .right },
                  setSide: { SpritePlacement.shared.setLeft($0, $1 == .left) },
                  toggleBoard: toggleBoard,
                  discard: { url in
                      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                      var trashed: NSURL?
                      if (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) == nil { try? FileManager.default.removeItem(at: url) }
                      return trashed as URL?
                  })
    }

    /// The sandbox keeps sides in memory and folders under its own directory.
    static func sandbox(directory: URL) -> AgentHost {
        final class Sides { var left: Set<UUID> = [] }
        let sides = Sides()
        return AgentHost(name: "MenuSprite (sandbox)", power: nil, spritesRoot: SpriteFolders.rootOverride ?? directory.appendingPathComponent("Sprites", isDirectory: true),
                         side: { sides.left.contains($0) ? .left : .right },
                         setSide: { id, side in if side == .left { sides.left.insert(id) } else { sides.left.remove(id) } },
                         toggleBoard: nil,
                         discard: { try? FileManager.default.removeItem(at: $0); return nil },
                         aiOffline: "AI limits are offline in this sandbox (the real app reads them from the Claude/Codex CLI logins).")
    }
}

/// Every op of the agent protocol, carried out against the running store exactly as the studio would:
/// specs compile through `SpriteSpec`, saves go through `MonitoringStore.save`, and previews draw through
/// the menu bar's own renderer. Spec: `docs/agent-authoring.md`.
@MainActor
final class AgentService {
    let store: MonitoringStore
    let host: AgentHost
    /// The last sprite an agent removed while the Sprites window can still undo it. `remove` moves its folder
    /// to the Trash; the store's Undo restores only the sprite, so this watches for it to come back and moves
    /// the folder (and its side) back with it. Replaced by the next removal, as the store's Undo is.
    private var undoWatch: (id: UUID, subscription: AnyCancellable)?
    /// Commands an apply has just made run fresh, by when it asked: those it ran again after rewriting the
    /// sprite's files, and those its save starts for the first time. A preview right after (apply_sprite's
    /// own) waits for those runs instead of starting second ones.
    private var reruns: [CommandSource: Date] = [:]
    static let rerunReuse: TimeInterval = 30

    init(store: MonitoringStore, host: AgentHost) {
        self.store = store; self.host = host
    }

    /// The server's entry point: runs one request and never throws.
    nonisolated func handler() -> AgentServer.Handler {
        { [weak self] op, args in
            guard let self else { return AgentResponse(error: AgentFailure(.unavailable, "MenuSprite is quitting.")) }
            return await self.handle(op, args: args)
        }
    }

    func handle(_ op: AgentOp, args: JSONValue) async -> AgentResponse {
        do {
            let result: JSONValue = switch op {
            case .hello: try encode(hello())
            case .readings: try encode(await readings(decode(ReadingsArgs.self, args, op)))
            case .list: try encode(ListResult(sprites: store.sprites.map(summary)))
            case .get: try get(decode(SpriteReference.self, args, op))
            case .validate: try validate(spec(args, op))
            case .apply: try apply(spec(args, op), dryRun: args["dryRun"]?.bool ?? false)
            case .remove: try encode(remove(decode(SpriteReference.self, args, op)))
            case .set: try encode(set(decode(SetArgs.self, args, op)))
            case .run: try encode(await run(decode(RunArgs.self, args, op)))
            case .render: try encode(await render(rendering(args), spec: args["spec"]))
            case .open: try encode(open(decode(SpriteReference.self, args, op)))
            case .refresh: try encode(await refresh(decode(SpriteReference.self, args, op)))
            }
            return AgentResponse(result: result)
        } catch {
            return AgentResponse(error: AgentServer.failure(error))
        }
    }

    // MARK: Ops

    func hello() -> HelloResult {
        let info = Bundle.main.infoDictionary
        return HelloResult(app: host.name, version: info?["CFBundleShortVersionString"] as? String ?? "dev",
                           build: info?["CFBundleVersion"] as? String ?? "dev", pid: getpid())
    }

    func readings(_ args: ReadingsArgs) async -> ReadingsResult {
        // Words, not substrings: "ai" finds ai.claude.session but not memory.available, and "claude codex" finds
        // either. Readings matching more of the words come first; an exact id comes before everything.
        let query = (args.query ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let terms = query.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        func words(_ metric: Metric) -> [String] {
            "\(metric.id) \(metric.name) \(metric.shortName) \(metric.group.rawValue)".lowercased()
                .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        func score(_ metric: Metric) -> Int {
            if metric.id.lowercased() == query { return Int.max }
            let own = words(metric)
            return terms.filter { term in own.contains { $0.hasPrefix(term) } }.count
        }
        func matches(_ metric: Metric) -> Bool { terms.isEmpty || score(metric) > 0 }
        let sampled = args.sample == true
        if sampled {
            // Sensors appear in the catalog only once discovered; discovery is a one-off per launch.
            if !store.catalog.contains(where: { $0.group == .sensors }) { store.discoverSensors() }
            for _ in 0..<40 where store.discoveringSensors { try? await Task.sleep(for: .milliseconds(50)) }
            // AI limits are left as last fetched: sampling them means a network request and the CLI's login.
            let ids = Set(store.catalog.filter { matches($0) && $0.group != .ai }.map(\.id))
            await AgentRender.sample(store: store, metrics: ids)
        }
        let found = terms.isEmpty ? store.catalog
            : store.catalog.enumerated().filter { matches($0.element) }
                .sorted { (score($0.element), -$0.offset) > (score($1.element), -$1.offset) }.map(\.element)
        return ReadingsResult(readings: found.map { metric in
            let reading = store.readings[metric.id]
            let available = reading?.available == true
            let issue = readingProblem(metric.id, reading: reading)
            let detail = issue.map { "\(metric.detail) Unavailable now: \($0)" } ?? metric.detail
            return ReadingInfo(id: metric.id, name: metric.name, short: metric.shortName, group: metric.group.rawValue,
                               unit: metric.unit.rawValue, value: available ? store.display(metric.id) : nil,
                               number: reading?.number, detail: detail, problem: sampled && !available ? issue ?? "No value." : nil)
        }, sampled: sampled ? true : nil)
    }

    /// Why a reading has no value: its own issue, else why nothing has been read. AI limits are never sampled
    /// on request (that is a network call on the user's login), so theirs says how they are read.
    func readingProblem(_ id: String, reading: Reading?) -> String? {
        if reading?.available == true { return nil }
        if id.hasPrefix(AIUsageMetrics.prefix) {
            if let offline = host.aiOffline { return offline }
            return reading?.issue ?? "Not fetched yet: AI limits are fetched while a sprite shows them, every few minutes."
        }
        if store.knownMetric(id) == nil { return "This Mac does not report \(id)." }
        return reading?.issue ?? (reading == nil ? "Not sampled yet." : nil)
    }

    func get(_ args: SpriteReference) throws -> JSONValue {
        let config = try resolve(args.sprite)
        let contents = SpriteFolders.contents(in: folder(config.id))
        let notes = contents.skipped.map { "files: \($0)." }
        return try encode(GetResult(spec: .null, notes: notes.isEmpty ? nil : notes), spec: emitted(config, files: contents.files))
    }

    func validate(_ spec: JSONValue) throws -> JSONValue {
        let existing = try target(of: spec)
        let (compiled, diagnostics) = SpriteSpecFormat.compile(spec, existing: existing, environment: environment())
        let all = merged(diagnostics, compiled?.diagnostics ?? [])
        guard let compiled else { return try encode(ValidateResult(valid: false, diagnostics: all, spec: nil)) }
        let side = compiled.side ?? existing.map { host.side($0.id) } ?? .right
        let files = compiled.files ?? existing.map { SpriteFolders.files(in: folder($0.id)) } ?? [:]
        let normalized = normalizedForPreview(compiled.config)
        return try encode(ValidateResult(valid: true, diagnostics: all, spec: nil),
                          spec: SpriteSpecFormat.emit(normalized, side: side, files: files, environment: environment()))
    }

    func apply(_ spec: JSONValue, dryRun: Bool) throws -> JSONValue {
        let existing = try target(of: spec)
        let (compiled, diagnostics) = SpriteSpecFormat.compile(spec, existing: existing, environment: environment())
        let all = merged(diagnostics, compiled?.diagnostics ?? [])
        guard var compiled else { throw invalid(all) }
        if let existing { compiled.config.id = existing.id }
        let side = compiled.side ?? existing.map { host.side($0.id) } ?? .right
        if dryRun {
            let files = compiled.files ?? existing.map { SpriteFolders.files(in: folder($0.id)) } ?? [:]
            let preview = normalizedForPreview(compiled.config)
            return try encode(ApplyResult(created: existing == nil, saved: false, sprite: summary(preview, side: side), diagnostics: all, spec: .null),
                              spec: SpriteSpecFormat.emit(preview, side: side, files: files, environment: environment()))
        }
        // An agent bringing a removed sprite back owns its folder now; the Undo watch must not move the old one in.
        if undoWatch?.id == compiled.config.id { undoWatch = nil }
        // As `save` will store them, so these match the runner's keys for the saved sprite.
        let sources = Self.commands(of: normalizedForPreview(compiled.config))
        let hadRun = sources.filter { store.commands.result(for: $0) != nil || store.commands.isRunning($0) }
        let asked = Date()
        // Files first: the sprite's commands start as soon as it is saved, and they run in its folder.
        if let files = compiled.files { try writeFiles(files, for: compiled.config.id) }
        let saved = store.save(compiled.config)
        if host.side(saved.id) != side { host.setSide(saved.id, side) }
        store.agentSaved(saved)
        noteFreshRuns(saved, hadRun: hadRun, asked: asked, filesChanged: compiled.files != nil)
        return try encode(ApplyResult(created: existing == nil, saved: true, sprite: summary(saved), diagnostics: all, spec: .null),
                          spec: emitted(saved, files: compiled.files))
    }

    /// A command's identity is its text and folder, never the scripts in that folder, so saving leaves a
    /// command that already runs alone: after its script was edited, the menu bar (and the next preview)
    /// would show the old script's output until its next turn, up to an hour away, or ten minutes after a
    /// failure. So when the files changed, every command of the sprite that has run (or is running) runs
    /// again now. A command the menu bar needs that has never run starts with the save, fresh anyway.
    /// Both are noted, so the preview that follows waits for these runs rather than starting its own.
    func noteFreshRuns(_ config: SpriteConfiguration, hadRun: Set<CommandSource>, asked: Date, filesChanged: Bool) {
        guard let design = config.design else { return }
        let starting = config.enabled ? Set(MonitoringStore.continuousCommands(design).map(\.normalized)).subtracting(hadRun) : []
        let rerun = filesChanged ? hadRun : []
        for source in starting.union(rerun) { reruns[source] = asked }
        guard !rerun.isEmpty else { return }
        Task { [store] in await store.commands.run(Array(rerun), trigger: .open) }
    }

    /// Every command a sprite runs as a value or a script block, as the runner keys them.
    static func commands(of config: SpriteConfiguration) -> Set<CommandSource> {
        guard let design = config.design else { return [] }
        return Set((design.commandVariables.compactMap(\.command) + design.boardScriptCommands).map(\.normalized)
            .filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    /// The reruns an apply asked for in the last `rerunReuse` seconds; older ones are forgotten.
    func recentReruns() -> [CommandSource: Date] {
        reruns = reruns.filter { -$0.value.timeIntervalSinceNow < Self.rerunReuse }
        return reruns
    }

    func remove(_ args: SpriteReference) throws -> RemoveResult {
        let config = try resolve(args.sprite)
        let wasLeft = host.side(config.id) == .left
        store.remove(config.id)
        store.agentChanged(config.id)
        if wasLeft { host.setSide(config.id, .right) }
        let original = folder(config.id)
        let trashed = host.discard(original)
        watchForUndo(config.id, folder: original, trashed: trashed, wasLeft: wasLeft)
        return RemoveResult(removed: config.name)
    }

    /// The store's Undo puts the sprite back without its folder (which is in the Trash) or its side. When the
    /// removed sprite reappears, this moves the folder back before the store schedules its commands (the
    /// publisher fires as the list changes), so they run where their files are.
    private func watchForUndo(_ id: UUID, folder: URL, trashed: URL?, wasLeft: Bool) {
        undoWatch = nil
        guard trashed != nil || wasLeft else { return }
        let host = self.host
        undoWatch = (id, store.$sprites.sink { [weak self] sprites in
            guard sprites.contains(where: { $0.id == id }) else { return }
            MainActor.assumeIsolated {
                self?.undoWatch = nil
                if let trashed, !FileManager.default.fileExists(atPath: folder.path) {
                    try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.moveItem(at: trashed, to: folder)
                }
                if wasLeft { host.setSide(id, .left) }
            }
        })
    }

    func set(_ args: SetArgs) throws -> SpriteResult {
        let config = try resolve(args.sprite)
        var side: SpriteSide?
        if let value = args.side {
            guard let parsed = SpriteSide(rawValue: value.lowercased()) else {
                throw AgentFailure(.badRequest, "A side is “left” or “right”, not “\(value)”.")
            }
            side = parsed
        }
        if let enabled = args.enabled, enabled != config.enabled { store.setEnabled(config.id, enabled) }
        if let menuBar = args.menuBar, menuBar != config.showInMenuBar { store.setMenuBar(config.id, menuBar) }
        if args.enabled != nil || args.menuBar != nil { store.agentChanged(config.id) }
        if let side, side != host.side(config.id) { host.setSide(config.id, side) }
        return SpriteResult(sprite: summary(store.sprites.first { $0.id == config.id } ?? config))
    }

    func run(_ args: RunArgs) async throws -> RunResult {
        guard !args.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentFailure(.badRequest, "There is no command to run.")
        }
        guard args.command.count <= CommandSource.maximumCommandLength else {
            throw AgentFailure(.badRequest, "A command is at most \(CommandSource.maximumCommandLength) characters; this one has \(args.command.count). Put a long script in the sprite's files.")
        }
        let output: CommandOutput
        switch args.parse?.lowercased() {
        case nil, "text": output = .text
        case "number": output = .number
        case "json": output = .json
        case let other?: throw AgentFailure(.badRequest, "“parse” is text, number or json, not “\(other)”.")
        }
        if output == .json, (args.path ?? "").isEmpty {
            throw AgentFailure(.badRequest, "JSON output needs a “path”, such as data.items.0.name.")
        }
        if args.sprite != nil, args.files != nil {
            throw AgentFailure(.badRequest, "Give “sprite” (run in a saved sprite's folder) or “files” (run with a draft's files), not both.")
        }
        var directory: String?
        if let reference = args.sprite {
            let config = try resolve(reference)
            let url = folder(config.id)
            if FileManager.default.fileExists(atPath: url.path) { directory = url.path }
        }
        // A draft's files go in a folder of their own for this one run, as a sprite's folder would hold them.
        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        if let files = args.files {
            try checkFiles(files)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MenuSprite-run-\(UUID().uuidString)", isDirectory: true)
            scratch = url
            do { try Self.write(files, to: url) } catch {
                throw AgentFailure(.internalError, "Could not write the files to \(url.path): \(error.localizedDescription)")
            }
            directory = url.path
        }
        let source = CommandSource(command: args.command, timeout: args.timeout ?? 10, output: output, path: args.path ?? "",
                                   directory: directory).normalized
        let result = await CommandVariableRunner.execute(source)
        return RunResult(text: result.text, number: result.number, output: result.output,
                         error: AgentRender.shortened(result.errorOutput, folder: directory),
                         status: result.status, problem: result.problem, elapsed: result.elapsed)
    }

    /// Runs a sprite's commands again now and says what its values show afterwards: a script that finished
    /// a long job (an upgrade a button opened in Terminal) calls `menusprite refresh <sprite>` so the menu
    /// bar catches up at once instead of at the value's next turn. AI limits are fetched again too (at most
    /// once a minute) when the sprite shows any.
    func refresh(_ args: SpriteReference) async throws -> RefreshResult {
        let config = try resolve(args.sprite)
        guard let design = config.design else { return RefreshResult(values: []) }
        if design.variables.contains(where: { $0.readingID?.hasPrefix(AIUsageMetrics.prefix) == true }) { store.refresh() }
        await store.rerun(design)
        return RefreshResult(values: AgentRender.valueStates(design, store: store, overrides: [:], service: self))
    }

    func render(_ args: RenderArgs, spec: JSONValue?) async throws -> RenderResult {
        if let spec, !spec.isNull {
            let existing = try target(of: spec)
            return try await AgentRender.renderDraft(spec: spec, existing: existing, args: args, service: self)
        }
        guard let reference = args.sprite else { throw AgentFailure(.badRequest, "Render needs a “sprite” or a “spec”.") }
        let config = try resolve(reference)
        return try await AgentRender.render(config, files: nil, diagnostics: [], args: args, service: self)
    }

    func open(_ args: SpriteReference) throws -> OpenResult {
        let config = try resolve(args.sprite)
        guard let toggle = host.toggleBoard else {
            return OpenResult(opened: false, message: "The sandbox has no menu bar, so there is no board to open. Use render to see it.")
        }
        guard config.showInMenuBar else {
            return OpenResult(opened: false, message: "\(config.name) is not in the menu bar. Show it first (menusprite show \"\(config.name)\").")
        }
        if store.isBoardOpen(config.id) { return OpenResult(opened: true, message: "\(config.name)'s board is already open.") }
        _ = toggle(config.id)
        return OpenResult(opened: true, message: config.enabled ? "Opened \(config.name)'s board." : "Opened \(config.name)'s board; the sprite is disabled, so its values do not run.")
    }

    // MARK: Sprites and specs

    func resolve(_ reference: String) throws -> SpriteConfiguration {
        var match = store.sprite(matching: reference)
        // Names are stored cut to 40 characters, so the full name an agent wrote finds its sprite by that cut.
        let stored = Self.storedName(reference)
        if case .noMatch = match, stored != reference.trimmingCharacters(in: .whitespacesAndNewlines) { match = store.sprite(matching: stored) }
        switch match {
        case .one(let config): return config
        case .several(let matches):
            throw AgentFailure(.ambiguous, "“\(reference)” matches \(matches.count) sprites: "
                + matches.map { "\($0.name) (\($0.id.uuidString.prefix(8)))" }.joined(separator: ", ") + ". Use an id.")
        case .noMatch:
            let names = store.sprites.map(\.name)
            throw AgentFailure(.notFound, "No sprite matches “\(reference)”. "
                + (names.isEmpty ? "There are no sprites yet." : "Sprites: \(names.joined(separator: ", "))."))
        }
    }

    /// The saved sprite a spec replaces: the one saved under its `id`, else the one with its name. An id
    /// that matches nothing (a spec from another Mac) falls back to the name, and failing that the spec
    /// makes a new sprite with that id. A name shared by two sprites is ambiguous.
    func target(of spec: JSONValue) throws -> SpriteConfiguration? {
        guard spec.members != nil else { throw AgentFailure(.invalidSpec, "A sprite spec is a JSON object, not \(spec.typeName).",
                                                            diagnostics: [.error("", "A sprite spec is a JSON object.")]) }
        let identity = SpriteSpecFormat.identity(of: spec)
        if let id = identity.id, let saved = store.sprites.first(where: { $0.id == id }) { return saved }
        guard let name = identity.name.map(Self.storedName), !name.isEmpty else { return nil }
        let named = store.sprites.filter { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if named.count > 1 {
            throw AgentFailure(.ambiguous, "\(named.count) sprites are called “\(name)”. Add the \"id\" of the one to replace: "
                + named.map(\.id.uuidString).joined(separator: ", ") + ".")
        }
        return named.first
    }

    /// A name as the store keeps it (`SpriteConfiguration.normalize`): trimmed and cut to 40 characters.
    static func storedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func summary(_ config: SpriteConfiguration) -> SpriteSummary { summary(config, side: host.side(config.id)) }

    func summary(_ config: SpriteConfiguration, side: SpriteSide) -> SpriteSummary {
        SpriteSummary(id: config.id.uuidString, name: config.name, icon: config.symbol, enabled: config.enabled,
                      menuBar: config.showInMenuBar, side: side.rawValue, board: config.design?.board == nil ? "classic" : "custom",
                      values: config.design?.variables.map(\.id) ?? [], commands: SpriteSpecFormat.commands(of: config))
    }

    /// A saved sprite as a spec, with its side and the files its spec wrote (read from its folder unless the
    /// caller has them already).
    func emitted(_ config: SpriteConfiguration, files: [String: String]? = nil) -> JSONValue {
        SpriteSpecFormat.emit(config, side: host.side(config.id), files: files ?? SpriteFolders.files(in: folder(config.id)), environment: environment())
    }

    /// The live catalog and this Mac's symbols, for compiling and emitting.
    func environment(directory override: String? = nil, hasFiles overrideFiles: Bool? = nil) -> SpecEnvironment {
        let catalog = Dictionary(store.catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = store.catalog.map(\.id)
        let root = host.spritesRoot
        return SpecEnvironment(metric: { catalog[$0] }, readingIDs: { ids },
                               symbolExists: { SpriteSymbols.exists($0) },
                               spriteDirectory: { override ?? SpriteFolders.directory(for: $0, root: root).path },
                               hasFiles: { id in overrideFiles ?? SpriteFolders.hasFiles(in: SpriteFolders.directory(for: id, root: root)) })
    }

    func folder(_ id: UUID) -> URL { SpriteFolders.directory(for: id, root: host.spritesRoot) }

    /// What `save` would store, without saving: the summary and spec of a dry run match a real apply.
    func normalizedForPreview(_ config: SpriteConfiguration) -> SpriteConfiguration {
        var value = config
        value.normalize()
        return value
    }

    // MARK: Files

    /// Writes the files a spec carries into its sprite's folder and removes the ones a previous spec wrote
    /// that this one no longer carries. Everything else in the folder is the scripts' own (a cache, a log, a
    /// chart.png) and is left alone, dotfiles and folders included, and so is a file the spec wrote that a
    /// script has since made too large or binary for `get` to carry: only what `get` shows can be removed by
    /// leaving it out. The names written are kept in the folder's manifest, so `get` carries exactly these.
    /// An empty set removes the folder, as documented.
    ///
    /// Names are compared case-insensitively, as the default APFS volume compares them: renaming `Prs.py` to
    /// `prs.py` renames the file rather than writing one name and deleting the other (which on that volume is
    /// the same file).
    func writeFiles(_ files: [String: String], for id: UUID) throws {
        let manager = FileManager.default
        let directory = folder(id)
        if files.isEmpty {
            if manager.fileExists(atPath: directory.path) { try? manager.removeItem(at: directory) }
            return
        }
        try checkFiles(files)
        do {
            let previous = Array(SpriteFolders.contents(in: directory).files.keys)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let wanted = Dictionary(files.keys.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            for name in SpriteFolders.entries(in: directory) {
                if let spelled = wanted[name.lowercased()], spelled != name {
                    // rename(2) changes only the case on a case-insensitive volume, where FileManager would refuse.
                    _ = Darwin.rename(directory.appendingPathComponent(name).path, directory.appendingPathComponent(spelled).path)
                }
            }
            try Self.write(files, to: directory)
            for name in previous where wanted[name.lowercased()] == nil {
                let url = directory.appendingPathComponent(name)
                if (try? manager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular { try manager.removeItem(at: url) }
            }
            try SpriteFolders.writeManifest(Array(files.keys), in: directory)
        } catch {
            throw AgentFailure(.internalError, "Could not write the sprite's files in \(directory.path): \(error.localizedDescription)")
        }
    }

    /// What `writeFiles` and a draft's run accept; the compiler checks the same, this is the last line.
    func checkFiles(_ files: [String: String]) throws {
        var problems: [SpecDiagnostic] = []
        if files.count > SpriteFolders.maximumFiles { problems.append(.error("files", "A sprite holds at most \(SpriteFolders.maximumFiles) files.")) }
        var folded: [String: String] = [:]
        for name in files.keys.sorted() {
            if !SpriteFolders.isValidName(name) { problems.append(.error("files.\(name)", "File names use letters, digits, “.”, “_” and “-”, and do not start with a dot.")) }
            if (files[name]?.utf8.count ?? 0) > SpriteFolders.maximumFileBytes { problems.append(.error("files.\(name)", "Larger than \(SpriteFolders.maximumFileBytes / 1024) KiB.")) }
            if let other = folded[name.lowercased()] {
                problems.append(.error("files.\(name)", "Differs from “\(other)” only by case; a Mac's disk treats them as one file."))
            } else { folded[name.lowercased()] = name }
        }
        guard problems.isEmpty else { throw invalid(problems) }
    }

    /// Writes `files` into `directory` (created 0700), each atomically; a file starting with `#!` is made
    /// executable.
    static func write(_ files: [String: String], to directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, content) in files {
            let url = directory.appendingPathComponent(name)
            try Data(content.utf8).write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: content.hasPrefix("#!") ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
    }

    // MARK: Helpers

    func invalid(_ diagnostics: [SpecDiagnostic]) -> AgentFailure {
        let errors = diagnostics.filter { $0.severity == .error }
        let first = errors.first.map { " First: \($0)" } ?? ""
        return AgentFailure(.invalidSpec, "The spec has \(errors.count) error\(errors.count == 1 ? "" : "s").\(first)", diagnostics: diagnostics)
    }

    func merged(_ first: [SpecDiagnostic], _ second: [SpecDiagnostic]) -> [SpecDiagnostic] {
        var result = first
        for diagnostic in second where !result.contains(diagnostic) { result.append(diagnostic) }
        return result
    }

    private func spec(_ args: JSONValue, _ op: AgentOp) throws -> JSONValue {
        guard let spec = args["spec"], !spec.isNull else { throw AgentFailure(.badRequest, "\(op.rawValue) needs a “spec”.") }
        return spec
    }

    /// A render's arguments, with the stand-ins taken as sent (like the spec) so they keep the order written.
    private func rendering(_ args: JSONValue) throws -> RenderArgs {
        var render = try decode(RenderArgs.self, args, .render)
        render.values = args["values"]
        return render
    }

    private func decode<T: Decodable>(_ type: T.Type, _ args: JSONValue, _ op: AgentOp) throws -> T {
        do { return try args.decode(T.self) } catch {
            throw AgentFailure(.badRequest, "The arguments to \(op.rawValue) are not right: \(Self.describe(error))")
        }
    }

    /// Encodes a result; `spec` replaces its `spec` member so the spec keeps its own key order.
    private func encode<T: Encodable>(_ value: T, spec: JSONValue? = nil) throws -> JSONValue {
        var json = try JSONValue(encoding: value)
        if let spec { json.set("spec", spec) }
        return json
    }

    static func describe(_ error: any Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _)?: "“\(key.stringValue)” is missing."
        case .typeMismatch(let type, let context)?: "“\(context.codingPath.map(\.stringValue).joined(separator: "."))” should be \(type)."
        case .valueNotFound(_, let context)?: "“\(context.codingPath.map(\.stringValue).joined(separator: "."))” is null."
        case .dataCorrupted(let context)?: context.debugDescription
        default: "\(error)"
        }
    }
}
