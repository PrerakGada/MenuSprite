import AgentProtocol
import AppKit
import SpriteSpec
import SwiftUI
import SystemMonitoring

// The board blocks that draw what the user's own tools produce: blocks a script prints, images a file
// or link holds, and switches that run a command each way. Spec: `docs/agent-authoring.md` ("Board").

// MARK: - Script blocks

/// A command that prints blocks as JSON, drawn in place. The command runs while the board is open
/// (`SpriteDesign.boardScriptCommands`); its output is parsed once per change, not on every redraw.
struct BoardScriptBlocks: View {
    let block: BoardBlock
    let context: BoardContext
    @State private var cache = ScriptBlocksCache()

    var body: some View {
        let monitoring = context.environment.monitoring
        let command = block.command ?? CommandSource()
        VStack(alignment: .leading, spacing: block.style.spacing) {
            if command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Write a command that prints blocks as JSON").font(.caption).foregroundStyle(.secondary)
            } else if let result = monitoring.commands.result(for: command) {
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let problem = result.problem, output.isEmpty || result.status != 0 {
                    BoardDiagnostics(lines: [BoardActions.failure(problem, errorOutput: result.errorOutput)])
                }
                if !output.isEmpty {
                    let parsed = cache.parse(result.output, design: context.design, directory: BoardScriptBlocks.directory(of: command))
                    let inner = innerContext(variables: parsed.variables)
                    ForEach(parsed.blocks) { child in BlockView(block: child, context: inner) }
                    if !parsed.diagnostics.isEmpty {
                        BoardDiagnostics(lines: parsed.diagnostics.prefix(3).map { ($0.path.isEmpty ? "" : "\($0.path): ") + $0.message }
                                         + (parsed.diagnostics.count > 3 ? ["and \(parsed.diagnostics.count - 3) more"] : []))
                    }
                }
            } else {
                Text("Running…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The printed blocks see the sprite's values plus the literal ones the script printed, and are never
    /// selectable on their own in the studio: they belong to the command, not the design. Their actions re-run
    /// the sprite's commands afterwards, this one included, so a printed switch shows what it changed.
    private func innerContext(variables: [SpriteVariable]) -> BoardContext {
        var design = context.design
        let known = Set(design.variables.map(\.id))
        design.variables += variables.filter { !known.contains($0.id) }
        var inner = BoardContext(design: design, values: context.values, overrides: context.overrides,
                                 environment: context.environment, editing: nil, config: context.config)
        inner.inherited = context.inherited
        return inner
    }

    /// Where the script ran, so a relative image it names is found there: the sprite's folder when it has
    /// one, else nil (the home folder).
    static func directory(of command: CommandSource) -> String? {
        CommandVariableRunner.existingDirectory(command.directory)
    }
}

/// The last parse of a script's output, reused until the output (or the design it refers to) changes.
@MainActor
final class ScriptBlocksCache {
    typealias Parsed = (blocks: [BoardBlock], variables: [SpriteVariable], diagnostics: [SpecDiagnostic])
    private var output: String?
    private var design: SpriteDesign?
    private var directory: String?
    private var parsed: Parsed = ([], [], [])

    func parse(_ output: String, design: SpriteDesign, directory: String?) -> Parsed {
        if output == self.output, design == self.design, directory == self.directory { return parsed }
        parsed = SpriteSpecFormat.scriptBlocks(output, design: design, directory: directory)
        self.output = output; self.design = design; self.directory = directory
        return parsed
    }
}

/// Problems with a script's output, in place of what it would have drawn.
struct BoardDiagnostics: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(8).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Images

/// A picture from a file (absolute, `~/…`, or in the sprite's folder) or an https link, fitted within
/// the block's height. A file is read again whenever it changes on disk, checked each time the board
/// redraws, so a script that rewrites it is shown at its next run.
struct BoardImage: View {
    let block: BoardBlock
    let context: BoardContext
    @State private var cache = ImageFileCache()

    /// Larger files are refused rather than held in memory while the board is open.
    static let fileLimit = 20 * 1024 * 1024

    var body: some View {
        let source = block.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let height = max(16, block.style.height)
        Group {
            if source.isEmpty {
                missing("Choose an image file or an https link")
            } else if let url = URL(string: source), url.scheme?.lowercased() == "https" {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): fitted(image.resizable())
                    case .failure: missing("Could not load \(url.host() ?? "the link")")
                    default: ProgressView().controlSize(.small)
                    }
                }
            } else if let url = URL(string: source), let scheme = url.scheme?.lowercased(), scheme != "file", scheme.count > 1 {
                missing("Images load from files or https links")
            } else {
                // The folder the commands carry when it exists (a draft preview's temporary copy), else the sprite's own.
                let folder = CommandVariableRunner.existingDirectory(context.design.filesDirectory).map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? SpriteFolders.directory(for: context.config.id)
                let path = BoardImage.path(source, folder: folder)
                switch cache.load(path) {
                case .image(let image): fitted(Image(nsImage: image).resizable())
                case .missing:
                    missing(BoardImage.isInFolder(source) ? "No \(source) in the sprite's folder yet" : "No image at \(BoardImage.shortened(path))")
                case .unreadable: missing("Not an image: \(BoardImage.shortened(path))")
                case .tooLarge: missing("Larger than \(BoardImage.fileLimit / 1024 / 1024) MB: \(BoardImage.shortened(path))")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    private func fitted(_ image: Image) -> some View {
        image.interpolation(.high).aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func missing(_ message: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: "photo").font(.system(size: 18)).foregroundStyle(.secondary)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    /// `source` as a file path: a file URL, absolute, under home, or relative to the sprite's folder.
    static func path(_ source: String, folder: URL) -> String {
        if let url = URL(string: source), url.isFileURL { return url.path }
        if source.hasPrefix("/") { return source }
        if source.hasPrefix("~") { return (source as NSString).expandingTildeInPath }
        return folder.appendingPathComponent(source).standardizedFileURL.path
    }
    static func isInFolder(_ source: String) -> Bool {
        !source.hasPrefix("/") && !source.hasPrefix("~") && !(URL(string: source)?.isFileURL ?? false)
    }
    static func shortened(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// One decoded image file, reloaded only when the file's size or modification time changes.
@MainActor
final class ImageFileCache {
    enum Loaded { case image(NSImage), missing, unreadable, tooLarge }
    private var stamp: String?
    private var loaded: Loaded = .missing

    func load(_ path: String) -> Loaded {
        // A symbolic link is followed before it is examined: its own size and date say nothing about the
        // picture it points at, so a rewritten target would never reload and a huge one would pass the limit.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            stamp = nil; loaded = .missing; return .missing
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let current = "\(resolved)|\(size)|\(modified)"
        guard current != stamp else { return loaded }
        stamp = current
        if size > BoardImage.fileLimit { loaded = .tooLarge; return loaded }
        // Read at most one byte past the limit, so a file that grew since it was examined is still refused.
        guard let handle = FileHandle(forReadingAtPath: resolved) else { loaded = .unreadable; return loaded }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: BoardImage.fileLimit + 1)) ?? Data()
        if data.count > BoardImage.fileLimit { loaded = .tooLarge }
        else if let image = NSImage(data: data) { loaded = .image(image) }
        else { loaded = .unreadable }
        return loaded
    }
}

// MARK: - Switches

/// A switch showing a value and running one command to turn it on and another to turn it off. While
/// the command runs the switch shows where it is going; afterwards the value's command runs again so
/// the switch shows what actually happened.
struct BoardToggle: View {
    let block: BoardBlock
    let context: BoardContext
    @State private var running = false
    @State private var pending: Bool?
    /// The state of a switch with no value behind it, which only remembers its last flip.
    @State private var local = false
    @State private var outcome: BoardActions.Outcome?

    var body: some View {
        let variable = context.variable(block.variable)
        let isOn = pending ?? variable.map { BoardToggle.isOn(context.values, $0) } ?? local
        let symbol = context.overrides[block.id]?.symbol ?? block.symbol
        let text = context.text(block)
        let title = text.isEmpty ? (variable?.name ?? "Switch") : text
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if !symbol.isEmpty { Image(systemName: symbol).font(.system(size: 13)).frame(width: 18) }
                BoardText(text: title, style: block.style).font(.system(size: 13))
                Spacer(minLength: 6)
                if running { ProgressView().controlSize(.small) }
                Toggle(title, isOn: Binding(get: { isOn }, set: { flip($0) }))
                    .toggleStyle(BoardSwitchStyle(tint: context.color(block) ?? .accentColor, title: title))
                    .labelsHidden()
                    .disabled(running || (isOn ? block.offAction : block.action) == nil)
            }
            if let outcome, let text = outcome.text, outcome.failed || text != "Done" {
                Text(text).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(outcome.failed ? Color.orange : Color.secondary).lineLimit(8).textSelection(.enabled)
            }
        }
    }

    private func flip(_ on: Bool) {
        guard let action = on ? block.action : block.offAction, !running else { return }
        running = true; pending = on; outcome = nil
        let context = context, hasValue = block.variable != nil
        Task {
            let result = await BoardActions.run(action, context: context)
            // Held where it is going until the sprite's commands have read the new state back.
            await BoardActions.afterwards(action, context: context)
            if !hasValue, !result.failed { local = on }
            outcome = result; pending = nil; running = false
        }
    }

    static let onWords: Set<String> = ["true", "on", "yes", "enabled", "active", "up", "connected", "running"]

    /// On for a non-zero number or one of the "on" words, in any case.
    static func isOn(_ values: DesignValues, _ variable: SpriteVariable) -> Bool {
        if let number = values.number(variable) { return number != 0 }
        guard let text = values.text(variable) else { return false }
        return onWords.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// A switch drawn as shapes: a capsule track filled with the block's colour (else the accent colour) when on,
/// and a white knob. The system switch draws its on state grey in a window that is not key, which is how a
/// board's popover and an off-screen preview both draw, so on and off could not be told apart.
struct BoardSwitchStyle: ToggleStyle {
    let tint: Color
    var title = ""
    func makeBody(configuration: Configuration) -> some View {
        BoardSwitch(isOn: configuration.$isOn, tint: tint).accessibilityLabel(title)
    }
}

private struct BoardSwitch: View {
    @Binding var isOn: Bool
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(isOn ? 0 : 0.08)))
            .frame(width: 32, height: 19)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 0.8, y: 0.5).padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: isOn)
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Capsule())
            .onTapGesture { if enabled { isOn.toggle() } }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAction { if enabled { isOn.toggle() } }
    }
}

