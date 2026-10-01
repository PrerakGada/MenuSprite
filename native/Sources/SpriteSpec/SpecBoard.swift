import AgentProtocol
import Foundation
import SystemMonitoring

extension SpecCompiler {
    static let blockKinds = ["stack", "row", "card", "divider", "space", "text", "value", "chart", "gauge", "stats", "button",
                             "toggle", "output", "script", "blocks", "image", "processes", "energy", "accounts", "readings"]
    static let blockProperties = ["id", "name", "color", "background", "align", "spacing", "padding", "hidden", "opacity",
                                  "height", "max", "limit", "font", "fit"]
    /// Blocks a click can act on besides buttons: a row of a list that opens its page, a figure that copies itself.
    static let clickable: Set<BoardBlockKind> = [.text, .value, .stack, .row, .card, .image, .stats]
    static let actionKeys = ["run", "open", "app", "copy", "refresh"]
    /// Keys that mean something only on some kinds of block.
    static let blockExtras: [(key: String, kinds: Set<BoardBlockKind>)] = [
        ("title", [.card]), ("caption", [.value, .chart, .gauge]), ("detail", [.gauge, .value]), ("icon", [.button, .toggle, .text]),
        ("run", clickable.union([.button])), ("open", clickable.union([.button])), ("app", clickable.union([.button])),
        ("copy", clickable.union([.button])), ("refresh", clickable.union([.button])),
        ("value", [.toggle]), ("on", [.toggle]), ("off", [.toggle]), ("every", [.script, .blocks]),
        ("timeout", clickable.union([.script, .blocks, .button, .toggle])),
        ("lines", [.text, .value, .button]), ("truncate", [.text, .value, .button])
    ]
    static let boardKeys = ["width", "header", "blocks"]
    static let blockNotes = [
        "size": "Board text has no size: use font (huge, title, headline, body, caption, mono).",
        "weight": "Board text has no weight: use font (huge, title, headline, body, caption, mono).",
        "label": "A button's or switch's label is its own key: {\"button\": \"Open\"}.",
        "command": "A command belongs in values (as a value), in a script or blocks block, or in a button's run."
    ]
    /// What a script may not print: commands that would run commands, and MenuSprite's own panels.
    static let scriptForbidden: Set<BoardBlockKind> = [.blocks, .script, .processes, .energy, .accounts, .readings]
    static let labelled: Set<BoardBlockKind> = [.text, .button, .toggle, .value, .chart, .gauge]

    /// What a click opens. Omitted or null keeps the classic panel. The board object carries the board's
    /// own stack's properties too (spacing, padding, …), so a studio board reads back exactly.
    func parseBoard(_ raw: JSONValue?) -> BoardDesign? {
        guard let raw else { return nil }
        guard let object = SpecObject(raw, path: "board", report: report, what: "The board") else { return nil }
        var board = BoardDesign(root: BoardBlock(id: "", kind: .stack, style: SpecDefaults.rootBoardStyle),
                                width: SpecDefaults.boardWidth, showHeader: true)
        if let width = object.number("width") {
            board.width = clamped(width, BoardDesign.widths, path: object.path("width"), what: "width", unit: " pt")
        }
        if let header = object.bool("header") { board.showHeader = header }
        if let id = explicitID(object) { board.root.id = id }
        board.root.name = object.string("name") ?? ""
        parseBlockStyle(object, kind: .stack, into: &board.root.style)
        if board.root.style.fit { report.warning(object.path("fit"), "fit sizes a block inside a row; the board itself is in none.") }
        if let blocks = object["blocks"] {
            if let items = blocks.items { board.root.children = parseBlocks(items, path: object.path("blocks"), index: [], parent: .stack) }
            else { report.error(object.path("blocks"), "blocks is a list ([…]) of blocks, not \(blocks.typeName).") }
        }
        object.checkKeys(Self.boardKeys + Self.blockProperties, what: "the board", notes: Self.blockNotes)
        return board
    }

    func parseBlocks(_ items: [JSONValue], path: String, index: [Int], parent: BoardBlockKind?) -> [BoardBlock] {
        items.enumerated().compactMap { offset, item in parseBlock(item, path: SpecPath.index(path, offset), index: index + [offset], parent: parent) }
    }

