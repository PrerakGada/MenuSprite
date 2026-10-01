import AgentProtocol
import Foundation
import SystemMonitoring

/// Every problem found in one pass over a spec. An agent fixes a whole list at once far more cheaply than
/// one problem per try, so the compiler keeps reading after an error and refuses the sprite only at the end.
final class SpecReport {
    private(set) var diagnostics: [SpecDiagnostic] = []
    var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
    func error(_ path: String, _ message: String, hint: String? = nil) { diagnostics.append(.error(path, message, hint: hint)) }
    func warning(_ path: String, _ message: String, hint: String? = nil) { diagnostics.append(.warning(path, message, hint: hint)) }

    /// A "did you mean" compares a word with every candidate. Past this many, a diagnostic still says what is
    /// wrong but goes without one, so a spec full of mistakes cannot keep the app busy (compiling runs on the
    /// main actor). An agent fixes the first fifty and is told about the rest on the next try.
    private var hintBudget = 50
    func hint(_ word: String, in candidates: @autoclosure () -> [String], format: (String) -> String = { $0 }) -> String? {
        guard hintBudget > 0 else { return nil }
        hintBudget -= 1
        return Fuzzy.hint(word, in: candidates(), format: format)
    }
    func matches(_ word: String, in candidates: @autoclosure () -> [String], limit: Int = 3) -> [String] {
        guard hintBudget > 0 else { return [] }
        hintBudget -= 1
        return Fuzzy.matches(word, in: candidates(), limit: limit)
    }
}

/// Paths into the document the agent wrote: `values[3].every`, `board.blocks[2].card[0]`.
enum SpecPath {
    static func key(_ base: String, _ key: String) -> String { base.isEmpty ? key : "\(base).\(key)" }
    static func index(_ base: String, _ index: Int) -> String { "\(base)[\(index)]" }
}

/// One JSON object being read: typed accessors that report a wrong type at the key's own path, and a
/// closing check that warns about keys nothing read. A null counts as absent, as agents often write it.
struct SpecObject {
    let members: [JSONMember]
    let path: String
    let report: SpecReport

    init?(_ value: JSONValue, path: String, report: SpecReport, what: String) {
        guard case .object(let members) = value else {
            report.error(path, "\(what) is an object ({…}), not \(value.typeName).")
            return nil
        }
        self.members = members; self.path = path; self.report = report
    }

    var keys: [String] { members.map(\.key) }
    func path(_ key: String) -> String { SpecPath.key(path, key) }
    /// The value as written, null included.
    func raw(_ key: String) -> JSONValue? { members.first { $0.key == key }?.value }
    /// The value, or nil when it is absent or null. (Not written with `flatMap { … ? nil : $0 }`: JSONValue is
    /// nil-literal-expressible, so that `nil` would be `.null` and a null would count as present.)
    subscript(_ key: String) -> JSONValue? {
        guard let value = raw(key), !value.isNull else { return nil }
        return value
    }

    func string(_ key: String) -> String? {
        guard let value = self[key] else { return nil }
        if let text = value.string { return text }
        report.error(path(key), "“\(key)” takes text in quotes, not \(value.typeName).")
        return nil
    }
    func number(_ key: String) -> Double? {
        guard let value = self[key] else { return nil }
        if let number = value.number { return number }
        report.error(path(key), "“\(key)” takes a number, not \(value.typeName).")
        return nil
    }
    func bool(_ key: String) -> Bool? {
        guard let value = self[key] else { return nil }
        if let flag = value.bool { return flag }
        report.error(path(key), "“\(key)” takes true or false, not \(value.typeName).")
        return nil
    }

    /// Warns about each key outside `allowed`, with the closest allowed key as a hint. `notes` explains keys
    /// that belong somewhere else rather than nowhere.
    func checkKeys(_ allowed: [String], what: String, notes: [String: String] = [:]) {
        for member in members where !allowed.contains(member.key) && !member.value.isNull {
            let key = member.key
            if let note = notes[key] { report.warning(path(key), note); continue }
            report.warning(path(key), "“\(key)” is not a property of \(what), so it is ignored.",
                           hint: SpecKeys.suggestion(for: key, among: allowed, report: report))
        }
    }
}

