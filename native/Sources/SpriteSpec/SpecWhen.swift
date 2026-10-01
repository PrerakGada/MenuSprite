import Foundation
import SystemMonitoring

/// The `when` of a rule: `value[.pace] op operand`, joined by ` and ` or by ` or `.
///
/// Operators are `>` `>=` `<` `<=` `==` `!=` `contains`, `is missing` and `is present`. An operand is a
/// number, a quoted string (`'…'` or `"…"`, with `\'` and `\\` escapes) or bare words up to the next
/// `and`/`or`, so `pace == on track` reads as it looks.
enum SpecWhen {
    struct Condition: Equatable {
        var variable: String
        var aspect: VariableAspect
        var comparison: RuleComparison
        var operand: String
    }
    struct Failure: Error {
        var message: String
        var hint: String?
        init(_ message: String, hint: String? = nil) { self.message = message; self.hint = hint }
    }

    private enum Token: Equatable { case word(String), quoted(String), op(String) }
    private static let operatorCharacters: Set<Character> = ["<", ">", "=", "!"]
    static let operatorList = "> >= < <= == != contains, is missing or is present"

    /// The conditions, and how they join: nil when there are fewer than two.
    static func parse(_ text: String) throws(Failure) -> (match: RuleMatch?, conditions: [Condition]) {
        let tokens = try tokenize(text)
        guard !tokens.isEmpty else { return (nil, []) }
        var index = 0, joiner: String?, conditions: [Condition] = []
        func joinWord(_ word: String) -> String? {
            switch word.lowercased() { case "and", "&&": "and"; case "or", "||": "or"; default: nil }
        }
        func isJoiner(_ word: String) -> Bool { joinWord(word) != nil }

        while true {
            guard index < tokens.count, case .word(let subject) = tokens[index] else {
                throw Failure("A condition starts with a value id, as in “cpu > 80”.")
            }
            index += 1
            var variable = subject, aspect = VariableAspect.value
            if let dot = subject.lastIndex(of: ".") {
                let suffix = subject[subject.index(after: dot)...].lowercased()
                if suffix == "pace" { aspect = .pace; variable = String(subject[..<dot]) }
                else if suffix == "value" { variable = String(subject[..<dot]) }
            }
            guard index < tokens.count else { throw Failure("“\(subject)” needs an operator: \(operatorList).") }
            let comparison: RuleComparison
            switch tokens[index] {
            case .op(let op):
                switch op {
                case ">": comparison = .above
                case ">=": comparison = .atLeast
                case "<": comparison = .below
                case "<=": comparison = .atMost
                case "!=": comparison = .notEquals
                default: comparison = .equals
                }
                index += 1
            case .word(let word) where word.lowercased() == "contains":
                comparison = .contains; index += 1
            case .word(let word) where word.lowercased() == "is":
                index += 1
                guard index < tokens.count, case .word(let next) = tokens[index] else {
                    throw Failure("“is” is followed by missing or present.", hint: "compare with == or !=")
                }
                switch next.lowercased() {
                case "missing", "unavailable": comparison = .isMissing
                case "present", "available": comparison = .isPresent
                default: throw Failure("“is \(next)” is not a test: write “is missing” or “is present”.", hint: "compare with == or !=")
                }
                index += 1
            default:
                throw Failure("After “\(subject)” comes an operator: \(operatorList).")
            }
            var operand = ""
            if comparison.needsOperand {
                guard index < tokens.count else { throw Failure("“\(subject)” is compared with nothing.", hint: "add a number or a 'quoted' text") }
                if case .quoted(let quoted) = tokens[index] {
                    operand = quoted; index += 1
                } else {
                    var words: [String] = []
                    while index < tokens.count, case .word(let word) = tokens[index], !(isJoiner(word) && !words.isEmpty) {
                        words.append(word); index += 1
                    }
                    if index < tokens.count, case .op(let op) = tokens[index] {
                        throw Failure("“\(op)” cannot appear in a value to compare with.", hint: "quote it: '…'")
                    }
                    guard !words.isEmpty else { throw Failure("“\(subject)” is compared with nothing.", hint: "add a number or a 'quoted' text") }
                    operand = words.joined(separator: " ")
                }
            }
            conditions.append(Condition(variable: variable, aspect: aspect, comparison: comparison, operand: operand))
            guard index < tokens.count else { break }
            guard case .word(let word) = tokens[index], isJoiner(word) else {
                throw Failure("Conditions are joined by “and” or “or”.", hint: "quote a value that contains spaces or operators")
            }
            let lower = joinWord(word) ?? word
            if let joiner, joiner != lower {
                throw Failure("A when joins its conditions with “and” or with “or”, not both.",
                              hint: "split it into cases, or into two rules")
            }
            joiner = lower
            index += 1
            guard index < tokens.count else { throw Failure("Nothing follows “\(word)”.") }
        }
        return (conditions.count < 2 ? nil : (joiner == "or" ? .any : .all), conditions)
    }

    private static func tokenize(_ text: String) throws(Failure) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            if character == "'" || character == "\"" {
                var value = "", closed = false
                index += 1
                while index < characters.count {
                    if characters[index] == "\\", index + 1 < characters.count, characters[index + 1] == "\\" || characters[index + 1] == character {
                        value.append(characters[index + 1]); index += 2; continue
                    }
                    if characters[index] == character { closed = true; index += 1; break }
                    value.append(characters[index]); index += 1
                }
                guard closed else { throw Failure("A quote (\(character)) is never closed.") }
                tokens.append(.quoted(value))
                continue
            }
            if operatorCharacters.contains(character) {
                var op = String(character)
                index += 1
                if index < characters.count, characters[index] == "=" { op.append("="); index += 1 }
                guard [">", ">=", "<", "<=", "==", "!=", "="].contains(op) else {
                    throw Failure("“\(op)” is not an operator: \(operatorList).")
                }
                tokens.append(.op(op))
                continue
            }
            var word = ""
            while index < characters.count, !characters[index].isWhitespace, !operatorCharacters.contains(characters[index]),
                  characters[index] != "'", characters[index] != "\"" {
                word.append(characters[index]); index += 1
            }
            tokens.append(.word(word))
        }
        return tokens
    }

    // MARK: - Writing

    static func string(_ branch: RuleBranch) -> String {
        branch.conditions.map { condition in
            let subject = condition.variable + (condition.aspect == .pace ? ".pace" : "")
            switch condition.comparison {
            case .isMissing: return "\(subject) is missing"
            case .isPresent: return "\(subject) is present"
            default: return "\(subject) \(symbol(condition.comparison)) \(operand(condition.operand))"
            }
        }.joined(separator: branch.match == .any ? " or " : " and ")
    }

    static func symbol(_ comparison: RuleComparison) -> String {
        switch comparison {
        case .above: ">"; case .atLeast: ">="; case .below: "<"; case .atMost: "<="
        case .equals: "=="; case .notEquals: "!="; case .contains: "contains"
        case .isMissing: "is missing"; case .isPresent: "is present"
        }
    }

    /// Numbers bare, anything else quoted, so the text reads back exactly.
    static func operand(_ text: String) -> String {
        let plain = !text.isEmpty && Double(text.replacingOccurrences(of: ",", with: ".")) != nil
            && !text.contains { $0.isWhitespace || operatorCharacters.contains($0) || $0 == "'" || $0 == "\"" }
        if plain { return text }
        let quote: Character = text.contains("'") && !text.contains("\"") ? "\"" : "'"
        var result = String(quote)
        for character in text {
            if character == "\\" || character == quote { result.append("\\") }
            result.append(character)
        }
        result.append(quote)
        return result
    }
}
