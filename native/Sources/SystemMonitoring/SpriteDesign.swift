import Foundation

/// A sprite's face as a flex tree, the named values it shows, and the rules that restyle it.
///
/// Rows lay children side by side, columns stack them (the menu bar has room for two lines).
/// Leaves are text (fixed text mixed with values), an SF Symbol, a level bar or the battery glyph.
/// A sprite saved before designs existed is converted by `migrated(from:metric:)`, which reproduces
/// the old layouts and colour rules as ordinary nodes and rules. Spec: `docs/sprite-studio.md`.
public struct SpriteDesign: Codable, Sendable, Equatable {
    public var root: DesignNode
    public var variables: [SpriteVariable]
    public var rules: [SpriteRule]
    /// What a click opens; nil keeps the sprite's classic panel.
    public var board: BoardDesign?

    public init(root: DesignNode = .row([]), variables: [SpriteVariable] = [], rules: [SpriteRule] = [], board: BoardDesign? = nil) {
        self.root = root; self.variables = variables; self.rules = rules; self.board = board
    }

    public func variable(_ id: String) -> SpriteVariable? { variables.first { $0.id == id } }

    /// Readings the face shows, in drawing order. These decide which panel a click opens, so a
    /// reading used only by a rule is left out (see `ruleOnlyReadingIDs`).
    public var displayedReadingIDs: [String] {
        var seen: Set<String> = []
        return root.flattened.flatMap(\.referencedVariables).compactMap { variable($0)?.readingID }
            .filter { seen.insert($0).inserted }
    }
    /// Readings sampled only because a rule compares them.
    public var ruleOnlyReadingIDs: [String] {
        let shown = Set(displayedReadingIDs)
        var seen: Set<String> = []
        return rules.flatMap(\.referencedVariables).compactMap { variable($0)?.readingID }
            .filter { !shown.contains($0) && seen.insert($0).inserted }
    }
    /// Every variable backed by a command, whether it is shown or only compared.
    public var commandVariables: [SpriteVariable] { variables.filter { $0.command != nil } }

    public func node(_ id: String) -> DesignNode? { root.find(id) }

    /// A variable id not yet used in this design, derived from `base`.
    public func freshVariableID(_ base: String) -> String {
        let stem = base.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
            .split(separator: "_").joined(separator: "_")
        let root = stem.isEmpty ? "value" : String(stem.prefix(24))
        var candidate = root, index = 2
        while variables.contains(where: { $0.id == candidate }) { candidate = "\(root)_\(index)"; index += 1 }
        return candidate
    }

    /// Drops references to variables and nodes that no longer exist, so a deleted value cannot leave
    /// a rule or a text pointing at nothing.
    public mutating func prune() {
        let ids = Set(variables.map(\.id))
        root.pruneVariables(keeping: ids)
        board?.root.pruneVariables(keeping: ids)
        let nodes = Set(root.flattened.map(\.id)).union(board?.root.flattened.map(\.id) ?? [])
        rules = rules.map { rule in
            var rule = rule
            rule.branches = rule.branches.map { branch in
                var branch = branch
                branch.conditions = branch.conditions.filter { ids.contains($0.variable) }
                branch.actions = branch.actions.filter { nodes.contains($0.target) }
                return branch
            }
            rule.otherwise = rule.otherwise.filter { nodes.contains($0.target) }
            return rule
        }
    }
}

// MARK: - Nodes

public enum DesignNodeKind: String, Codable, Sendable, CaseIterable {
    case row, column, text, icon, bar, battery
    public var isContainer: Bool { self == .row || self == .column }
    public var title: String {
        switch self {
        case .row: "Row"; case .column: "Column"; case .text: "Text"
        case .icon: "Icon"; case .bar: "Level bar"; case .battery: "Battery"
        }
    }
}

public enum TextSegment: Codable, Sendable, Equatable, Hashable {
    case literal(String)
    case value(String)
    public var variableID: String? { if case .value(let id) = self { id } else { nil } }
}