    /// One block. `index` is its position (script blocks take their ids from it: `s.2.0`); `parent` is the kind
    /// of the container it sits in, nil where that is not known (the top of what a script prints).
    func parseBlock(_ raw: JSONValue, path: String, index: [Int], parent: BoardBlockKind?) -> BoardBlock? {
        if mode == .spec { pieceCount += 1 }
        if mode == .script {
            blockCount += 1
            if blockCount == Self.scriptBlockLimit + 1 {
                report.error(path, "A script prints at most \(Self.scriptBlockLimit) blocks; the rest are left out.")
            }
            if blockCount > Self.scriptBlockLimit { return nil }
        }
        let scriptID = "s." + index.map(String.init).joined(separator: ".")
        // A bare string is a text block, the way a script most naturally prints a line.
        if case .string = raw {
            var block = BoardBlock(id: mode == .script ? scriptID : "", kind: .text, name: SpecDefaults.blockName(.text), style: SpecDefaults.blockStyle(.text))
            block.segments = template(raw, path: path) ?? []
            return block
        }
        guard let object = SpecObject(raw, path: path, report: report, what: "A block") else { return nil }
        var kinds = Self.kindKeys(object, Self.blockKinds)
        if kinds.contains("toggle") { kinds.removeAll { $0 == "value" } }
        guard kinds.count == 1 else {
            reportKinds(kinds, object: object, all: Self.blockKinds, what: "A block")
            return nil
        }
        let key = kinds[0]
        let kind = key == "space" ? BoardBlockKind.spacer : BoardBlockKind(rawValue: key)!
        if mode == .script, Self.scriptForbidden.contains(kind) {
            report.error(object.path(key), "A script cannot print a “\(key)” block.",
                         hint: "script blocks draw stack, row, card, divider, space, text, value, chart, gauge, stats, button, toggle, output and image")
            return nil
        }
        let content = object.raw(key) ?? .null
        let contentPath = object.path(key)
        var block = BoardBlock(id: mode == .script ? scriptID : "", kind: kind, name: SpecDefaults.blockName(kind), style: SpecDefaults.blockStyle(kind))

        switch kind {
        case .stack, .row, .card:
            if let items = content.items { block.children = parseBlocks(items, path: contentPath, index: index, parent: kind) }
            else { report.error(contentPath, "“\(key)” takes a list of blocks, not \(content.typeName).") }
        case .divider:
            if content != .bool(true) { report.error(contentPath, "A divider is {\"divider\": true}.") }
        case .spacer:
            if let height = content.number { block.style.spacing = clamped(height, 0...400, path: contentPath, what: "space", unit: " pt") }
            else if content != .bool(true) { report.error(contentPath, "“space” takes a height in points, such as 12.") }
        case .text, .button, .toggle:
            block.segments = content.isNull ? [] : template(content, path: contentPath) ?? []
        case .value, .chart, .gauge, .output:
            block.variable = mode == .script ? scriptValue(content, kind: kind, path: contentPath, id: scriptID) : reference(content, path: contentPath)
            if mode == .spec, let id = block.variable, let variable = variable(id) { checkShown(variable, kind: kind, path: contentPath) }
        case .stats:
            if let items = content.items {
                for (offset, item) in items.enumerated() {
                    let itemPath = SpecPath.index(contentPath, offset)
                    if mode == .script, item.members != nil {
                        if let id = scriptStat(item, path: itemPath, id: "\(scriptID).\(offset)") { block.variables.append(id) }
                    } else if let id = item.string {
                        if checkReference(id, path: itemPath) { block.variables.append(id) }
                    } else {
                        report.error(itemPath, mode == .script ? "A stats row is a value id or {\"name\": …, \"value\": …}, not \(item.typeName)."
                                                               : "A stats row is a value id in quotes, not \(item.typeName).")
                    }
                }
            } else {
                report.error(contentPath, "“stats” takes a list of value ids, not \(content.typeName).")
            }
        case .script, .blocks:
            // An empty command is a state the studio saves (a cleared editor), so it reads back with a warning.
            if let command = content.string ?? (content.isNull ? "" : nil) {
                if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    report.warning(contentPath, "“\(key)” has no command yet, so it draws nothing.", hint: "the command to run, such as \"python3 prs.py\"")
                }
                checkLength(command, path: contentPath)
                block.command = CommandSource(command: command)
            } else {
                report.error(contentPath, "“\(key)” takes the command to run, such as \"python3 prs.py\", not \(content.typeName).")
            }
        case .image:
            // The studio's new image block has no source yet; it reads back with a warning.
            if let source = content.string ?? (content.isNull ? "" : nil) {
                if source.trimmingCharacters(in: .whitespaces).isEmpty {
                    report.warning(contentPath, "This image shows nothing until it has a file or an https:// address.")
                    block.source = source
                } else {
                    block.source = mode == .script ? Self.resolvedImage(source, directory: scriptDirectory) : source
                    if source.lowercased().hasPrefix("http://") { report.warning(contentPath, "Images load over https only.") }
                }
            } else {
                report.error(contentPath, "“image” takes a file (absolute, ~/…, or in the sprite's folder) or an https:// address.")
            }
        case .processes:
            if let text = content.string, let list = ProcessListKind(rawValue: text.lowercased()) { block.style.processKind = list }
            else { report.error(contentPath, "“processes” is \"cpu\", \"memory\" or \"power\", not \(content.serialized()).") }
        case .energy, .accounts, .readings:
            if content != .bool(true) { report.error(contentPath, "MenuSprite's own panels are switched on with true: {\"\(key)\": true}.") }
        }