/// A gauge's level drawn as shapes: a rounded track in the text's quaternary shade, filled in the gauge's
/// colour (else the accent colour). A ProgressView's tint is drawn grey wherever the window is not key.
struct BoardLevelBar: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        Capsule().fill(.quaternary)
            .overlay { LevelShape(fraction: fraction.isFinite ? min(1, max(0, fraction)) : 0).fill(tint) }
            .frame(height: 6)
    }
    private struct LevelShape: Shape {
        let fraction: Double
        func path(in rect: CGRect) -> Path {
            guard fraction > 0 else { return Path() }
            // Never narrower than it is tall, so a sliver still reads as a rounded fill.
            let width = max(rect.height, rect.width * fraction)
            return Capsule().path(in: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
        }
    }
}

// MARK: - Chart series

/// What a chart draws for a value: a reading's history, the numbers a command produced while the board
/// (or the sprite, for a background command) was running, or a literal series ("3, 5, 2") a script printed.
@MainActor
struct BoardChartSeries {
    var points: [HistoryPoint]
    var percent = false
    /// The newest figure, shown instead of a literal series' whole text.
    var latest: String?
    /// Said over the chart until there are two points to join.
    var waiting: String?

    init?(_ variable: SpriteVariable, monitoring: MonitoringStore) {
        switch variable.source {
        case .reading(let id):
            points = monitoring.history[id] ?? []
            percent = monitoring.metric(id).unit == .percent
        case .command(let source):
            points = monitoring.commands.points(for: source)
            waiting = "Charting from its next run"
        case .constant(let text):
            guard let numbers = BoardChartSeries.literal(text), let last = numbers.last else { return nil }
            points = numbers.enumerated().map { HistoryPoint(time: Date(timeIntervalSinceReferenceDate: Double($0.offset)), value: $0.element) }
            latest = BoardChartSeries.compact(last)
        }
    }

    /// Two or more numbers separated by commas, else nil.
    nonisolated static func literal(_ text: String) -> [Double]? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        let numbers = parts.compactMap(Double.init).filter(\.isFinite)
        return numbers.count == parts.count ? numbers : nil
    }
    nonisolated static func compact(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e12 ? String(Int64(value))
            : String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
