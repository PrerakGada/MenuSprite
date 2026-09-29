import SwiftUI
import SystemMonitoring

extension StudioModel {
    var board: BoardDesign? { design.board }
    var selectedBlock: BoardBlock? { boardSelection.flatMap { design.board?.root.find($0) } }

    func editBoard(coalesce: Bool = false, _ body: (inout BoardDesign) -> Void) {
        edit(coalesce: coalesce) { design in
            guard var board = design.board else { return }
            body(&board)
            design.board = board
            design.prune()
        }
    }
    func block<Value>(_ id: String, _ path: WritableKeyPath<BoardBlock, Value>, fallback: Value, coalesce: Bool = false) -> Binding<Value> {
        Binding(get: { self.design.board?.root.find(id)?[keyPath: path] ?? fallback },
                set: { value in self.editBoard(coalesce: coalesce) { $0.root.update(id) { $0[keyPath: path] = value } } })
    }
    /// Adds a new block of `kind` below the selected block (or at the end) and selects it.
    func addBlock(_ kind: String, edge: DropEdge = .below, target: String? = nil) {
        guard let block = freshBlock(kind) else { return }
        let target = target ?? boardSelection ?? design.board?.root.id ?? ""
        editBoard { board in if !board.insert(block, at: edge, of: target) { board.root.children.append(block) } }
        boardSelection = block.id
    }

    /// A new block with sensible contents drawn from the sprite's own values.
    func freshBlock(_ kind: String) -> BoardBlock? {
        guard let kind = BoardBlockKind(rawValue: kind) else { return nil }
        let readings = design.variables.filter { $0.readingID != nil }
        let first = design.variables.first?.id
        var block = BoardBlock(kind: kind, name: kind.title)
        switch kind {
        case .stack, .row: block.name = ""; block.style.spacing = 8
        case .card: block.segments = [.literal("Card")]; block.style.spacing = 8
        case .spacer: block.style.spacing = 12
        case .text: block.segments = [.literal("Text")]
        case .value: block.variable = first
        case .chart: block.variable = readings.first?.id; block.style.height = 44
        case .gauge: block.variable = readings.first { $0.readingID.map { store.metric($0).unit == .percent } ?? false }?.id ?? first
        case .stats: block.variables = design.variables.map(\.id)
        case .button:
            block.segments = [.literal("Open Activity Monitor")]; block.symbol = "gauge.with.dots.needle.50percent"
            block.action = BoardAction(kind: .openApp, value: "Activity Monitor")
        case .output:
            block.variable = design.variables.first { $0.command != nil }?.id; block.style.height = 90
        case .script:
            block.command = CommandSource(command: """
            echo "Hello from a script | sfimage=hand.wave"
            echo "---"
            echo "Uptime: $(uptime | sed 's/.*up \\([^,]*\\),.*/\\1/') | font=Menlo"
            echo "Open Activity Monitor | bash='open -a \\"Activity Monitor\\"' sfimage=arrow.up.forward.app"
            """, interval: 30)
        case .processes: block.style.limit = 8; block.style.processKind = .memory
        case .energy: block.style.height = 640
        case .accounts: block.style.height = 520
        case .divider, .readings: break
        }
        return block
    }
}