public enum DesignWeight: String, Codable, Sendable, CaseIterable {
    case regular, medium, semibold, bold, heavy
    public var title: String { rawValue.capitalized }
}
public enum DesignAlign: String, Codable, Sendable, CaseIterable {
    case leading, center, trailing
}
/// How a container spreads its children: packed at the start, centre or end, pushed apart, or
/// (for columns) given equal bands.
public enum DesignJustify: String, Codable, Sendable, CaseIterable {
    case start, center, end, spaceBetween, even
    public var title: String {
        switch self {
        case .start: "Start"; case .center: "Centre"; case .end: "End"
        case .spaceBetween: "Push apart"; case .even: "Equal bands"
        }
    }
}

public struct NodeStyle: Codable, Sendable, Equatable {
    /// "inherit" takes the parent's colour, "auto" follows the menu bar's appearance, else RRGGBB.
    public var color: String = "inherit"
    /// Point size of text, or the height of an icon's slot, or the width of a level bar.
    public var size: Double?
    public var weight: DesignWeight = .regular
    /// Fixed-width digits, so a changing number does not shuffle its neighbours.
    public var tabular: Bool = true
    public var opacity: Double = 1
    /// Where this node sits across its parent (a column's children) and inside its own slot.
    public var align: DesignAlign = .center
    /// Space between a container's children.
    public var gap: Double = 4
    public var justify: DesignJustify = .center
    /// Leading and trailing padding of a container.
    public var padding: Double = 0
    public var hidden: Bool = false
    /// Text that gives up size (down to 6.5 pt) before it widens its column or overflows the bar:
    /// the small label above a value.
    public var shrinkToFit: Bool = false
    /// Battery only: draw the charge inside the glyph.
    public var chargeInside: Bool = true
    /// Level bar only: the value that fills it.
    public var maximum: Double = 100

    public init() {}
    enum CodingKeys: String, CodingKey {
        case color, size, weight, tabular, opacity, align, gap, justify, padding, hidden, shrinkToFit, chargeInside, maximum
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NodeStyle()
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? d.color
        size = try c.decodeIfPresent(Double.self, forKey: .size)
        weight = try c.decodeIfPresent(DesignWeight.self, forKey: .weight) ?? d.weight
        tabular = try c.decodeIfPresent(Bool.self, forKey: .tabular) ?? d.tabular
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        align = try c.decodeIfPresent(DesignAlign.self, forKey: .align) ?? d.align
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? d.gap
        justify = try c.decodeIfPresent(DesignJustify.self, forKey: .justify) ?? d.justify
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? d.hidden
        shrinkToFit = try c.decodeIfPresent(Bool.self, forKey: .shrinkToFit) ?? d.shrinkToFit
        chargeInside = try c.decodeIfPresent(Bool.self, forKey: .chargeInside) ?? d.chargeInside
        maximum = try c.decodeIfPresent(Double.self, forKey: .maximum) ?? d.maximum
    }
}

