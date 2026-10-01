import Foundation

/// Any JSON document, with object keys kept in the order they were written, so a spec read back from
/// a sprite prints `menusprite`, `name`, `icon` first rather than alphabetically.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }
    public var members: [JSONMember]? { if case .object(let members) = self { members } else { nil } }
    public var items: [JSONValue]? { if case .array(let items) = self { items } else { nil } }
    public var string: String? { if case .string(let text) = self { text } else { nil } }
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var isNull: Bool { self == .null }
    public var keys: [String] { members?.map(\.key) ?? [] }

    /// The kind of value, as an error message names it.
    public var typeName: String {
        switch self {
        case .null: "null"; case .bool: "a true/false"; case .number: "a number"; case .string: "text"
        case .array: "a list"; case .object: "an object"
        }
    }

    /// An object from ordered pairs, leaving out nil values.
    public static func object(pairs: [(String, JSONValue?)]) -> JSONValue {
        .object(pairs.compactMap { key, value in value.map { JSONMember(key, $0) } })
    }

    /// Replaces or appends `key`, keeping its place if it already exists.
    public mutating func set(_ key: String, _ value: JSONValue?) {
        guard case .object(var members) = self else { return }
        if let index = members.firstIndex(where: { $0.key == key }) {
            if let value { members[index].value = value } else { members.remove(at: index) }
        } else if let value {
            members.append(JSONMember(key, value))
        }
        self = .object(members)
    }
}

public struct JSONMember: Sendable, Equatable, Hashable {
    public var key: String
    public var value: JSONValue
    public init(_ key: String, _ value: JSONValue) { self.key = key; self.value = value }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Parsing

/// Where and why a document is not JSON, in words an agent can act on.
public struct JSONParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public var line: Int
    public var column: Int
    public var description: String { "Not valid JSON at line \(line), column \(column): \(message)" }
}

extension JSONValue {
    public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        if parser.index < parser.bytes.count { throw parser.error("unexpected text after the end of the document") }
        return value
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0
    static let maximumDepth = 128

    init(bytes: [UInt8]) {
        // Tolerate a UTF-8 byte-order mark.
        self.bytes = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(bytes.dropFirst(3)) : bytes
    }

    func error(_ message: String) -> JSONParseError {
        var line = 1, column = 1
        for byte in bytes[..<min(index, bytes.count)] {
            if byte == 0x0A { line += 1; column = 1 } else if byte & 0xC0 != 0x80 { column += 1 }
        }
        return JSONParseError(message: message, line: line, column: column)
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func value(depth: Int) throws -> JSONValue {
        guard depth < Self.maximumDepth else { throw error("nested more than \(Self.maximumDepth) deep") }
        guard index < bytes.count else { throw error("the document ends where a value was expected") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
        case UInt8(ascii: "'"): throw error("strings take double quotes, not single quotes")
        case UInt8(ascii: "/"): throw error("comments are not allowed in JSON")
        default: throw error("unexpected character “\(Character(Unicode.Scalar(bytes[index])))”")
        }
    }

    mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard bytes.count - index >= expected.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw error("expected \(word)")
        }
        index += expected.count
    }

    mutating func object(depth: Int) throws -> JSONValue {
        index += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard index < bytes.count else { throw error("the document ends inside an object") }
            if bytes[index] == UInt8(ascii: "}") { throw error("a comma before “}” (trailing commas are not allowed)") }
            guard bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key in double quotes") }
            let key = try string()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected “:” after the key “\(key)”") }
            index += 1
            skipWhitespace()
            let item = try value(depth: depth + 1)
            // A repeated key keeps the last value, as most parsers do, but in the first one's place.
            if let existing = members.firstIndex(where: { $0.key == key }) { members[existing].value = item }
            else { members.append(JSONMember(key, item)) }
            skipWhitespace()
            guard index < bytes.count else { throw error("the document ends inside an object") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            throw error("expected “,” or “}” after the value of “\(key)”")
        }
    }

    mutating func array(depth: Int) throws -> JSONValue {
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
        while true {
            skipWhitespace()
            guard index < bytes.count else { throw error("the document ends inside a list") }
            if bytes[index] == UInt8(ascii: "]") { throw error("a comma before “]” (trailing commas are not allowed)") }
            items.append(try value(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw error("the document ends inside a list") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw error("expected “,” or “]” in a list")
        }
    }

    mutating func string() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var run = index
        func flush(_ end: Int) { if end > run { scalars.append(contentsOf: String(decoding: bytes[run..<end], as: UTF8.self).unicodeScalars) } }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") { flush(index); index += 1; return String(scalars) }
            if byte < 0x20 {
                throw error(byte == 0x0A ? "a line break inside a string (write it as \\n)" : "a control character inside a string")
            }
            if byte == UInt8(ascii: "\\") {
                flush(index)
                index += 1
                guard index < bytes.count else { break }
                switch bytes[index] {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    // A high surrogate pairs only with a low one that follows at once. The next escape is
                    // looked at, not consumed, so when it is anything else the loop decodes it normally
                    // and only the lone surrogate becomes U+FFFD.
                    if (0xD800...0xDBFF).contains(code), index + 6 < bytes.count,
                       bytes[index + 1] == UInt8(ascii: "\\"), bytes[index + 2] == UInt8(ascii: "u"),
                       let low = UInt32(String(decoding: bytes[index + 3...index + 6], as: UTF8.self), radix: 16),
                       (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        index += 6
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: throw error("unknown escape “\\\(Character(Unicode.Scalar(bytes[index])))”")
                }
                index += 1
                run = index
                continue
            }
            index += 1
        }
        throw error("a string is never closed")
    }

    mutating func hex4() throws -> UInt32 {
        guard index + 4 < bytes.count, let value = UInt32(String(decoding: bytes[index + 1...index + 4], as: UTF8.self), radix: 16) else {
            throw error("\\u needs four hex digits")
        }
        index += 4
        return value
    }

    mutating func number() throws -> Double {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        func digits() -> Int { let begin = index; while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }; return index - begin }
        guard digits() > 0 else { throw error("a number needs digits") }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") { index += 1; guard digits() > 0 else { throw error("a number needs digits after “.”") } }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw error("a number needs digits in its exponent") }
        }
        guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else { throw error("a number out of range") }
        return value
    }
}