enum SpecKeys {
    /// Words agents reach for that the spec spells differently (folded: lowercase, letters and digits only).
    static let aliases: [String: String] = [
        "colour": "color", "symbol": "icon", "sfsymbol": "icon", "sfimage": "icon", "systemimage": "icon",
        "interval": "every", "refreshinterval": "every", "fontsize": "size", "fontweight": "weight", "bold": "weight",
        "visible": "hidden", "maximum": "max", "shrinktofit": "shrink", "backgroundcolor": "background",
        "bg": "background", "items": "blocks", "condition": "when", "if": "when", "actions": "then",
        "otherwise": "else", "branches": "cases", "elseif": "cases", "spacingbetween": "gap", "label": "name",
        "textstyle": "font", "command": "run", "url": "open", "href": "open", "link": "open", "application": "app",
        "showheader": "header", "visibleinmenubar": "menuBar", "showinmenubar": "menuBar", "menubar": "menuBar"
    ]
    static func suggestion(for key: String, among allowed: [String], report: SpecReport) -> String? {
        let folded = key.lowercased().filter { $0.isLetter || $0.isNumber }
        if let alias = aliases[folded], allowed.contains(alias), alias != key { return "did you mean \(alias)?" }
        if ["type", "kind"].contains(folded) {
            return "a node or block names its kind by its key, e.g. {\"text\": \"…\"} or {\"gauge\": \"cpu\"}"
        }
        return report.hint(key, in: allowed)
    }
}

/// "Did you mean" for keys, reading ids, value ids and targets.
///
/// Bounded, because it runs on the app's main actor for whatever an agent sends: a word longer than any real
/// key or id gets no hint, a candidate whose length differs by more than the threshold is never compared,
/// and the comparison keeps three rows rather than a whole table.
enum Fuzzy {
    /// No key, reading id or value id is longer than this (the longest reading id has 27 characters).
    static let longestWord = 64

    /// Edits between two words, a swap of neighbours counting as one ("widht", "fnot"): the typos agents and
    /// people actually make.
    static func distance(_ a: String, _ b: String) -> Int {
        distance(Array(a.lowercased()), Array(b.lowercased()))
    }
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        // Rows i-2, i-1 and i: the swap step reads two rows back.
        var before = [Int](repeating: 0, count: b.count + 1), previous = Array(0...b.count), current = before
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { current[j] = Swift.min(current[j], before[j - 2] + 1) }
            }
            (before, previous, current) = (previous, current, before)
        }
        return previous[b.count]
    }

    /// Up to `limit` candidates close to `word`: near spellings, or failing those, names containing it
    /// ("cpu" → cpu.usage, cpu.user…).
    static func matches(_ word: String, in candidates: [String], limit: Int = 3) -> [String] {
        let lower = word.lowercased()
        guard !lower.isEmpty, lower.count <= longestWord else { return [] }
        let letters = Array(lower)
        let threshold = max(1, min(3, letters.count / 3))
        var close: [(name: String, score: Int)] = [], containing: [String] = []
        var seen: Set<String> = []
        for candidate in candidates where seen.insert(candidate).inserted {
            let other = candidate.lowercased()
            let otherLetters = Array(other)
            if abs(otherLetters.count - letters.count) <= threshold, case let d = distance(letters, otherLetters), d <= threshold {
                close.append((candidate, d))
            } else if other.contains(lower) || (other.count >= 3 && lower.contains(other)) {
                containing.append(candidate)
            }
        }
        if !close.isEmpty {
            return close.sorted { ($0.score, $0.name.count, $0.name) < ($1.score, $1.name.count, $1.name) }.prefix(limit).map(\.name)
        }
        return containing.sorted { ($0.count, $0) < ($1.count, $1) }.prefix(limit).map { $0 }
    }

    static func hint(_ word: String, in candidates: [String], format: (String) -> String = { $0 }) -> String? {
        let found = matches(word, in: candidates)
        return found.isEmpty ? nil : "did you mean \(list(found.map(format)))?"
    }

    static func list(_ items: [String], conjunction: String = "or") -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " \(conjunction) " + items.last!
    }
}

