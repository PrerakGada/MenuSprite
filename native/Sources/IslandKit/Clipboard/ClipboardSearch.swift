import Foundation

/// Search over the history. Each entry's folded text is built once per history change (and reused
/// for entries that did not change), never per keystroke.
public struct ClipboardSearchIndex: Sendable {
    private struct Folded: Sendable {
        var source: ClipboardEntry
        var text: String
    }

    private var folded: [Folded] = []

    public init(entries: [ClipboardEntry] = []) { update(entries) }

    /// Rebuilds for a changed history, keeping the folded text of entries whose content is unchanged.
    public mutating func update(_ entries: [ClipboardEntry]) {
        var previous: [UUID: Folded] = [:]
        for item in folded { previous[item.source.id] = item }
        folded = entries.map { entry in
            if let old = previous[entry.id], Self.sameContent(old.source, entry) {
                return Folded(source: entry, text: old.text)
            }
            return Folded(source: entry, text: Self.fold(Self.searchableText(entry)))
        }
    }

    /// The visible list for a query: with no query, the history's own order; otherwise every token
    /// must match (AND), ranked by score, ties in history order. `pinnedOnly` keeps pinned entries.
    public func results(_ query: String, pinnedOnly: Bool) -> [ClipboardEntry] {
        let candidates = pinnedOnly ? folded.filter { $0.source.isPinned } : folded
        let foldedQuery = Self.fold(query).trimmingCharacters(in: .whitespaces)
        let tokens = foldedQuery.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return candidates.map(\.source) }
        var scored: [(score: Int, index: Int, entry: ClipboardEntry)] = []
        for (index, item) in candidates.enumerated() {
            if let score = Self.score(item.text, pinned: item.source.isPinned, query: foldedQuery, tokens: tokens) {
                scored.append((score, index, item.source))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.map(\.entry)
    }

    /// Pinned +30; the whole query equal +1200, a prefix +900, contained +700; per token +140 for a
    /// whole word, +80 for a word start, +40 otherwise. Nil when any token is missing.
    public static func score(_ text: String, pinned: Bool, query: String, tokens: [String]) -> Int? {
        var score = pinned ? 30 : 0
        for token in tokens {
            guard let match = wordMatch(token, in: text) else { return nil }
            switch match {
            case .whole: score += 140
            case .start: score += 80
            case .inside: score += 40
            }
        }
        if text == query { score += 1200 }
        else if text.hasPrefix(query) { score += 900 }
        else if text.contains(query) { score += 700 }
        return score
    }

    enum WordMatch { case whole, start, inside }

    /// The best way `token` appears in `text`: as a whole word, at a word's start, or inside a word.
    static func wordMatch(_ token: String, in text: String) -> WordMatch? {
        var best: WordMatch?
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: token, range: searchRange) {
            let startsWord = range.lowerBound == text.startIndex || !isWordCharacter(text[text.index(before: range.lowerBound)])
            let endsWord = range.upperBound == text.endIndex || !isWordCharacter(text[range.upperBound])
            if startsWord && endsWord { return .whole }
            if startsWord { best = .start } else if best == nil { best = .inside }
            guard range.lowerBound < text.endIndex else { break }
            searchRange = text.index(after: range.lowerBound)..<text.endIndex
        }
        return best
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Case, diacritics and width folded with no locale; newlines and tabs become spaces.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    /// Images are searchable as "Image", "png" and their size; files by their names.
    public static func searchableText(_ entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .text: entry.text
        case .image: "Image png " + (entry.image.map { "\($0.dimensions) \($0.width)x\($0.height)" } ?? "")
        case .files: entry.files.map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
        }
    }

    private static func sameContent(_ a: ClipboardEntry, _ b: ClipboardEntry) -> Bool {
        a.kind == b.kind && a.text == b.text && a.files == b.files && a.image == b.image
    }
}

/// The keyboard highlight in the list: which row Return activates.
public struct ClipboardHighlight: Equatable, Sendable {
    public private(set) var id: UUID?

    public init(id: UUID? = nil) { self.id = id }

    /// The query or the pinned filter changed: a non-empty query highlights its top result so Return
    /// pastes it; an empty one waits for the first arrow.
    public mutating func restart(results: [UUID], hasQuery: Bool) {
        id = hasQuery ? results.first : nil
    }

    /// ↑ or ↓: the first press (or the first after the row left the list) lands on the top result;
    /// after that it steps and stops at the ends.
    public mutating func move(down: Bool, results: [UUID]) {
        guard let current = id, let index = results.firstIndex(of: current) else { id = results.first; return }
        let next = down ? min(results.count - 1, index + 1) : max(0, index - 1)
        id = results[next]
    }

    /// The list changed under the highlight: a row that disappeared hands the highlight to the top
    /// result when there is a query, otherwise clears it.
    public mutating func reconcile(results: [UUID], hasQuery: Bool) {
        guard let current = id, !results.contains(current) else { return }
        id = hasQuery ? results.first : nil
    }
}

/// ⌘1…⌘9 on the Clipboard page, matched by physical key (ANSI 1–9) so every layout works.
public enum ClipboardQuickKeys {
    public static let keyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// The list position a key press activates, or nil. `commandOnly` means ⌘ is the only modifier
    /// held (Caps Lock and function-key flags aside).
    public static func index(keyCode: UInt16, commandOnly: Bool) -> Int? {
        guard commandOnly else { return nil }
        return keyCodes.firstIndex(of: keyCode)
    }
}
