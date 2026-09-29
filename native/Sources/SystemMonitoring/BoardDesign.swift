import Foundation

/// What opens when a sprite is clicked, as blocks: stacks, rows and cards of text, values, charts,
/// buttons, command output and scripted rows, plus premade blocks that host MenuSprite's own
/// panels (processes, Battery & Power, AI accounts). It shares the sprite's values and rules: a rule
/// can colour, hide, show or re-text a block just as it does a menu-bar piece.
///
/// A sprite without a board keeps its classic panel. Spec: `docs/sprite-studio.md`.
public struct BoardDesign: Codable, Sendable, Equatable {
    public var root: BoardBlock
    /// The panel's width in points.
    public var width: Double
    /// The sprite's name and a Configure button across the top.
    public var showHeader: Bool

    public init(root: BoardBlock = .stack([]), width: Double = 360, showHeader: Bool = true) {
        self.root = root; self.width = width; self.showHeader = showHeader
    }
    enum CodingKeys: String, CodingKey { case root, width, showHeader }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(BoardBlock.self, forKey: .root) ?? .stack([])
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 360
        showHeader = try c.decodeIfPresent(Bool.self, forKey: .showHeader) ?? true
    }
    public static let widths: ClosedRange<Double> = 260...560
}

public enum BoardBlockKind: String, Codable, Sendable, CaseIterable {
    case stack, row, card, divider, spacer
    case text, value, chart, gauge, stats, button, output, script
    case processes, energy, accounts, readings

    public var isContainer: Bool { self == .stack || self == .row || self == .card }
    /// Hosts one of MenuSprite's own panels.
    public var isPremade: Bool { [.processes, .energy, .accounts, .readings].contains(self) }
    public var title: String {
        switch self {
        case .stack: "Stack"; case .row: "Row"; case .card: "Card"; case .divider: "Divider"; case .spacer: "Space"
        case .text: "Text"; case .value: "Big value"; case .chart: "Chart"; case .gauge: "Gauge"; case .stats: "Stats list"
        case .button: "Button"; case .output: "Command output"; case .script: "Script rows"
        case .processes: "Process list"; case .energy: "Battery & Power"; case .accounts: "AI accounts"; case .readings: "Readings with graphs"
        }
    }
    public var symbol: String {
        switch self {
        case .stack: "rectangle.split.1x2"; case .row: "rectangle.split.3x1"; case .card: "rectangle.roundedtop"
        case .divider: "minus"; case .spacer: "arrow.up.and.down"
        case .text: "textformat"; case .value: "number.square"; case .chart: "chart.xyaxis.line"; case .gauge: "gauge.with.dots.needle.50percent"
        case .stats: "list.bullet.rectangle"; case .button: "button.horizontal.top.press"; case .output: "terminal"; case .script: "scroll"
        case .processes: "list.number"; case .energy: "bolt.batteryblock"; case .accounts: "sparkles"; case .readings: "waveform.path.ecg"
        }
    }
}

public enum BoardTextStyle: String, Codable, Sendable, CaseIterable {
    case huge, title, headline, body, caption, mono
    public var title: String {
        switch self {
        case .huge: "Huge"; case .title: "Title"; case .headline: "Headline"; case .body: "Body"; case .caption: "Caption"; case .mono: "Monospaced"
        }
    }
}

public enum ProcessListKind: String, Codable, Sendable, CaseIterable {
    case cpu, memory, power
    public var title: String { switch self { case .cpu: "CPU"; case .memory: "Memory"; case .power: "Power" } }
}

public enum BoardActionKind: String, Codable, Sendable, CaseIterable {
    case runCommand, openURL, openApp, copyText, refresh
    public var title: String {
        switch self {
        case .runCommand: "Run a command"; case .openURL: "Open a link"; case .openApp: "Open an app"
        case .copyText: "Copy text"; case .refresh: "Refresh readings"
        }
    }
}

/// What a button does. `value` is the command, URL, app name or path, or text to copy (may use {values}).
public struct BoardAction: Codable, Sendable, Equatable {
    public var kind: BoardActionKind
    public var value: String
    public init(kind: BoardActionKind = .runCommand, value: String = "") { self.kind = kind; self.value = value }
}

