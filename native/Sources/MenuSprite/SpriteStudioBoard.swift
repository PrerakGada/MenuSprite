import AgentProtocol
import AppKit
import SwiftUI
import SystemMonitoring
import UniformTypeIdentifiers

extension BoardAction {
    /// A timeout as saved: the default (30 s) is saved as none, so a spec read back leaves it out.
    static func stored(timeout seconds: Double) -> Double? { seconds == defaultTimeout ? nil : seconds }
}

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
        case .blocks:
            // Real data, so the first thing seen is a working example to change rather than a blank.
            block.command = CommandSource(command: """
            used=$(df -P / | awk 'NR==2 {sub("%", "", $5); print $5}')
            cat <<JSON
            {"blocks": [
              {"card": [
                {"text": "Printed by a script", "font": "headline"},
                {"gauge": ${used:-0}, "caption": "Startup disk", "detail": "${used:-0}% used"}
              ], "title": "Script blocks"}
            ]}
            JSON
            """, interval: 60)
        case .image: block.style.height = 120
        case .toggle:
            block.segments = [.literal("Example switch")]; block.symbol = "power"; block.variable = first
            block.action = BoardAction(kind: .runCommand, value: "echo 'Turned on'")
            block.offAction = BoardAction(kind: .runCommand, value: "echo 'Turned off'")
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
            move: { id, edge, target in
                let targets = model.design.ruleTargets
                model.editBoard { $0.move(id, to: edge, of: target, keeping: targets) }; model.boardSelection = id
            },
            insert: { kind, edge, target in model.addBlock(kind, edge: edge, target: target) })
    }
}