/// Seconds as a number, or "30s", "5m", "1h", "1d".
enum SpecDuration {
    /// Longest suffix first, so "second" is not read as a number of days ending in "d".
    private static let units: [(String, Double)] = [
        ("hours", 3600), ("hour", 3600), ("hrs", 3600), ("hr", 3600), ("h", 3600),
        ("minutes", 60), ("minute", 60), ("mins", 60), ("min", 60), ("m", 60),
        ("seconds", 1), ("second", 1), ("secs", 1), ("sec", 1), ("s", 1),
        ("days", 86400), ("day", 86400), ("d", 86400)
    ].sorted { $0.0.count > $1.0.count }
    static func seconds(_ value: JSONValue) -> Double? {
        if let number = value.number { return number }
        guard var text = value.string?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        var scale = 1.0
        for (suffix, factor) in units where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            scale = factor
            break
        }
        guard let number = Double(text), number.isFinite else { return nil }
        return number * scale
    }
    /// "5m", "1h" or "1d" when that is exact, else plain seconds.
    static func json(_ seconds: Double) -> JSONValue {
        guard seconds.isFinite, abs(seconds) < 1e12 else { return .number(seconds) }
        if seconds >= 86400, seconds.truncatingRemainder(dividingBy: 86400) == 0 { return .string("\(Int(seconds / 86400))d") }
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 { return .string("\(Int(seconds / 3600))h") }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 { return .string("\(Int(seconds / 60))m") }
        return .number(seconds)
    }
}

/// Colours as the studio stores them: RRGGBB without "#" (upper case), or one of Apple's system colours by
/// name. A name is kept as a name rather than turned into hex, so it adapts: `SpriteColors` draws it as the
/// system colour for the light or dark bar and board, where a fixed hex chosen for one is too pale on the other.
enum SpecColor {
    static let names = SpriteColors.names
    /// `keywords` are the words the field takes besides colours ("inherit", "auto"; "none" for a background).
    static func parse(_ text: String, keywords: [String]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if keywords.contains(lower) { return lower }
        if lower == "grey" { return "gray" }
        if names.contains(lower) { return lower }
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return digits.uppercased()
    }
    /// Names and keywords as they are; hex with its "#", so it reads back as the same hex (writing FF453A as
    /// "red" would turn a fixed colour into the adaptive one).
    static func json(_ stored: String) -> JSONValue {
        if ["inherit", "auto", "none"].contains(stored) || names.contains(stored) { return .string(stored) }
        let upper = stored.uppercased()
        return .string(upper.count == 6 && upper.allSatisfy(\.isHexDigit) ? "#" + upper : stored)
    }
}

enum SpecFormat {
    /// A number as JSON writes it: no ".0" on whole numbers.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : "\(value)"
    }
}

/// What a spec leaves out. Compile starts from these and emit drops whatever still equals them, so both
/// sides must agree; they follow what the studio itself gives a new piece, so a studio-made sprite reads short.
enum SpecDefaults {
    static let symbol = "gauge.with.dots.needle.50percent"
    static let spriteInterval: Double = 2
    static let spriteIntervals: [Double] = [1, 2, 5, 10, 30, 60]
    static let boardWidth: Double = 360
    static let command = CommandSource()
    /// The longest command that runs whole: the runtime cuts commands at this length, so the compiler refuses
    /// a longer one rather than let a script lose its end without a word.
    static let commandLength = CommandSource.maximumCommandLength
    /// A command value's `every`: 2 s to a day.
    static let commandIntervals: ClosedRange<Double> = 2...CommandSource.longestInterval
    /// A board action's `timeout`: 1 s to 10 minutes.
    static let actionTimeouts: ClosedRange<Double> = 1...BoardAction.longestTimeout
    /// Size limits for a spec. Far above any real sprite, they keep one request from freezing the app (the
    /// compile runs on the main actor) or saving a sprite whose drawing would crawl.
    static let valueLimit = 100
    static let pieceLimit = 500

    /// Columns stack two lines in a 22 pt bar, so they sit closer than rows; the root keeps 3 pt of padding.
    static func nodeStyle(_ kind: DesignNodeKind, root: Bool) -> NodeStyle {
        var style = NodeStyle()
        if kind == .column { style.gap = 1.5 }
        if root && kind.isContainer { style.padding = 3 }
        return style
    }
    static func blockStyle(_ kind: BoardBlockKind) -> BoardStyle {
        var style = BoardStyle()
        switch kind {
        case .chart: style.height = 44
        case .output: style.height = 90
        case .image: style.height = 120
        case .energy: style.height = 640
        case .accounts: style.height = 520
        case .processes: style.limit = 8
        case .spacer: style.spacing = 12
        default: break
        }
        return style
    }
    /// The board's own stack, as `BoardDesign()` makes it.
    static var rootBoardStyle: BoardStyle { BoardBlock.stack([]).style }
    static func blockName(_ kind: BoardBlockKind) -> String { kind == .stack || kind == .row ? "" : kind.title }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
