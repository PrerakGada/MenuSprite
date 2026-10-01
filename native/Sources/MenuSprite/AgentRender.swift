import AgentProtocol
import AIAccounts
import AppKit
import SpriteSpec
import SwiftUI
import SystemMonitoring

/// Draws a sprite for an agent: its face exactly as the menu bar draws it, and its board through the same
/// view a click opens, after sampling the readings it uses and running its commands once, so the picture
/// shows live values. A draft spec is drawn without being saved. Every reading and command it asked for is
/// withdrawn when the files are written. Stand-in values (`RenderArgs.values`) replace live ones in the
/// picture only, so each branch of a sprite's rules can be seen without making it happen.
/// Spec: `docs/agent-authoring.md` ("Previews are real").
@MainActor
enum AgentRender {
    /// The tallest board drawn; a taller one is cut off and noted.
    static let maximumBoardHeight: CGFloat = 1600
    /// Readings get this long to produce two samples.
    static let readingWait: Double = 2.5
    /// Commands get their own timeout plus this, up to `commandWaitCap`.
    static let commandGrace: Double = 1.5
    static let commandWaitCap: Double = 30

    // MARK: Entry points

    /// A spec that is not saved: compiled as `apply` would, its files written to a temporary folder its
    /// commands run in, and that folder removed afterwards.
    static func renderDraft(spec: JSONValue, existing: SpriteConfiguration?, args: RenderArgs, service: AgentService) async throws -> RenderResult {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent("MenuSprite-draft-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: scratch) }
        let declared = spec["files"]?.members
        // Only a draft that leaves `files` out draws with the saved sprite's own.
        let existingFiles = declared == nil ? existing.map { SpriteFolders.files(in: service.folder($0.id)) } ?? [:] : [:]
        // The compiler decides from these whether commands run in the sprite's folder; for a draft that
        // folder is the scratch copy.
        let hasFiles = declared.map { !$0.isEmpty } ?? !existingFiles.isEmpty
        let environment = service.environment(directory: scratch.path, hasFiles: hasFiles)
        let (compiled, diagnostics) = SpriteSpecFormat.compile(spec, existing: existing, environment: environment)
        let all = service.merged(diagnostics, compiled?.diagnostics ?? [])
        guard let compiled else { throw service.invalid(all) }
        let files = compiled.files ?? existingFiles
        if !files.isEmpty {
            do {
                try AgentService.write(files.filter { SpriteFolders.isValidName($0.key) }, to: scratch)
            } catch {
                throw AgentFailure(.internalError, "Could not write the draft's files to \(scratch.path): \(error.localizedDescription)")
            }
        }
        // A draft of a saved sprite keeps its id: nothing a render touches is keyed on it (demand is by
        // token, command results by command), and image blocks find the saved sprite's own folder by it.
        let config = service.normalizedForPreview(compiled.config)
        var result = try await render(config, files: files, diagnostics: all, args: args, service: service)
        result.notes.insert("Draft: drawn from the spec without saving it.", at: 0)
        return result
    }

    /// A saved sprite or a compiled draft. Throws only for arguments it cannot use (an unknown appearance, a
    /// stand-in value that is a list); a picture that cannot be drawn becomes a note.
    static func render(_ config: SpriteConfiguration, files: [String: String]?, diagnostics: [SpecDiagnostic],
                       args: RenderArgs, service: AgentService) async throws -> RenderResult {
        let store = service.store
        let design = config.design ?? SpriteDesign()
        let appearances: [(name: String, appearance: NSAppearance.Name)]
        switch args.appearance?.lowercased() {
        case "dark": appearances = [("dark", .darkAqua)]
        case "light": appearances = [("light", .aqua)]
        case "both": appearances = [("dark", .darkAqua), ("light", .aqua)]
        case nil, "", "system":
            appearances = [NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? ("light", .aqua) : ("dark", .darkAqua)]
        case let other?: throw AgentFailure(.badRequest, "“appearance” is dark, light, both or system, not “\(other)”.")
        }
        let standIns = try StandIns(args.values, design: design, store: store)
        var notes = standIns.notes
        let directory = URL(fileURLWithPath: (args.directory as NSString).expandingTildeInPath, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            return RenderResult(files: [], values: [], diagnostics: diagnostics,
                                notes: ["Could not create \(directory.path): \(error.localizedDescription)"])
        }

        // What the picture reads: every reading the design names (the readings block lists them all), the
        // Battery & Power block's own, and every command — values, script rows and script blocks. A value
        // with a stand-in is neither sampled nor run, unless another value needs the same reading or command.
        let live = design.variables.filter { !standIns.replaces($0.id) }
        var metrics = Set(live.compactMap(\.readingID))
        if design.board?.root.flattened.contains(where: { $0.kind == .energy }) == true { metrics.formUnion(ProcessPanelKind.power.metricIDs) }
        if design.root.flattened.contains(where: { $0.kind == .battery }) { metrics.formUnion(["battery.charge", "battery.state", "battery.current"]) }
        let commands = Set((live.compactMap(\.command) + design.boardScriptCommands).map(\.normalized)
            .filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let owner = UUID()
        let start = Date()
        // A command already running for the menu bar has a result from before this render (perhaps from
        // before its script was edited) or a run that started before it: it runs again now, so the picture
        // shows what it prints today. One an apply just ran again or started is that fresh run already, and is
        // waited for rather than run twice. A command not running yet starts fresh with the demand below.
        let fresh = service.recentReruns()
        var since: [CommandSource: Date] = [:]
        for source in commands {
            if let asked = fresh[source] { since[source] = asked; continue }
            guard store.commands.result(for: source) != nil || store.commands.isRunning(source) else { continue }
            Task { await store.commands.run(source, trigger: .preview) }
        }
        store.setAgentDemand(owner, metrics: metrics, commands: commands)
        defer { store.setAgentDemand(owner, metrics: [], commands: []) }
        await wait(store: store, metrics: metrics, commands: commands, since: start, startedAfter: since)

        let scale = CGFloat(min(4, max(1, args.scale ?? 2)))
        let stem = fileStem(config.name)
        var rendered: [RenderedFile] = []
        var reports: [BlockReport]?

        if args.face ?? true {
            if let output = face(config, store: store, overrides: standIns.overrides, ceiling: service.host.power?.activeCeiling) {
                for (name, appearance) in appearances {
                    let url = directory.appendingPathComponent("\(stem)-face-\(name).png")
                    if let size = writeFace(output, dark: appearance == .darkAqua, scale: scale, to: url) {
                        rendered.append(RenderedFile(kind: "face", appearance: name, path: url.path, width: size.width, height: size.height))
                    } else { notes.append("Could not write \(url.path).") }
                }
            } else { notes.append("The sprite has no design to draw in the menu bar.") }
            if !config.enabled { notes.append("Disabled: the menu bar shows it paused, and its values do not run until it is enabled.") }
            if !config.showInMenuBar { notes.append("Hidden from the menu bar: the face is drawn as it would look there.") }
        }

        if args.board ?? true {
            if let board = design.board {
                // Panels that collect for themselves (processes, power, accounts, remote images) need longer.
                let slow = board.root.flattened.contains { [.processes, .energy, .accounts, .image].contains($0.kind) }
                for (name, appearance) in appearances {
                    let url = directory.appendingPathComponent("\(stem)-board-\(name).png")
                    let environment = BoardEnvironment(monitoring: store, power: service.host.power, overrides: standIns.overrides)
                    let view = BoardView(config: config, environment: environment).background(Color(nsColor: .windowBackgroundColor))
                    if let drawn = await writeBoard(view, width: board.width, appearance: appearance, scale: scale,
                                                    settle: slow ? 1.8 : 0.5, to: url) {
                        rendered.append(RenderedFile(kind: "board", appearance: name, path: url.path, width: drawn.size.width, height: drawn.size.height))
                        if drawn.clipped, name == appearances[0].name { notes.append("The board is taller than \(Int(maximumBoardHeight)) pt; the picture is cut off there and the real board scrolls.") }
                    } else { notes.append("Could not write \(url.path).") }
                }
                let found = blockReports(board, design: design, store: store, waited: commandWait(commands))
                reports = found.reports
                notes += found.notes
            } else {
                notes.append("No board of its own: a click opens the classic \(classicPanel(config)), which render does not draw. Add a \"board\" to design one.")
            }
        }

        return RenderResult(files: rendered, values: valueStates(design, store: store, overrides: standIns.overrides, service: service),
                            diagnostics: diagnostics, notes: notes, blocks: reports)
    }

    /// The face as the menu bar draws it (`MonitoringStore.renderDesign`), from stand-in values when there are any.
    static func face(_ config: SpriteConfiguration, store: MonitoringStore, overrides: [String: ValueOverride], ceiling: Int?) -> DesignRenderer.Output? {
        guard !overrides.isEmpty else { return store.renderDesign(config, ceiling: ceiling) }
        guard let design = config.design else { return nil }
        var glyph: BatteryGlyph?
        if design.root.flattened.contains(where: { $0.kind == .battery }) {
            glyph = store.batteryGlyph(ceiling: ceiling)
            glyph?.percentInside = config.enabled
        }
        return DesignRenderer.render(design, values: store.designValues(design, overrides: overrides), height: NSStatusBar.system.thickness,
                                     battery: glyph)
    }

    // MARK: Sampling

    /// Readings an agent asked about, sampled through the store's own schedule (rates need two samples).
    static func sample(store: MonitoringStore, metrics: Set<String>) async {
        guard !metrics.isEmpty else { return }
        let owner = UUID()
        store.setAgentDemand(owner, metrics: metrics, commands: [])
        await wait(store: store, metrics: metrics, commands: [], since: Date())
        store.setAgentDemand(owner, metrics: [], commands: [])
    }

    /// How long a render waits for its commands: the slowest one's timeout and a little, within a cap.
    static func commandWait(_ commands: Set<CommandSource>) -> Double {
        min(commandWaitCap, (commands.map(\.timeout).max() ?? 0) + commandGrace)
    }

    /// Until two local samples have landed (or `readingWait`), AI limits have an answer, and every command
    /// has a result from a run that started after `since` (or its own date in `startedAfter`), or until
    /// `commandWait`. A run's start, not its end, decides: one that began before the request (before a
    /// script was rewritten, say) may end after it and still print the old script's output.
    static func wait(store: MonitoringStore, metrics: Set<String>, commands: Set<CommandSource>, since: Date,
                     startedAfter: [CommandSource: Date] = [:]) async {
        let start = ProcessInfo.processInfo.systemUptime
        let startCount = store.sampleCount
        let local = metrics.contains { !$0.hasPrefix(AIUsageMetrics.prefix) }
        let ai = metrics.filter { $0.hasPrefix(AIUsageMetrics.prefix) }
        let limit = commandWait(commands)
        while true {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let readingsDone = elapsed >= readingWait
                || ((!local || store.sampleCount - startCount >= 2) && ai.allSatisfy { store.readings[$0] != nil })
            let commandsDone = elapsed >= limit || commands.allSatisfy { source in
                guard let result = store.commands.result(for: source) else { return false }
                return result.finishedAt.addingTimeInterval(-result.elapsed) >= startedAfter[source] ?? since
            }
            if readingsDone && commandsDone { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Drawing

    /// The face on a strip coloured like the menu bar, the image tinted as the bar tints a template image.
    static func writeFace(_ output: DesignRenderer.Output, dark: Bool, scale: CGFloat, to url: URL) -> (width: Int, height: Int)? {
        let margin: CGFloat = 8
        let size = NSSize(width: ceil(output.size.width + margin * 2), height: ceil(output.size.height))
        let pixels = (width: Int(size.width * scale), height: Int(size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels.width, pixelsHigh: pixels.height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        (dark ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        SpriteStudioRenderHarness.tinted(output.image, dark: dark)
            .draw(in: NSRect(x: margin, y: 0, width: output.size.width, height: output.size.height))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = size
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else { return nil }
        return pixels
    }

    /// A board drawn at its own width and the height it asks for, in a window that is never shown.
    static func writeBoard<V: View>(_ view: V, width: Double, appearance: NSAppearance.Name, scale: CGFloat, settle: Double,
                                    to url: URL) async -> (size: (width: Int, height: Int), clipped: Bool)? {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        // Drawn as in a key window: an off-screen window never becomes key, and controls would otherwise
        // draw in their inactive grey (a switch's on state and a gauge's tint would not show).
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .environment(\.controlActiveState, .key))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(Int(settle * 1000)))
        let fitting = host.fittingSize.height
        let height = min(maximumBoardHeight, max(40, ceil(fitting)))
        window.setContentSize(NSSize(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let pixels = (width: Int(width * scale), height: Int(height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels.width, pixelsHigh: pixels.height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: width, height: height)
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else { return nil }
        return (pixels, fitting > maximumBoardHeight)
    }

    // MARK: Reporting

    /// What every value showed, so an agent can tell a blank from a failing command. A failing command's
    /// problem ends with the last lines it wrote to standard error, where a traceback names its exception.
    static func valueStates(_ design: SpriteDesign, store: MonitoringStore, overrides: [String: ValueOverride],
                            service: AgentService) -> [ValueState] {
        let values = store.designValues(design, overrides: overrides)
        return design.variables.map { variable in
            if let standIn = overrides[variable.id], standIn.text != nil || standIn.number != nil {
                return ValueState(id: variable.id, name: variable.name, value: values.formatted(variable), problem: nil)
            }
            switch variable.source {
            case .reading(let id):
                let reading = store.readings[id]
                return ValueState(id: variable.id, name: variable.name, value: reading?.available == true ? values.formatted(variable) : nil,
                                  problem: service.readingProblem(id, reading: reading))
            case .command(let source):
                guard let result = store.commands.result(for: source) else {
                    return ValueState(id: variable.id, name: variable.name, value: nil, problem: "Did not finish in time.")
                }
                let problem = result.problem.map { problem in
                    let tail = lastLines(result.errorOutput, count: 3, folder: source.directory).replacingOccurrences(of: "\n", with: " / ")
                    return tail.isEmpty ? problem : "\(problem): \(tail)"
                }
                return ValueState(id: variable.id, name: variable.name, value: result.available ? values.formatted(variable) : nil, problem: problem)
            case .constant(let text):
                return ValueState(id: variable.id, name: variable.name, value: text, problem: nil)
            }
        }
    }

    /// Every script-rows and script-blocks block: its path in the spec, why it drew nothing, the end of its
    /// standard error, and what its rows and buttons do. A script block's warnings (an unknown `{word}`) come
    /// back as notes.
    static func blockReports(_ board: BoardDesign, design: SpriteDesign, store: MonitoringStore, waited: Double)
        -> (reports: [BlockReport], notes: [String]) {
        var reports: [BlockReport] = []
        var notes: [String] = []
        for (block, path) in pathed(board) where block.kind == .script || block.kind == .blocks {
            guard let source = block.command?.normalized, !source.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let kind = block.kind == .script ? "script" : "blocks"
            var report = BlockReport(path: path, kind: kind, command: source.command)
            guard let result = store.commands.result(for: source) else {
                report.problem = "Did not finish within \(Int(waited.rounded(.up))) s (its timeout is \(Int(source.timeout)) s)."
                reports.append(report); continue
            }
            if let problem = result.problem {
                report.problem = problem
                let tail = lastLines(result.errorOutput, count: 6, folder: source.directory)
                report.stderr = tail.isEmpty ? nil : tail
                reports.append(report); continue
            }
            if block.kind == .script {
                report.rows = scriptRows(result.output)
            } else {
                let parsed = SpriteSpecFormat.scriptBlocks(result.output, design: design, directory: source.directory)
                let errors = parsed.diagnostics.filter { $0.severity == .error }
                if parsed.blocks.isEmpty, let first = errors.first {
                    report.problem = "Its output is not blocks: \(first)"
                } else {
                    report.rows = printedBlocks(parsed.blocks)
                    for diagnostic in parsed.diagnostics { notes.append("\(path) printed: \(diagnostic)") }
                }
            }
            reports.append(report)
        }
        return (reports, notes)
    }

    /// Every block of a board with its spec path: the board's own blocks are `board.blocks[i]`, a container's
    /// children `….stack[j]`, `….row[j]` or `….card[j]`, as the spec writes them.
    static func pathed(_ board: BoardDesign) -> [(BoardBlock, String)] {
        var result: [(BoardBlock, String)] = []
        func walk(_ block: BoardBlock, _ path: String) {
            result.append((block, path))
            guard block.kind.isContainer else { return }
            for (index, child) in block.children.enumerated() { walk(child, "\(path).\(block.kind.rawValue)[\(index)]") }
        }
        for (index, child) in board.root.children.enumerated() { walk(child, "board.blocks[\(index)]") }
        return result
    }

    static let reportedRows = 30

    /// Script rows as text: `“#12 Fix login” → https://…`, `“Restart” runs `brew services restart x``, `---`.
    static func scriptRows(_ output: String) -> [String] {
        let lines = ScriptLine.parse(output)
        var rows = lines.prefix(reportedRows).map { line -> String in
            if line.isDivider { return "---" }
            var text = String(repeating: "  ", count: line.depth) + "“\(clipped(line.text, 70))”"
            if let href = line.href { text += " → \(clipped(href, 120))" }
            if let bash = line.bash { text += " runs `\(clipped(bash, 100))`" }
            return text
        }
        if lines.count > reportedRows { rows.append("… \(lines.count - reportedRows) more rows") }
        return rows
    }

    /// Printed blocks as text: how many, then each one that does something when clicked.
    static func printedBlocks(_ blocks: [BoardBlock]) -> [String] {
        let all = blocks.flatMap(\.flattened)
        var rows = ["\(all.count) block\(all.count == 1 ? "" : "s")"]
        for block in all {
            let title = block.segments.compactMap { if case .literal(let text) = $0 { text } else { nil } }.joined()
            let label = title.isEmpty ? block.kind.title : "\(block.kind.title) “\(clipped(title, 60))”"
            if block.kind == .toggle {
                let on = block.action.map { "on runs `\(clipped($0.value, 80))`" } ?? "no on command"
                let off = block.offAction.map { "off runs `\(clipped($0.value, 80))`" } ?? "no off command"
                rows.append("\(label): \(on), \(off)")
            } else if let action = block.action {
                rows.append("\(label) \(describe(action))")
            }
            if rows.count > reportedRows { rows.append("… and more"); break }
        }
        return rows
    }

    static func describe(_ action: BoardAction) -> String {
        switch action.kind {
        case .runCommand: "runs `\(clipped(action.value, 100))`"
        case .openURL: "→ \(clipped(action.value, 120))"
        case .openApp: "opens the app \(action.value)"
        case .copyText: "copies “\(clipped(action.value, 60))”"
        case .refresh: "refreshes the board"
        }
    }

    static func clipped(_ text: String, _ limit: Int) -> String { text.count > limit ? String(text.prefix(limit - 1)) + "…" : text }

    /// The last lines of a stream that say something (a traceback's exception is its last line), with the
    /// folder the command ran in written as `$SPRITE_DIR` so a long temporary path does not crowd out the
    /// message. Python's "Traceback (most recent call last):" and its `~~^^` underlines are left out.
    static func lastLines(_ text: String, count: Int, folder: String?) -> String {
        let lines = shortened(text, folder: folder).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && line != "Traceback (most recent call last):" && !line.allSatisfy { "~^ ".contains($0) } }
        return lines.suffix(count).map { clipped($0, 240) }.joined(separator: "\n")
    }

    /// `text` with the command's folder (and its /private twin) written as `$SPRITE_DIR`.
    static func shortened(_ text: String, folder: String?) -> String {
        guard let folder, !folder.isEmpty else { return text }
        var result = text
        let resolved = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        for path in Set([resolved, folder, "/private" + folder]).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: path, with: "$SPRITE_DIR")
        }
        return result
    }

    static func classicPanel(_ config: SpriteConfiguration) -> String {
        if config.opensAccountsBoard { return "AI Accounts board" }
        switch config.processPanelKind {
        case .power?: return "Battery & Power dashboard"
        case .cpu?: return "CPU process panel"
        case .memory?: return "memory panel"
        default: return config.opensFanBoard ? "fan controls" : "readings panel"
        }
    }

    /// A file name from the sprite's name: lowercase letters, digits and dashes.
    static func fileStem(_ name: String) -> String {
        let stem = name.lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return stem.isEmpty ? "sprite" : String(stem.prefix(40))
    }
}

/// Stand-in values for one render, read from `RenderArgs.values`: `{"free": 12, "state": "Running",
/// "session.pace": "over", "awake": true}`. A number or text replaces the value (formatted as the live one
/// would be: a reading's unit, a command's suffix); `id.pace` replaces a Claude/Codex limit's pace alone. A
/// value with a stand-in is not sampled or run for the picture. Unknown ids are noted, not fatal.
@MainActor
struct StandIns {
    var overrides: [String: ValueOverride] = [:]
    var notes: [String] = []

    static let paces = ["on track", "ahead", "over"]

    init(_ value: JSONValue?, design: SpriteDesign, store: MonitoringStore) throws {
        guard let value, !value.isNull else { return }
        guard let members = value.members else {
            throw AgentFailure(.badRequest, "“values” is an object of stand-in values by value id, such as {\"free\": 12, \"session.pace\": \"over\"}; not \(value.typeName).")
        }
        var used: [String] = []
        for member in members {
            let key = member.key
            let isPace = key.lowercased().hasSuffix(".pace")
            let id = isPace ? String(key.dropLast(5)) : key
            guard let variable = design.variable(id) else {
                let ids = design.variables.map(\.id)
                notes.append("values.\(key): the sprite has no value “\(id)”, so it was ignored. "
                             + (ids.isEmpty ? "It has no values." : "Its values: \(ids.joined(separator: ", ")).")); continue
            }
            var standIn = overrides[id] ?? ValueOverride()
            if isPace {
                guard variable.readingID.map({ store.metric($0).group == .ai }) == true else {
                    notes.append("values.\(key): “\(id)” is not a Claude/Codex limit, so it has no pace; ignored."); continue
                }
                let pace = member.value.string?.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
                guard let pace, Self.paces.contains(pace) else {
                    throw AgentFailure(.badRequest, "values.\(key) is “on track”, “ahead” or “over”, not \(member.value.serialized()).")
                }
                standIn.pace = pace
            } else {
                switch member.value {
                case .number(let number): standIn.number = number; standIn.text = nil
                case .string(let text): standIn.text = text; standIn.number = Double(text.trimmingCharacters(in: .whitespaces))
                case .bool(let flag): standIn.text = flag ? "true" : "false"; standIn.number = flag ? 1 : 0
                case .null: standIn.missing = true; standIn.text = nil; standIn.number = nil
                default:
                    throw AgentFailure(.badRequest, "values.\(key) is a number, text, true/false or null (missing) — the value as its command or reading would give it — not \(member.value.typeName).")
                }
            }
            overrides[id] = standIn
            used.append("\(key) = \(member.value.serialized())")
        }
        if !used.isEmpty { notes.insert("Stand-in values, drawn instead of live ones: \(used.joined(separator: ", ")).", at: 0) }
    }

    /// Whether the value itself is stood in (a pace alone leaves the value live).
    func replaces(_ id: String) -> Bool { overrides[id].map { $0.text != nil || $0.number != nil } ?? false }
}