        parseExtras(object, kind: kind, key: key, into: &block)
        if let id = explicitID(object) { block.id = id }
        if let name = object.string("name") { block.name = name }
        parseBlockStyle(object, kind: kind, into: &block.style)
        if block.style.fit, let parent, parent != .row {
            report.warning(object.path("fit"), "fit gives a block its natural width inside a row; this one is in a \(parent.specKey), so it does nothing.")
        }
        if kind == .chart, object["max"] != nil {
            report.warning(object.path("max"), "A chart scales itself (0–100 for a percentage, else from 0 to its highest point), so max does nothing here.",
                           hint: "max sets how much fills a gauge")
        }
        object.checkKeys([key] + Self.blockProperties + Self.blockExtras.map(\.key), what: "a \(key) block", notes: Self.blockNotes)
        return block
    }

    private func parseExtras(_ object: SpecObject, kind: BoardBlockKind, key: String, into block: inout BoardBlock) {
        for extra in Self.blockExtras where object[extra.key] != nil && !extra.kinds.contains(kind) && !(extra.key == "value" && kind == .value) {
            if extra.key == "title" && !Self.labelled.contains(kind) { continue }
            report.warning(object.path(extra.key), "“\(extra.key)” applies to \(Fuzzy.list(extra.kinds.map(\.specKey).sorted(), conjunction: "and")) blocks, not \(key).")
        }
        if let raw = object["title"] {
            if Self.labelled.contains(kind) {
                // Reported above: a text, button, switch or value carries its words elsewhere.
            } else {
                if kind != .card { report.warning(object.path("title"), "Only a card draws its title.", hint: "put the blocks in a card, or add a text block") }
                block.segments = template(raw, path: object.path("title")) ?? []
            }
        }
        if let raw = object["caption"], [.value, .chart, .gauge].contains(kind) { block.segments = template(raw, path: object.path("caption")) ?? [] }
        if let raw = object["detail"] { block.detail = template(raw, path: object.path("detail")) ?? [] }
        if let symbol = object.string("icon") {
            if symbol.isEmpty { report.error(object.path("icon"), "icon is an SF Symbol name.") }
            else { block.symbol = symbol; checkSymbol(symbol, path: object.path("icon")) }
        }
        if kind == .button || Self.clickable.contains(kind) {
            let actions = Self.actionKeys.filter { object[$0] != nil }
            if actions.count > 1 {
                report.error(object.path, "A \(kind == .button ? "button" : "block") does one thing when clicked; this one has \(Fuzzy.list(actions, conjunction: "and")).",
                             hint: kind == .button ? "use one button per action" : "keep one, or add a button for the other")
            } else if let action = actions.first {
                block.action = boardAction(action, object: object)
            } else if kind == .button {
                report.warning(object.path, "This button does nothing when clicked.", hint: "add run, open, app, copy or refresh")
            }
        }
        if kind == .toggle {
            if let raw = object["value"] {
                block.variable = mode == .script ? scriptToggleValue(raw, path: object.path("value"), id: block.id) : reference(raw, path: object.path("value"))
            } else {
                report.warning(object.path, "This switch shows no state: add \"value\", a value that reads on or off.")
            }
            if let on = commandText(object, "on") { block.action = BoardAction(kind: .runCommand, value: on) }
            if let off = commandText(object, "off") { block.offAction = BoardAction(kind: .runCommand, value: off) }
            if object["on"] == nil && object["off"] == nil { report.warning(object.path, "This switch runs nothing: add \"on\" and \"off\" commands.") }
        }
        if kind == .script || kind == .blocks {
            if block.command != nil {
                if let raw = object["every"], let seconds = duration(raw, path: object.path("every"), range: SpecDefaults.commandIntervals) { block.command?.interval = seconds }
                if let timeout = object.number("timeout") {
                    block.command?.timeout = clamped(timeout, 1...60, path: object.path("timeout"), what: "timeout", unit: " s")
                }
            }
        } else if kind == .button || kind == .toggle || Self.clickable.contains(kind), let timeout = object.number("timeout") {
            // How long a clicked command may run before it is stopped (30 s unless set); kept even where it
            // does nothing, so the block reads back as written.
            let seconds = clamped(timeout, SpecDefaults.actionTimeouts, path: object.path("timeout"), what: "timeout", unit: " s")
            let actions = [block.action, block.offAction].compactMap { $0 }
            if actions.isEmpty {
                report.warning(object.path("timeout"), "timeout limits the command a click runs, and this block runs none.")
            } else if !actions.contains(where: { $0.kind == .runCommand }) {
                report.warning(object.path("timeout"), "timeout limits a run command; open, app, copy and refresh finish at once.")
            }
            block.action?.timeout = seconds; block.offAction?.timeout = seconds
        }
    }

    /// A switch's on or off command. An empty one is a state the studio saves (a cleared editor), so it is kept
    /// with a warning.
    private func commandText(_ object: SpecObject, _ key: String) -> String? {
        guard let text = object.string(key) else { return nil }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { report.warning(object.path(key), "“\(key)” is an empty command, so it does nothing.") }
        checkLength(text, path: object.path(key))
        return text
    }

    /// What a click does. The studio can save an action half made (a cleared command, a link typed without its
    /// scheme, a copy naming a value since deleted), so those read back as written, with a warning.
    private func boardAction(_ key: String, object: SpecObject) -> BoardAction? {
        let path = object.path(key)
        if key == "refresh" {
            if object[key] == .bool(true) { return BoardAction(kind: .refresh, value: "") }
            report.error(path, "A refresh is {\"refresh\": true}, as in {\"button\": \"Refresh\", \"refresh\": true}.")
            return nil
        }
        guard let text = object.string(key) else { return nil }
        let kind: BoardActionKind = switch key { case "run": .runCommand; case "open": .openURL; case "app": .openApp; default: .copyText }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report.warning(path, "“\(key)” is empty, so a click does nothing.")
            return BoardAction(kind: kind, value: text)
        }
        switch kind {
        case .runCommand: checkLength(text, path: path)
        case .openURL:
            if URL(string: text.trimmingCharacters(in: .whitespaces))?.scheme == nil {
                report.warning(path, "“open” takes a link with its scheme, such as https://github.com; without one a click only says “Not a link”.",
                               hint: "an app goes in \"app\", a command in \"run\"")
            }
        case .copyText: _ = templateString(text, path: path, copied: true)
        case .openApp, .refresh: break
        }
        return BoardAction(kind: kind, value: text)
    }

    func parseBlockStyle(_ object: SpecObject, kind: BoardBlockKind, into style: inout BoardStyle) {
        if let raw = object["color"], let color = color(raw, path: object.path("color"), keywords: ["inherit", "auto"]) { style.color = color }
        if let raw = object["background"], let color = color(raw, path: object.path("background"), keywords: ["none"]) { style.background = color }
        if let align = choice(object, "align", DesignAlign.self) { style.align = align }
        if let spacing = object.number("spacing") {
            if kind == .spacer { report.warning(object.path("spacing"), "A space's height is its own value: {\"space\": 12}.") }
            else { style.spacing = clamped(spacing, 0...200, path: object.path("spacing"), what: "spacing") }
        }
        if let padding = object.number("padding") { style.padding = clamped(padding, 0...200, path: object.path("padding"), what: "padding") }
        if let hidden = object.bool("hidden") { style.hidden = hidden }
        if let opacity = object.number("opacity") { style.opacity = clamped(opacity, 0...1, path: object.path("opacity"), what: "opacity") }
        if let height = object.number("height") { style.height = clamped(height, 4...2000, path: object.path("height"), what: "height", unit: " pt") }
        if let maximum = object.number("max") {
            if maximum > 0 { style.maximum = maximum } else { report.error(object.path("max"), "max is the value that fills the gauge: a positive number.") }
        }
        if let limit = object.number("limit") {
            let rows = Int(clamped(limit.rounded(), 1...100, path: object.path("limit"), what: "limit"))
            style.limit = rows
        }
        if let font = choice(object, "font", BoardTextStyle.self) { style.textStyle = font }
        if let lines = object.number("lines") {
            let whole = clamped(lines.rounded(), 0...100, path: object.path("lines"), what: "lines")
            if lines.rounded() != lines, (0...100).contains(lines) {
                report.warning(object.path("lines"), "lines is a whole number of lines (0 for as many as the text needs); \(SpecFormat.number(lines)) became \(SpecFormat.number(whole)).")
            }
            style.lines = Int(whole)
        }
        if let truncate = choice(object, "truncate", BoardTruncation.self) {
            style.truncate = truncate
            if style.lines == 0 {
                report.warning(object.path("truncate"), "truncate says where text held to its lines is cut, and this text has no line limit.",
                               hint: "add \"lines\": 1")
            }
        }
        if let fit = object.bool("fit") { style.fit = fit }
    }

    /// What a block can sensibly draw from a value.
    private func checkShown(_ variable: SpriteVariable, kind: BoardBlockKind, path: String) {
        switch (kind, variable.source) {
        case (.chart, .constant):
            report.warning(path, "A chart draws a value's history; a fixed text has none.")
        case (.chart, .reading(let id)) where environment.metric(id)?.unit == .text:
            report.warning(path, "A chart draws numbers; the reading \(id) is text.")
        case (.chart, .command(let command)):
            if command.output != .number && command.output != .json {
                report.warning(path, "A chart draws numbers; give the value \(variable.id) \"parse\": \"number\".")
            }
            if !command.background { commandCharts.append((path, variable.id)) }
        case (.output, .reading), (.output, .constant):
            report.warning(path, "“output” shows a command value's raw output; \(variable.id) is not a command.")
        default: break
        }
    }

    // MARK: - Script blocks

    /// A value, gauge, chart or output a script printed: one of the sprite's values by id, or literal data
    /// kept as a fixed value the block refers to.
    private func scriptValue(_ raw: JSONValue, kind: BoardBlockKind, path: String, id: String) -> String? {
        if let text = raw.string, variableIDs.contains(text) { return text }
        switch (kind, raw) {
        case (.gauge, .number(let number)), (.value, .number(let number)):
            return constant(id, text: SpecFormat.number(number))
        case (.gauge, .string(let text)) where Double(text.trimmingCharacters(in: .whitespaces)) != nil:
            return constant(id, text: text.trimmingCharacters(in: .whitespaces))
        case (.value, .string(let text)):
            return constant(id, text: text)
        case (.value, .bool(let flag)):
            return constant(id, text: flag ? "true" : "false")
        case (.chart, .array(let items)):
            let numbers = items.compactMap(\.number)
            guard numbers.count == items.count else {
                report.error(path, "A chart a script prints is a value id or a list of numbers.")
                return nil
            }
            return constant(id, text: numbers.map(SpecFormat.number).joined(separator: ","))
        case (_, .null):
            return nil
        default:
            let values = variables.map(\.id).joined(separator: ", ")
            if kind == .output {
                report.error(path, "“output” shows one of the sprite's command values (\(values)), not \(raw.serialized()).", hint: "print text as {\"text\": …}")
            } else {
                let what = kind == .gauge ? "a number" : kind == .chart ? "a list of numbers" : "text or a number"
                report.error(path, "“\(kind.specKey)” takes one of the sprite's values (\(values)) or \(what), not \(raw.serialized()).")
            }
            return nil
        }
    }

    private func scriptToggleValue(_ raw: JSONValue, path: String, id: String) -> String? {
        switch raw {
        case .string(let text): return variableIDs.contains(text) ? text : constant(id, text: text)
        case .bool(let flag): return constant(id, text: flag ? "true" : "false")
        case .number(let number): return constant(id, text: SpecFormat.number(number))
        default:
            report.error(path, "A switch's value is one of the sprite's values, true/false, or text such as \"on\".")
            return nil
        }
    }

    /// `{"name": "Open", "value": 12}` in a stats list.
    private func scriptStat(_ raw: JSONValue, path: String, id: String) -> String? {
        guard let object = SpecObject(raw, path: path, report: report, what: "A stats row") else { return nil }
        let name = object["name"].map { $0.string ?? ($0.number.map(SpecFormat.number) ?? $0.serialized()) } ?? ""
        let text: String
        switch object["value"] {
        case .string(let value)?: text = value
        case .number(let value)?: text = SpecFormat.number(value)
        case .bool(let value)?: text = value ? "true" : "false"
        default:
            report.error(object.path("value"), "A stats row is {\"name\": \"…\", \"value\": \"…\"}.")
            return nil
        }
        object.checkKeys(["name", "value"], what: "a stats row")
        constants.append(SpriteVariable(id: id, name: name, source: .constant(text: text)))
        return id
    }

    private func constant(_ id: String, text: String) -> String {
        constants.append(SpriteVariable(id: id, name: "", source: .constant(text: text)))
        return id
    }

    /// A script runs in the sprite's folder (or the home folder), so a relative image is relative to that.
    static func resolvedImage(_ source: String, directory: String?) -> String {
        let lower = source.lowercased()
        if source.hasPrefix("/") || source.hasPrefix("~") || lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("file://") {
            return source
        }
        return ((directory ?? NSHomeDirectory()) as NSString).appendingPathComponent(source)
    }
}

