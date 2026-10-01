import AgentProtocol
import Foundation
import SystemMonitoring

/// Reads a spec (or the blocks a script printed) over `JSONValue` by hand rather than through Codable, so
/// every finding carries the path the agent wrote, unknown keys get a "did you mean", and reading goes on
/// past the first problem. Spec: `docs/agent-authoring.md`, "The sprite spec, version 1".
final class SpecCompiler {
    enum Mode { case spec, script }

    let environment: SpecEnvironment
    let mode: Mode
    let report = SpecReport()
    /// The values texts, blocks and rules may name. `variableIDs` also holds ids whose value failed to compile,
    /// so a reference to one is not reported a second time; `variableByID` and `valueByReading` are lookups
    /// (a spec may hold many values and many references to them).
    var variables: [SpriteVariable] = []
    var variableIDs: Set<String> = []
    var variableByID: [String: SpriteVariable] = [:]
    var valueByReading: [String: String] = [:]
    /// Ids written in the spec, with where each was written. Face and board share one namespace because a
    /// rule's target may be either.
    var explicitIDs: [String: String] = [:]
    /// Charts of command values, checked once the rules are known (a chart needs its value running).
    var commandCharts: [(path: String, variable: String)] = []
    /// Script mode: fixed values standing for the literal data a script printed.
    var constants: [SpriteVariable] = []
    var blockCount = 0
    /// Face nodes and board blocks read so far (spec mode), against `SpecDefaults.pieceLimit`.
    var pieceCount = 0
    /// The conditions of the sprite being replaced, which are kept even when they can never hold.
    var existingConditions: Set<String> = []
    /// Script mode: the folder the script ran in, which a relative image is relative to.
    var scriptDirectory: String?
    static let scriptBlockLimit = 200

    init(environment: SpecEnvironment, mode: Mode = .spec) {
        self.environment = environment; self.mode = mode
    }

    static let topKeys = ["menusprite", "id", "name", "icon", "enabled", "menuBar", "side", "every", "values", "face", "rules", "board", "files"]

