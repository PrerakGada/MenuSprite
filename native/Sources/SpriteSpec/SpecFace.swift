import AgentProtocol
import Foundation
import SystemMonitoring

extension SpecCompiler {
    static let nodeKinds = ["row", "column", "text", "icon", "bar", "battery"]
    static let nodeProperties = ["id", "name", "color", "size", "weight", "tabular", "opacity", "align", "gap", "justify",
                                 "padding", "hidden", "shrink", "chargeInside", "max", "level"]
    static let nodeNotes = [
        "font": "Face text has no font: use size and weight (font is for board blocks).",
        "title": "Face nodes have no title; a text node is {\"text\": \"…\"}.",
        "value": "Face text shows values as {value} inside \"text\"; a bar or battery names its value directly, an icon names it as \"level\"."
    ]

    /// The menu-bar tree. Omitted, it is the sprite's icon alone; a single leaf is wrapped in a row so the
    /// studio always finds a container at the top.
    func parseFace(_ raw: JSONValue?, icon: String) -> DesignNode {
        guard let raw else {
            return DesignNode(id: "", kind: .row, children: [DesignNode(id: "", kind: .icon, symbol: icon)],
                              style: SpecDefaults.nodeStyle(.row, root: true))
        }
        guard let node = parseNode(raw, path: "face", root: true, parent: nil) else {
            return DesignNode(id: "", kind: .row, style: SpecDefaults.nodeStyle(.row, root: true))
        }
        if node.kind.isContainer { return node }
        return DesignNode(id: "", kind: .row, children: [node], style: SpecDefaults.nodeStyle(.row, root: true))
    }

    /// `parent` is the kind of the container the node sits in (nil at the top).
    func parseNode(_ raw: JSONValue, path: String, root: Bool, parent: DesignNodeKind?) -> DesignNode? {
        if mode == .spec { pieceCount += 1 }
        switch raw {
        case .string, .number:
            return DesignNode(id: "", kind: .text, segments: template(raw, path: path) ?? [], style: SpecDefaults.nodeStyle(.text, root: false))
        case .array(let items):
            return DesignNode(id: "", kind: .row, children: parseNodes(items, path: path, parent: .row), style: SpecDefaults.nodeStyle(.row, root: root))
        case .object:
            break
        default:
            report.error(path, "A face node is text, a list (a row) or an object such as {\"text\": …}, not \(raw.typeName).")
            return nil
        }
        guard let object = SpecObject(raw, path: path, report: report, what: "A face node") else { return nil }
        let kinds = Self.kindKeys(object, Self.nodeKinds)
        guard kinds.count == 1 else {
            reportKinds(kinds, object: object, all: Self.nodeKinds, what: "A face node")
            return nil
        }
        let key = kinds[0]
        let kind = DesignNodeKind(rawValue: key)!
        let content = object.raw(key) ?? .null
        let contentPath = object.path(key)
        var node = DesignNode(id: "", kind: kind, style: SpecDefaults.nodeStyle(kind, root: root))
        switch kind {
        case .row, .column:
            if let items = content.items { node.children = parseNodes(items, path: contentPath, parent: kind) }
            else { report.error(contentPath, "“\(key)” takes a list of nodes, not \(content.typeName).") }
        case .text:
            node.segments = content.isNull ? [] : template(content, path: contentPath) ?? []
        case .icon:
            if let symbol = content.string, !symbol.isEmpty { node.symbol = symbol; checkSymbol(symbol, path: contentPath) }
            else { report.error(contentPath, "“icon” takes an SF Symbol name, such as \"flame\".") }
            // A value that fills the symbol's variable layers: wifi's bars, speaker.wave.3's waves.
            if let level = object.raw("level") { node.variable = reference(level, path: object.path("level")) }
        case .bar, .battery:
            node.variable = reference(content, path: contentPath)
            // A level bar stands the whole height of the menu bar, so in a column it pushes the lines above
            // and below it out of the bar.
            if kind == .bar, parent == .column {
                report.warning(contentPath, "A level bar stands the full height of the menu bar, so inside a column it crowds out the other lines.",
                               hint: "put the bar beside the column, in a row: [{\"bar\": …}, {\"column\": […]}]")
            }
        }
        if let id = explicitID(object) { node.id = id }
        node.name = object.string("name") ?? ""
        parseNodeStyle(object, into: &node.style)
        if kind != .icon, object.raw("level") != nil {
            report.warning(object.path("level"), "Only an icon takes a level; a bar or battery names its value as its content.")
        }
        object.checkKeys([key] + Self.nodeProperties, what: "a \(key) node", notes: Self.nodeNotes)
        return node
    }