extension BoardBlockKind {
    /// The block's key in the spec.
    var specKey: String { self == .spacer ? "space" : rawValue }
}

extension SpecCompiler {
    /// No catalog or symbols are consulted for what a script prints: it is redrawn while the board is open,
    /// and the sprite's own values are all it may name.
    static let scriptEnvironment = SpecEnvironment(metric: { _ in nil }, readingIDs: { [] }, spriteDirectory: { _ in "" })

    static func scriptBlocks(_ output: String, design: SpriteDesign, directory: String?)
        -> (blocks: [BoardBlock], variables: [SpriteVariable], diagnostics: [SpecDiagnostic]) {
        let compiler = SpecCompiler(environment: scriptEnvironment, mode: .script)
        design.variables.forEach(compiler.declare)
        compiler.scriptDirectory = directory
        let document: JSONValue
        do { document = try JSONValue.parse(output) }
        catch let error as JSONParseError { return ([], [], [.error("", error.description, hint: "print the blocks as JSON: [{\"text\": \"…\"}]")]) }
        catch { return ([], [], [.error("", "The output is not JSON.")]) }
        let items: [JSONValue], base: String
        switch document {
        case .array(let list):
            items = list; base = ""
        case .object(let members) where members.contains(where: { $0.key == "blocks" }):
            guard let list = document["blocks"]?.items else {
                return ([], [], [.error("blocks", "blocks is a list ([…]) of blocks, not \(document["blocks"]?.typeName ?? "null").")])
            }
            items = list; base = "blocks"
            for member in members where member.key != "blocks" {
                compiler.report.warning(member.key, "Only \"blocks\" is read from the printed object; “\(member.key)” is ignored.")
            }
        default:
            return ([], [], [.error("", "A script prints a list of blocks ([…]) or {\"blocks\": […]}, not \(document.typeName).")])
        }
        let blocks = compiler.parseBlocks(items, path: base, index: [], parent: nil)
        return (blocks, compiler.constants, compiler.report.diagnostics)
    }
}