public struct DesignNode: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: DesignNodeKind
    /// What the studio calls this node ("Label", "Value"); rules name their targets by it.
    public var name: String
    public var children: [DesignNode]
    public var segments: [TextSegment]
    public var symbol: String
    /// The value a level bar or battery draws.
    public var variable: String?
    public var style: NodeStyle

    public init(id: String = DesignNode.newID(), kind: DesignNodeKind, name: String = "", children: [DesignNode] = [],
                segments: [TextSegment] = [], symbol: String = "", variable: String? = nil, style: NodeStyle = NodeStyle()) {
        self.id = id; self.kind = kind; self.name = name; self.children = children
        self.segments = segments; self.symbol = symbol; self.variable = variable; self.style = style
    }
    enum CodingKeys: String, CodingKey { case id, kind, name, children, segments, symbol, variable, style }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? DesignNode.newID()
        kind = try c.decode(DesignNodeKind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        children = try c.decodeIfPresent([DesignNode].self, forKey: .children) ?? []
        segments = try c.decodeIfPresent([TextSegment].self, forKey: .segments) ?? []
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        variable = try c.decodeIfPresent(String.self, forKey: .variable)
        style = try c.decodeIfPresent(NodeStyle.self, forKey: .style) ?? NodeStyle()
    }

    public static func newID() -> String { "n" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(7).lowercased() }

    public static func row(_ children: [DesignNode], gap: Double = 4, name: String = "") -> Self {
        var style = NodeStyle(); style.gap = gap
        return Self(kind: .row, name: name, children: children, style: style)
    }
    public static func column(_ children: [DesignNode], gap: Double = 1.5, name: String = "") -> Self {
        var style = NodeStyle(); style.gap = gap
        return Self(kind: .column, name: name, children: children, style: style)
    }
    public static func text(_ segments: [TextSegment], size: Double = 12, name: String = "") -> Self {
        var style = NodeStyle(); style.size = size
        return Self(kind: .text, name: name, segments: segments, style: style)
    }

    /// This node and every node beneath it, depth first.
    public var flattened: [DesignNode] { [self] + children.flatMap(\.flattened) }
    public var referencedVariables: [String] {
        switch kind {
        case .text: segments.compactMap(\.variableID)
        case .bar, .battery: variable.map { [$0] } ?? []
        default: []
        }
    }
    public func find(_ id: String) -> DesignNode? {
        if self.id == id { return self }
        for child in children { if let found = child.find(id) { return found } }
        return nil
    }
    /// The container holding `id`, and its index there.
    public func parent(of id: String) -> (DesignNode, Int)? {
        if let index = children.firstIndex(where: { $0.id == id }) { return (self, index) }
        for child in children { if let found = child.parent(of: id) { return found } }
        return nil
    }
    /// Applies `change` to the node `id`; returns false if there is no such node.
    @discardableResult
    public mutating func update(_ id: String, _ change: (inout DesignNode) -> Void) -> Bool {
        if self.id == id { change(&self); return true }
        for index in children.indices where children[index].update(id, change) { return true }
        return false
    }
    /// Removes and returns the node `id` (never the node itself).
    public mutating func remove(_ id: String) -> DesignNode? {
        if let index = children.firstIndex(where: { $0.id == id }) { return children.remove(at: index) }
        for index in children.indices { if let removed = children[index].remove(id) { return removed } }
        return nil
    }
    mutating func pruneVariables(keeping ids: Set<String>) {
        segments = segments.filter { $0.variableID.map(ids.contains) ?? true }
        if let variable, !ids.contains(variable) { self.variable = nil }
        for index in children.indices { children[index].pruneVariables(keeping: ids) }
    }
    /// Gives this node and everything beneath it new ids (a pasted or duplicated copy).
    public func reidentified() -> DesignNode {
        var copy = self
        copy.id = DesignNode.newID()
        copy.children = children.map { $0.reidentified() }
        return copy
    }
}

// MARK: - Variables

public enum CommandOutput: String, Codable, Sendable, CaseIterable {
    case text, number, json
    public var title: String {
        switch self { case .text: "Text"; case .number: "Number"; case .json: "JSON field" }
    }
}

/// A shell command whose output becomes a value. It runs only while its sprite is enabled (or open in
/// the studio), never overlaps itself, is killed at its timeout and backs off after failures.
public struct CommandSource: Codable, Sendable, Equatable, Hashable {
    public var command: String
    public var interval: Double
    public var timeout: Double
    public var output: CommandOutput
    /// For JSON output: a dotted path into the document ("data.count", "items.0.name").
    public var path: String
    public init(command: String = "", interval: Double = 60, timeout: Double = 10, output: CommandOutput = .text, path: String = "") {
        self.command = command; self.interval = interval; self.timeout = timeout; self.output = output; self.path = path
    }
    public static let intervals: [Double] = [2, 5, 10, 30, 60, 300, 900, 3600]
    public var normalized: Self {
        var copy = self
        copy.interval = min(3600, max(2, interval.isFinite ? interval : 60))
        copy.timeout = min(60, max(1, timeout.isFinite ? timeout : 10))
        copy.command = String(command.prefix(4000))
        return copy
    }
}

public enum VariableSource: Codable, Sendable, Equatable {
    case reading(metric: String)
    case command(CommandSource)
    case constant(text: String)
}

/// How a value is written: units, decimals and the reading-specific switches.
public struct ValueFormat: Codable, Sendable, Equatable {
    public var showUnit: Bool = true
    public var decimals: Int = 0
    public var fahrenheit: Bool = false
    public var bits: Bool = false
    /// Appended to a command's number ("GB", "°").
    public var suffix: String = ""
    public init() {}
    enum CodingKeys: String, CodingKey { case showUnit, decimals, fahrenheit, bits, suffix }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showUnit = try c.decodeIfPresent(Bool.self, forKey: .showUnit) ?? true
        decimals = try c.decodeIfPresent(Int.self, forKey: .decimals) ?? 0
        fahrenheit = try c.decodeIfPresent(Bool.self, forKey: .fahrenheit) ?? false
        bits = try c.decodeIfPresent(Bool.self, forKey: .bits) ?? false
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
    }
}

