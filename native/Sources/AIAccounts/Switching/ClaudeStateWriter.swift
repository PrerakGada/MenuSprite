import Foundation

/// Replaces `oauthAccount` in Claude Code's state file and nothing else.
public enum ClaudeStateWriter {
    public enum Outcome: Sendable, Equatable { case replaced, fileMissing, unparsable }

    /// Re-reads the file immediately before writing. Every byte outside the `oauthAccount` value stays
    /// as Claude Code wrote it and the new value follows the file's own indentation. The result is
    /// validated before an atomic replace that keeps the file's mode.
    public static func replaceOAuthAccount(with accountJSON: String, at url: URL) throws -> Outcome {
        guard let account = CredentialJSON.object(from: accountJSON) else {
            throw SwitchingError.file("The saved Claude profile is not a JSON object.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .fileMissing }
        let data = try Data(contentsOf: url)
        guard let original = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unparsable }
        let bytes = [UInt8](data)
        let updated: Data
        if let location = JSONTextScanner.topLevelValue(forKey: "oauthAccount", in: bytes) {
            let value = JSONTextScanner.render(account, indentUnit: location.indentUnit, level: 1)
            updated = Data(bytes[..<location.value.lowerBound]) + Data(value.utf8) + Data(bytes[location.value.upperBound...])
        } else {
            var state = original
            state["oauthAccount"] = account
            updated = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .withoutEscapingSlashes])
        }
        guard let check = (try? JSONSerialization.jsonObject(with: updated)) as? [String: Any],
              let written = check["oauthAccount"] as? [String: Any],
              NSDictionary(dictionary: written).isEqual(to: account),
              check.count == original.count + (original["oauthAccount"] == nil ? 1 : 0) else {
            throw SwitchingError.file("Refused to write ~/.claude.json: the updated file did not validate.")
        }
        try AtomicFile.write(updated, to: url)
        return .replaced
    }
}

/// Just enough JSON scanning to locate one top-level value by byte range.
enum JSONTextScanner {
    struct Location {
        let key: Range<Int>
        let value: Range<Int>
        /// Spaces per level when the file is indented; nil for compact files.
        let indentUnit: Int?
    }

    static func topLevelValue(forKey key: String, in bytes: [UInt8]) -> Location? {
        let target = Array("\"\(key)\"".utf8)
        var index = skipWhitespace(bytes, 0)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
        index += 1
        while true {
            index = skipWhitespace(bytes, index)
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let keyEnd = endOfString(bytes, index) else { return nil }
            let keyRange = index..<keyEnd
            index = skipWhitespace(bytes, keyEnd)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index = skipWhitespace(bytes, index + 1)
            guard let valueEnd = endOfValue(bytes, index) else { return nil }
            if Array(bytes[keyRange]) == target {
                return Location(key: keyRange, value: index..<valueEnd, indentUnit: indentation(bytes, before: keyRange.lowerBound))
            }
            index = skipWhitespace(bytes, valueEnd)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ",") else { return nil }
            index += 1
        }
    }

    /// Renders like `JSON.stringify(value, null, unit)` nested at `level`, or compact without a unit.
    static func render(_ value: Any, indentUnit: Int?, level: Int) -> String {
        guard let unit = indentUnit else { return compact(value) }
        let pad = String(repeating: " ", count: unit * level)
        let inner = String(repeating: " ", count: unit * (level + 1))
        if let object = value as? [String: Any] {
            guard !object.isEmpty else { return "{}" }
            let entries = object.keys.sorted().map { key in
                "\(inner)\(compact(key)): \(render(object[key] as Any, indentUnit: unit, level: level + 1))"
            }
            return "{\n" + entries.joined(separator: ",\n") + "\n" + pad + "}"
        }
        if let array = value as? [Any] {
            guard !array.isEmpty else { return "[]" }
            let items = array.map { inner + render($0, indentUnit: unit, level: level + 1) }
            return "[\n" + items.joined(separator: ",\n") + "\n" + pad + "]"
        }
        return compact(value)
    }

    /// JSONSerialization escapes strings and formats numbers; wrapping in an array allows scalars.
    private static func compact(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return String(text.dropFirst().dropLast())
    }

    private static func indentation(_ bytes: [UInt8], before position: Int) -> Int? {
        var index = position - 1
        var count = 0
        while index >= 0 {
            switch bytes[index] {
            case UInt8(ascii: " "): count += 1
            case UInt8(ascii: "\n"): return count > 0 ? count : nil
            default: return nil
            }
            index -= 1
        }
        return nil
    }

    private static func skipWhitespace(_ bytes: [UInt8], _ start: Int) -> Int {
        var index = start
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        return index
    }

    private static func endOfString(_ bytes: [UInt8], _ start: Int) -> Int? {
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""): return index + 1
            default: index += 1
            }
        }
        return nil
    }

    private static func endOfValue(_ bytes: [UInt8], _ start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return endOfString(bytes, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    guard let end = endOfString(bytes, index) else { return nil }
                    index = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            return nil
        default:
            var index = start
            while index < bytes.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
            return index > start ? index : nil
        }
    }
}
