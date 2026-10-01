import AppKit
import SwiftUI
import SystemMonitoring

/// Everything a board's blocks can draw from or act on.
@MainActor
struct BoardEnvironment {
    let monitoring: MonitoringStore
    let power: PowerStore?
    /// Stand-in values by value id, for an agent's preview only (empty everywhere else).
    var overrides: [String: ValueOverride] = [:]
    var accounts: AccountsStore? { (NSApp.delegate as? AppDelegate)?.accountsStore }
}

/// In the studio the board is a canvas: blocks select on click and move by dragging.
struct BoardEditing: Sendable {
    var selection: String?
    var select: @MainActor @Sendable (String?) -> Void
    var move: @MainActor @Sendable (String, DropEdge, String) -> Void
    var insert: @MainActor @Sendable (String, DropEdge, String) -> Void
}

/// A sprite's custom board: what opens when it is clicked, and the studio's live canvas.
struct BoardView: View {
    let config: SpriteConfiguration
    let environment: BoardEnvironment
    @ObservedObject var monitoring: MonitoringStore
    var editing: BoardEditing? = nil
    var configure: () -> Void = {}

    init(config: SpriteConfiguration, environment: BoardEnvironment, editing: BoardEditing? = nil, configure: @escaping () -> Void = {}) {
        self.config = config; self.environment = environment; self.monitoring = environment.monitoring
        self.editing = editing; self.configure = configure
    }

    var body: some View {
        let design = config.design ?? SpriteDesign()
        let board = design.board ?? BoardDesign()
        let values = monitoring.designValues(design, overrides: environment.overrides)
        let context = BoardContext(design: design, values: values, overrides: SpriteRules.evaluate(design, values: values),
                                   environment: environment, editing: editing, config: config)
        VStack(alignment: .leading, spacing: 12) {
            if board.showHeader {
                HStack(spacing: 8) {
                    Image(systemName: config.symbol).font(.system(size: 14, weight: .semibold))
                    Text(config.name).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if editing == nil { Button("Configure…", action: configure).controlSize(.small) }
                }
            }
            BlockView(block: board.root, context: context)
        }
        .padding(16)
        .frame(width: board.width, alignment: .topLeading)
    }
}

/// What every block needs while drawing: values, rule results, and the studio's editing hooks.
@MainActor
struct BoardContext {
    let design: SpriteDesign
    let values: DesignValues
    let overrides: [String: NodeOverride]
    let environment: BoardEnvironment
    let editing: BoardEditing?
    let config: SpriteConfiguration
    /// The colour the enclosing block draws in, which "inherit" takes; nil is the system's own.
    var inherited: Color? = nil

    func text(_ block: BoardBlock) -> String { render(overrides[block.id]?.text ?? block.segments) }
    func render(_ segments: [TextSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .literal(let text): text
            case .value(let id): design.variable(id).map(values.formatted) ?? "?"
            }
        }.joined()
    }
    func color(_ block: BoardBlock) -> Color? {
        let hex = overrides[block.id]?.color ?? block.style.color
        return hex == "inherit" || hex == "auto" ? nil : spriteColor(hex)
    }
    /// The block's fill as stored (RRGGBB or a system colour name), or nil when it has none.
    func background(_ block: BoardBlock) -> String? {
        let stored = block.style.background.trimmingCharacters(in: .whitespaces)
        return stored.lowercased() == "none" || SpriteColors.color(stored) == nil ? nil : stored
    }
    /// What the block's text draws in: its own colour, else black or white for legibility on its fill, else
    /// whatever the enclosing block draws in. A gauge, chart or switch puts its colour on its bar, line or
    /// track instead, so its caption and figure stay as legible as the text around them.
    func foreground(_ block: BoardBlock) -> Color? {
        if !BoardContext.colorsItsMark(block.kind), let explicit = color(block) { return explicit }
        if let fill = background(block) { return BoardContext.contrasting(fill) }
        return inherited
    }
    static func colorsItsMark(_ kind: BoardBlockKind) -> Bool { kind == .gauge || kind == .chart || kind == .toggle }
    func inheriting(_ color: Color?) -> BoardContext { var copy = self; copy.inherited = color; return copy }
    func variable(_ id: String?) -> SpriteVariable? { id.flatMap(design.variable) }

    /// Black on light fills and white on dark ones, by relative luminance (a named colour as it resolves now).
    static func contrasting(_ stored: String) -> Color {
        guard let rgb = SpriteColors.color(stored)?.usingColorSpace(.sRGB) else { return .primary }
        func linear(_ channel: CGFloat) -> Double {
            let c = Double(channel)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return luminance > 0.4 ? .black : .white
    }
}