    func compile(_ spec: JSONValue, existing: SpriteConfiguration?) -> (CompiledSprite?, [SpecDiagnostic]) {
        guard let top = SpecObject(spec, path: "", report: report, what: "A sprite spec") else { return (nil, report.diagnostics) }
        switch top.raw("menusprite") {
        case nil: report.error("menusprite", "A spec starts with \"menusprite\": 1, the format version.")
        case .number(let version)? where version == Double(SpriteSpecFormat.version): break
        case let other?: report.error("menusprite", "This MenuSprite reads spec version 1, not \(other.serialized()).")
        }
        var specID: UUID?
        if let raw = top["id"] {
            if let text = raw.string, let id = UUID(uuidString: text) { specID = id }
            else {
                report.error("id", "id is the sprite's UUID as `menusprite get` prints it, not \(raw.serialized()).",
                             hint: "leave id out to make a new sprite; apply also finds an existing sprite by name")
            }
        }
        var name = ""
        if top["name"] == nil {
            report.error("name", "Every sprite needs a name.", hint: "add \"name\": \"…\"")
        } else if let text = top.string("name") {
            // Saved as `normalize()` saves it, and matched that way by `identity(of:)`, so applying the same
            // spec again finds the sprite it made rather than making another.
            name = SpriteSpecFormat.normalizedName(text)
            if name.isEmpty { report.error("name", "The sprite's name is empty.") }
            else if text.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 {
                report.warning("name", "A name is at most 40 characters; this one is saved as “\(name)”.",
                               hint: "apply finds the sprite again by that name, or by its id")
            }
        }
        var icon = SpecDefaults.symbol
        if let text = top.string("icon") {
            if text.isEmpty { report.error("icon", "icon is an SF Symbol name, such as \"cpu\" or \"bolt.fill\".") }
            else { icon = text; checkSymbol(text, path: "icon") }
        }
        let enabled = top.bool("enabled") ?? true
        let menuBar = top.bool("menuBar") ?? true
        var side: SpriteSide?
        if let text = top.string("side") {
            if let value = SpriteSide(rawValue: text.lowercased()) { side = value }
            else { report.error("side", "side is \"left\" or \"right\", not “\(text)”.") }
        }
        var interval = SpecDefaults.spriteInterval
        if let raw = top["every"] {
            if let seconds = SpecDuration.seconds(raw), seconds.isFinite {
                let snapped = SpecDefaults.spriteIntervals.min { abs($0 - seconds) < abs($1 - seconds) }!
                if snapped != seconds {
                    report.warning("every", "A sprite samples its readings every 1, 2, 5, 10, 30 or 60 seconds; \(SpecFormat.number(seconds)) became \(SpecFormat.number(snapped)).",
                                   hint: "a command value has its own every")
                }
                interval = snapped
            } else {
                report.error("every", "every is seconds: 1, 2, 5, 10, 30 or 60, not \(raw.serialized()).")
            }
        }

        parseValues(top["values"])
        // Agents set it hoping to pace their commands; it paces readings only.
        if top["every"] != nil, !variables.contains(where: { $0.readingID != nil }) {
            report.warning("every", "The top-level every only paces readings, and this sprite reads none, so it does nothing.",
                           hint: "commands have their own every: {\"id\": …, \"command\": …, \"every\": \"5m\"}")
        }
        var face = parseFace(top["face"], icon: icon)
        var board = parseBoard(top["board"])
        assignIDs(face: &face, board: &board)
        let rules = parseRules(top["rules"], face: face, board: board, existing: existing?.design)
        checkCommandCharts(face: face, rules: rules)
        let files = parseFiles(top["files"])
        if pieceCount > SpecDefaults.pieceLimit {
            report.error("", "A sprite holds at most \(SpecDefaults.pieceLimit) face pieces and board blocks together; this one has \(pieceCount).",
                         hint: "draw long lists from a blocks script: {\"blocks\": \"python3 list.py\"}")
        }
        top.checkKeys(Self.topKeys, what: "a sprite",
                      notes: ["blocks": "blocks belong inside \"board\": {\"blocks\": […]}."])
        guard !report.hasErrors else { return (nil, report.diagnostics) }

        let id = existing?.id ?? specID ?? UUID()
        var design = SpriteDesign(root: face, variables: variables, rules: rules, board: board)
        let keepsFiles = files.map { !$0.isEmpty } ?? environment.hasFiles(id)
        Self.setDirectory(keepsFiles ? environment.spriteDirectory(id) : nil, in: &design)

        var config: SpriteConfiguration
        if let existing {
            config = existing
        } else {
            config = SpriteConfiguration(name: name, symbol: icon, enabled: enabled, showInMenuBar: menuBar)
            config.id = id
        }
        config.name = name; config.symbol = icon; config.enabled = enabled; config.showInMenuBar = menuBar
        config.interval = interval
        config.design = design
        config.normalize()
        return (CompiledSprite(config: config, side: side, files: files, diagnostics: report.diagnostics), report.diagnostics)
    }

    // MARK: - Values

    static let valueKeys = ["id", "name", "reading", "command", "text", "decimals", "unit", "fahrenheit", "bits", "clock",
                            "every", "timeout", "parse", "path", "suffix", "background"]
    // `clock` is not here: a numeric command value counts as seconds from the run, and the runtime writes it as a time.
    static let readingOnly = ["unit", "fahrenheit", "bits"]
    static let commandOnly = ["every", "timeout", "parse", "path", "suffix", "background"]

