import AgentProtocol
import Foundation
import SystemMonitoring

/// A saved sprite as a spec: what the compiler would assume is left out, shorthand is used where it reads
/// back exactly, and ids appear only where they differ from the position-derived ones (or a rule aims at
/// them, so an agent that moves a piece does not silently retarget the rule).
struct SpecEmitter {
    let environment: SpecEnvironment
    let design: SpriteDesign
    /// Every id a rule aims at.
    let targets: Set<String>

    init(environment: SpecEnvironment, design: SpriteDesign) {
        self.environment = environment; self.design = design
        targets = Set(design.rules.flatMap { $0.branches.flatMap(\.actions) + $0.otherwise }.map(\.target))
    }

    static func emit(_ config: SpriteConfiguration, side: SpriteSide, files: [String: String], environment: SpecEnvironment) -> JSONValue {
        let design = config.design ?? SpriteDesign.migrated(from: config, metric: { environment.metric($0) })
        let emitter = SpecEmitter(environment: environment, design: design)
        var members = [JSONMember("menusprite", .number(Double(SpriteSpecFormat.version))), JSONMember("id", .string(config.id.uuidString)),
                       JSONMember("name", .string(config.name)), JSONMember("icon", .string(config.symbol))]
        if !config.enabled { members.append(JSONMember("enabled", false)) }
        if !config.showInMenuBar { members.append(JSONMember("menuBar", false)) }
        if side == .left { members.append(JSONMember("side", "left")) }
        if config.interval != SpecDefaults.spriteInterval { members.append(JSONMember("every", .number(config.interval))) }
        if !design.variables.isEmpty { members.append(JSONMember("values", .array(design.variables.map(emitter.value)))) }
        if !emitter.isImpliedFace(symbol: config.symbol) { members.append(JSONMember("face", emitter.node(design.root, id: "f", root: true))) }
        if !design.rules.isEmpty { members.append(JSONMember("rules", .array(design.rules.enumerated().map { emitter.rule($1, index: $0) }))) }
        if let board = design.board { members.append(JSONMember("board", emitter.board(board))) }
        if !files.isEmpty {
            members.append(JSONMember("files", .object(files.keys.sorted().map { JSONMember($0, .string(files[$0]!)) })))
        }
        return .object(members)
    }

    // MARK: - Values

    func value(_ variable: SpriteVariable) -> JSONValue {
        var members = [JSONMember("id", .string(variable.id))]
        var defaultName: String? = variable.id
        var command: CommandSource?
        switch variable.source {
        case .reading(let id):
            members.append(JSONMember("reading", .string(id)))
            defaultName = environment.metric(id)?.name
        case .command(let source):
            members.append(JSONMember("command", .string(source.command)))
            command = source
        case .constant(let text):
            members.append(JSONMember("text", .string(text)))
        }
        if variable.name != defaultName { members.append(JSONMember("name", .string(variable.name))) }
        if let command {
            let d = SpecDefaults.command
            // Always written, even at the default: it is the first thing an agent tunes, and a key that is not
            // there cannot be edited.
            members.append(JSONMember("every", SpecDuration.json(command.interval)))
            if command.timeout != d.timeout { members.append(JSONMember("timeout", .number(command.timeout))) }
            if command.output != d.output { members.append(JSONMember("parse", .string(command.output.rawValue))) }
            if !command.path.isEmpty { members.append(JSONMember("path", .string(command.path))) }
            if command.background { members.append(JSONMember("background", true)) }
        }
        let format = variable.format, d = ValueFormat()
        if format.decimals != d.decimals { members.append(JSONMember("decimals", .number(Double(format.decimals)))) }
        if format.showUnit != d.showUnit { members.append(JSONMember("unit", .bool(format.showUnit))) }
        if format.fahrenheit != d.fahrenheit { members.append(JSONMember("fahrenheit", .bool(format.fahrenheit))) }
        if format.bits != d.bits { members.append(JSONMember("bits", .bool(format.bits))) }
        if format.clock != d.clock { members.append(JSONMember("clock", .bool(format.clock))) }
        if format.suffix != d.suffix { members.append(JSONMember("suffix", .string(format.suffix))) }
        return .object(members)
    }

