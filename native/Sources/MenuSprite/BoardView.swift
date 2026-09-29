import AppKit
import SwiftUI
import SystemMonitoring

/// Everything a board's blocks can draw from or act on.
@MainActor
struct BoardEnvironment {
    let monitoring: MonitoringStore
    let power: PowerStore?
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
        let values = monitoring.designValues(design)
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

    func text(_ block: BoardBlock) -> String {
        (overrides[block.id]?.text ?? block.segments).map { segment in
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
    func variable(_ id: String?) -> SpriteVariable? { id.flatMap(design.variable) }
}

/// One block and, in the studio, its selection outline, click and drag handling.
struct BlockView: View {
    let block: BoardBlock
    let context: BoardContext

    var body: some View {
        if !(context.overrides[block.id]?.hidden ?? block.style.hidden) || context.editing != nil {
            let content = BlockContent(block: block, context: context)
                .foregroundStyle(context.color(block) ?? Color.primary)
                .opacity((context.overrides[block.id]?.opacity ?? block.style.opacity) * (block.style.hidden && context.editing != nil ? 0.35 : 1))
                .padding(block.style.padding)
            if let editing = context.editing, block.id != context.design.board?.root.id {
                EditableBlock(block: block, editing: editing) { content }
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
            HStack(alignment: .top, spacing: block.style.spacing) {
                ForEach(block.children) { child in BlockView(block: child, context: context).frame(maxWidth: .infinity, alignment: .leading) }
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
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
        case .divider:
            Divider()
        case .spacer:
            Color.clear.frame(height: max(2, block.style.spacing))
        case .text:
            Text(context.text(block)).font(font(block.style.textStyle))
                .multilineTextAlignment(textAlignment).frame(maxWidth: .infinity, alignment: frameAlignment)
                .fixedSize(horizontal: false, vertical: true)
        case .value:
            let variable = context.variable(block.variable)
            VStack(alignment: horizontal, spacing: 2) {
                let caption = context.text(block)
                Text(caption.isEmpty ? (variable?.name ?? "Value") : caption).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(variable.map(context.values.formatted) ?? "—")
                    .font(.system(size: block.style.textStyle == .huge ? 34 : 26, weight: .bold, design: .rounded)).monospacedDigit()
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
                    Text(variable.map(context.values.formatted) ?? "—").font(.system(size: 12, design: .rounded)).monospacedDigit()
                }
                ProgressView(value: min(1, max(0, number / max(0.0001, block.style.maximum))))
                    .tint(context.color(block) ?? .accentColor)
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
            let result = variable?.command.flatMap { monitoring.commands.results[$0.normalized] }
            ScrollView {
                Text(result.map { $0.output.isEmpty ? ($0.problem ?? "") : $0.output } ?? (variable == nil ? "Choose a command value" : "Waiting for the first run…"))
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
        let id = variable?.readingID
        let points = id.map { monitoring.history[$0] ?? [] } ?? []
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(context.text(block).isEmpty ? (variable?.name ?? "Chart") : context.text(block)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(variable.map(context.values.formatted) ?? "—").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            if id == nil {
                Text(variable == nil ? "Choose a reading" : "Charts draw readings; a command has no history yet")
                    .font(.caption).foregroundStyle(.tertiary).frame(height: block.style.height)
            } else {
                HubSparkline(points: points, percent: id.map { monitoring.metric($0).unit == .percent } ?? false)
                    .stroke(context.color(block) ?? Color.accentColor, lineWidth: 1.5)
                    .frame(height: block.style.height)
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
    static func perform(_ action: BoardAction, context: BoardContext) async -> String? {
        switch action.kind {
        case .runCommand:
            let result = await CommandVariableRunner.execute(CommandSource(command: action.value, timeout: 30).normalized)
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.problem.map { "\($0)" + (result.errorOutput.isEmpty ? "" : ": \(result.errorOutput.prefix(160))") }
                ?? (output.isEmpty ? "Done" : String(output.prefix(200)))
        case .openURL:
            guard let url = URL(string: action.value.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return "Not a link: \(action.value)" }
            NSWorkspace.shared.open(url); return nil
        case .openApp:
            let name = action.value.trimmingCharacters(in: .whitespaces)
            let url: URL? = name.hasPrefix("/") ? URL(fileURLWithPath: name)
                : NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
                ?? ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
                    .map { URL(fileURLWithPath: "\($0)/\(name.hasSuffix(".app") ? name : name + ".app")") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let url else { return "No app called \(name)" }
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init()); return nil
        case .copyText:
            let text = TextTemplate.parse(action.value).map { segment in
                switch segment { case .literal(let t): t; case .value(let id): context.design.variable(id).map(context.values.formatted) ?? "" }
            }.joined()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            return "Copied"
        case .refresh:
            context.environment.monitoring.refresh(); return nil
        }
    }
}

private struct BoardButton: View {
    let block: BoardBlock
    let context: BoardContext
    @State private var running = false
    @State private var outcome: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard let action = block.action else { return }
                running = true
                Task { outcome = await BoardActions.perform(action, context: context); running = false }
            } label: {
                HStack(spacing: 6) {
                    if running { ProgressView().controlSize(.small) }
                    else if !(context.overrides[block.id]?.symbol ?? block.symbol).isEmpty {
                        Image(systemName: context.overrides[block.id]?.symbol ?? block.symbol)
                    }
                    Text(context.text(block).isEmpty ? "Button" : context.text(block))
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large).disabled(running || block.action == nil)
            if let outcome {
                Text(outcome).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Script rows

private struct ScriptRows: View {
    let block: BoardBlock
    let context: BoardContext
    @State private var outcome: String?

    var body: some View {
        let monitoring = context.environment.monitoring
        let result = block.command.flatMap { monitoring.commands.results[$0.normalized] }
        VStack(alignment: .leading, spacing: 4) {
            if block.command?.command.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                Text("Write a command whose output lines become rows").font(.caption).foregroundStyle(.secondary)
            } else if let result {
                if let problem = result.problem, result.output.isEmpty {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                ForEach(Array(ScriptLine.parse(result.output).enumerated()), id: \.offset) { _, line in row(line) }
            } else {
                Text("Running…").font(.caption).foregroundStyle(.secondary)
            }
            if let outcome { Text(outcome).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3) }
        }
    }

    @ViewBuilder private func row(_ line: ScriptLine) -> some View {
        if line.isDivider { Divider() }
        else {
            let actionable = line.href != nil || line.bash != nil
            HStack(spacing: 6) {
                if let symbol = line.symbol { Image(systemName: symbol).frame(width: 16) }
                Text(line.text)
                    .font(line.monospaced ? .system(size: line.size ?? 12, design: .monospaced) : .system(size: line.size ?? 13))
                Spacer(minLength: 0)
                if actionable { Image(systemName: "arrow.up.forward").font(.system(size: 9)).foregroundStyle(.tertiary) }
            }
            .foregroundStyle(line.color.map(spriteColor) ?? Color.primary)
            .padding(.leading, CGFloat(line.depth) * 14)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                if let href = line.href, let url = URL(string: href) { NSWorkspace.shared.open(url) }
                if let bash = line.bash {
                    Task { outcome = await BoardActions.perform(BoardAction(kind: .runCommand, value: bash), context: context) }
                }
            }
        }
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