/// One block and, in the studio, its selection outline, click and drag handling.
struct BlockView: View {
    let block: BoardBlock
    let context: BoardContext

    var body: some View {
        if !(context.overrides[block.id]?.hidden ?? block.style.hidden) || context.editing != nil {
            // A card draws its own fill in its own shape; every other block gets the shared rounded one.
            let fill = block.kind == .card ? nil : context.background(block)
            let foreground = context.foreground(block)
            // The modifiers stay the same whether or not there is a fill, so a rule that recolours a
            // block does not reset a switch or button inside it.
            let content = BlockContent(block: block, context: context.inheriting(foreground))
                .foregroundStyle(foreground ?? Color.primary)
                .padding(block.style.padding)
                .padding(fill == nil ? 0 : 8)
                .frame(maxWidth: fill == nil ? nil : .infinity, alignment: .leading)
                .background(fill.map(spriteColor) ?? Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .opacity((context.overrides[block.id]?.opacity ?? block.style.opacity) * (block.style.hidden && context.editing != nil ? 0.35 : 1))
            if let editing = context.editing, block.id != context.design.board?.root.id {
                EditableBlock(block: block, editing: editing) { content }
            } else if context.editing == nil, let action = block.action, block.kind.takesClickAction {
                BoardClickable(actions: [action], context: context) { content }
            } else {
                content
            }
        }
    }
}

private struct EditableBlock<Content: View>: View {
    let block: BoardBlock
    let editing: BoardEditing
    @ViewBuilder let content: () -> Content
    @State private var size: CGSize = .zero
    @State private var dropEdge: DropEdge?

    var body: some View {
        let selected = editing.selection == block.id
        content()
            // Controls inside do not fire while designing; the click selects the block instead.
            .allowsHitTesting(block.kind.isContainer)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : Color.accentColor.opacity(0.18),
                        style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [3, 3])))
            .overlay(alignment: alignment) { if let dropEdge { marker(dropEdge) } }
            .contentShape(Rectangle())
            .onTapGesture { editing.select(block.id) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onDrag { NSItemProvider(object: "block:\(block.id)" as NSString) }
            .onDrop(of: [.text], delegate: BlockDrop(target: block.id, size: size, editing: editing, edge: $dropEdge))
    }
    private var alignment: Alignment {
        switch dropEdge { case .left: .leading; case .right: .trailing; case .above: .top; case .below: .bottom; case nil: .center }
    }
    private func marker(_ edge: DropEdge) -> some View {
        Capsule().fill(Color.accentColor)
            .frame(width: edge == .left || edge == .right ? 3 : nil, height: edge == .above || edge == .below ? 3 : nil)
            .frame(maxWidth: edge == .above || edge == .below ? .infinity : nil, maxHeight: edge == .left || edge == .right ? .infinity : nil)
    }
    static func edge(_ point: CGPoint, size: CGSize) -> DropEdge {
        let w = max(1, size.width), h = max(1, size.height)
        let candidates: [(DropEdge, CGFloat)] = [(.left, point.x / w * 1.8), (.right, (w - point.x) / w * 1.8),
                                                 (.above, point.y / h), (.below, (h - point.y) / h)]
        return candidates.min { $0.1 < $1.1 }!.0
    }
}

/// A block or a new piece dropped on a block: the nearest edge decides where it lands.
private struct BlockDrop: DropDelegate {
    let target: String
    let size: CGSize
    let editing: BoardEditing
    @Binding var edge: DropEdge?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = EditableBlock<EmptyView>.edge(info.location, size: size)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { edge = nil }
    func performDrop(info: DropInfo) -> Bool {
        let landing = EditableBlock<EmptyView>.edge(info.location, size: size)
        edge = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let target = target, editing = editing
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let item = object as? String else { return }
            Task { @MainActor in
                if item.hasPrefix("block:") { editing.move(String(item.dropFirst(6)), landing, target) }
                else { editing.insert(item, landing, target) }
            }
        }
        return true
    }
}

// MARK: - Block content

private struct BlockContent: View {
    let block: BoardBlock
    let context: BoardContext
    private var monitoring: MonitoringStore { context.environment.monitoring }