    // MARK: - Face

    /// The face the compiler builds when a spec has none: the icon alone.
    func isImpliedFace(symbol: String) -> Bool {
        let root = design.root
        guard root.kind == .row, root.id == "f", root.name.isEmpty, root.style == SpecDefaults.nodeStyle(.row, root: true),
              root.segments.isEmpty, root.symbol.isEmpty, root.variable == nil, root.children.count == 1,
              !targets.contains(root.id) else { return false }
        let icon = root.children[0]
        return icon.kind == .icon && icon.id == "f-0" && icon.name.isEmpty && icon.style == NodeStyle() && icon.symbol == symbol
            && icon.children.isEmpty && icon.segments.isEmpty && icon.variable == nil && !targets.contains(icon.id)
    }

    func node(_ node: DesignNode, id derived: String, root: Bool) -> JSONValue {
        let style = Self.styleMembers(node.style, SpecDefaults.nodeStyle(node.kind, root: root))
        let showsID = node.id != derived || targets.contains(node.id)
        let children = node.children.enumerated().map { self.node($1, id: "\(derived)-\($0)", root: false) }
        if !showsID, node.name.isEmpty, style.isEmpty, node.symbol.isEmpty, node.variable == nil {
            if node.kind == .row, node.segments.isEmpty { return .array(children) }
            if node.kind == .text, node.children.isEmpty, case .string(let text) = template(node.segments) { return .string(text) }
        }
        var members: [JSONMember] = []
        if showsID { members.append(JSONMember("id", .string(node.id))) }
        if !node.name.isEmpty { members.append(JSONMember("name", .string(node.name))) }
        members += style
        let content: JSONValue
        switch node.kind {
        case .row, .column: content = .array(children)
        case .text: content = template(node.segments)
        case .icon: content = .string(node.symbol)
        case .bar, .battery: content = node.variable.map(JSONValue.string) ?? .null
        }
        return Self.ordered(JSONMember(node.kind.rawValue, content), members, container: node.kind.isContainer)
    }

    /// A leaf leads with its kind (`{"text": "CPU", "size": 9}`); a container ends with its children, so its
    /// own properties are not stranded after a long list.
    static func ordered(_ content: JSONMember, _ members: [JSONMember], container: Bool) -> JSONValue {
        .object(container ? members + [content] : [content] + members)
    }

    static func styleMembers(_ style: NodeStyle, _ d: NodeStyle) -> [JSONMember] {
        var members: [JSONMember] = []
        if style.color != d.color { members.append(JSONMember("color", SpecColor.json(style.color))) }
        if style.size != d.size, let size = style.size { members.append(JSONMember("size", .number(size))) }
        if style.weight != d.weight { members.append(JSONMember("weight", .string(style.weight.rawValue))) }
        if style.tabular != d.tabular { members.append(JSONMember("tabular", .bool(style.tabular))) }
        if style.opacity != d.opacity { members.append(JSONMember("opacity", .number(style.opacity))) }
        if style.align != d.align { members.append(JSONMember("align", .string(style.align.rawValue))) }
        if style.gap != d.gap { members.append(JSONMember("gap", .number(style.gap))) }
        if style.justify != d.justify { members.append(JSONMember("justify", .string(style.justify.rawValue))) }
        if style.padding != d.padding { members.append(JSONMember("padding", .number(style.padding))) }
        if style.hidden != d.hidden { members.append(JSONMember("hidden", .bool(style.hidden))) }
        if style.shrinkToFit != d.shrinkToFit { members.append(JSONMember("shrink", .bool(style.shrinkToFit))) }
        if style.chargeInside != d.chargeInside { members.append(JSONMember("chargeInside", .bool(style.chargeInside))) }
        if style.maximum != d.maximum { members.append(JSONMember("max", .number(style.maximum))) }
        return members
    }