    private func parseNodes(_ items: [JSONValue], path: String, parent: DesignNodeKind) -> [DesignNode] {
        items.enumerated().compactMap { index, item in parseNode(item, path: SpecPath.index(path, index), root: false, parent: parent) }
    }

    /// The kind keys an object carries. A kind key set to null counts only when there is no other: the
    /// emitter writes `{"bar": null}` for a bar with no value yet, while `{"text": "x", "icon": null}` is a text.
    static func kindKeys(_ object: SpecObject, _ all: [String]) -> [String] {
        let present = object.keys.filter(all.contains)
        let set = present.filter { object[$0] != nil }
        return set.isEmpty ? present : set
    }

    func parseNodeStyle(_ object: SpecObject, into style: inout NodeStyle) {
        if let raw = object["color"], let color = color(raw, path: object.path("color"), keywords: ["inherit", "auto"]) { style.color = color }
        if let size = object.number("size") {
            if size < 4 || size > 40 { report.warning(object.path("size"), "Sizes are drawn between 4 and 40 points.") }
            if size > 0 { style.size = size } else { report.error(object.path("size"), "A size is a positive number of points.") }
        }
        if let weight = choice(object, "weight", DesignWeight.self) { style.weight = weight }
        if let tabular = object.bool("tabular") { style.tabular = tabular }
        if let opacity = object.number("opacity") { style.opacity = clamped(opacity, 0...1, path: object.path("opacity"), what: "opacity") }
        if let align = choice(object, "align", DesignAlign.self) { style.align = align }
        if let gap = object.number("gap") { style.gap = clamped(gap, 0...100, path: object.path("gap"), what: "gap") }
        if let justify = choice(object, "justify", DesignJustify.self) { style.justify = justify }
        if let padding = object.number("padding") { style.padding = clamped(padding, 0...100, path: object.path("padding"), what: "padding") }
        if let hidden = object.bool("hidden") { style.hidden = hidden }
        if let shrink = object.bool("shrink") { style.shrinkToFit = shrink }
        if let inside = object.bool("chargeInside") { style.chargeInside = inside }
        if let maximum = object.number("max") {
            if maximum > 0 { style.maximum = maximum } else { report.error(object.path("max"), "max is the value that fills the bar: a positive number.") }
        }
    }

    /// Zero kind keys, or more than one: say which, and guess at a misspelt one.
    func reportKinds(_ kinds: [String], object: SpecObject, all: [String], what: String) {
        if kinds.isEmpty {
            let guess = object.keys.lazy.compactMap { key in self.report.matches(key, in: all, limit: 1).first.map { (key, $0) } }.first
            report.error(object.path, "\(what) needs exactly one kind key: \(Fuzzy.list(all)).",
                         hint: guess.map { "“\($0.0)” — did you mean \($0.1)?" }
                            ?? (object.keys.isEmpty ? nil : "found only \(object.keys.joined(separator: ", "))"))
        } else {
            report.error(object.path, "\(what) has exactly one kind key; this one has \(Fuzzy.list(kinds, conjunction: "and")).",
                         hint: "split it into separate pieces inside a row, column or stack")
        }
    }
}