    /// Letters, digits and `_`, at most 32. A leading digit is allowed because the studio already makes
    /// such ids from labels ("5h", "7d"), and texts and rules read them without trouble.
    static func isValueID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
    /// Face, board and rule ids: ASCII letters, digits, `_` and `-`.
    static func isNodeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    func parseValues(_ raw: JSONValue?) {
        guard let raw else { return }
        guard let items = raw.items else {
            report.error("values", "values is a list ([…]) of values, not \(raw.typeName).")
            return
        }
        if items.count > SpecDefaults.valueLimit {
            report.error("values", "A sprite has at most \(SpecDefaults.valueLimit) values; this one has \(items.count).",
                         hint: "one command can feed a board of many rows: {\"blocks\": \"python3 list.py\"}")
        }
        var firstPath: [String: String] = [:]
        for (index, item) in items.enumerated() {
            let path = SpecPath.index("values", index)
            if let reading = item.string {
                let id = reading.split(separator: ".").last.map(String.init) ?? "value"
                report.error(path, "A value is an object with an id, not \(item.typeName).",
                             hint: environment.metric(reading) != nil ? "{\"id\": \"\(id)\", \"reading\": \"\(reading)\"}" : "{\"id\": \"…\", \"command\": \"…\"}")
                continue
            }
            guard let object = SpecObject(item, path: path, report: report, what: "A value") else { continue }
            var id: String?
            if let raw = object.raw("id"), !raw.isNull {
                if let text = raw.string {
                    if !Self.isValueID(text) {
                        let cleaned = String(text.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(32))
                        report.error(object.path("id"), "“\(text)” is not a value id: letters, digits and _, at most 32.",
                                     hint: cleaned.isEmpty ? nil : "try \(cleaned)")
                    } else if let first = firstPath[text] {
                        report.error(object.path("id"), "Two values have the id “\(text)” (the first is \(first)).")
                    } else {
                        id = text; firstPath[text] = path
                    }
                } else {
                    report.error(object.path("id"), "“id” takes text in quotes, not \(raw.typeName).")
                }
            } else {
                report.error(path, "Every value needs an id; texts name it as {id}.", hint: "add \"id\": \"…\"")
            }

            let sources = ["reading", "command", "text"].filter { object[$0] != nil }
            var source: VariableSource?
            var defaultName = id ?? ""
            var format = ValueFormat()
            if sources.count != 1 {
                report.error(path, sources.isEmpty ? "A value needs one of reading, command or text."
                                                   : "A value takes one of reading, command or text, not \(Fuzzy.list(sources, conjunction: "and")).")
            }
            switch sources.count == 1 ? sources[0] : "" {
            case "reading":
                if let reading = requiredString(object, "reading") {
                    if let metric = environment.metric(reading) {
                        source = .reading(metric: reading); defaultName = metric.name
                    } else {
                        report.error(object.path("reading"), "This Mac has no reading “\(reading)”.",
                                     hint: report.hint(reading, in: environment.readingIDs()) ?? "`menusprite readings` lists them")
                    }
                }
            case "command":
                if let command = requiredString(object, "command") { source = .command(parseCommand(command, object)) }
            case "text":
                if let value = object["text"] {
                    if let text = value.string { source = .constant(text: text) }
                    else if let number = value.number { source = .constant(text: SpecFormat.number(number)) }
                    else { report.error(object.path("text"), "“text” takes text in quotes, not \(value.typeName).") }
                } else {
                    source = .constant(text: "")
                }
            default: break
            }
            // What applies to which kind of value. Format fields are kept even where they do nothing, so a
            // sprite reads back exactly as it was.
            let kind = sources.count == 1 ? sources[0] : ""
            for key in Self.readingOnly where object[key] != nil && kind != "reading" && !kind.isEmpty {
                report.warning(object.path(key), "“\(key)” applies to reading values only.")
            }
            for key in Self.commandOnly where object[key] != nil && kind != "command" && !kind.isEmpty {
                report.warning(object.path(key), "“\(key)” applies to command values only.")
            }
            if object["decimals"] != nil, kind == "text" { report.warning(object.path("decimals"), "A fixed text has no decimals.") }
            if let decimals = object.number("decimals") {
                let whole = Int(min(2, max(0, decimals.rounded())))
                if Double(whole) != decimals { report.warning(object.path("decimals"), "decimals is 0, 1 or 2; \(SpecFormat.number(decimals)) became \(whole).") }
                format.decimals = whole
            }
            if let unit = object.bool("unit") { format.showUnit = unit }
            if let fahrenheit = object.bool("fahrenheit") { format.fahrenheit = fahrenheit }
            if let bits = object.bool("bits") { format.bits = bits }
            if let clock = object.bool("clock") {
                format.clock = clock
                // A duration is a reading in seconds (a limit's reset, uptime); anything else has no end time.
                if clock, kind == "reading", case .reading(let id)? = source, let unit = environment.metric(id)?.unit, unit != .seconds {
                    report.warning(object.path("clock"), "clock writes a duration as the time it ends, and \(id) is not a duration (it is in \(unit.rawValue)).",
                                   hint: "readings in seconds take it, such as ai.claude.sessionReset")
                }
            }
            if let suffix = object.string("suffix") { format.suffix = suffix }
            let name = object.string("name") ?? defaultName
            object.checkKeys(Self.valueKeys, what: "a value",
                             notes: ["value": "A value names its source with reading, command or text."])
            guard let id else { continue }
            variableIDs.insert(id)
            if let source { declare(SpriteVariable(id: id, name: name, source: source, format: format)) }
        }
    }