    /// A string when it reads back as the same segments, else the exact list form.
    func template(_ segments: [TextSegment]) -> JSONValue {
        let text = TextTemplate.string(segments)
        let braced = segments.contains { segment in
            guard case .literal(let literal) = segment else { return false }
            return literal.contains("{") && !SpecCompiler.bracedReadings(literal, environment: environment).isEmpty
        }
        if !braced, TextTemplate.parse(text) == segments { return .string(text) }
        return .array(segments.map { segment in
            switch segment {
            case .literal(let literal): .string(literal)
            case .value(let id): .object([JSONMember("value", .string(id))])
            }
        })
    }

    // MARK: - Board

    func board(_ board: BoardDesign) -> JSONValue {
        var members: [JSONMember] = []
        if board.width != SpecDefaults.boardWidth { members.append(JSONMember("width", .number(board.width))) }
        if !board.showHeader { members.append(JSONMember("header", false)) }
        let root = board.root
        if root.kind == .stack {
            if root.id != "b" || targets.contains(root.id) { members.append(JSONMember("id", .string(root.id))) }
            if !root.name.isEmpty { members.append(JSONMember("name", .string(root.name))) }
            members += blockStyleMembers(root.style, SpecDefaults.rootBoardStyle, kind: .stack)
            members.append(JSONMember("blocks", .array(root.children.enumerated().map { block($1, id: "b-\($0)") })))
        } else {
            // The studio always keeps a stack at the top; anything else is carried as the board's one block.
            members.append(JSONMember("blocks", .array([block(root, id: "b-0")])))
        }
        return .object(members)
    }

    func block(_ block: BoardBlock, id derived: String) -> JSONValue {
        var members: [JSONMember] = []
        let content: JSONValue
        switch block.kind {
        case .stack, .row, .card: content = .array(block.children.enumerated().map { self.block($1, id: "\(derived)-\($0)") })
        case .divider, .energy, .accounts, .readings: content = true
        case .spacer: content = .number(block.style.spacing)
        case .text, .button, .toggle: content = template(block.segments)
        case .value, .chart, .gauge, .output: content = block.variable.map(JSONValue.string) ?? .null
        case .stats: content = .array(block.variables.map(JSONValue.string))
        case .script, .blocks: content = .string(block.command?.command ?? "")
        case .image: content = .string(block.source)
        case .processes: content = .string(block.style.processKind.rawValue)
        }
        if !block.segments.isEmpty, block.kind.isContainer { members.append(JSONMember("title", template(block.segments))) }
        if block.id != derived || targets.contains(block.id) { members.append(JSONMember("id", .string(block.id))) }
        if block.name != SpecDefaults.blockName(block.kind) { members.append(JSONMember("name", .string(block.name))) }
        if !block.segments.isEmpty, !block.kind.isContainer {
            switch block.kind {
            case .text, .button, .toggle: break
            case .value, .chart, .gauge: members.append(JSONMember("caption", template(block.segments)))
            default: members.append(JSONMember("title", template(block.segments)))
            }
        }
        if !block.detail.isEmpty { members.append(JSONMember("detail", template(block.detail))) }
        if !block.symbol.isEmpty { members.append(JSONMember("icon", .string(block.symbol))) }
        if block.kind == .toggle {
            if let variable = block.variable { members.append(JSONMember("value", .string(variable))) }
            if let on = block.action { members.append(JSONMember("on", .string(on.value))) }
            if let off = block.offAction { members.append(JSONMember("off", .string(off.value))) }
            if let timeout = block.action?.timeout ?? block.offAction?.timeout { members.append(JSONMember("timeout", .number(timeout))) }
        } else if let action = block.action {
            // A button's action, or what a click on a row, text or figure does.
            switch action.kind {
            case .runCommand: members.append(JSONMember("run", .string(action.value)))
            case .openURL: members.append(JSONMember("open", .string(action.value)))
            case .openApp: members.append(JSONMember("app", .string(action.value)))
            case .copyText: members.append(JSONMember("copy", .string(action.value)))
            case .refresh: members.append(JSONMember("refresh", true))
            }
            if let timeout = action.timeout { members.append(JSONMember("timeout", .number(timeout))) }
        }
        if block.kind == .script || block.kind == .blocks, let command = block.command {
            members.append(JSONMember("every", SpecDuration.json(command.interval)))
            if command.timeout != SpecDefaults.command.timeout { members.append(JSONMember("timeout", .number(command.timeout))) }
        }
        members += blockStyleMembers(block.style, SpecDefaults.blockStyle(block.kind), kind: block.kind)
        return Self.ordered(JSONMember(block.kind.specKey, content), members, container: block.kind.isContainer)
    }

