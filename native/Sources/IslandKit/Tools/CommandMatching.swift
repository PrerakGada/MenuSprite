import Foundation

/// Something the Command Bar can find: an app or a MenuSprite action. Its text is folded once, when
/// the candidate is made, so ranking on every keystroke only compares strings.
public struct CommandCandidate: Equatable, Sendable {
    public let title: String
    let foldedTitle: String
    let words: [String]
    let haystack: String

    public init(title: String, keywords: [String] = []) {
        self.title = title
        foldedTitle = CommandMatcher.fold(title)
        let folded = [foldedTitle] + keywords.map(CommandMatcher.fold)
        haystack = folded.joined(separator: " ")
        words = folded.flatMap(CommandMatcher.words)
    }
}

/// Ranks candidates for a typed query. Matching ignores case, accents and character width with no
/// locale, strips invisible formatting characters and collapses runs of spaces. Every typed word must
/// land somewhere, in any order: a whole word scores 140, the start of a word 80, anywhere else 44.
/// The whole query then earns a bonus against the title: 1200 for the exact title, 900 for its start,
/// 700 anywhere in it. Ties keep the candidates' own order, and at most twelve rows come back.
public enum CommandMatcher {
    public static let limit = 12

    public static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if scalar.properties.generalCategory == .format { continue }
            if scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace { scalars.append(" "); pendingSpace = false }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Words split at anything that is not a letter or a digit.
    static func words(_ folded: String) -> [String] {
        folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The candidate's score for a query, or nil when some typed word does not match.
    public static func score(_ candidate: CommandCandidate, query: String) -> Int? {
        let whole = fold(query)
        let tokens = whole.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        var total = 0
        for token in tokens {
            if candidate.words.contains(token) { total += 140 }
            else if candidate.words.contains(where: { $0.hasPrefix(token) }) { total += 80 }
            else if candidate.haystack.contains(token) { total += 44 }
            else { return nil }
        }
        if candidate.foldedTitle == whole { total += 1200 }
        else if candidate.foldedTitle.hasPrefix(whole) { total += 900 }
        else if candidate.foldedTitle.contains(whole) { total += 700 }
        return total
    }

    /// Indices of the best matches, best first. An empty query matches nothing: the bar shows its
    /// action list instead.
    public static func rank(_ candidates: [CommandCandidate], query: String, limit: Int = limit) -> [Int] {
        let scored = candidates.enumerated().compactMap { index, candidate in
            score(candidate, query: query).map { (index, $0) }
        }
        let sorted = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return sorted.prefix(limit).map(\.0)
    }
}

/// A key press in the Command Bar, as the pure rules see it. `character` is the key without
/// modifiers, so ⌥ never disguises ⌘Q as another letter.
public enum CommandBarKey: Equatable, Sendable {
    case up, down, returnKey, escape
    case character(String)
}

public enum CommandBarKeyAction: Equatable, Sendable {
    case moveUp, moveDown, run, escape
    /// ⌘1–⌘9: run that row (zero-based).
    case runRow(Int)
    /// ⌘Q, ⌘W, ⌘M and ⌘H would quit, close, minimise or hide MenuSprite itself; the bar eats them.
    case swallow
    /// Typing, editing shortcuts, and everything while an input method is composing.
    case passThrough
}

public enum CommandBarKeys {
    static let swallowed: Set<String> = ["q", "w", "m", "h"]

    public static func action(_ key: CommandBarKey, command: Bool = false, control: Bool = false,
                              option: Bool = false, composing: Bool = false) -> CommandBarKeyAction {
        guard !composing else { return .passThrough }
        switch key {
        case .up: return .moveUp
        case .down: return .moveDown
        case .returnKey: return .run
        case .escape: return .escape
        case .character(let text):
            let letter = text.lowercased()
            if control, !command, !option {
                if letter == "p" { return .moveUp }
                if letter == "n" { return .moveDown }
            }
            if command, !control {
                if let digit = Int(letter), (1...9).contains(digit) { return .runRow(digit - 1) }
                if swallowed.contains(letter) { return .swallow }
            }
            return .passThrough
        }
    }

    /// Moving the selection wraps at both ends.
    public static func move(_ selection: Int?, by offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let selection else { return offset >= 0 ? 0 : count - 1 }
        return ((selection + offset) % count + count) % count
    }
}

/// Stamps each opening of the bar so work started for one opening (the app scan) is dropped if it
/// finishes after the bar closed or opened again.
public struct CommandBarPresentations: Sendable {
    public private(set) var current = 0
    public private(set) var isVisible = false

    public init() {}

    public mutating func begin() -> Int {
        current += 1
        isVisible = true
        return current
    }

    public mutating func end() { isVisible = false }

    public func accepts(_ presentation: Int) -> Bool { isVisible && presentation == current }
}

/// Installed apps from the scan: one per resolved bundle path, never MenuSprite itself, sorted by
/// name so ties in ranking read alphabetically.
public enum CommandAppList {
    public struct Entry: Equatable, Sendable {
        public var path: String
        public var name: String
        public init(path: String, name: String) { self.path = path; self.name = name }
    }

    /// `entries` carry already-resolved paths (symbolic links followed).
    public static func unique(_ entries: [Entry], excluding own: String?) -> [Entry] {
        var seen = Set<String>()
        let kept = entries.filter { entry in
            let key = entry.path.lowercased()
            guard entry.path != own, seen.insert(key).inserted else { return false }
            return true
        }
        return kept.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether a path from the scan is inside another bundle (a helper app shipped within an app).
    public static func isInsidePackage(_ path: String) -> Bool {
        let parts = path.split(separator: "/").dropLast()
        return parts.contains { $0.hasSuffix(".app") || $0.hasSuffix(".bundle") || $0.hasSuffix(".framework") }
    }
}