/// The board half of the design pane: what opens when the sprite is clicked.
struct StudioBoardPane: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore

    var body: some View {
        if let board = model.board {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Board").font(.headline)
                    Text("Opens when the sprite is clicked · click a block to select it · drag to move").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Toggle("Header", isOn: Binding(get: { board.showHeader }, set: { value in model.editBoard { $0.showHeader = value } }))
                        .toggleStyle(.checkbox)
                    Text("Width").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { board.width }, set: { value in model.editBoard(coalesce: true) { $0.width = value.rounded() } }),
                           in: BoardDesign.widths).frame(width: 90)
                    Menu {
                        Button("Start again from the classic panel") { model.edit { $0.board = BoardDesign.starter(for: model.config) } }
                        Button("Use the classic panel instead", role: .destructive) { model.edit { $0.board = nil }; model.boardSelection = nil }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .controlSize(.small).padding(.horizontal, 16).padding(.vertical, 10)
                HSplitView {
                    ScrollView([.vertical, .horizontal]) {
                        BoardView(config: model.config, environment: BoardEnvironment(monitoring: store, power: nil), editing: editing)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1)))
                            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                            .padding(20)
                            .onTapGesture { model.boardSelection = nil }
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .defaultScrollAnchor(.top)
                    .frame(minWidth: 300, maxWidth: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    VStack(spacing: 0) {
                        BoardPalette(model: model)
                        Divider()
                        BoardOutline(model: model).frame(maxHeight: 190)
                        Divider()
                        GeometryReader { proxy in
                            ScrollView { BoardInspector(model: model, store: store).padding(14).frame(width: proxy.size.width, alignment: .leading) }
                        }
                    }
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 360)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Board").font(.headline)
                Text("Clicking this sprite opens its classic panel: \(classicName). Make a board to design what opens instead — values, charts, buttons that run commands, rows written by a script, and MenuSprite's own panels as blocks.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Customize, starting from the current panel") {
                        model.edit { $0.board = BoardDesign.starter(for: model.config) }
                    }.keyboardShortcut(.defaultAction)
                    Button("Start from a blank board") {
                        model.edit { $0.board = BoardDesign(root: .stack([BoardBlock.text("Hello", style: .headline)]), width: 340) }
                    }
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var classicName: String {
        if model.config.opensAccountsBoard { return "the AI accounts board" }
        switch model.config.processPanelKind {
        case .memory: return "the Memory panel"
        case .cpu: return "the CPU panel"
        case .power: return "Battery & Power"
        case nil: return "its readings with graphs"
        }
    }

    private var editing: BoardEditing {
        let model = model
        return BoardEditing(
            selection: model.boardSelection,
            select: { id in model.boardSelection = id },
            move: { id, edge, target in model.editBoard { $0.move(id, to: edge, of: target) }; model.boardSelection = id },
            insert: { kind, edge, target in model.addBlock(kind, edge: edge, target: target) })
    }
}

/// Blocks to add, grouped: click adds one under the selection, dragging drops it on a block.
private struct BoardPalette: View {
    @ObservedObject var model: StudioModel
    private let groups: [(String, [BoardBlockKind])] = [
        ("Layout", [.stack, .row, .card, .divider, .spacer]),
        ("Content", [.text, .value, .chart, .gauge, .stats, .button, .output, .script]),
        ("MenuSprite panels", [.processes, .energy, .accounts, .readings])
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups, id: \.0) { title, kinds in
                Text(title).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                FlowLayout(spacing: 4) {
                    ForEach(kinds, id: \.self) { kind in
                        Button { model.addBlock(kind.rawValue) } label: {
                            Label(kind.title, systemImage: kind.symbol).font(.system(size: 11))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .onDrag { NSItemProvider(object: kind.rawValue as NSString) }
                        .help("Click to add below the selection, or drag onto a block")
                    }
                }
            }
        }
        .padding(12)
    }
}

private struct BoardOutline: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if let root = model.board?.root { rows(root, depth: 0) }
            }.padding(6)
        }
    }
    private func rows(_ block: BoardBlock, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 1) {
            let selected = model.boardSelection == block.id
            Button { model.boardSelection = block.id } label: {
                HStack(spacing: 6) {
                    Image(systemName: block.kind.symbol).font(.system(size: 11)).frame(width: 14).foregroundStyle(.secondary)
                    Text(block.id == model.board?.root.id ? "Board" : model.design.title(of: block)).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                    if block.style.hidden { Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(.tertiary) }
                }
                .padding(.leading, CGFloat(depth) * 12 + 6).padding(.vertical, 3).padding(.trailing, 6)
                .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            ForEach(block.children) { child in rows(child, depth: depth + 1) }
        })
    }
}

