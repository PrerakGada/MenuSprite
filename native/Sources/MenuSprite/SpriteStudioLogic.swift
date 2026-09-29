import SwiftUI
import SystemMonitoring

/// The right half of the studio: the values the sprite shows or compares, and the rules that
/// restyle it while they hold.
struct StudioLogicPane: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    @State private var pickingReading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StudioSection(title: "Values", subtitle: "what the sprite knows") {
                    Menu {
                        Button("A reading from this Mac…") { pickingReading = true }
                        Button("The output of a command") {
                            model.addVariable(SpriteVariable(id: "command", name: "Command", source: .command(CommandSource(command: "date +%H:%M")),
                                                             format: ValueFormat()))
                        }
                        Button("Fixed text") { model.addVariable(SpriteVariable(id: "text", name: "Text", source: .constant(text: "Hello"))) }
                    } label: { Label("Add value", systemImage: "plus") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("add-value")
                } content: {
                    if model.design.variables.isEmpty {
                        Text("A value is a reading (CPU, battery, Claude usage…), a command's output, or fixed text. Texts show values; rules compare them.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.design.variables) { variable in VariableCard(model: model, store: store, variableID: variable.id) }
                }
                StudioSection(title: "Rules", subtitle: "if this, then change that") {
                    Menu {
                        Button("Colour a piece when a value is high") { addThresholdRule() }
                        Button("Hide a piece while a value is unavailable") { addHideRule() }
                        Button("Empty rule") { addRule(SpriteRule(name: "New rule", branches: [RuleBranch(conditions: [firstCondition()], actions: [])])) }
                    } label: { Label("Add rule", systemImage: "plus") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(model.design.variables.isEmpty)
                        .accessibilityIdentifier("add-rule")
                } content: {
                    if model.design.rules.isEmpty {
                        Text("Rules run top to bottom whenever the values change; a later rule wins. Each one is If → Otherwise if → Otherwise, like Shortcuts.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    let active = SpriteRules.chosenBranches(model.design, values: store.designValues(model.design))
                    ForEach(model.design.rules) { rule in
                        RuleCard(model: model, store: store, ruleID: rule.id, active: active[rule.id] ?? nil)
                    }
                }
            }
            .padding(16)
        }
        .controlSize(.small)
        .sheet(isPresented: $pickingReading) { ReadingPicker(model: model, store: store) }
    }

    private func firstCondition() -> RuleCondition {
        RuleCondition(variable: model.design.variables.first?.id ?? "", comparison: .above, operand: "80")
    }
    /// The piece a new rule should change: the selection, else the first text showing a value.
    private func defaultTarget() -> String {
        if let selection = model.selection, selection != model.design.root.id { return selection }
        return model.design.root.flattened.first { !$0.referencedVariables.isEmpty }?.id ?? model.design.root.id
    }
    private func addRule(_ rule: SpriteRule) { model.edit { $0.rules.append(rule) } }
    private func addThresholdRule() {
        let target = defaultTarget()
        let variable = model.design.node(target)?.referencedVariables.first ?? model.design.variables.first?.id ?? ""
        addRule(SpriteRule(name: "Warn when high", branches: [
            RuleBranch(conditions: [RuleCondition(variable: variable, comparison: .above, operand: "85")],
                       actions: [RuleAction(kind: .color, target: target, value: "FF453A")]),
            RuleBranch(conditions: [RuleCondition(variable: variable, comparison: .above, operand: "60")],
                       actions: [RuleAction(kind: .color, target: target, value: "FFD60A")])
        ]))
    }
    private func addHideRule() {
        let target = defaultTarget()
        let variable = model.design.node(target)?.referencedVariables.first ?? model.design.variables.first?.id ?? ""
        addRule(SpriteRule(name: "Hide while unavailable", branches: [
            RuleBranch(conditions: [RuleCondition(variable: variable, comparison: .isMissing)],
                       actions: [RuleAction(kind: .hide, target: target)])
        ]))
    }
}

// MARK: - Values

private struct VariableCard: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    let variableID: String
    @State private var open = false

    var body: some View {
        if let variable = model.design.variable(variableID) {
            let live = store.designValues(model.design).formatted(variable)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon(variable)).frame(width: 18).foregroundStyle(Color.accentColor)
                    TextField("Name", text: model.variable(variableID, \.name, fallback: "", coalesce: true))
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(live).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .help("Its value right now")
                    Button { open.toggle() } label: { Image(systemName: open ? "chevron.up" : "chevron.down") }
                        .buttonStyle(.borderless).help("Settings")
                    Menu {
                        if let node = model.selectedNode, node.kind == .text {
                            Button("Insert into the selected text") { model.edit { $0.root.update(node.id) { $0.segments.append(.value(variableID)) } } }
                        }
                        Button("Show it as a new text") { model.addValueText(variableID) }
                        Divider()
                        Button("Delete value", role: .destructive) { model.edit { design in design.variables.removeAll { $0.id == variableID }; design.prune() } }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Text(summary(variable)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if open || variable.command != nil && variable.command?.command.isEmpty == true { details(variable) }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            .onAppear { if variable.command != nil && model.config.design?.variables.last?.id == variableID && !model.isSaved { open = true } }
        }
    }

    private func icon(_ variable: SpriteVariable) -> String {
        switch variable.source { case .reading: "gauge.with.dots.needle.50percent"; case .command: "terminal"; case .constant: "textformat" }
    }
    private func summary(_ variable: SpriteVariable) -> String {
        switch variable.source {
        case .reading(let id): "Reading · \(store.metric(id).name) · key {\(variable.id)}"
        case .command(let command): "Command · every \(Self.interval(command.interval)) · key {\(variable.id)}"
        case .constant: "Fixed text · key {\(variable.id)}"
        }
    }
    static func interval(_ seconds: Double) -> String {
        seconds >= 3600 ? "\(Int(seconds / 3600)) h" : seconds >= 60 ? "\(Int(seconds / 60)) min" : "\(Int(seconds)) s"
    }

    @ViewBuilder private func details(_ variable: SpriteVariable) -> some View {
        switch variable.source {
        case .reading(let id):
            let metric = store.metric(id)
            Toggle("Show the unit (%, W, °C…)", isOn: model.variable(variableID, \.format.showUnit, fallback: true))
            if metric.unit != .text && metric.unit != .seconds {
                Stepper("Decimals: \(variable.format.decimals)", value: model.variable(variableID, \.format.decimals, fallback: 0), in: 0...2)
            }
            if metric.unit == .celsius { Toggle("Fahrenheit", isOn: model.variable(variableID, \.format.fahrenheit, fallback: false)) }
            if metric.group == .network && metric.unit == .bytesPerSecond {
                Toggle("Bits per second", isOn: model.variable(variableID, \.format.bits, fallback: false))
            }
            Text(metric.detail).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        case .command(let command):
            CommandEditor(model: model, store: store, variableID: variableID, command: command, format: variable.format)
        case .constant(let text):
            TextField("Text", text: Binding(get: { text }, set: { value in
                model.edit(coalesce: true) { design in
                    if let index = design.variables.firstIndex(where: { $0.id == variableID }) { design.variables[index].source = .constant(text: value) }
                }
            })).textFieldStyle(.roundedBorder)
        }
    }
}

/// A command variable: the shell line, how to read its output, how often, and its last run.
private struct CommandEditor: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    let variableID: String
    let command: CommandSource
    let format: ValueFormat

    private func update(coalesce: Bool = false, _ body: @escaping (inout CommandSource) -> Void) {
        model.edit(coalesce: coalesce) { design in
            guard let index = design.variables.firstIndex(where: { $0.id == variableID }), var source = design.variables[index].command else { return }
            body(&source)
            design.variables[index].source = .command(source)
        }
    }

    var body: some View {
        let result = store.commands.results[command.normalized]
        let running = store.commands.running.contains(command.normalized)
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: Binding(get: { command.command }, set: { value in update(coalesce: true) { $0.command = value } }))
                .font(.system(size: 12, design: .monospaced)).frame(height: 58)
                .scrollContentBackground(.hidden).padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            Text("Runs with /bin/zsh (without your shell profile; Homebrew is on the path) while this sprite is running.")
                .font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Picker("Read as", selection: Binding(get: { command.output }, set: { value in update { $0.output = value } })) {
                    ForEach(CommandOutput.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 170)
                if command.output == .json {
                    TextField("path, e.g. data.count", text: Binding(get: { command.path }, set: { value in update(coalesce: true) { $0.path = value } }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Picker("Every", selection: Binding(get: { command.interval }, set: { value in update { $0.interval = value } })) {
                    ForEach(CommandSource.intervals, id: \.self) { Text(VariableCard.interval($0)).tag($0) }
                }.frame(width: 130)
                Stepper("Stop after \(Int(command.timeout)) s", value: Binding(get: { command.timeout }, set: { value in update { $0.timeout = value } }), in: 1...60)
            }
            HStack {
                TextField("After the value, e.g. GB", text: model.variable(variableID, \.format.suffix, fallback: "", coalesce: true))
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                if command.output != .text {
                    Stepper("Decimals: \(format.decimals)", value: model.variable(variableID, \.format.decimals, fallback: 0), in: 0...3)
                }
            }
            HStack(alignment: .top) {
                Button { Task { await store.commands.run(command) } } label: {
                    Label(running ? "Running…" : "Run now", systemImage: "play.fill")
                }.disabled(running || command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let result {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.problem ?? "Read “\(result.text ?? result.number.map { String($0) } ?? "")”")
                            .font(.caption).foregroundStyle(result.problem == nil ? Color.green : Color.orange)
                        Text("\(String(format: "%.2f", result.elapsed)) s · \(result.finishedAt.formatted(date: .omitted, time: .standard))\(result.status.map { " · exit \($0)" } ?? "")")
                            .font(.caption2).foregroundStyle(.secondary)
                        let shown = (result.output.isEmpty ? result.errorOutput : result.output).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !shown.isEmpty {
                            Text(String(shown.prefix(300))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(4).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

/// Choose a reading from the catalog to add as a value.
private struct ReadingPicker: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var open: Set<MetricGroup> = [.cpu, .memory]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Add a reading").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            TextField("Search readings", text: $search).textFieldStyle(.roundedBorder)
            Text(model.selectedNode?.kind == .text ? "It is added to the end of the selected text." : "It is added as a new text beside the selection.")
                .font(.caption).foregroundStyle(.secondary)
            ReadingGroupList(store: store, search: search, expanded: $open) { metric in
                let used = model.design.variables.contains { $0.readingID == metric.id }
                Button { model.addReading(metric) } label: { Image(systemName: used ? "checkmark.circle.fill" : "plus.circle") }
                    .buttonStyle(.borderless).help(used ? "Already a value · add it again" : "Add this reading")
            }
            .padding(.horizontal, -16)
        }
        .padding(18).frame(width: 520, height: 560)
    }
}

// MARK: - Rules

private struct RuleCard: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    let ruleID: String
    /// The branch holding now: an index, nil for "otherwise", absent when the rule is off.
    let active: Int?

    private var rule: SpriteRule? { model.design.rules.first { $0.id == ruleID } }
    private func update(coalesce: Bool = false, _ body: @escaping (inout SpriteRule) -> Void) {
        model.edit(coalesce: coalesce) { design in
            if let index = design.rules.firstIndex(where: { $0.id == ruleID }) { body(&design.rules[index]) }
        }
    }

    var body: some View {
        if let rule {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Toggle("", isOn: model.rule(ruleID, \.enabled, fallback: true)).toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    TextField("Rule name", text: model.rule(ruleID, \.name, fallback: "", coalesce: true))
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Menu {
                        Button("Move up") { model.edit { d in if let i = d.rules.firstIndex(where: { $0.id == ruleID }), i > 0 { d.rules.swapAt(i, i - 1) } } }
                        Button("Move down") { model.edit { d in if let i = d.rules.firstIndex(where: { $0.id == ruleID }), i < d.rules.count - 1 { d.rules.swapAt(i, i + 1) } } }
                        Button("Duplicate") { model.edit { d in if let i = d.rules.firstIndex(where: { $0.id == ruleID }) {
                            var copy = d.rules[i]; copy.id = DesignNode.newID(); copy.name += " copy"; d.rules.insert(copy, at: i + 1) } } }
                        Divider()
                        Button("Delete rule", role: .destructive) { model.edit { $0.rules.removeAll { $0.id == ruleID } } }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                ForEach(Array(rule.branches.enumerated()), id: \.element.id) { index, branch in
                    BranchView(model: model, store: store, ruleID: ruleID, branchID: branch.id,
                               title: index == 0 ? "If" : "Otherwise if", isActive: rule.enabled && active == index)
                }
                OtherwiseView(model: model, ruleID: ruleID, isActive: rule.enabled && active == nil && !rule.otherwise.isEmpty)
                HStack {
                    Button { update { $0.branches.append(RuleBranch(conditions: [RuleCondition(variable: $0.branches.last?.conditions.first?.variable ?? model.design.variables.first?.id ?? "")], actions: [])) } }
                        label: { Label("Otherwise if", systemImage: "plus") }
                    if rule.otherwise.isEmpty {
                        Button { update { $0.otherwise = [RuleAction(kind: .color, target: $0.branches.first?.actions.first?.target ?? model.design.root.id, value: "FFFFFF")] } }
                            label: { Label("Otherwise", systemImage: "plus") }
                    }
                }.buttonStyle(.borderless).font(.caption)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            .opacity(rule.enabled ? 1 : 0.6)
        }
    }
}

/// "If" / "Otherwise if": the conditions, then what to change while they hold.
private struct BranchView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    let ruleID: String
    let branchID: String
    let title: String
    let isActive: Bool

    private var branch: RuleBranch? { model.design.rules.first { $0.id == ruleID }?.branches.first { $0.id == branchID } }
    private func update(coalesce: Bool = false, _ body: @escaping (inout RuleBranch) -> Void) {
        model.edit(coalesce: coalesce) { design in
            guard let r = design.rules.firstIndex(where: { $0.id == ruleID }),
                  let b = design.rules[r].branches.firstIndex(where: { $0.id == branchID }) else { return }
            body(&design.rules[r].branches[b])
        }
    }

    var body: some View {
        if let branch {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.accentColor)
                    if branch.conditions.count > 1 {
                        Picker("", selection: Binding(get: { branch.match }, set: { value in update { $0.match = value } })) {
                            Text("all of these").tag(RuleMatch.all); Text("any of these").tag(RuleMatch.any)
                        }.labelsHidden().fixedSize()
                    }
                    Spacer()
                    if isActive { Label("true now", systemImage: "circle.fill").font(.caption2).foregroundStyle(.green).labelStyle(.titleAndIcon) }
                    if title != "If" {
                        Button { model.edit { d in if let r = d.rules.firstIndex(where: { $0.id == ruleID }) { d.rules[r].branches.removeAll { $0.id == branchID } } } }
                            label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove this branch")
                    }
                }
                ForEach(branch.conditions) { condition in
                    ConditionRow(model: model, store: store, condition: condition,
                                 set: { value in update(coalesce: true) { b in if let i = b.conditions.firstIndex(where: { $0.id == condition.id }) { b.conditions[i] = value } } },
                                 remove: branch.conditions.count > 1 ? { update { $0.conditions.removeAll { $0.id == condition.id } } } : nil)
                }
                Button { update { $0.conditions.append(RuleCondition(variable: $0.conditions.last?.variable ?? model.design.variables.first?.id ?? "")) } }
                    label: { Label("and…", systemImage: "plus") }.buttonStyle(.borderless).font(.caption)
                ActionList(model: model, actions: branch.actions) { value in update(coalesce: true) { $0.actions = value } }
            }
            .padding(9)
            .background(isActive ? Color.green.opacity(0.07) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct OtherwiseView: View {
    @ObservedObject var model: StudioModel
    let ruleID: String
    let isActive: Bool
    var body: some View {
        if let rule = model.design.rules.first(where: { $0.id == ruleID }), !rule.otherwise.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Otherwise").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.accentColor)
                    Spacer()
                    if isActive { Label("true now", systemImage: "circle.fill").font(.caption2).foregroundStyle(.green) }
                    Button { model.edit { d in if let r = d.rules.firstIndex(where: { $0.id == ruleID }) { d.rules[r].otherwise = [] } } }
                        label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
                ActionList(model: model, actions: rule.otherwise) { value in
                    model.edit(coalesce: true) { d in if let r = d.rules.firstIndex(where: { $0.id == ruleID }) { d.rules[r].otherwise = value } }
                }
            }
            .padding(9)
            .background(isActive ? Color.green.opacity(0.07) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// [value] [value/pace] [is above] [80]
private struct ConditionRow: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    let condition: RuleCondition
    let set: (RuleCondition) -> Void
    let remove: (() -> Void)?

    var body: some View {
        let variable = model.design.variable(condition.variable)
        let isAI = variable?.readingID.map { store.metric($0).group == .ai } ?? false
        FlowLayout(spacing: 5) {
            Picker("", selection: Binding(get: { condition.variable }, set: { var c = condition; c.variable = $0; set(c) })) {
                ForEach(model.design.variables) { Text($0.name).tag($0.id) }
            }.labelsHidden().fixedSize()
            if isAI || condition.aspect != .value {
                Picker("", selection: Binding(get: { condition.aspect }, set: { var c = condition; c.aspect = $0; set(c) })) {
                    Text("value").tag(VariableAspect.value); Text("pace").tag(VariableAspect.pace)
                }.labelsHidden().fixedSize()
            }
            Picker("", selection: Binding(get: { condition.comparison }, set: { var c = condition; c.comparison = $0; set(c) })) {
                ForEach(RuleComparison.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().fixedSize()
            if condition.comparison.needsOperand {
                if condition.aspect == .pace {
                    Picker("", selection: Binding(get: { condition.operand }, set: { var c = condition; c.operand = $0; set(c) })) {
                        Text("on track").tag("on track"); Text("ahead").tag("ahead"); Text("over").tag("over")
                    }.labelsHidden().fixedSize()
                } else if variable?.readingID == "memory.pressure" {
                    Picker("", selection: Binding(get: { condition.operand }, set: { var c = condition; c.operand = $0; set(c) })) {
                        Text("Normal").tag("Normal"); Text("Warning").tag("Warning"); Text("Critical").tag("Critical")
                    }.labelsHidden().fixedSize()
                } else {
                    TextField(condition.comparison.isNumeric ? "80" : "text", text: Binding(get: { condition.operand }, set: { var c = condition; c.operand = $0; set(c) }))
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                }
            }
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
    }
}

/// → [Colour] [piece] [swatches]
private struct ActionList: View {
    @ObservedObject var model: StudioModel
    let actions: [RuleAction]
    let set: ([RuleAction]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { action.kind }, set: { kind in
                            var next = actions; next[index].kind = kind
                            next[index].value = switch kind {
                            case .color: "FF453A"; case .symbol: "exclamationmark.triangle.fill"; case .opacity: "0.4"
                            case .text: model.design.node(action.target).map { TextTemplate.string($0.segments) } ?? ""
                            case .hide, .show: ""
                            }
                            set(next)
                        })) { ForEach(RuleActionKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                            .labelsHidden().fixedSize()
                        Picker("", selection: Binding(get: { action.target }, set: { var next = actions; next[index].target = $0; set(next) })) {
                            Section("Menu bar") {
                                ForEach(model.design.root.flattened.filter { $0.id != model.design.root.id || action.kind == .color }) { node in
                                    Text(node.id == model.design.root.id ? "Whole sprite" : model.design.title(of: node)).tag(node.id)
                                }
                            }
                            if let board = model.design.board {
                                Section("Board") {
                                    ForEach(board.root.flattened.filter { $0.id != board.root.id }) { block in
                                        Text(model.design.title(of: block)).tag(block.id)
                                    }
                                }
                            }
                        }
                        .labelsHidden().frame(maxWidth: 190)
                        .onHover { model.highlighted = $0 ? action.target : nil }
                        Spacer(minLength: 0)
                        Button { var next = actions; next.remove(at: index); set(next) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    switch action.kind {
                    case .color:
                        ColorChoice(value: Binding(get: { action.value }, set: { var next = actions; next[index].value = $0; set(next) }), allowInherit: false)
                            .padding(.leading, 20)
                    case .symbol:
                        TextField("SF Symbol name", text: Binding(get: { action.value }, set: { var next = actions; next[index].value = $0; set(next) }))
                            .textFieldStyle(.roundedBorder).padding(.leading, 20)
                    case .text:
                        TextField("New text, values as {key}", text: Binding(get: { action.value }, set: { var next = actions; next[index].value = $0; set(next) }))
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).padding(.leading, 20)
                    case .opacity:
                        Slider(value: Binding(get: { Double(action.value) ?? 0.4 }, set: { var next = actions; next[index].value = String(format: "%.2f", $0); set(next) }),
                               in: 0.1...1).padding(.leading, 20).frame(maxWidth: 220)
                    case .hide, .show: EmptyView()
                    }
                }
            }
            Button {
                let target = actions.last?.target ?? model.selection ?? model.design.root.flattened.first { !$0.referencedVariables.isEmpty }?.id ?? model.design.root.id
                set(actions + [RuleAction(kind: .color, target: target, value: "FF453A")])
            } label: { Label("then…", systemImage: "plus") }.buttonStyle(.borderless).font(.caption)
        }
    }
}