public struct BoardStyle: Codable, Sendable, Equatable {
    public var color: String = "inherit"
    public var textStyle: BoardTextStyle = .body
    public var align: DesignAlign = .leading
    public var spacing: Double = 8
    public var padding: Double = 0
    public var hidden: Bool = false
    /// Gauge: the value that fills it.
    public var maximum: Double = 100
    /// Chart, command output, premade panels: their height.
    public var height: Double = 60
    /// Process list: how many rows.
    public var limit: Int = 10
    public var processKind: ProcessListKind = .memory
    public var opacity: Double = 1

    public init() {}
    enum CodingKeys: String, CodingKey { case color, textStyle, align, spacing, padding, hidden, maximum, height, limit, processKind, opacity }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BoardStyle()
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? d.color
        textStyle = try c.decodeIfPresent(BoardTextStyle.self, forKey: .textStyle) ?? d.textStyle
        align = try c.decodeIfPresent(DesignAlign.self, forKey: .align) ?? d.align
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? d.spacing
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? d.hidden
        maximum = try c.decodeIfPresent(Double.self, forKey: .maximum) ?? d.maximum
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? d.height
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? d.limit
        processKind = try c.decodeIfPresent(ProcessListKind.self, forKey: .processKind) ?? d.processKind
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
    }
}

public struct BoardBlock: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: BoardBlockKind
    public var name: String
    public var children: [BoardBlock]
    /// Text, a card's title, a button's title, a big value's caption.
    public var segments: [TextSegment]
    /// The value a big value, chart, gauge or command output shows.
    public var variable: String?
    /// A stats list's values, in order.
    public var variables: [String]
    public var symbol: String
    public var action: BoardAction?
    /// Script rows: the command whose output lines become rows.
    public var command: CommandSource?
    public var style: BoardStyle

    public init(id: String = DesignNode.newID(), kind: BoardBlockKind, name: String = "", children: [BoardBlock] = [],
                segments: [TextSegment] = [], variable: String? = nil, variables: [String] = [], symbol: String = "",
                action: BoardAction? = nil, command: CommandSource? = nil, style: BoardStyle = BoardStyle()) {
        self.id = id; self.kind = kind; self.name = name; self.children = children; self.segments = segments
        self.variable = variable; self.variables = variables; self.symbol = symbol; self.action = action
        self.command = command; self.style = style
    }
    enum CodingKeys: String, CodingKey { case id, kind, name, children, segments, variable, variables, symbol, action, command, style }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? DesignNode.newID()
        kind = try c.decode(BoardBlockKind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        children = try c.decodeIfPresent([BoardBlock].self, forKey: .children) ?? []
        segments = try c.decodeIfPresent([TextSegment].self, forKey: .segments) ?? []
        variable = try c.decodeIfPresent(String.self, forKey: .variable)
        variables = try c.decodeIfPresent([String].self, forKey: .variables) ?? []
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        action = try c.decodeIfPresent(BoardAction.self, forKey: .action)
        command = try c.decodeIfPresent(CommandSource.self, forKey: .command)
        style = try c.decodeIfPresent(BoardStyle.self, forKey: .style) ?? BoardStyle()
    }

    public static func stack(_ children: [BoardBlock], spacing: Double = 10) -> Self {
        var style = BoardStyle(); style.spacing = spacing
        return Self(kind: .stack, children: children, style: style)
    }
    public static func text(_ text: String, style textStyle: BoardTextStyle = .body) -> Self {
        var style = BoardStyle(); style.textStyle = textStyle
        return Self(kind: .text, name: "Text", segments: TextTemplate.parse(text), style: style)
    }

    public var flattened: [BoardBlock] { [self] + children.flatMap(\.flattened) }
    public var referencedVariables: [String] {
        segments.compactMap(\.variableID) + (variable.map { [$0] } ?? []) + variables
            + (action?.kind == .copyText ? TextTemplate.parse(action?.value ?? "").compactMap(\.variableID) : [])
    }
    public func find(_ id: String) -> BoardBlock? {
        if self.id == id { return self }
        for child in children { if let found = child.find(id) { return found } }
        return nil
    }
    public func parent(of id: String) -> (BoardBlock, Int)? {
        if let index = children.firstIndex(where: { $0.id == id }) { return (self, index) }
        for child in children { if let found = child.parent(of: id) { return found } }
        return nil
    }
    @discardableResult
    public mutating func update(_ id: String, _ change: (inout BoardBlock) -> Void) -> Bool {
        if self.id == id { change(&self); return true }
        for index in children.indices where children[index].update(id, change) { return true }
        return false
    }
    public mutating func remove(_ id: String) -> BoardBlock? {
        if let index = children.firstIndex(where: { $0.id == id }) { return children.remove(at: index) }
        for index in children.indices { if let removed = children[index].remove(id) { return removed } }
        return nil
    }
    mutating func pruneVariables(keeping ids: Set<String>) {
        segments = segments.filter { $0.variableID.map(ids.contains) ?? true }
        if let variable, !ids.contains(variable) { self.variable = nil }
        variables = variables.filter(ids.contains)
        for index in children.indices { children[index].pruneVariables(keeping: ids) }
    }
    public func reidentified() -> Self {
        var copy = self; copy.id = DesignNode.newID(); copy.children = children.map { $0.reidentified() }
        return copy
    }
}