    func blockStyleMembers(_ style: BoardStyle, _ d: BoardStyle, kind: BoardBlockKind) -> [JSONMember] {
        var members: [JSONMember] = []
        if style.textStyle != d.textStyle { members.append(JSONMember("font", .string(style.textStyle.rawValue))) }
        if style.color != d.color { members.append(JSONMember("color", SpecColor.json(style.color))) }
        if style.background != d.background { members.append(JSONMember("background", SpecColor.json(style.background))) }
        if style.align != d.align { members.append(JSONMember("align", .string(style.align.rawValue))) }
        if style.spacing != d.spacing, kind != .spacer { members.append(JSONMember("spacing", .number(style.spacing))) }
        if style.padding != d.padding { members.append(JSONMember("padding", .number(style.padding))) }
        if style.hidden != d.hidden { members.append(JSONMember("hidden", .bool(style.hidden))) }
        if style.opacity != d.opacity { members.append(JSONMember("opacity", .number(style.opacity))) }
        if style.height != d.height { members.append(JSONMember("height", .number(style.height))) }
        if style.maximum != d.maximum { members.append(JSONMember("max", .number(style.maximum))) }
        if style.limit != d.limit { members.append(JSONMember("limit", .number(Double(style.limit)))) }
        if style.lines != d.lines { members.append(JSONMember("lines", .number(Double(style.lines)))) }
        if style.truncate != d.truncate { members.append(JSONMember("truncate", .string(style.truncate.rawValue))) }
        if style.fit != d.fit { members.append(JSONMember("fit", .bool(style.fit))) }
        return members
    }

    // MARK: - Rules

    func rule(_ rule: SpriteRule, index: Int) -> JSONValue {
        var members: [JSONMember] = []
        if rule.id != "r\(index)" { members.append(JSONMember("id", .string(rule.id))) }
        if !rule.name.isEmpty { members.append(JSONMember("name", .string(rule.name))) }
        if !rule.enabled { members.append(JSONMember("enabled", false)) }
        if rule.branches.count == 1 {
            members += branch(rule.branches[0])
        } else {
            members.append(JSONMember("cases", .array(rule.branches.map { .object(branch($0)) })))
        }
        if !rule.otherwise.isEmpty { members.append(JSONMember("else", actions(rule.otherwise))) }
        return .object(members)
    }

    private func branch(_ branch: RuleBranch) -> [JSONMember] {
        var members = [JSONMember("when", .string(SpecWhen.string(branch)))]
        if branch.match == .any, branch.conditions.count < 2 { members.append(JSONMember("match", "any")) }
        members.append(JSONMember("then", actions(branch.actions)))
        return members
    }

    /// Consecutive effects on one target share an object, in their order.
    private func actions(_ actions: [RuleAction]) -> JSONValue {
        var objects: [[JSONMember]] = []
        var kinds: Set<RuleActionKind> = []
        var last: String?
        for action in actions {
            let effect = Self.effect(action)
            if last == action.target, !kinds.contains(action.kind) {
                objects[objects.count - 1].append(effect)
            } else {
                objects.append([JSONMember("target", .string(action.target)), effect])
                last = action.target; kinds = []
            }
            kinds.insert(action.kind)
        }
        return .array(objects.map(JSONValue.object))
    }

    private static func effect(_ action: RuleAction) -> JSONMember {
        switch action.kind {
        case .color: return JSONMember("color", SpecColor.json(action.value))
        case .hide: return JSONMember("hide", true)
        case .show: return JSONMember("show", true)
        case .symbol: return JSONMember("icon", .string(action.value))
        case .text: return JSONMember("text", .string(action.value))
        case .opacity:
            if let number = Double(action.value), SpecFormat.number(number) == action.value { return JSONMember("opacity", .number(number)) }
            return JSONMember("opacity", .string(action.value))
        }
    }
}