public struct SpriteVariable: Codable, Sendable, Equatable, Identifiable {
    /// Stable within the sprite; texts and rules refer to it.
    public var id: String
    public var name: String
    public var source: VariableSource
    public var format: ValueFormat
    public init(id: String, name: String, source: VariableSource, format: ValueFormat = ValueFormat()) {
        self.id = id; self.name = name; self.source = source; self.format = format
    }
    public var readingID: String? { if case .reading(let id) = source { id } else { nil } }
    public var command: CommandSource? { if case .command(let command) = source { command } else { nil } }
}

// MARK: - Rules

/// Which facet of a value a condition reads.
public enum VariableAspect: String, Codable, Sendable, CaseIterable {
    /// The number (or text) itself.
    case value
    /// Claude and Codex limits: "on track", "ahead" or "over" the even pace; empty when unknown.
    case pace
    public var title: String { self == .value ? "value" : "pace" }
}

public enum RuleComparison: String, Codable, Sendable, CaseIterable {
    case above, atLeast, below, atMost, equals, notEquals, contains, isMissing, isPresent
    public var title: String {
        switch self {
        case .above: "is above"; case .atLeast: "is at least"; case .below: "is below"; case .atMost: "is at most"
        case .equals: "is"; case .notEquals: "is not"; case .contains: "contains"
        case .isMissing: "is unavailable"; case .isPresent: "is available"
        }
    }
    public var needsOperand: Bool { self != .isMissing && self != .isPresent }
    public var isNumeric: Bool { [.above, .atLeast, .below, .atMost].contains(self) }
}

public struct RuleCondition: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var variable: String
    public var aspect: VariableAspect
    public var comparison: RuleComparison
    public var operand: String
    public init(id: String = DesignNode.newID(), variable: String, aspect: VariableAspect = .value,
                comparison: RuleComparison = .above, operand: String = "") {
        self.id = id; self.variable = variable; self.aspect = aspect; self.comparison = comparison; self.operand = operand
    }
}

public enum RuleActionKind: String, Codable, Sendable, CaseIterable {
    case color, hide, show, symbol, text, opacity
    public var title: String {
        switch self {
        case .color: "Colour"; case .hide: "Hide"; case .show: "Show"; case .symbol: "Change icon"
        case .text: "Replace text"; case .opacity: "Fade"
        }
    }
}

public struct RuleAction: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: RuleActionKind
    public var target: String
    /// A colour (RRGGBB), a symbol name, replacement text (may use {variable}) or an opacity 0–1.
    public var value: String
    public init(id: String = DesignNode.newID(), kind: RuleActionKind = .color, target: String, value: String = "FF453A") {
        self.id = id; self.kind = kind; self.target = target; self.value = value
    }
}

public enum RuleMatch: String, Codable, Sendable, CaseIterable {
    case all, any
}

public struct RuleBranch: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var match: RuleMatch
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]
    public init(id: String = DesignNode.newID(), match: RuleMatch = .all, conditions: [RuleCondition], actions: [RuleAction]) {
        self.id = id; self.match = match; self.conditions = conditions; self.actions = actions
    }
}

/// If / otherwise if / otherwise. The first branch whose conditions hold applies its actions; if none
/// does, the otherwise actions apply. Rules run top to bottom, so a later rule wins over an earlier one.
public struct SpriteRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var branches: [RuleBranch]
    public var otherwise: [RuleAction]
    public init(id: String = DesignNode.newID(), name: String = "", enabled: Bool = true,
                branches: [RuleBranch], otherwise: [RuleAction] = []) {
        self.id = id; self.name = name; self.enabled = enabled; self.branches = branches; self.otherwise = otherwise
    }
    public var referencedVariables: [String] {
        branches.flatMap { $0.conditions.map(\.variable) }
            + (branches.flatMap(\.actions) + otherwise).flatMap { action in
                action.kind == .text ? TextTemplate.parse(action.value).compactMap(\.variableID) : []
            }
    }
}