/// Settings for the selected block.
private struct BoardInspector: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore

    var body: some View {
        if let block = model.selectedBlock {
            let id = block.id
            let isRoot = id == model.board?.root.id
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("Name", text: model.block(id, \.name, fallback: "", coalesce: true))
                        .textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if !isRoot {
                        Menu {
                            Button("Move up") { model.editBoard { $0.shift(id, by: -1) } }
                            Button("Move down") { model.editBoard { $0.shift(id, by: 1) } }
                            Button("Duplicate") { var copy: String?; model.editBoard { copy = $0.duplicate(id) }; model.boardSelection = copy }
                            Divider()
                            Button("Delete", role: .destructive) { model.editBoard { $0.delete(id) }; model.boardSelection = nil }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                content(block)
                StudioSection(title: "Look") {
                    VStack(alignment: .leading, spacing: 8) {
                        InspectorField("Colour") { ColorChoice(value: model.block(id, \.style.color, fallback: "inherit")) }
                        if [.text, .stack, .card, .value].contains(block.kind) {
                            InspectorField("Align") {
                                Picker("Align", selection: model.block(id, \.style.align, fallback: .leading)) {
                                    Image(systemName: "text.alignleft").tag(DesignAlign.leading)
                                    Image(systemName: "text.aligncenter").tag(DesignAlign.center)
                                    Image(systemName: "text.alignright").tag(DesignAlign.trailing)
                                }.pickerStyle(.segmented).labelsHidden().frame(width: 120)
                            }
                        }
                        if block.kind.isContainer || block.kind == .spacer {
                            InspectorField(block.kind == .spacer ? "Height" : "Spacing") {
                                Slider(value: model.block(id, \.style.spacing, fallback: 8, coalesce: true), in: 0...32, step: 1).frame(width: 160)
                            }
                        }
                        InspectorField("Padding") {
                            Slider(value: model.block(id, \.style.padding, fallback: 0, coalesce: true), in: 0...20, step: 1).frame(width: 160)
                        }
                        if !isRoot { Toggle("Hidden (rules can show it)", isOn: model.block(id, \.style.hidden, fallback: false)) }
                    }
                }
            }
            .controlSize(.small)
        } else {
            Text("Click a block on the board to change it, or add one above.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func variablePicker(_ id: String, filter: @escaping (SpriteVariable) -> Bool = { _ in true }) -> some View {
        Picker("Value", selection: model.block(id, \.variable, fallback: nil)) {
            Text("Nothing").tag(String?.none)
            ForEach(model.design.variables.filter(filter)) { Text($0.name).tag(String?.some($0.id)) }
        }.labelsHidden().frame(maxWidth: 220)
    }
    private func template(_ id: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: Binding(get: { TextTemplate.string(model.design.board?.root.find(id)?.segments ?? []) },
                                                 set: { value in model.editBoard(coalesce: true) { $0.root.update(id) { $0.segments = TextTemplate.parse(value) } } }))
                .textFieldStyle(.roundedBorder)
            if !model.design.variables.isEmpty {
                Menu("Insert a value") {
                    ForEach(model.design.variables) { variable in
                        Button(variable.name) { model.editBoard { $0.root.update(id) { $0.segments.append(.value(variable.id)) } } }
                    }
                }.menuStyle(.borderlessButton).fixedSize().font(.caption)
            }
        }
    }

    @ViewBuilder private func content(_ block: BoardBlock) -> some View {
        let id = block.id
        switch block.kind {
        case .text:
            StudioSection(title: "Text") {
                template(id, placeholder: "Text, values as {key}")
                Picker("Style", selection: model.block(id, \.style.textStyle, fallback: .body)) {
                    ForEach(BoardTextStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(maxWidth: 220)
            }
        case .card:
            StudioSection(title: "Card title") { template(id, placeholder: "Title") }
        case .value:
            StudioSection(title: "Big value") {
                variablePicker(id)
                template(id, placeholder: "Caption (defaults to the value's name)")
                Toggle("Huge", isOn: Binding(get: { block.style.textStyle == .huge },
                                              set: { value in model.editBoard { $0.root.update(id) { $0.style.textStyle = value ? .huge : .body } } }))
            }
        case .chart:
            StudioSection(title: "Chart") {
                variablePicker(id) { $0.readingID != nil }
                template(id, placeholder: "Caption")
                InspectorField("Height") { Slider(value: model.block(id, \.style.height, fallback: 44, coalesce: true), in: 20...160).frame(width: 160) }
            }
        case .gauge:
            StudioSection(title: "Gauge") {
                variablePicker(id)
                template(id, placeholder: "Caption")
                InspectorField("Full at") {
                    TextField("100", value: model.block(id, \.style.maximum, fallback: 100, coalesce: true), format: .number).frame(width: 80)
                }
            }
        case .stats:
            StudioSection(title: "Values listed") {
                ForEach(model.design.variables) { variable in
                    Toggle(variable.name, isOn: Binding(get: { block.variables.contains(variable.id) }, set: { on in
                        model.editBoard { $0.root.update(id) { b in
                            if on { b.variables.append(variable.id) } else { b.variables.removeAll { $0 == variable.id } }
                        } }
                    }))
                }
            }
        case .button:
            StudioSection(title: "Button") {
                template(id, placeholder: "Title")
                TextField("SF Symbol (optional)", text: model.block(id, \.symbol, fallback: "", coalesce: true)).textFieldStyle(.roundedBorder)
                Picker("Does", selection: Binding(get: { block.action?.kind ?? .runCommand }, set: { kind in
                    model.editBoard { $0.root.update(id) { $0.action = BoardAction(kind: kind, value: $0.action?.value ?? "") } }
                })) { ForEach(BoardActionKind.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(maxWidth: 240)
                if block.action?.kind != .refresh {
                    let value = Binding(get: { block.action?.value ?? "" }, set: { text in
                        model.editBoard(coalesce: true) { $0.root.update(id) { $0.action = BoardAction(kind: $0.action?.kind ?? .runCommand, value: text) } }
                    })
                    if block.action?.kind == .runCommand {
                        TextEditor(text: value).font(.system(size: 12, design: .monospaced)).frame(height: 54)
                            .scrollContentBackground(.hidden).padding(4)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        Text("Runs with /bin/zsh when pressed; its output shows under the button.").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        TextField(placeholder(block.action?.kind), text: value).textFieldStyle(.roundedBorder)
                    }
                }
            }
        case .output:
            StudioSection(title: "Command output") {
                variablePicker(id) { $0.command != nil }
                Text("Shows everything a command value printed. Add one under Values → The output of a command.").font(.caption2).foregroundStyle(.tertiary)
                InspectorField("Height") { Slider(value: model.block(id, \.style.height, fallback: 90, coalesce: true), in: 30...300).frame(width: 160) }
            }
        case .script:
            ScriptInspector(model: model, store: store, block: block)
        case .processes:
            StudioSection(title: "Process list") {
                Picker("Ranks by", selection: model.block(id, \.style.processKind, fallback: .memory)) {
                    ForEach(ProcessListKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 220)
                Stepper("Rows: \(block.style.limit)", value: model.block(id, \.style.limit, fallback: 10), in: 1...40)
                Text("Each row quits its app on one click and force quits on a second, as in the panels.").font(.caption2).foregroundStyle(.tertiary)
            }
        case .energy, .accounts:
            StudioSection(title: block.kind.title) {
                InspectorField("Height") { Slider(value: model.block(id, \.style.height, fallback: 500, coalesce: true), in: 200...900).frame(width: 160) }
                Text("The same live panel MenuSprite shows elsewhere; it runs only while the board is open.").font(.caption2).foregroundStyle(.tertiary)
            }
        case .readings:
            StudioSection(title: "Readings") {
                Text("Every reading value with its figure and a graph.").font(.caption).foregroundStyle(.secondary)
            }
        case .stack, .row, .divider, .spacer:
            EmptyView()
        }
    }
    private func placeholder(_ kind: BoardActionKind?) -> String {
        switch kind {
        case .openURL: "https://…"
        case .openApp: "App name, bundle ID or path"
        case .copyText: "Text to copy, values as {key}"
        default: ""
        }
    }
}

/// A script block: its command, how often it runs, and what the output format means.
private struct ScriptInspector: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    let block: BoardBlock

    private func update(coalesce: Bool = false, _ body: @escaping (inout CommandSource) -> Void) {
        model.editBoard(coalesce: coalesce) { $0.root.update(block.id) { b in var source = b.command ?? CommandSource(); body(&source); b.command = source } }
    }
    var body: some View {
        let command = block.command ?? CommandSource()
        let result = store.commands.results[command.normalized]
        StudioSection(title: "Script rows") {
            TextEditor(text: Binding(get: { command.command }, set: { value in update(coalesce: true) { $0.command = value } }))
                .font(.system(size: 11, design: .monospaced)).frame(height: 110)
                .scrollContentBackground(.hidden).padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Text("Each printed line is a row. After a `|`: color=red sfimage=bolt href=https://… bash='command' size=13 font=Menlo. A line of --- is a divider; a leading -- indents. Same format as SwiftBar.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Every", selection: Binding(get: { command.interval }, set: { value in update { $0.interval = value } })) {
                    ForEach(CommandSource.intervals, id: \.self) { seconds in
                        Text(seconds >= 3600 ? "\(Int(seconds / 3600)) h" : seconds >= 60 ? "\(Int(seconds / 60)) min" : "\(Int(seconds)) s").tag(seconds)
                    }
                }.frame(width: 120)
                Button { Task { await store.commands.run(command) } } label: { Label("Run now", systemImage: "play.fill") }
            }
            if let result {
                Text(result.problem ?? "\(ScriptLine.parse(result.output).count) rows · \(String(format: "%.2f", result.elapsed)) s")
                    .font(.caption).foregroundStyle(result.problem == nil ? Color.green : Color.orange)
            }
        }
    }
}