// MARK: - Editing

extension BoardDesign {
    /// Puts `block` at `edge` of `target`: above/below within a stack or card, left/right within a row,
    /// wrapping the target in a new row or stack when its container runs the other way.
    @discardableResult
    public mutating func insert(_ block: BoardBlock, at edge: DropEdge, of target: String) -> Bool {
        let horizontal = edge == .left || edge == .right
        // Dropping on the board itself, or on an empty container, puts the block inside it.
        if let container = root.find(target), container.kind.isContainer, target == root.id || container.children.isEmpty {
            return root.update(target) { if edge.after { $0.children.append(block) } else { $0.children.insert(block, at: 0) } }
        }
        guard let (parent, index) = root.parent(of: target) else { return false }
        if horizontal == (parent.kind == .row) {
            return root.update(parent.id) { $0.children.insert(block, at: edge.after ? index + 1 : index) }
        }
        return root.update(target) { existing in
            var wrapper = BoardBlock(kind: horizontal ? .row : .stack, children: edge.after ? [existing, block] : [block, existing])
            wrapper.style.spacing = 8
            existing = wrapper
        }
    }
    @discardableResult
    public mutating func move(_ id: String, to edge: DropEdge, of target: String) -> Bool {
        guard id != target, id != root.id, let moving = root.find(id), moving.find(target) == nil else { return false }
        var copy = self
        guard let removed = copy.root.remove(id) else { return false }
        copy.collapse()
        guard copy.root.find(target) != nil, copy.insert(removed, at: edge, of: target) else { return false }
        self = copy
        return true
    }
    @discardableResult
    public mutating func delete(_ id: String) -> Bool {
        guard id != root.id, root.remove(id) != nil else { return false }
        collapse()
        return true
    }
    @discardableResult
    public mutating func duplicate(_ id: String) -> String? {
        guard let block = root.find(id), let (parent, index) = root.parent(of: id) else { return nil }
        let copy = block.reidentified()
        root.update(parent.id) { $0.children.insert(copy, at: index + 1) }
        return copy.id
    }
    @discardableResult
    public mutating func shift(_ id: String, by offset: Int) -> Bool {
        guard let (parent, index) = root.parent(of: id), parent.children.indices.contains(index + offset) else { return false }
        return root.update(parent.id) { $0.children.swapAt(index, index + offset) }
    }
    /// Removes unnamed stacks and rows left empty or holding a single block.
    public mutating func collapse() {
        func tidy(_ block: inout BoardBlock, isRoot: Bool) {
            for index in block.children.indices { tidy(&block.children[index], isRoot: false) }
            block.children.removeAll { ($0.kind == .stack || $0.kind == .row) && $0.children.isEmpty && $0.name.isEmpty }
            if !isRoot, block.kind == .stack || block.kind == .row, block.name.isEmpty, block.children.count == 1 {
                block = block.children[0]
            }
        }
        tidy(&root, isRoot: true)
    }

    public var referencedReadingIDs: [String] { root.flattened.flatMap(\.referencedVariables) }
}