/// "{cpu}%" ↔ segments. Used by replacement-text actions, where a single field is easier to edit.
public enum TextTemplate {
    public static func parse(_ text: String) -> [TextSegment] {
        var result: [TextSegment] = [], literal = "", index = text.startIndex
        while index < text.endIndex {
            if text[index] == "{", let close = text[index...].firstIndex(of: "}") {
                let name = String(text[text.index(after: index)..<close])
                if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    if !literal.isEmpty { result.append(.literal(literal)); literal = "" }
                    result.append(.value(name))
                    index = text.index(after: close)
                    continue
                }
            }
            literal.append(text[index]); index = text.index(after: index)
        }
        if !literal.isEmpty { result.append(.literal(literal)) }
        return result
    }
    public static func string(_ segments: [TextSegment]) -> String {
        segments.map { segment in
            switch segment { case .literal(let text): text; case .value(let id): "{\(id)}" }
        }.joined()
    }
}

// MARK: - Evaluation

/// The live values a design is drawn from, supplied by the monitoring store.
public struct DesignValues: Sendable {
    public var formatted: @Sendable (SpriteVariable) -> String
    public var number: @Sendable (SpriteVariable) -> Double?
    public var text: @Sendable (SpriteVariable) -> String?
    public var aspect: @Sendable (SpriteVariable, VariableAspect) -> String?
    /// The widest strings a value normally produces, so its slot keeps one width.
    public var widthTemplates: @Sendable (SpriteVariable) -> [String]
    public init(formatted: @escaping @Sendable (SpriteVariable) -> String,
                number: @escaping @Sendable (SpriteVariable) -> Double?,
                text: @escaping @Sendable (SpriteVariable) -> String? = { _ in nil },
                aspect: @escaping @Sendable (SpriteVariable, VariableAspect) -> String? = { _, _ in nil },
                widthTemplates: @escaping @Sendable (SpriteVariable) -> [String] = { _ in [] }) {
        self.formatted = formatted; self.number = number; self.text = text; self.aspect = aspect; self.widthTemplates = widthTemplates
    }
}

/// What the rules changed on one node.
public struct NodeOverride: Equatable, Sendable {
    public var color: String?
    public var hidden: Bool?
    public var symbol: String?
    public var text: [TextSegment]?
    public var opacity: Double?
    public init() {}
}

public enum SpriteRules {
    public static func holds(_ condition: RuleCondition, design: SpriteDesign, values: DesignValues) -> Bool {
        guard let variable = design.variable(condition.variable) else { return false }
        let number: Double?, text: String?
        if condition.aspect == .value {
            number = values.number(variable)
            text = values.text(variable) ?? number.map { _ in values.formatted(variable) }
        } else {
            number = nil
            text = values.aspect(variable, condition.aspect)
        }
        let present = number != nil || !(text ?? "").isEmpty
        let operand = condition.operand.trimmingCharacters(in: .whitespaces)
        switch condition.comparison {
        case .isMissing: return !present
        case .isPresent: return present
        case .above, .atLeast, .below, .atMost:
            guard let number, let limit = Double(operand.replacingOccurrences(of: ",", with: ".")) else { return false }
            switch condition.comparison {
            case .above: return number > limit
            case .atLeast: return number >= limit
            case .below: return number < limit
            default: return number <= limit
            }
        case .equals, .notEquals:
            let equal: Bool
            if let number, let other = Double(operand) { equal = number == other }
            else { equal = (text ?? "").caseInsensitiveCompare(operand) == .orderedSame }
            return condition.comparison == .equals ? equal : !equal
        case .contains:
            return (text ?? "").localizedCaseInsensitiveContains(operand)
        }
    }

    public static func branchHolds(_ branch: RuleBranch, design: SpriteDesign, values: DesignValues) -> Bool {
        guard !branch.conditions.isEmpty else { return false }
        return branch.match == .all
            ? branch.conditions.allSatisfy { holds($0, design: design, values: values) }
            : branch.conditions.contains { holds($0, design: design, values: values) }
    }