    var body: some View {
        switch block.kind {
        case .stack:
            VStack(alignment: horizontal, spacing: block.style.spacing) { children }
                .frame(maxWidth: .infinity, alignment: frameAlignment)
        case .row:
            // Blocks share the row equally, except those marked fit, which take their natural width first.
            HStack(alignment: .top, spacing: block.style.spacing) {
                ForEach(block.children) { child in
                    if child.style.fit { BlockView(block: child, context: context).fixedSize(horizontal: true, vertical: false) }
                    else { BlockView(block: child, context: context).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
        case .card:
            VStack(alignment: horizontal, spacing: block.style.spacing) {
                let title = context.text(block)
                if !title.isEmpty {
                    Text(title).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                }
                children
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding(12)
            .background(context.background(block).map(spriteColor) ?? Color(nsColor: .controlBackgroundColor).opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
        case .divider:
            Divider()
        case .spacer:
            Color.clear.frame(height: max(2, block.style.spacing))
        case .text:
            let text = context.text(block)
            let symbol = context.overrides[block.id]?.symbol ?? block.symbol
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if !symbol.isEmpty { Image(systemName: symbol) }
                BoardText(text: text, style: block.style).multilineTextAlignment(textAlignment)
            }
            .font(font(block.style.textStyle))
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .fixedSize(horizontal: false, vertical: true)
        case .value:
            let variable = context.variable(block.variable)
            VStack(alignment: horizontal, spacing: 2) {
                let caption = context.text(block).isEmpty ? (variable?.name ?? "Value") : context.text(block)
                // A value a script printed literally has no name; it shows without a caption line.
                if !caption.isEmpty { Text(caption).font(.system(size: 11)).foregroundStyle(.secondary) }
                BoardText(text: variable.map(context.values.formatted) ?? "—", style: block.style)
                    .font(.system(size: block.style.textStyle == .huge ? 34 : 26, weight: .bold, design: .rounded)).monospacedDigit()
                let detail = context.render(block.detail)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(textAlignment)
                }
            }.frame(maxWidth: .infinity, alignment: frameAlignment)
        case .chart:
            chart
        case .gauge:
            let variable = context.variable(block.variable)
            let number = variable.flatMap(context.values.number) ?? 0
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(context.text(block).isEmpty ? (variable?.name ?? "Gauge") : context.text(block)).font(.system(size: 12))
                    Spacer()
                    // A detail ("{used} of {limit}") says more than the bare figure, so it takes its place.
                    Text(block.detail.isEmpty ? (variable.map(context.values.formatted) ?? "—") : context.render(block.detail))
                        .font(.system(size: 12, design: .rounded)).monospacedDigit()
                }
                BoardLevelBar(fraction: number / max(0.0001, block.style.maximum), tint: context.color(block) ?? .accentColor)
            }
        case .stats:
            VStack(spacing: 5) {
                ForEach(block.variables, id: \.self) { id in
                    if let variable = context.design.variable(id) {
                        HStack {
                            Text(variable.name).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Text(context.values.formatted(variable)).font(.system(size: 12, design: .rounded)).monospacedDigit()
                        }
                    }
                }
                if block.variables.isEmpty { Text("Choose values for this list").font(.caption).foregroundStyle(.secondary) }
            }
        case .button:
            BoardButton(block: block, context: context)
        case .output:
            let variable = context.variable(block.variable)
            let result = variable?.command.flatMap { monitoring.commands.result(for: $0) }
            ScrollView {
                Text(result.map { $0.output.isEmpty ? BoardActions.failure($0.problem ?? "", errorOutput: $0.errorOutput) : $0.output }
                     ?? (variable == nil ? "Choose a command value" : "Waiting for the first run…"))
                    .font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(height: block.style.height)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        case .script:
            ScriptRows(block: block, context: context)
        case .processes:
            BoardProcessList(monitoring: monitoring, kind: block.style.processKind, limit: block.style.limit, live: true)
        case .energy:
            if let power = context.environment.power, context.editing == nil {
                BoardEnergyHost(monitoring: monitoring, power: power).frame(height: block.style.height)
            } else {
                placeholder("Battery & Power dashboard", symbol: "bolt.batteryblock", height: min(block.style.height, 160))
            }
        case .accounts:
            if let accounts = context.environment.accounts {
                AccountsBoard(store: accounts, close: {}, embedded: true).frame(height: block.style.height)
            } else {
                placeholder("AI accounts", symbol: "sparkles", height: min(block.style.height, 160))
            }
        case .readings:
            BoardReadings(context: context)
        case .blocks:
            BoardScriptBlocks(block: block, context: context)
        case .image:
            BoardImage(block: block, context: context)
        case .toggle:
            BoardToggle(block: block, context: context)
        }
    }

    @ViewBuilder private var children: some View {
        ForEach(block.children) { child in BlockView(block: child, context: context) }
        if block.children.isEmpty, context.editing != nil {
            Text("Drop blocks here").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 30)
        }
    }

    @ViewBuilder private var chart: some View {
        let variable = context.variable(block.variable)
        let series = variable.flatMap { BoardChartSeries($0, monitoring: monitoring) }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(context.text(block).isEmpty ? (variable?.name ?? "Chart") : context.text(block)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(series?.latest ?? variable.map(context.values.formatted) ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            if let series {
                HubSparkline(points: series.points, percent: series.percent)
                    .stroke(context.color(block) ?? Color.accentColor, lineWidth: 1.5)
                    .frame(height: block.style.height)
                    .overlay {
                        if series.points.count < 2, let waiting = series.waiting {
                            Text(waiting).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
            } else {
                Text(variable == nil ? "Choose a value" : "This value has no numbers to chart")
                    .font(.caption).foregroundStyle(.tertiary).frame(height: block.style.height)
            }
        }
    }

    private func placeholder(_ title: String, symbol: String, height: Double) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22))
            Text(title).font(.system(size: 12, weight: .medium))
            Text("Shown live when the board opens").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).frame(height: height)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var horizontal: HorizontalAlignment {
        switch block.style.align { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
    private var frameAlignment: Alignment {
        switch block.style.align { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
    private var textAlignment: TextAlignment {
        switch block.style.align { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
    private func font(_ style: BoardTextStyle) -> Font {
        switch style {
        case .huge: .system(size: 30, weight: .bold, design: .rounded)
        case .title: .system(size: 20, weight: .semibold)
        case .headline: .system(size: 14, weight: .semibold)
        case .body: .system(size: 13)
        case .caption: .system(size: 11)
        case .mono: .system(size: 12, design: .monospaced)
        }
    }
}

// MARK: - Buttons and actions

/// Runs a board action and keeps its outcome to show beneath the button.
@MainActor
enum BoardActions {
    /// What an action leaves to show beneath its control, and whether that is a failure.
    struct Outcome: Equatable {
        var text: String?
        var failed = false
    }

    /// Does the action and returns when it has finished. It does not re-read the sprite's values: callers
    /// do that once the outcome is shown (`afterwards`), so the control is not held up by every command.
    static func run(_ action: BoardAction, context: BoardContext) async -> Outcome {
        switch action.kind {
        case .runCommand:
            // An action is judged by how it exits, not by whether it printed something parseable. It may run
            // longer than a value (a value stops at a minute; an action at its own timeout, up to ten).
            var source = CommandSource(command: action.value, directory: folder(of: context.config)).normalized
            source.timeout = timeout(action)
            let result = await CommandVariableRunner.execute(source, parse: false, trigger: .action)
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = result.problem {
                return Outcome(text: failure(problem, errorOutput: result.errorOutput), failed: true)
            }
            return Outcome(text: output.isEmpty ? "Done" : String(output.prefix(200)))
        case .openURL:
            guard let url = URL(string: action.value.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
                return Outcome(text: "Not a link: \(action.value)", failed: true)
            }
            NSWorkspace.shared.open(url); return Outcome()
        case .openApp:
            let name = action.value.trimmingCharacters(in: .whitespaces)
            let url: URL? = name.hasPrefix("/") ? URL(fileURLWithPath: name)
                : NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
                ?? ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
                    .map { URL(fileURLWithPath: "\($0)/\(name.hasSuffix(".app") ? name : name + ".app")") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let url else { return Outcome(text: "No app called \(name)", failed: true) }
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init()); return Outcome()
        case .copyText:
            let text = context.render(TextTemplate.parse(action.value).map { segment in
                // A value that cannot be resolved copies as nothing rather than "?".
                if case .value(let id) = segment, context.design.variable(id) == nil { return .literal("") }
                return segment
            })
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            return Outcome(text: "Copied")
        case .refresh:
            await refresh(context); return Outcome()
        }
    }

    /// After a command action: every command the sprite draws from runs again, so the face and the board
    /// show what it changed rather than waiting for their next turn.
    static func afterwards(_ action: BoardAction, context: BoardContext) async {
        guard action.kind == .runCommand else { return }
        await context.environment.monitoring.rerun(context.design)
    }

    /// How long a command action may run: its own timeout (default 30 s), within 1 s and ten minutes.
    static func timeout(_ action: BoardAction) -> Double {
        let seconds = action.timeout ?? BoardAction.defaultTimeout
        return min(BoardAction.longestTimeout, max(1, seconds.isFinite ? seconds : BoardAction.defaultTimeout))
    }

    /// A failed command's problem ("Exited with status 1") and the last lines it wrote to stderr: a Python
    /// traceback ends with its exception and most tools print their reason last, so the head of stderr is
    /// usually the least useful part.
    /// Lines before the last are cut shorter than the last, so a long source line quoted in a traceback
    /// cannot push the exception itself out of the few lines a board shows.
    static func failure(_ problem: String, errorOutput: String, lines: Int = 3) -> String {
        let tail = Array(errorOutput.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(lines))
        guard !tail.isEmpty else { return problem }
        func cut(_ line: String, _ limit: Int) -> String { line.count > limit ? String(line.prefix(limit - 1)) + "…" : line }
        let detail = (tail.dropLast().map { cut($0, 90) } + [cut(tail[tail.count - 1], 200)]).joined(separator: "\n")
        return problem.isEmpty ? detail : problem + "\n" + detail
    }

    /// The sprite's own folder, when it has one: actions run there with `SPRITE_DIR` set, as its values do.
    /// Its own folder comes first, so a copy whose commands still name another sprite's folder works in its
    /// own; the folder its commands carry is the fallback (a draft preview's temporary copy).
    static func folder(of config: SpriteConfiguration) -> String? {
        CommandVariableRunner.existingDirectory(SpriteFolders.directory(for: config.id).path)
            ?? CommandVariableRunner.existingDirectory(config.design?.filesDirectory)
    }

    /// Samples the readings again and re-runs every command the sprite draws from (values, script rows and
    /// script blocks), side by side; the commands see `MENUSPRITE_TRIGGER=refresh`.
    static func refresh(_ context: BoardContext) async {
        let monitoring = context.environment.monitoring
        monitoring.refresh()
        await monitoring.rerun(context.design)
    }
}

private struct BoardButton: View {
    let block: BoardBlock
    let context: BoardContext
    @State private var running = false
    @State private var outcome: BoardActions.Outcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard let action = block.action else { return }
                running = true
                let context = context
                Task {
                    outcome = await BoardActions.run(action, context: context); running = false
                    await BoardActions.afterwards(action, context: context)
                }
            } label: {
                HStack(spacing: 6) {
                    if running { ProgressView().controlSize(.small) }
                    else if !(context.overrides[block.id]?.symbol ?? block.symbol).isEmpty {
                        Image(systemName: context.overrides[block.id]?.symbol ?? block.symbol)
                    }
                    BoardText(text: context.text(block).isEmpty ? "Button" : context.text(block), style: block.style)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large).disabled(running || block.action == nil)
            if let outcome, let text = outcome.text {
                Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(outcome.failed ? Color.orange : Color.secondary)
                    .lineLimit(8).textSelection(.enabled)
            }
        }
    }
}

/// Text cut to the block's line count where its truncation says, with the whole text on hover.
struct BoardText: View {
    let text: String
    let style: BoardStyle
    var body: some View {
        if style.lines > 0 {
            Text(text).lineLimit(style.lines).truncationMode(BoardText.mode(style.truncate)).help(text)
        } else {
            Text(text)
        }
    }
    static func mode(_ truncation: BoardTruncation) -> Text.TruncationMode {
        switch truncation { case .tail: .tail; case .middle: .middle; case .head: .head }
    }
}

/// A block or script row that does something when clicked anywhere on it: a soft fill under the pointer,
/// the pointing hand, a small arrow when it opens a link, a spinner while its command runs, and the outcome
/// for a few seconds beneath it. After a command, the sprite's commands run again (`BoardActions.afterwards`).
struct BoardClickable<Content: View>: View {
    let actions: [BoardAction]
    let context: BoardContext
    @ViewBuilder let content: () -> Content
    @State private var hovering = false
    @State private var running = false
    @State private var outcome: BoardActions.Outcome?
    @State private var shown = 0

    var body: some View {
        let link = actions.contains { $0.kind == .openURL }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                content()
                if running { ProgressView().controlSize(.mini) }
                else if link { Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
            }
            // Drawn past the block's edges so it does not move anything when it appears.
            .background { RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)).padding(-4) }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointerStyle(.link)
            .onTapGesture(perform: perform)
            .accessibilityAddTraits(link ? .isLink : .isButton)
            .accessibilityAction(.default, perform)
            if let text = outcome?.text {
                Text(text).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(outcome?.failed == true ? Color.orange : Color.secondary).lineLimit(8).textSelection(.enabled)
            }
        }
    }

    private func perform() {
        guard !running, !actions.isEmpty else { return }
        running = true; outcome = nil
        let actions = actions, context = context
        Task {
            var last = BoardActions.Outcome()
            for action in actions {
                last = await BoardActions.run(action, context: context)
                if last.failed { break }
            }
            running = false
            show(last)
            if let command = actions.first(where: { $0.kind == .runCommand }) { await BoardActions.afterwards(command, context: context) }
        }
    }
    /// Shows the outcome, then clears it: a failure stays long enough to read.
    private func show(_ next: BoardActions.Outcome) {
        outcome = next; shown += 1
        let generation = shown
        guard next.text != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(next.failed ? 10 : 3))
            if shown == generation { outcome = nil }
        }
    }
}