extension SpriteDesign {
    /// Readings the board shows; sampled while the board is open.
    public var boardReadingIDs: [String] {
        guard let board else { return [] }
        var seen: Set<String> = []
        return board.referencedReadingIDs.compactMap { variable($0)?.readingID }.filter { seen.insert($0).inserted }
    }
    /// Commands the board runs while open: its script rows (command values are listed with the rest).
    public var boardScriptCommands: [CommandSource] {
        board?.root.flattened.compactMap { $0.kind == .script ? $0.command : nil } ?? []
    }

    /// A description of a board block for pickers and the outline.
    public func title(of block: BoardBlock) -> String {
        let base = block.name.isEmpty ? block.kind.title : block.name
        switch block.kind {
        case .text, .button, .card:
            let text = block.segments.map { segment -> String in
                switch segment { case .literal(let literal): literal; case .value(let id): "{\(variable(id)?.name ?? id)}" }
            }.joined()
            return text.isEmpty ? base : "\(base) “\(text.prefix(22))”"
        case .value, .chart, .gauge, .output:
            return "\(base) · \(block.variable.flatMap(variable)?.name ?? "no value")"
        case .processes: return "\(base) · \(block.style.processKind.title)"
        case .stack, .row: return "\(base) · \(block.children.count) inside"
        default: return base
        }
    }
}

// MARK: - Script rows

/// One line of a script block's output, in the SwiftBar/xbar style:
/// `Text | color=red sfimage=bolt href=https://… bash="…" size=13 font=Menlo`. A line of `---` is a
/// divider; leading `--` indents a row.
public struct ScriptLine: Equatable, Sendable {
    public var text: String
    public var depth: Int
    public var isDivider: Bool
    public var color: String?
    public var symbol: String?
    public var href: String?
    public var bash: String?
    public var size: Double?
    public var monospaced: Bool

    public static func parse(_ output: String, limit: Int = 200) -> [ScriptLine] {
        output.split(separator: "\n", omittingEmptySubsequences: true).prefix(limit).map { raw in
            var line = String(raw)
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                return ScriptLine(text: "", depth: 0, isDivider: true, monospaced: false)
            }
            var depth = 0
            while line.hasPrefix("--") { depth += 1; line.removeFirst(2) }
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            var result = ScriptLine(text: parts.first?.trimmingCharacters(in: .whitespaces) ?? "", depth: depth, isDivider: false, monospaced: false)
            if parts.count > 1 {
                for (key, value) in parameters(parts[1]) {
                    switch key.lowercased() {
                    case "color": result.color = namedColors[value.lowercased()] ?? value.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
                    case "sfimage": result.symbol = value
                    case "href": result.href = value
                    case "bash", "shell": result.bash = value
                    case "size": result.size = Double(value)
                    case "font": result.monospaced = value.localizedCaseInsensitiveContains("mono") || value.localizedCaseInsensitiveContains("menlo")
                    default: break
                    }
                }
            }
            return result
        }
    }
    static let namedColors = ["red": "FF453A", "orange": "FF9F0A", "yellow": "FFD60A", "green": "30D158", "blue": "0A84FF",
                              "purple": "BF5AF2", "pink": "FF375F", "gray": "8E8E93", "grey": "8E8E93", "white": "FFFFFF", "black": "000000"]
    /// `key=value key="a value"` pairs.
    static func parameters(_ text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
            guard let equals = text[index...].firstIndex(of: "=") else { break }
            let key = String(text[index..<equals]).trimmingCharacters(in: .whitespaces)
            var cursor = text.index(after: equals)
            var value = ""
            if cursor < text.endIndex, text[cursor] == "\"" || text[cursor] == "'" {
                let quote = text[cursor]; cursor = text.index(after: cursor)
                let close = text[cursor...].firstIndex(of: quote) ?? text.endIndex
                value = String(text[cursor..<close])
                index = close < text.endIndex ? text.index(after: close) : close
            } else {
                let end = text[cursor...].firstIndex(of: " ") ?? text.endIndex
                value = String(text[cursor..<end]); index = end
            }
            if !key.isEmpty { result.append((key, value)) }
        }
        return result
    }
}