    func declare(_ variable: SpriteVariable) {
        variables.append(variable); variableIDs.insert(variable.id); variableByID[variable.id] = variable
        if let reading = variable.readingID, valueByReading[reading] == nil { valueByReading[reading] = variable.id }
    }

    private func requiredString(_ object: SpecObject, _ key: String) -> String? {
        guard let value = object[key] else { report.error(object.path(key), "“\(key)” is empty."); return nil }
        guard let text = value.string else { report.error(object.path(key), "“\(key)” takes text in quotes, not \(value.typeName)."); return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { report.error(object.path(key), "“\(key)” is empty."); return nil }
        return text
    }

    private func parseCommand(_ command: String, _ object: SpecObject) -> CommandSource {
        checkLength(command, path: object.path("command"))
        var source = CommandSource(command: command)
        if let raw = object["every"], let seconds = duration(raw, path: object.path("every"), range: SpecDefaults.commandIntervals) { source.interval = seconds }
        if let timeout = object.number("timeout") { source.timeout = clamped(timeout, 1...60, path: object.path("timeout"), what: "timeout", unit: " s") }
        if let parse = object.string("parse") {
            if let output = CommandOutput(rawValue: parse.lowercased()) { source.output = output }
            else { report.error(object.path("parse"), "parse is text, number or json, not “\(parse)”.", hint: report.hint(parse, in: ["text", "number", "json"])) }
        }
        if let path = object.string("path") {
            source.path = path
            if source.output != .json, !path.isEmpty { report.warning(object.path("path"), "path is read only with \"parse\": \"json\".") }
        }
        if let background = object.bool("background") { source.background = background }
        return source
    }

    /// Seconds within `range`, from a number or "30s"/"5m"/"1h"/"1d".
    func duration(_ raw: JSONValue, path: String, range: ClosedRange<Double>) -> Double? {
        guard let seconds = SpecDuration.seconds(raw), seconds.isFinite else {
            report.error(path, "every is seconds (30) or a duration such as \"30s\", \"5m\", \"1h\" or \"1d\", not \(raw.serialized()).")
            return nil
        }
        return clamped(seconds, range, path: path, what: "every", unit: " s")
    }

    /// The runtime runs a command only up to `SpecDefaults.commandLength` characters; a longer one would lose
    /// its end silently (a script that runs half, or a quote never closed), so it is refused.
    func checkLength(_ command: String, path: String) {
        guard command.count > SpecDefaults.commandLength else { return }
        report.error(path, "A command is at most \(SpecDefaults.commandLength) characters; this one has \(command.count).",
                     hint: "put the script in \"files\" and run it by name, e.g. \"python3 prs.py\"")
    }

    func clamped(_ value: Double, _ range: ClosedRange<Double>, path: String, what: String, unit: String = "") -> Double {
        let result = min(range.upperBound, max(range.lowerBound, value))
        if result != value {
            report.warning(path, "\(what) is \(SpecFormat.number(range.lowerBound))–\(SpecFormat.number(range.upperBound))\(unit); \(SpecFormat.number(value)) became \(SpecFormat.number(result)).")
        }
        return result
    }

    func variable(_ id: String) -> SpriteVariable? { variableByID[id] }

    // MARK: - References

    /// Text with `{value}` references, as a string, a number, or (lossless form) a list of strings and
    /// `{"value": "id"}` objects.
    func template(_ value: JSONValue, path: String) -> [TextSegment]? {
        switch value {
        case .string(let text): return templateString(text, path: path)
        case .number(let number): return [.literal(SpecFormat.number(number))]
        case .array(let items):
            var segments: [TextSegment] = []
            for (index, item) in items.enumerated() {
                if let text = item.string { segments.append(.literal(text)); continue }
                if let id = item["value"]?.string, item.members?.count == 1 {
                    if checkReference(id, path: SpecPath.index(path, index)) { segments.append(.value(id)) }
                    continue
                }
                report.error(SpecPath.index(path, index), "A text list holds strings and {\"value\": \"id\"} objects, not \(item.typeName).")
            }
            return segments
        default:
            report.error(path, "This takes text (with {value} references), not \(value.typeName).")
            return nil
        }
    }

    /// `copied`: the text of a copy action, which is stored as written. An unknown `{word}` there is copied as
    /// nothing, so it is a warning: the studio keeps such a text when the value it named is deleted.
    func templateString(_ text: String, path: String, copied: Bool = false) -> [TextSegment] {
        var segments = TextTemplate.parse(text)
        for index in segments.indices {
            guard case .value(let id) = segments[index], !variableIDs.contains(id) else { continue }
            if mode == .script {
                report.warning(path, "“{\(id)}” names no value of this sprite, so it is shown as written.",
                               hint: report.hint(id, in: variables.map(\.id), format: { "{\($0)}" }))
                segments[index] = .literal("{\(id)}")
            } else if copied {
                report.warning(path, "“{\(id)}” names no value, so it copies as nothing.", hint: valueHint(id, format: { "{\($0)}" }))
            } else {
                report.error(path, "“{\(id)}” names no value.", hint: valueHint(id, format: { "{\($0)}" }))
            }
        }
        if mode == .spec {
            for reading in bracedReadings(text) {
                report.error(path, "Texts name values, not readings: “{\(reading)}”.", hint: valueHint(reading, format: { "{\($0)}" }))
            }
        }
        return segments
    }

    /// `{cpu.usage}`: a reading id where a value id belongs. TextTemplate leaves it as literal text, which
    /// would draw the braces in the menu bar.
    func bracedReadings(_ text: String) -> [String] { Self.bracedReadings(text, environment: environment) }
    static func bracedReadings(_ text: String, environment: SpecEnvironment) -> [String] {
        var result: [String] = []
        var rest = text[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let inner = String(rest[rest.index(after: open)..<close])
            if inner.contains("."), environment.metric(inner) != nil { result.append(inner) }
            rest = rest[rest.index(after: open)...]
        }
        return result
    }

    /// A value id where a value belongs; reports and returns false when it names nothing.
    @discardableResult
    func checkReference(_ id: String, path: String) -> Bool {
        if variableIDs.contains(id) { return true }
        report.error(path, "“\(id)” names no value.", hint: valueHint(id))
        return false
    }

    /// A value reference that may be null (a level bar or block with no value yet).
    func reference(_ raw: JSONValue, path: String) -> String? {
        if raw.isNull { return nil }
        guard let id = raw.string else {
            report.error(path, "This takes a value id in quotes, not \(raw.typeName).")
            return nil
        }
        return checkReference(id, path: path) ? id : nil
    }

    func valueHint(_ id: String, format: (String) -> String = { $0 }) -> String? {
        if environment.metric(id) != nil {
            if let existing = valueByReading[id] { return "the value \(format(existing)) reads \(id)" }
            let suggested = id.split(separator: ".").last.map(String.init).flatMap { Self.isValueID($0) ? $0 : nil } ?? "value"
            return "add {\"id\": \"\(suggested)\", \"reading\": \"\(id)\"} to values and write \(format(suggested))"
        }
        if let close = report.hint(id, in: variables.map(\.id), format: format) { return close }
        // A sample, so a spec with many values and many bad references cannot grow a reply as their product.
        return variables.isEmpty ? "declare it under values first"
            : "values: " + variables.prefix(10).map { format($0.id) }.joined(separator: ", ") + (variables.count > 10 ? " and \(variables.count - 10) more" : "")
    }

    func checkSymbol(_ name: String, path: String) {
        guard mode == .spec, !environment.symbolExists(name) else { return }
        report.warning(path, "This Mac has no SF Symbol called “\(name)”, so nothing is drawn.", hint: "the SF Symbols app lists names, e.g. bolt.fill")
    }

    func color(_ raw: JSONValue, path: String, keywords: [String]) -> String? {
        guard let text = raw.string else {
            report.error(path, "A colour is text: a name, \"#RRGGBB\"\(keywords.isEmpty ? "" : " or " + keywords.joined(separator: "/")), not \(raw.typeName).")
            return nil
        }
        if let color = SpecColor.parse(text, keywords: keywords) { return color }
        report.error(path, "“\(text)” is not a colour: use #RRGGBB, \(keywords.map { "\"\($0)\"" }.joined(separator: ", "))\(keywords.isEmpty ? "" : ", ")or one of \(SpecColor.names.joined(separator: " ")).",
                     hint: report.hint(text, in: SpecColor.names + keywords))
        return nil
    }

    /// A string choice from an enum, accepting a few spellings people use.
    func choice<T: RawRepresentable & CaseIterable>(_ object: SpecObject, _ key: String, _ type: T.Type) -> T? where T.RawValue == String {
        guard let text = object.string(key) else { return nil }
        let aliases = ["centre": "center", "middle": "center", "left": "leading", "right": "trailing",
                       "space-between": "spaceBetween", "between": "spaceBetween", "spacebetween": "spaceBetween",
                       "monospaced": "mono", "monospace": "mono", "large": "huge"]
        let lower = text.lowercased()
        if let value = T.allCases.first(where: { $0.rawValue.lowercased() == lower })
            ?? aliases[lower].flatMap({ alias in T.allCases.first { $0.rawValue == alias } }) {
            return value
        }
        let names = T.allCases.map(\.rawValue)
        report.error(object.path(key), "\(key) is \(Fuzzy.list(names)), not “\(text)”.", hint: report.hint(text, in: names))
        return nil
    }

    // MARK: - Ids

    /// An id written on a node or block: checked, and claimed in the shared namespace.
    func explicitID(_ object: SpecObject) -> String? {
        guard mode == .spec, let raw = object["id"] else { return nil }
        guard let id = raw.string else {
            report.error(object.path("id"), "“id” takes text in quotes, not \(raw.typeName).")
            return nil
        }
        guard Self.isNodeID(id) else {
            report.error(object.path("id"), "“\(id)” is not an id: use letters, digits, _ and -.")
            return nil
        }
        if let first = explicitIDs[id] {
            report.error(object.path("id"), "The id “\(id)” is already used at \(first.isEmpty ? "the board" : first).",
                         hint: "ids are unique across the face and the board")
            return nil
        }
        explicitIDs[id] = object.path
        return id
    }

    static func unique(_ base: String, _ taken: inout Set<String>) -> String {
        var candidate = base, suffix = 2
        while taken.contains(candidate) { candidate = "\(base)_\(suffix)"; suffix += 1 }
        taken.insert(candidate)
        return candidate
    }

    /// Gives every node and block without an id one derived from its position (`f-1-0`, `b-2`), so the
    /// same spec always builds the same design. An id the spec wrote wins; a derived id that collides
    /// with one gets a suffix.
    func assignIDs(face: inout DesignNode, board: inout BoardDesign?) {
        var taken = Set(explicitIDs.keys)
        func walk(_ node: inout DesignNode, _ path: String) {
            if node.id.isEmpty { node.id = Self.unique(path, &taken) }
            for index in node.children.indices { walk(&node.children[index], "\(path)-\(index)") }
        }
        func walk(_ block: inout BoardBlock, _ path: String) {
            if block.id.isEmpty { block.id = Self.unique(path, &taken) }
            for index in block.children.indices { walk(&block.children[index], "\(path)-\(index)") }
        }
        walk(&face, "f")
        if var design = board { walk(&design.root, "b"); board = design }
    }

    // MARK: - Files

    func parseFiles(_ raw: JSONValue?) -> [String: String]? {
        guard let raw else { return nil }
        guard let members = raw.members else {
            report.error("files", "files is an object of file names and their text, such as {\"prs.py\": \"…\"}, not \(raw.typeName).")
            return nil
        }
        if members.count > SpriteFolders.maximumFiles {
            report.error("files", "A sprite carries at most \(SpriteFolders.maximumFiles) files; this one has \(members.count).")
        }
        var files: [String: String] = [:]
        // This Mac's disk ignores case in file names: "Run.sh" and "run.sh" would be one file, and which text
        // survived would be chance.
        var folded: [String: String] = [:]
        for member in members {
            let path = "files[\"\(member.key)\"]"
            guard SpriteFolders.isValidName(member.key) else {
                report.error(path, "“\(member.key)” is not a file name a sprite may use: letters, digits, ., _ and -, not starting with a dot (no folders).")
                continue
            }
            if let first = folded[member.key.lowercased()] {
                report.error(path, "“\(member.key)” and “\(first)” are the same file on this Mac, which ignores case in file names.", hint: "use one name")
                continue
            }
            folded[member.key.lowercased()] = member.key
            guard let text = member.value.string else {
                report.error(path, "A file's content is text, not \(member.value.typeName).")
                continue
            }
            if text.utf8.count > SpriteFolders.maximumFileBytes {
                report.error(path, "A file is at most \(SpriteFolders.maximumFileBytes / 1024) KiB; this one is \(text.utf8.count / 1024) KiB.")
                continue
            }
            files[member.key] = text
        }
        return files
    }

    /// Every command of a sprite that carries files runs in its folder.
    static func setDirectory(_ directory: String?, in design: inout SpriteDesign) {
        for index in design.variables.indices {
            if case .command(var command) = design.variables[index].source {
                command.directory = directory
                design.variables[index].source = .command(command)
            }
        }
        func walk(_ block: inout BoardBlock) {
            block.command?.directory = directory
            for index in block.children.indices { walk(&block.children[index]) }
        }
        if var board = design.board { walk(&board.root); design.board = board }
    }

    /// A chart draws history, and a command value only the board shows runs only while the board is open.
    func checkCommandCharts(face: DesignNode, rules: [SpriteRule]) {
        let running = Set(face.flattened.flatMap(\.referencedVariables) + rules.flatMap(\.referencedVariables))
        for chart in commandCharts where !running.contains(chart.variable) {
            report.warning(chart.path, "This chart has no history to draw while the board is closed: its command value runs only while the board is open.",
                           hint: "add \"background\": true to the value \(chart.variable)")
        }
    }
}