    /// The branch index each enabled rule took (nil = its otherwise), for the studio's live hints.
    public static func chosenBranches(_ design: SpriteDesign, values: DesignValues) -> [String: Int?] {
        var result: [String: Int?] = [:]
        for rule in design.rules where rule.enabled {
            result[rule.id] = .some(rule.branches.firstIndex { branchHolds($0, design: design, values: values) })
        }
        return result
    }

    public static func evaluate(_ design: SpriteDesign, values: DesignValues) -> [String: NodeOverride] {
        var overrides: [String: NodeOverride] = [:]
        for rule in design.rules where rule.enabled {
            let actions = rule.branches.first { branchHolds($0, design: design, values: values) }?.actions ?? rule.otherwise
            for action in actions {
                var entry = overrides[action.target] ?? NodeOverride()
                switch action.kind {
                case .color: entry.color = action.value
                case .hide: entry.hidden = true
                case .show: entry.hidden = false
                case .symbol: entry.symbol = action.value
                case .text: entry.text = TextTemplate.parse(action.value)
                case .opacity: entry.opacity = Double(action.value).map { min(1, max(0, $0)) }
                }
                overrides[action.target] = entry
            }
        }
        return overrides
    }
}

// MARK: - Migration from the settings-form sprites

extension SpriteDesign {
    public static let paceColors = (onTrack: "34C759", ahead: "FFCC00", over: "FF453A", unknown: "A0A0A0")

