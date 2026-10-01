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
    /// A command that prints blocks (the spec's board vocabulary) as JSON, drawn in place while open.
    case blocks
    case image, toggle
    case processes, energy, accounts, readings

    public var isContainer: Bool { self == .stack || self == .row || self == .card }
    /// Hosts one of MenuSprite's own panels.
    public var isPremade: Bool { [.processes, .energy, .accounts, .readings].contains(self) }
    /// Runs its `action` when clicked anywhere on it (a clickable row, card or link). Buttons and switches
    /// run theirs from their own control; script rows, printed blocks, command output and the premade panels
    /// handle clicks inside themselves, and a divider or space has nothing to click.
    public var takesClickAction: Bool {
        [.stack, .row, .card, .text, .value, .chart, .gauge, .stats, .image].contains(self)
    }
    public var title: String {
        switch self {
        case .stack: "Stack"; case .row: "Row"; case .card: "Card"; case .divider: "Divider"; case .spacer: "Space"
        case .text: "Text"; case .value: "Big value"; case .chart: "Chart"; case .gauge: "Gauge"; case .stats: "Stats list"
        case .button: "Button"; case .output: "Command output"; case .script: "Script rows"
        case .blocks: "Script blocks"; case .image: "Image"; case .toggle: "Switch"
        case .processes: "Process list"; case .energy: "Battery & Power"; case .accounts: "AI accounts"; case .readings: "Readings with graphs"
        }
    }
    public var symbol: String {
        switch self {
        case .stack: "rectangle.split.1x2"; case .row: "rectangle.split.3x1"; case .card: "rectangle.roundedtop"
        case .divider: "minus"; case .spacer: "arrow.up.and.down"
        case .text: "textformat"; case .value: "number.square"; case .chart: "chart.xyaxis.line"; case .gauge: "gauge.with.dots.needle.50percent"
        case .stats: "list.bullet.rectangle"; case .button: "button.horizontal.top.press"; case .output: "terminal"; case .script: "scroll"
        case .blocks: "square.stack.3d.up"; case .image: "photo"; case .toggle: "switch.2"
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

/// What a button does, or a click on any other block that carries one (a clickable row). `value` is the
/// command, URL, app name or path, or text to copy (may use {values}).
public struct BoardAction: Codable, Sendable, Equatable {
    public var kind: BoardActionKind
    public var value: String
    /// How long a command may run, in seconds (default 30, at most 600); the board shows it working.
    public var timeout: Double?
    public init(kind: BoardActionKind = .runCommand, value: String = "", timeout: Double? = nil) {
        self.kind = kind; self.value = value; self.timeout = timeout
    }
    public static let defaultTimeout: Double = 30
    public static let longestTimeout: Double = 600
}

/// Where text that does not fit its line count is cut.
public enum BoardTruncation: String, Codable, Sendable, CaseIterable {
    case tail, middle, head
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
    /// A rounded fill behind the block: "none", RRGGBB or a system colour name.
    public var background: String = "none"
    /// Text: at most this many lines (0 = as many as it needs), cut where `truncate` says.
    public var lines: Int = 0
    public var truncate: BoardTruncation = .tail
    /// In a row: take the block's natural width instead of an equal share, so a long name beside a short
    /// figure does not wrap.
    public var fit: Bool = false

    public init() {}
    enum CodingKeys: String, CodingKey { case color, textStyle, align, spacing, padding, hidden, maximum, height, limit, processKind, opacity, background, lines, truncate, fit }
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
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? d.background
        lines = try c.decodeIfPresent(Int.self, forKey: .lines) ?? d.lines
        truncate = try c.decodeIfPresent(BoardTruncation.self, forKey: .truncate) ?? d.truncate
        fit = try c.decodeIfPresent(Bool.self, forKey: .fit) ?? d.fit
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
    /// A button's action; a switch's "turn on" action.
    public var action: BoardAction?
    /// A switch's "turn off" action.
    public var offAction: BoardAction?
    /// Script rows and script blocks: the command whose output becomes rows or blocks.
    public var command: CommandSource?
    /// A gauge's (or big value's) secondary text in place of the formatted value: "{used} of {limit}".
    public var detail: [TextSegment]
    /// An image: a file path (absolute, `~/…`, or inside the sprite's folder) or an https URL.
    public var source: String
    public var style: BoardStyle

    public init(id: String = DesignNode.newID(), kind: BoardBlockKind, name: String = "", children: [BoardBlock] = [],
                segments: [TextSegment] = [], variable: String? = nil, variables: [String] = [], symbol: String = "",
                action: BoardAction? = nil, offAction: BoardAction? = nil, command: CommandSource? = nil,
                detail: [TextSegment] = [], source: String = "", style: BoardStyle = BoardStyle()) {
        self.id = id; self.kind = kind; self.name = name; self.children = children; self.segments = segments
        self.variable = variable; self.variables = variables; self.symbol = symbol; self.action = action
        self.offAction = offAction; self.command = command; self.detail = detail; self.source = source; self.style = style
    }
    enum CodingKeys: String, CodingKey { case id, kind, name, children, segments, variable, variables, symbol, action, offAction, command, detail, source, style }
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
        offAction = try c.decodeIfPresent(BoardAction.self, forKey: .offAction)
        command = try c.decodeIfPresent(CommandSource.self, forKey: .command)
        detail = try c.decodeIfPresent([TextSegment].self, forKey: .detail) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        style = try c.decodeIfPresent(BoardStyle.self, forKey: .style) ?? BoardStyle()
    }
    // Written by hand so a block without the newer fields saves exactly as it did before them, which keeps
    // the file readable by builds that predate them.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(name, forKey: .name)
        try c.encode(children, forKey: .children); try c.encode(segments, forKey: .segments)
        try c.encodeIfPresent(variable, forKey: .variable); try c.encode(variables, forKey: .variables)
        try c.encode(symbol, forKey: .symbol); try c.encodeIfPresent(action, forKey: .action)
        try c.encodeIfPresent(offAction, forKey: .offAction); try c.encodeIfPresent(command, forKey: .command)
        if !detail.isEmpty { try c.encode(detail, forKey: .detail) }
        if !source.isEmpty { try c.encode(source, forKey: .source) }
        try c.encode(style, forKey: .style)
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
        segments.compactMap(\.variableID) + detail.compactMap(\.variableID) + (variable.map { [$0] } ?? []) + variables
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
        detail = detail.filter { $0.variableID.map(ids.contains) ?? true }
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
    /// `keeping`: ids a rule targets (`SpriteDesign.ruleTargets`), whose containers must survive the tidy.
    @discardableResult
    public mutating func move(_ id: String, to edge: DropEdge, of target: String, keeping: Set<String> = []) -> Bool {
        guard id != target, id != root.id, let moving = root.find(id), moving.find(target) == nil else { return false }
        var copy = self
        guard let removed = copy.root.remove(id) else { return false }
        copy.collapse(keeping: keeping)
        guard copy.root.find(target) != nil, copy.insert(removed, at: edge, of: target) else { return false }
        self = copy
        return true
    }
    @discardableResult
    public mutating func delete(_ id: String, keeping: Set<String> = []) -> Bool {
        guard id != root.id, root.remove(id) != nil else { return false }
        collapse(keeping: keeping)
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
    /// Removes the wrappers moving and deleting leave behind: unnamed stacks and rows left empty or holding
    /// a single block. Only a pure layout wrapper goes (the kind `insert` makes): one with a fill, padding,
    /// colour, opacity, a click action, a fit or any other look of its own, or one a rule targets (`keeping`),
    /// is the author's and stays, as the face's tidy keeps a styled row.
    public mutating func collapse(keeping: Set<String> = []) {
        func wrapper(_ block: BoardBlock) -> Bool {
            guard block.kind == .stack || block.kind == .row, block.name.isEmpty, block.action == nil,
                  !keeping.contains(block.id) else { return false }
            // Spacing means nothing around one block, so any spacing still counts as plain.
            var style = block.style; style.spacing = BoardStyle().spacing
            return style == BoardStyle()
        }
        func tidy(_ block: inout BoardBlock, isRoot: Bool) {
            for index in block.children.indices { tidy(&block.children[index], isRoot: false) }
            block.children.removeAll { $0.children.isEmpty && wrapper($0) }
            if !isRoot, wrapper(block), block.children.count == 1 {
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
    /// The folder the sprite's files live in, as its commands carry it (the compiler sets it on every command
    /// of a sprite that has files; a draft render points it at a temporary copy). Nil for a sprite without files.
    public var filesDirectory: String? {
        variables.lazy.compactMap { $0.command?.directory }.first ?? boardScriptCommands.lazy.compactMap(\.directory).first
    }
    /// Commands the board runs while open: its script rows and script blocks (command values are listed
    /// with the rest).
    public var boardScriptCommands: [CommandSource] {
        board?.root.flattened.compactMap { $0.kind == .script || $0.kind == .blocks ? $0.command : nil } ?? []
    }
    /// Points every command of the sprite (its command values, script rows and script blocks) at `directory`,
    /// where it runs with `SPRITE_DIR` set; nil runs them in the home folder. The compiler does this on apply,
    /// the studio on every edit of a sprite that has a folder, and Duplicate for the copy's own folder, so a
    /// command added in the studio runs beside the sprite's files just as an agent's does.
    public mutating func setCommandDirectory(_ directory: String?) {
        for index in variables.indices {
            if case .command(var command) = variables[index].source, command.directory != directory {
                command.directory = directory
                variables[index].source = .command(command)
            }
        }
        func walk(_ block: inout BoardBlock) {
            if block.command != nil, block.command?.directory != directory { block.command?.directory = directory }
            for index in block.children.indices { walk(&block.children[index]) }
        }
        if var board { walk(&board.root); self.board = board }
    }
    /// Every face node and board block a rule acts on, which editing must not fold away.
    public var ruleTargets: Set<String> {
        Set(rules.flatMap { rule in rule.branches.flatMap(\.actions).map(\.target) + rule.otherwise.map(\.target) })
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
/// `Text | color=red sfimage=bolt href=https://… bash="…" size=13 font=Menlo weight=bold length=40 tooltip="…"`.
/// A line of `---` is a divider; leading `--` indents a row.
public struct ScriptLine: Equatable, Sendable {
    public var text: String
    public var depth: Int
    public var isDivider: Bool
    /// As sprites store colours: one of `SpriteColors.names` (adaptive light/dark) or RRGGBB.
    public var color: String?
    public var symbol: String?
    public var href: String?
    public var bash: String?
    public var size: Double?
    public var monospaced: Bool
    /// "medium", "semibold" or "bold": from `weight=`, or a `font=` whose name says it (Helvetica-Bold).
    public var weight: String?
    /// At most this many characters, cut with an ellipsis (SwiftBar's `length=`); the full text shows on hover.
    public var length: Int?
    /// Shown on hover.
    public var tooltip: String?

    public init(text: String, depth: Int = 0, isDivider: Bool = false, color: String? = nil, symbol: String? = nil,
                href: String? = nil, bash: String? = nil, size: Double? = nil, monospaced: Bool = false,
                weight: String? = nil, length: Int? = nil, tooltip: String? = nil) {
        self.text = text; self.depth = depth; self.isDivider = isDivider; self.color = color; self.symbol = symbol
        self.href = href; self.bash = bash; self.size = size; self.monospaced = monospaced; self.weight = weight
        self.length = length; self.tooltip = tooltip
    }

    /// The text as drawn: cut to `length` characters with an ellipsis.
    public var shown: String {
        guard let length, length > 0, text.count > length else { return text }
        return String(text.prefix(max(1, length - 1))) + "…"
    }

    public static func parse(_ output: String, limit: Int = 200) -> [ScriptLine] {
        output.split(separator: "\n", omittingEmptySubsequences: true).prefix(limit).map { raw in
            var line = String(raw)
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                return ScriptLine(text: "", isDivider: true)
            }
            var depth = 0
            while line.hasPrefix("--") { depth += 1; line.removeFirst(2) }
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            var result = ScriptLine(text: parts.first?.trimmingCharacters(in: .whitespaces) ?? "", depth: depth)
            if parts.count > 1 {
                for (key, value) in parameters(parts[1]) {
                    switch key.lowercased() {
                    case "color": result.color = color(value)
                    case "sfimage": result.symbol = value
                    case "href": result.href = value
                    case "bash", "shell": result.bash = value
                    case "size": result.size = Double(value)
                    case "font":
                        let font = value.lowercased()
                        result.monospaced = ["mono", "menlo", "courier", "monaco"].contains { font.contains($0) }
                        if result.weight == nil { result.weight = weight(fontName: font) }
                    case "weight": result.weight = weight(value.lowercased())
                    case "length": result.length = Int(value).flatMap { $0 > 0 ? $0 : nil }
                    case "tooltip": result.tooltip = value
                    default: break
                    }
                }
            }
            return result
        }
    }
    /// A named colour keeps its name, so it is drawn as Apple's adaptive system colour on a light board and a
    /// dark one alike (a fixed dark-bar orange is too pale on white); anything else is read as hex.
    static func color(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let name = trimmed.lowercased() == "grey" ? "gray" : trimmed.lowercased()
        if SpriteColors.names.contains(name) { return name }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
    }
    static func weight(_ value: String) -> String? {
        switch value {
        case "bold", "heavy", "black": "bold"
        case "semibold", "demibold": "semibold"
        case "medium": "medium"
        default: nil
        }
    }
    /// SwiftBar users write a font's own bold face (`Helvetica-Bold`, `Menlo-Bold`).
    static func weight(fontName font: String) -> String? {
        if font.contains("semibold") || font.contains("demibold") { return "semibold" }
        if font.contains("bold") || font.contains("heavy") || font.contains("black") { return "bold" }
        if font.contains("medium") { return "medium" }
        return nil
    }
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