// MARK: - Writing

extension JSONValue {
    /// JSON text with keys in their stored order. Pretty output indents by two spaces and keeps short
    /// lists of plain values on one line.
    public func serialized(pretty: Bool = false) -> String {
        var output = ""
        write(to: &output, pretty: pretty, indent: 0)
        return output
    }

    public var data: Data { Data(serialized().utf8) }

    private func write(to output: inout String, pretty: Bool, indent: Int) {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let value): output += Self.format(value)
        case .string(let text): Self.quote(text, into: &output)
        case .array(let items):
            if items.isEmpty { output += "[]"; return }
            let simple = items.allSatisfy { if case .array = $0 { false } else if case .object = $0 { false } else { true } }
            if !pretty || (simple && items.count <= 8) {
                output += "["
                for (offset, item) in items.enumerated() {
                    if offset > 0 { output += pretty ? ", " : "," }
                    item.write(to: &output, pretty: pretty, indent: indent)
                }
                output += "]"
                return
            }
            output += "[\n"
            for (offset, item) in items.enumerated() {
                output += String(repeating: "  ", count: indent + 1)
                item.write(to: &output, pretty: pretty, indent: indent + 1)
                output += offset == items.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: "  ", count: indent) + "]"
        case .object(let members):
            if members.isEmpty { output += "{}"; return }
            if !pretty {
                output += "{"
                for (offset, member) in members.enumerated() {
                    if offset > 0 { output += "," }
                    Self.quote(member.key, into: &output); output += ":"
                    member.value.write(to: &output, pretty: false, indent: 0)
                }
                output += "}"
                return
            }
            output += "{\n"
            for (offset, member) in members.enumerated() {
                output += String(repeating: "  ", count: indent + 1)
                Self.quote(member.key, into: &output); output += ": "
                member.value.write(to: &output, pretty: true, indent: indent + 1)
                output += offset == members.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: "  ", count: indent) + "}"
        }
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    static func quote(_ text: String, into output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 { output += String(format: "\\u%04x", scalar.value) }
                else { output.unicodeScalars.append(scalar) }
            }
        }
        output += "\""
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: Key.self) {
            self = .object(try container.allKeys.map { JSONMember($0.stringValue, try container.decode(JSONValue.self, forKey: $0)) })
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !container.isAtEnd { items.append(try container.decode(JSONValue.self)) }
            self = .array(items)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let members):
            var container = encoder.container(keyedBy: Key.self)
            for member in members { try container.encode(member.value, forKey: Key(member.key)) }
        case .array(let items):
            var container = encoder.unkeyedContainer()
            for item in items { try container.encode(item) }
        case .null:
            var container = encoder.singleValueContainer(); try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer(); try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer(); try container.encode(value)
        case .string(let text):
            var container = encoder.singleValueContainer(); try container.encode(text)
        }
    }

    /// Converts any Codable value through JSON. Object keys come out in the encoder's order.
    public init<T: Encodable>(encoding value: T) throws {
        self = try JSONValue.parse(JSONEncoder().encode(value))
    }

    /// Decodes a Codable value from this JSON.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}