    /// The design that draws what `config`'s old layout, labels and colour rule drew.
    /// `metric` resolves reading ids to names and units (the store's catalog).
    public static func migrated(from config: SpriteConfiguration, metric: (String) -> Metric?) -> SpriteDesign {
        var design = SpriteDesign()
        var format = ValueFormat()
        format.showUnit = config.showUnits; format.decimals = config.decimals
        format.fahrenheit = config.fahrenheit; format.bits = config.networkBits
        let percentOnly = config.colorRule == .usagePacePercent

        // One variable per reading. A pace-coloured percentage is written without its "%", which
        // becomes its own text so a rule can colour just that character.
        var variableFor: [String: String] = [:]
        for id in config.metricIDs {
            let known = metric(id)
            // The sprite's own label ("GPT"), else a worded short name ("RAM"), else the full name ("Upload rate").
            let custom = config.customLabel(for: id).trimmingCharacters(in: .whitespaces)
            let short = known?.shortName ?? ""
            let name = !custom.isEmpty ? custom
                : short.filter(\.isLetter).count >= 2 && short.count <= 12 ? short : (known?.name ?? id)
            let key = design.freshVariableID(name)
            var variableFormat = format
            if percentOnly && known?.unit == .percent && known?.group == .ai { variableFormat.showUnit = false }
            design.variables.append(SpriteVariable(id: key, name: name, source: .reading(metric: id), format: variableFormat))
            variableFor[id] = key
        }
        func unit(_ id: String) -> MetricUnit? { metric(id)?.unit }
        func splitsPercent(_ id: String) -> Bool {
            percentOnly && config.showUnits && unit(id) == .percent && metric(id)?.group == .ai
        }

        let valueWeight: DesignWeight = config.bold ? .heavy : .regular
        let labelIDs = config.drawsChargeInsideBattery ? config.metricIDs.filter { $0 != "battery.charge" } : config.metricIDs

        // The value, and a trailing "%" text when the percent is coloured on its own.
        func valueNode(_ id: String, size: Double) -> (node: DesignNode, percent: DesignNode?) {
            var value = DesignNode.text([.value(variableFor[id]!)], size: size, name: "Value")
            value.style.weight = valueWeight; value.style.align = .trailing
            guard splitsPercent(id) else { return (value, nil) }
            var percent = DesignNode.text([.literal("%")], size: size, name: "%")
            percent.style.weight = valueWeight; percent.style.tabular = false; percent.style.align = .leading
            var joined = DesignNode.row([value, percent], gap: 0, name: "Value")
            joined.style.align = .trailing
            return (joined, percent)
        }
        func labelNode(_ id: String, size: Double, weight: DesignWeight, tabular: Bool) -> DesignNode {
            let fallback = config.layout == .twoRows && id == "sensor.cpuTemperature" ? "TEMP" : (metric(id)?.shortName ?? id)
            var label = DesignNode.text([.literal(config.label(for: id, fallback: fallback))], size: size, name: "Label")
            label.style.weight = weight; label.style.tabular = tabular
            return label
        }

        // Nodes to colour for each reading under the old rule: the whole reading, its label or its "%".
        var whole: [String: String] = [:], labels: [String: String] = [:], percents: [String: String] = [:], bars: [String: String] = [:]
        var content: [DesignNode] = []

        switch config.layout {
        case .stacked:
            let size = min(16, max(8, config.fontSize - (config.showLabels ? 1.5 : 0)))
            for id in labelIDs {
                let (value, percent) = valueNode(id, size: size)
                var children: [DesignNode] = []
                if config.showLabels {
                    var label = labelNode(id, size: 8.5, weight: config.bold ? .bold : .medium, tabular: false)
                    label.style.shrinkToFit = true
                    label.style.opacity = percentOnly || config.colorRule == .memoryPressure || config.colorRule == .powerDraw ? 1 : 0.9
                    labels[id] = label.id
                    children.append(label)
                }
                children.append(value)
                var column = DesignNode.column(children, gap: config.showLabels ? 1.5 : 0, name: "Reading")
                column.style.justify = .center
                whole[id] = column.id; percents[id] = percent?.id
                content.append(column)
            }
        case .twoRows:
            let size = min(13, max(8, config.fontSize))
            for first in stride(from: 0, to: labelIDs.count, by: 2) {
                let pair = Array(labelIDs[first..<min(first + 2, labelIDs.count)])
                var rows: [DesignNode] = []
                for id in pair {
                    let (value, percent) = valueNode(id, size: size)
                    var children: [DesignNode] = []
                    if config.showLabels {
                        var label = labelNode(id, size: 8, weight: config.bold ? .bold : .semibold, tabular: false)
                        label.style.opacity = 0.9; label.style.align = .leading
                        labels[id] = label.id
                        children.append(label)
                    }
                    children.append(value)
                    var row = DesignNode.row(children, gap: 4, name: "Reading")
                    row.style.justify = .spaceBetween
                    whole[id] = row.id; percents[id] = percent?.id
                    rows.append(row)
                }
                var column = DesignNode.column(rows, gap: 2, name: "Pair")
                column.style.justify = .even
                content.append(column)
            }
        case .inline:
            for id in labelIDs {
                let (value, percent) = valueNode(id, size: config.fontSize)
                var children: [DesignNode] = []
                if config.showLabels {
                    var label = labelNode(id, size: config.fontSize, weight: valueWeight, tabular: true)
                    label.style.opacity = 0.9
                    labels[id] = label.id
                    children.append(label)
                }
                children.append(value)
                let row = DesignNode.row(children, gap: 4, name: "Reading")
                whole[id] = row.id; percents[id] = percent?.id
                content.append(row)
            }
        case .bar:
            for id in labelIDs {
                if unit(id) == .percent {
                    var bar = DesignNode(kind: .bar, name: "Bar", variable: variableFor[id])
                    bar.style.size = 9
                    bars[id] = bar.id; whole[id] = bar.id
                    content.append(bar)
                } else {
                    let (value, percent) = valueNode(id, size: config.fontSize)
                    whole[id] = value.id; percents[id] = percent?.id
                    content.append(value)
                }
            }
        }

        let gap: Double = switch config.layout { case .stacked: 6; case .twoRows: 7; case .inline: 8; case .bar: 3 }
        let readings = DesignNode.row(content, gap: gap, name: "Readings")
        var root = readings
        if config.showIcon {
            var icon: DesignNode
            if config.isBatteryItem {
                icon = DesignNode(kind: .battery, name: "Battery", variable: variableFor["battery.charge"])
                icon.style.chargeInside = config.batteryPercentPlacement == .inside
            } else {
                icon = DesignNode(kind: .icon, name: "Icon", symbol: config.symbol)
                icon.style.size = 14
            }
            icon.style.color = config.iconColorHex == "text" ? "inherit" : config.iconColorHex
            let iconGap: Double = config.layout == .bar ? 4 : 5
            root = content.isEmpty ? .row([icon], gap: 0)
                : .row(config.iconTrailing ? [readings, icon] : [icon, readings], gap: iconGap)
        }
        root.name = "Sprite"
        root.style.padding = 3
        root.style.color = config.colorHex
        design.root = root

        // The old colour rules, as ordinary nodes and rules.
        for id in config.metricIDs {
            guard let key = variableFor[id] else { continue }
            switch config.colorRule {
            case .fixed: break
            case .networkDirection:
                let hex = id == "network.upload" ? "FF9F0A" : (id == "network.download" ? "30D158" : nil)
                if let hex, let target = whole[id] { design.root.update(target) { $0.style.color = hex } }
            case .memoryPressure:
                guard id.hasPrefix("memory."), let target = labels[id] else { continue }
                if !design.variables.contains(where: { $0.readingID == "memory.pressure" }) {
                    design.variables.append(SpriteVariable(id: design.freshVariableID("pressure"), name: "Memory pressure",
                                                           source: .reading(metric: "memory.pressure")))
                }
                let pressure = design.variables.first { $0.readingID == "memory.pressure" }!.id
                design.rules.append(SpriteRule(name: "Label follows memory pressure", branches: [
                    RuleBranch(conditions: [RuleCondition(variable: pressure, comparison: .equals, operand: "Critical")],
                               actions: [RuleAction(kind: .color, target: target, value: "FF453A")]),
                    RuleBranch(conditions: [RuleCondition(variable: pressure, comparison: .equals, operand: "Warning")],
                               actions: [RuleAction(kind: .color, target: target, value: "FFD60A")]),
                    RuleBranch(conditions: [RuleCondition(variable: pressure, comparison: .equals, operand: "Normal")],
                               actions: [RuleAction(kind: .color, target: target, value: "30D158")])
                ]))
            case .powerDraw:
                guard unit(id) == .watts, let target = labels[id] else { continue }
                design.rules.append(SpriteRule(name: "Label warns on power draw", branches: [
                    RuleBranch(conditions: [RuleCondition(variable: key, comparison: .above, operand: "45")],
                               actions: [RuleAction(kind: .color, target: target, value: "FF453A")]),
                    RuleBranch(conditions: [RuleCondition(variable: key, comparison: .atLeast, operand: "35")],
                               actions: [RuleAction(kind: .color, target: target, value: "FFD60A")])
                ]))
            case .usagePace, .usagePacePercent:
                guard metric(id)?.group == .ai, unit(id) == .percent,
                      let target = config.colorRule == .usagePace ? whole[id] : percents[id] else { continue }
                let c = paceColors
                let valueName = design.variable(key)?.name ?? key
                design.rules.append(SpriteRule(name: "\(valueName) % follows its pace", branches: [
                    RuleBranch(conditions: [RuleCondition(variable: key, aspect: .pace, comparison: .equals, operand: "on track")],
                               actions: [RuleAction(kind: .color, target: target, value: c.onTrack)]),
                    RuleBranch(conditions: [RuleCondition(variable: key, aspect: .pace, comparison: .equals, operand: "ahead")],
                               actions: [RuleAction(kind: .color, target: target, value: c.ahead)]),
                    RuleBranch(conditions: [RuleCondition(variable: key, aspect: .pace, comparison: .equals, operand: "over")],
                               actions: [RuleAction(kind: .color, target: target, value: c.over)])
                ], otherwise: [RuleAction(kind: .color, target: target, value: c.unknown)]))
                if let percent = percents[id] {
                    design.rules.append(SpriteRule(name: "Hide % while \(valueName) is unknown", branches: [
                        RuleBranch(conditions: [RuleCondition(variable: key, comparison: .isMissing)],
                                   actions: [RuleAction(kind: .hide, target: percent)])
                    ]))
                }
            }
            // A level bar turned amber and red at the sprite's thresholds.
            if let bar = bars[id] {
                design.rules.append(SpriteRule(name: "Bar warns when high", branches: [
                    RuleBranch(conditions: [RuleCondition(variable: key, comparison: .above, operand: "\(config.barAlert)")],
                               actions: [RuleAction(kind: .color, target: bar, value: "FF453A")]),
                    RuleBranch(conditions: [RuleCondition(variable: key, comparison: .above, operand: "\(config.barWarning)")],
                               actions: [RuleAction(kind: .color, target: bar, value: "FFD60A")])
                ]))
            }
        }
        return design
    }
}