/// Blocks to add, grouped: click adds one under the selection, dragging drops it on a block.
private struct BoardPalette: View {
    @ObservedObject var model: StudioModel
    private let groups: [(String, [BoardBlockKind])] = [
        ("Layout", [.stack, .row, .card, .divider, .spacer]),
        ("Content", [.text, .value, .chart, .gauge, .stats, .button, .toggle, .image]),
        ("From a command", [.output, .script, .blocks]),
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
                            Button("Delete", role: .destructive) {
                                let targets = model.design.ruleTargets
                                model.editBoard { $0.delete(id, keeping: targets) }; model.boardSelection = nil
                            }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                content(block)
                if block.kind.takesClickAction { clickAction(block) }
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
                        InspectorField("Background") { BackgroundChoice(value: model.block(id, \.style.background, fallback: "none")) }
                        if model.board?.root.parent(of: id)?.0.kind == .row {
                            Toggle("Fit its content (its natural width; the others share the rest)", isOn: model.block(id, \.style.fit, fallback: false))
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
    /// A gauge's or big value's secondary text, values as {key}.
    private func detail(_ id: String) -> some View {
        InspectorField("Detail") {
            TextField("e.g. {used} of {limit}", text: Binding(get: { TextTemplate.string(model.design.board?.root.find(id)?.detail ?? []) },
                                                               set: { value in model.editBoard(coalesce: true) { $0.root.update(id) { $0.detail = TextTemplate.parse(value) } } }))
                .textFieldStyle(.roundedBorder)
        }
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
                TextField("SF Symbol before the text (optional)", text: model.block(id, \.symbol, fallback: "", coalesce: true)).textFieldStyle(.roundedBorder)
                lines(block)
            }
        case .card:
            StudioSection(title: "Card title") { template(id, placeholder: "Title") }
        case .value:
            StudioSection(title: "Big value") {
                variablePicker(id)
                template(id, placeholder: "Caption (defaults to the value's name)")
                Toggle("Huge", isOn: Binding(get: { block.style.textStyle == .huge },
                                              set: { value in model.editBoard { $0.root.update(id) { $0.style.textStyle = value ? .huge : .body } } }))
                detail(id)
                Text("A second line under the number, e.g. {used} of {limit}.").font(.caption2).foregroundStyle(.tertiary)
                lines(block)
            }
        case .chart:
            StudioSection(title: "Chart") {
                variablePicker(id)
                Text("Readings chart their history; a command value charts the numbers it printed while the board was open (or always, when it runs in the background); fixed text charts a list like 3, 5, 2.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
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
                detail(id)
                Text("Shown on the right in place of the value, e.g. {used} of {limit}.").font(.caption2).foregroundStyle(.tertiary)
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
                    model.editBoard { $0.root.update(id) { $0.action = BoardAction(kind: kind, value: $0.action?.value ?? "", timeout: $0.action?.timeout) } }
                })) { ForEach(BoardActionKind.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(maxWidth: 240)
                actionFields(block, \.action)
                if block.action?.kind == .runCommand {
                    Text("Runs with /bin/zsh in the sprite's folder when pressed; its output shows under the button, then the sprite's commands run again so the board shows what changed.")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                lines(block)
            }
        case .output:
            StudioSection(title: "Command output") {
                variablePicker(id) { $0.command != nil }
                Text("Shows everything a command value printed. Add one under Values → The output of a command.").font(.caption2).foregroundStyle(.tertiary)
                InspectorField("Height") { Slider(value: model.block(id, \.style.height, fallback: 90, coalesce: true), in: 30...300).frame(width: 160) }
            }
        case .script, .blocks:
            ScriptInspector(model: model, store: store, block: block)
        case .image:
            ImageInspector(model: model, block: block)
        case .toggle:
            StudioSection(title: "Switch") {
                template(id, placeholder: "Title (defaults to the value's name)")
                TextField("SF Symbol (optional)", text: model.block(id, \.symbol, fallback: "", coalesce: true)).textFieldStyle(.roundedBorder)
                variablePicker(id)
                Text("On while the value is a non-zero number or reads true, on, yes, enabled, active, up, connected or running.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                InspectorField("Turning it on runs") { actionEditor(id, \.action) }
                InspectorField("Turning it off runs") { actionEditor(id, \.offAction) }
                timeout(Binding(get: { block.action?.timeout ?? block.offAction?.timeout ?? BoardAction.defaultTimeout }, set: { seconds in
                    model.editBoard(coalesce: true) { $0.root.update(id) { b in let stored = BoardAction.stored(timeout: seconds); b.action?.timeout = stored; b.offAction?.timeout = stored } }
                }))
                Text("Both run with /bin/zsh in the sprite's folder; the sprite's commands run again afterwards so the switch shows what happened. Its colour fills the switch when it is on.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                lines(block)
            }
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
    /// A switch's command for one direction.
    private func actionEditor(_ id: String, _ path: WritableKeyPath<BoardBlock, BoardAction?>) -> some View {
        TextEditor(text: Binding(get: { model.design.board?.root.find(id)?[keyPath: path]?.value ?? "" }, set: { text in
            model.editBoard(coalesce: true) { $0.root.update(id) { b in
                b[keyPath: path] = text.isEmpty ? nil : BoardAction(kind: .runCommand, value: text, timeout: b[keyPath: path]?.timeout)
            } }
        }))
        .font(.system(size: 12, design: .monospaced)).frame(height: 44)
        .scrollContentBackground(.hidden).padding(4)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
    /// What an action works on (a command, link, app or text to copy) and, for a command, how long it may run.
    @ViewBuilder private func actionFields(_ block: BoardBlock, _ path: WritableKeyPath<BoardBlock, BoardAction?>) -> some View {
        let id = block.id
        let action = block[keyPath: path]
        if let action, action.kind != .refresh {
            let value = Binding(get: { model.design.board?.root.find(id)?[keyPath: path]?.value ?? "" }, set: { text in
                model.editBoard(coalesce: true) { $0.root.update(id) { b in b[keyPath: path]?.value = text } }
            })
            if action.kind == .runCommand {
                TextEditor(text: value).font(.system(size: 12, design: .monospaced)).frame(height: 54)
                    .scrollContentBackground(.hidden).padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                timeout(Binding(get: { action.timeout ?? BoardAction.defaultTimeout }, set: { seconds in
                    model.editBoard(coalesce: true) { $0.root.update(id) { b in b[keyPath: path]?.timeout = BoardAction.stored(timeout: seconds) } }
                }))
            } else {
                TextField(placeholder(action.kind), text: value).textFieldStyle(.roundedBorder)
            }
        }
    }
    /// How long a command action may run, 1 s to ten minutes.
    private func timeout(_ seconds: Binding<Double>) -> some View {
        InspectorField("Stop after") {
            HStack(spacing: 4) {
                TextField("30", value: Binding(get: { seconds.wrappedValue }, set: { value in
                    let clamped = min(BoardAction.longestTimeout, max(1, value))
                    seconds.wrappedValue = clamped
                }), format: .number).frame(width: 56)
                Text("s (up to 600)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    /// Text that may be cut to a number of lines, and where.
    private func lines(_ block: BoardBlock) -> some View {
        let id = block.id
        return HStack {
            Stepper(block.style.lines == 0 ? "Lines: all" : "Lines: at most \(block.style.lines)",
                    value: model.block(id, \.style.lines, fallback: 0), in: 0...20)
            if block.style.lines > 0 {
                Picker("Cut at", selection: model.block(id, \.style.truncate, fallback: .tail)) {
                    Text("End").tag(BoardTruncation.tail); Text("Middle").tag(BoardTruncation.middle); Text("Start").tag(BoardTruncation.head)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150).help("Where text that does not fit is cut; the whole text shows on hover")
            }
        }
    }
    /// Any block but a button or switch can run an action when clicked anywhere on it.
    private func clickAction(_ block: BoardBlock) -> some View {
        let id = block.id
        return StudioSection(title: "When clicked") {
            Picker("Does", selection: Binding<BoardActionKind?>(get: { block.action?.kind }, set: { kind in
                model.editBoard { $0.root.update(id) { b in
                    b.action = kind.map { BoardAction(kind: $0, value: b.action?.value ?? "", timeout: b.action?.timeout) }
                } }
            })) {
                Text("Nothing").tag(BoardActionKind?.none)
                ForEach(BoardActionKind.allCases, id: \.self) { Text($0.title).tag(BoardActionKind?.some($0)) }
            }.frame(maxWidth: 240)
            actionFields(block, \.action)
            if block.action != nil {
                Text("The whole block is clickable on the board: it lights up under the pointer, a link shows a small arrow, and a command shows a spinner, then its outcome, then runs the sprite's commands again.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
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

/// A script-rows or script-blocks block: its command, how often it runs, and what its output must look like.
private struct ScriptInspector: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    let block: BoardBlock
    @State private var cache = ScriptBlocksCache()

    private func update(coalesce: Bool = false, _ body: @escaping (inout CommandSource) -> Void) {
        model.editBoard(coalesce: coalesce) { $0.root.update(block.id) { b in var source = b.command ?? CommandSource(); body(&source); b.command = source } }
    }
    private var printsBlocks: Bool { block.kind == .blocks }
    var body: some View {
        let command = block.command ?? CommandSource()
        let result = store.commands.result(for: command)
        let running = store.commands.running.contains(command.normalized)
        StudioSection(title: printsBlocks ? "Script blocks" : "Script rows") {
            TextEditor(text: Binding(get: { command.command }, set: { value in update(coalesce: true) { $0.command = value } }))
                .font(.system(size: 11, design: .monospaced)).frame(height: printsBlocks ? 150 : 110)
                .scrollContentBackground(.hidden).padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Text(printsBlocks
                 ? "Print a JSON list of blocks, or {\"blocks\": [...]}, in the board's own vocabulary: text, value, gauge, chart, stats, button, toggle, image, card, row… Literal data works ({\"gauge\": 45}, {\"chart\": [3, 5, 2]}) and so do this sprite's {values}. Runs in the sprite's folder while the board is open; `menusprite guide` has the full list."
                 : "Each printed line is a row. After a `|`: color=red sfimage=bolt href=https://… bash='command' size=13 font=Menlo weight=bold length=40 tooltip='…'. A line of --- is a divider; a leading -- indents. Same format as SwiftBar.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Every", selection: Binding(get: { command.interval }, set: { value in update { $0.interval = value } })) {
                    ForEach(CommandSource.intervals, id: \.self) { seconds in
                        Text(seconds >= 3600 ? "\(Int(seconds / 3600)) h" : seconds >= 60 ? "\(Int(seconds / 60)) min" : "\(Int(seconds)) s").tag(seconds)
                    }
                }.frame(width: 120)
                Button { Task { await store.commands.run(command) } } label: { Label(running ? "Running…" : "Run now", systemImage: "play.fill") }
                    .disabled(running || command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Stepper("Stop after \(Int(command.timeout)) s", value: Binding(get: { command.timeout }, set: { value in update { $0.timeout = value } }), in: 1...60)
            if let result { summary(result) }
        }
    }

    @ViewBuilder private func summary(_ result: CommandResult) -> some View {
        let elapsed = "\(String(format: "%.2f", result.elapsed)) s"
        if printsBlocks, !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = cache.parse(result.output, design: model.design, directory: BoardScriptBlocks.directory(of: block.command ?? CommandSource()))
            let problems = parsed.diagnostics.filter { $0.severity == .error }
            Text(problems.isEmpty ? "\(parsed.blocks.count) blocks · \(elapsed)" + (parsed.diagnostics.isEmpty ? "" : " · \(parsed.diagnostics.count) warnings")
                 : "\(problems.count) problems · \(elapsed)")
                .font(.caption).foregroundStyle(problems.isEmpty && result.problem == nil ? Color.green : Color.orange)
            ForEach(Array(parsed.diagnostics.prefix(4).enumerated()), id: \.offset) { _, diagnostic in
                Text(diagnostic.description).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
            }
        } else if printsBlocks {
            Text(BoardActions.failure(result.problem ?? "Printed nothing", errorOutput: result.errorOutput))
                .font(.caption).foregroundStyle(.orange).lineLimit(8).textSelection(.enabled)
        } else if let problem = result.problem {
            Text(BoardActions.failure(problem, errorOutput: result.errorOutput))
                .font(.caption).foregroundStyle(.orange).lineLimit(8).textSelection(.enabled)
        } else {
            Text("\(ScriptLine.parse(result.output).count) rows · \(elapsed)").font(.caption).foregroundStyle(.green)
        }
    }
}

/// An image block: where the picture comes from and how tall it may be.
private struct ImageInspector: View {
    @ObservedObject var model: StudioModel
    let block: BoardBlock

    var body: some View {
        StudioSection(title: "Image") {
            HStack {
                TextField("File, ~/path, name in the sprite's folder, or https://…", text: model.block(block.id, \.source, fallback: "", coalesce: true))
                    .textFieldStyle(.roundedBorder)
                Button("Choose…", action: choose)
            }
            Text("A file is read again whenever it changes, so a script can redraw it. Links must be https.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            InspectorField("Height") {
                Slider(value: model.block(block.id, \.style.height, fallback: 120, coalesce: true), in: 20...400, step: 1).frame(width: 160)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let id = block.id
        model.editBoard { $0.root.update(id) { $0.source = url.path } }
    }
}

/// Swatches for a block's fill: none, a few that read well behind text, or any colour.
private struct BackgroundChoice: View {
    @Binding var value: String
    static let presets = ["1C1C1E", "2C2C2E", "3A3A3C", "E5E5EA", "0A84FF", "30D158", "FF9F0A", "FF453A", "BF5AF2", "1E3A5F", "3B2A14", "143A2B"]

    var body: some View {
        FlowLayout(spacing: 5) {
            swatch("none", help: "No fill") {
                Image(systemName: "circle.slash").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(Self.presets, id: \.self) { hex in
                swatch(hex, help: "#\(hex)") { Circle().fill(spriteColor(hex)).frame(width: 14, height: 14) }
            }
            if SpriteColors.system(value) != nil {
                swatch(value, help: "\(value) (Apple's system colour, adapts to light and dark)") {
                    Circle().fill(spriteColor(value)).frame(width: 14, height: 14)
                }
            }
            ColorPicker("", selection: Binding(
                get: { SpriteColors.color(value).map { Color(nsColor: $0) } ?? .gray },
                set: { value = ColorChoice.hex($0) ?? value }), supportsOpacity: false)
                .labelsHidden().frame(width: 26).help("Any colour")
        }
    }
    private func swatch<Content: View>(_ hex: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        Button { value = hex } label: {
            content().frame(width: 20, height: 20)
                .overlay(Circle().stroke(value.uppercased() == hex.uppercased() ? Color.accentColor : Color.secondary.opacity(0.3),
                                         lineWidth: value.uppercased() == hex.uppercased() ? 2 : 1))
        }.buttonStyle(.plain).help(help)
    }
}