// MARK: - Script rows

private struct ScriptRows: View {
    let block: BoardBlock
    let context: BoardContext

    var body: some View {
        let monitoring = context.environment.monitoring
        let result = block.command.flatMap { monitoring.commands.result(for: $0) }
        VStack(alignment: .leading, spacing: 4) {
            if block.command?.command.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                Text("Write a command whose output lines become rows").font(.caption).foregroundStyle(.secondary)
            } else if let result {
                // A failure says why, with the end of what the script wrote to stderr, above whatever it printed.
                if let problem = result.problem, result.output.isEmpty || result.status != 0 {
                    BoardDiagnostics(lines: [BoardActions.failure(problem, errorOutput: result.errorOutput)])
                }
                ForEach(Array(ScriptLine.parse(result.output).enumerated()), id: \.offset) { _, line in row(line) }
            } else {
                Text("Running…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func row(_ line: ScriptLine) -> some View {
        if line.isDivider { Divider() }
        else {
            let actions = (line.href.map { [BoardAction(kind: .openURL, value: $0)] } ?? [])
                + (line.bash.map { [BoardAction(kind: .runCommand, value: $0)] } ?? [])
            let label = HStack(spacing: 6) {
                if let symbol = line.symbol { Image(systemName: symbol).frame(width: 16) }
                Text(line.shown).font(font(line)).lineLimit(line.length == nil ? nil : 1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(line.color.map(spriteColor) ?? Color.primary)
            .help(line.tooltip ?? (line.shown == line.text ? "" : line.text))
            Group {
                if actions.isEmpty { label } else { BoardClickable(actions: actions, context: context) { label } }
            }
            .padding(.leading, CGFloat(line.depth) * 14)
            .padding(.vertical, 2)
        }
    }

    private func font(_ line: ScriptLine) -> Font {
        let weight: Font.Weight = switch line.weight { case "bold": .bold; case "semibold": .semibold; case "medium": .medium; default: .regular }
        return line.monospaced ? .system(size: line.size ?? 12, weight: weight, design: .monospaced) : .system(size: line.size ?? 13, weight: weight)
    }
}

// MARK: - Premade blocks

/// The process list from the RAM, CPU and Power panels, collected only while the board is open.
private struct BoardProcessList: View {
    @ObservedObject var monitoring: MonitoringStore
    let kind: ProcessListKind
    let limit: Int
    let live: Bool
    @StateObject private var holder = ProcessHolder()

    var body: some View {
        Group {
            if let processes = holder.store { BoardProcessRows(monitoring: monitoring, processes: processes, limit: limit) }
            else { Text("\(kind.title) processes").font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { holder.start(kind: panelKind, live: live) }
        .onChange(of: kind) { _, _ in holder.start(kind: panelKind, live: live) }
        .onDisappear { holder.stop() }
    }
    private var panelKind: ProcessPanelKind {
        switch kind { case .cpu: .cpu; case .memory: .memory; case .power: .power }
    }
}

@MainActor
private final class ProcessHolder: ObservableObject {
    @Published var store: MemoryBoardStore?
    func start(kind: ProcessPanelKind, live: Bool) {
        store?.stop()
        let store = MemoryBoardStore(kind: kind)
        self.store = store
        if live { store.start() }
    }
    func stop() { store?.stop(); store = nil }
}

private struct BoardProcessRows: View {
    @ObservedObject var monitoring: MonitoringStore
    @ObservedObject var processes: MemoryBoardStore
    let limit: Int
    private var content: ProcessBoardContent { .init(kind: processes.kind, monitoring: monitoring, processes: processes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let rows = processes.visibleRows(limit: max(1, limit))
            if rows.isEmpty {
                Text(processes.loading ? "Reading processes…" : processes.emptyMessage).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.row.id) { item in
                let row = item.row
                HStack(spacing: 8) {
                    if let path = row.consumer.presentation.iconBundlePath, let icon = processes.icons[path] {
                        Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                    } else {
                        Image(systemName: row.consumer.presentation.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 15)
                    }
                    Text(row.consumer.presentation.title).font(.system(size: 12)).lineLimit(1)
                        .padding(.leading, CGFloat(item.depth) * 12)
                    Spacer(minLength: 6)
                    Text(content.formatted(row)).font(.system(size: 12, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                    ProcessQuitButton(row: row, processes: processes)
                }
                .contentShape(Rectangle())
                .onTapGesture { if !row.members.isEmpty { processes.toggle(row.id) } }
                .help(content.tooltip(row))
            }
            if let notice = processes.notice {
                Text(notice).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
            }
        }
    }
}

private struct BoardEnergyHost: NSViewControllerRepresentable {
    let monitoring: MonitoringStore
    let power: PowerStore
    func makeNSViewController(context: Context) -> EnergyBoardController {
        let processes = MemoryBoardStore(kind: .power)
        processes.start()
        return EnergyBoardController(monitoring: monitoring, processes: processes, power: power, id: nil, embedded: true,
                                     configure: {}, showPower: {}, close: {})
    }
    func updateNSViewController(_ controller: EnergyBoardController, context: Context) {}
    static func dismantleNSViewController(_ controller: EnergyBoardController, coordinator: ()) { controller.stop() }
}

/// Every reading value with its figure and a sparkline: the classic generic board as a block.
private struct BoardReadings: View {
    let context: BoardContext
    var body: some View {
        let monitoring = context.environment.monitoring
        VStack(alignment: .leading, spacing: 10) {
            ForEach(context.design.variables.filter { $0.readingID != nil }) { variable in
                let id = variable.readingID!
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(variable.name).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(context.values.formatted(variable)).font(.system(size: 15, weight: .medium, design: .rounded)).monospacedDigit()
                    }
                    if monitoring.metric(id).unit != .text {
                        HubSparkline(points: monitoring.history[id] ?? [], percent: monitoring.metric(id).unit == .percent)
                            .stroke(Color.accentColor, lineWidth: 1.4).frame(height: 30)
                    }
                }
            }
        }
    }
}

// MARK: - Starting points

extension BoardDesign {
    /// A board that starts where the sprite's classic panel is: its premade panel (or its readings)
    /// under the header, ready to add to.
    @MainActor static func starter(for config: SpriteConfiguration) -> BoardDesign {
        var blocks: [BoardBlock] = []
        if config.opensAccountsBoard {
            var block = BoardBlock(kind: .accounts, name: "AI accounts"); block.style.height = 520
            blocks = [block]
        } else if let kind = config.processPanelKind {
            if kind == .power {
                var block = BoardBlock(kind: .energy, name: "Battery & Power"); block.style.height = 640
                blocks = [block]
                return BoardDesign(root: .stack(blocks), width: 440, showHeader: true)
            }
            let variables = config.design?.variables.filter { $0.readingID != nil }.map(\.id) ?? []
            var chart = BoardBlock(kind: .chart, name: "Chart", variable: variables.first); chart.style.height = 44
            var list = BoardBlock(kind: .processes, name: "Processes"); list.style.limit = 12
            list.style.processKind = kind == .cpu ? .cpu : .memory
            blocks = [chart, list]
        } else {
            blocks = [BoardBlock(kind: .readings, name: "Readings")]
        }
        return BoardDesign(root: .stack(blocks, spacing: 12), width: 380, showHeader: true)
    }
}
