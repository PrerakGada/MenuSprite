import Foundation

/// Byte-level helpers for session logs: a cheap search before any JSON decoding, and an ISO-8601
/// timestamp reader that needs no formatter on the hot path.
public enum AgentBytes {
    public static func contains(_ line: Data, _ needle: StaticString) -> Bool {
        offset(of: needle, in: line) != nil
    }

    static func offset(of needle: StaticString, in line: Data) -> Int? {
        let length = needle.utf8CodeUnitCount
        guard length > 0, line.count >= length else { return nil }
        return line.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress,
                  let found = memmem(base, raw.count, needle.utf8Start, length) else { return nil }
            return base.distance(to: UnsafeRawPointer(found))
        }
    }

    /// The first top-level-looking `"timestamp":"…"` value on a line. A key inside a JSON string is
    /// escaped, so a raw match is always structural.
    public static func timestamp(in line: Data) -> Date? {
        guard let start = offset(of: "\"timestamp\":\"", in: line) else { return nil }
        let from = line.startIndex + start + 13
        let end = min(line.endIndex, from + 40)
        guard from < end, let close = line[from..<end].firstIndex(of: 0x22) else { return nil }
        return AgentTimestamp.parse(line[from..<close])
    }
}

/// ISO-8601 with optional fractional seconds and a `Z` or ±HH:MM offset, parsed to UTC by hand.
public enum AgentTimestamp {
    public static func parse<C: Collection>(_ text: C) -> Date? where C.Element == UInt8 {
        let bytes = Array(text)
        guard bytes.count >= 19 else { return nil }
        func number(_ at: Int, _ length: Int) -> Int? {
            guard at + length <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[at..<at + length] {
                guard (0x30...0x39).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        guard bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54 || bytes[10] == 0x20, bytes[13] == 0x3A, bytes[16] == 0x3A,
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var index = 19
        var fraction = 0.0
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            var scale = 0.1
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                fraction += Double(bytes[index] - 0x30) * scale
                scale /= 10
                index += 1
            }
        }
        var offset = 0
        if index < bytes.count {
            switch bytes[index] {
            case 0x5A, 0x7A: break
            case 0x2B, 0x2D:
                let sign = bytes[index] == 0x2B ? 1 : -1
                guard let hours = number(index + 1, 2) else { return nil }
                let minutes = index + 3 < bytes.count && bytes[index + 3] == 0x3A ? number(index + 4, 2) : number(index + 3, 2)
                offset = sign * (hours * 3600 + (minutes ?? 0) * 60)
            default: return nil
            }
        }
        let seconds = daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

/// One live Claude Code session as its own registry file (`~/.claude/sessions/<pid>.json`) states
/// it. Only what the island shows is kept: no prompt or message text.
public struct ClaudeRegistryRecord: Equatable, Sendable {
    public var pid: Int32
    public var sessionID: String
    public var directory: String?
    public var name: String?
    public var nameSource: String?
    /// Claude Code's own word: "busy", "idle", "shell"…, or nil from versions that do not write one.
    public var status: String?
    /// When `status` last changed: the start of a busy turn, the end of one.
    public var statusChangedAt: Date?

    public init(pid: Int32, sessionID: String, directory: String? = nil, name: String? = nil, nameSource: String? = nil,
                status: String? = nil, statusChangedAt: Date? = nil) {
        self.pid = pid; self.sessionID = sessionID; self.directory = directory; self.name = name
        self.nameSource = nameSource; self.status = status; self.statusChangedAt = statusChangedAt
    }

    public var isBusy: Bool { status == "busy" }
    /// A rename the person made; other names are Claude Code's own slugs.
    public var userTitle: String? { nameSource == "user" ? name : nil }

    public static func parse(_ data: Data) -> ClaudeRegistryRecord? {
        guard data.count < 65_536, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (json["pid"] as? NSNumber)?.int32Value, let id = json["sessionId"] as? String, !id.isEmpty else { return nil }
        func text(_ key: String) -> String? { (json[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func date(_ key: String) -> Date? { (json[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
        return ClaudeRegistryRecord(pid: pid, sessionID: id, directory: text("cwd"), name: text("name"),
                                    nameSource: text("nameSource"), status: text("status"),
                                    statusChangedAt: date("statusUpdatedAt") ?? date("updatedAt"))
    }
}

/// One response's usage, as a log line reports it.
public struct AgentResponse: Equatable, Sendable {
    public enum Stop: Equatable, Sendable {
        /// Tool use, or no stop yet: work continues.
        case working
        /// The reply ended the turn.
        case completed
        /// An API error or a synthetic reply ended the turn: nothing to announce.
        case failed
    }

    public var key: String
    public var model: String
    public var tokens: AgentTokens
    public var time: Date?
    public var stop: Stop
    /// A subagent's reply: it adds spend but never ends the turn it serves.
    public var isSidechain: Bool

    public init(key: String, model: String, tokens: AgentTokens, time: Date?, stop: Stop, isSidechain: Bool = false) {
        self.key = key; self.model = model; self.tokens = tokens; self.time = time; self.stop = stop; self.isSidechain = isSidechain
    }
}

/// What one Claude Code transcript line means for the island.
public enum ClaudeLogEvent: Equatable, Sendable {
    case response(AgentResponse)
    /// The person's own prompt: a turn starts at this time.
    case prompt(Date?)
    /// The person interrupted, or a local command ran: the turn ends with nothing to announce.
    case interrupted(Date?)
    /// Anything else with a time: tool results, attachments, progress.
    case activity(Date)
    case title(String, isCustom: Bool)
}

public enum ClaudeLogLine {
    static let endReasons: Set<String> = ["end_turn", "stop_sequence", "max_tokens", "refusal"]

    /// Classifies one line. A cheap byte search picks the few lines worth decoding; tool results are
    /// never decoded.
    public static func classify(_ line: Data) -> ClaudeLogEvent? {
        if AgentBytes.contains(line, "\"type\":\"assistant\"") { return assistant(line) }
        if AgentBytes.contains(line, "\"type\":\"user\"") { return user(line) }
        if AgentBytes.contains(line, "\"type\":\"custom-title\"") || AgentBytes.contains(line, "\"type\":\"ai-title\"") {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            if json["type"] as? String == "custom-title", let title = json["customTitle"] as? String, !title.isEmpty {
                return .title(title, isCustom: true)
            }
            if json["type"] as? String == "ai-title", let title = json["aiTitle"] as? String, !title.isEmpty {
                return .title(title, isCustom: false)
            }
            return nil
        }
        return AgentBytes.timestamp(in: line).map(ClaudeLogEvent.activity)
    }

    private static func assistant(_ line: Data) -> ClaudeLogEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              json["type"] as? String == "assistant", let message = json["message"] as? [String: Any] else {
            return AgentBytes.timestamp(in: line).map(ClaudeLogEvent.activity)
        }
        let time = (json["timestamp"] as? String).flatMap { AgentTimestamp.parse(Array($0.utf8)) }
        let model = (message["model"] as? String) ?? ""
        let usage = message["usage"] as? [String: Any] ?? [:]
        var tokens = AgentTokens(input: int(usage["input_tokens"]), cacheRead: int(usage["cache_read_input_tokens"]),
                                 output: int(usage["output_tokens"]))
        let writes = int(usage["cache_creation_input_tokens"])
        if let creation = usage["cache_creation"] as? [String: Any] {
            tokens.cacheWrite1h = int(creation["ephemeral_1h_input_tokens"])
            tokens.cacheWrite5m = creation["ephemeral_5m_input_tokens"] != nil
                ? int(creation["ephemeral_5m_input_tokens"]) : max(0, writes - tokens.cacheWrite1h)
        } else {
            tokens.cacheWrite5m = writes
        }
        let synthetic = model.isEmpty || model.hasPrefix("<")
        if synthetic { tokens = AgentTokens() }
        let stop: AgentResponse.Stop
        if let reason = message["stop_reason"] as? String, endReasons.contains(reason) {
            stop = (json["isApiErrorMessage"] as? Bool == true || synthetic) ? .failed : .completed
        } else {
            stop = .working
        }
        let id = message["id"] as? String ?? ""
        let request = json["requestId"] as? String ?? ""
        let key = id.isEmpty && request.isEmpty
            ? "\(json["sessionId"] as? String ?? "")\u{0}\(json["timestamp"] as? String ?? "")"
            : "\(id)\u{0}\(request)"
        return .response(AgentResponse(key: key, model: synthetic ? "" : model, tokens: tokens, time: time, stop: stop,
                                        isSidechain: json["isSidechain"] as? Bool == true))
    }

    private static func user(_ line: Data) -> ClaudeLogEvent? {
        let time = AgentBytes.timestamp(in: line)
        // Meta lines, subagent prompts and tool results only mean work continues.
        if AgentBytes.contains(line, "\"isMeta\":true") || AgentBytes.contains(line, "\"isSidechain\":true")
            || AgentBytes.contains(line, "\"tool_result\"") {
            return time.map(ClaudeLogEvent.activity)
        }
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              json["type"] as? String == "user", let message = json["message"] as? [String: Any] else {
            return time.map(ClaudeLogEvent.activity)
        }
        let text: String
        if let plain = message["content"] as? String {
            text = plain
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            text = ""
        }
        let trimmed = text.drop { $0.isWhitespace }
        if trimmed.hasPrefix("[Request interrupted by user") || trimmed.hasPrefix("<local-command-std") {
            return .interrupted(time)
        }
        if trimmed.isEmpty { return time.map(ClaudeLogEvent.activity) }
        return .prompt(time)
    }

    static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return max(0, number.intValue) }
        if let text = value as? String { return max(0, Int(text) ?? 0) }
        return 0
    }
}

/// What one Codex session-log line means for the island.
public enum CodexLogEvent: Equatable, Sendable {
    case session(directory: String?)
    case context(model: String?, directory: String?)
    /// One response's own usage record.
    case usage(key: String, tokens: AgentTokens, time: Date?)
    /// Older logs: running totals, with the last response's own usage when logged.
    case totals(last: AgentTokens?, total: AgentTokens?, time: Date?)
    case started(Date?)
    /// The task finished, with Codex's own measured duration.
    case completed(at: Date?, duration: Double?)
    case aborted(Date?)
}

public enum CodexLogLine {
    /// `includeTotals` false skips the running-total lines, which a log with per-response records
    /// never needs decoded.
    public static func classify(_ line: Data, includeTotals: Bool = true) -> CodexLogEvent? {
        let kinds: [StaticString] = ["\"token_usage_record\"", "\"session_meta\"", "\"turn_context\"", "\"task_started\"",
                                     "\"task_complete\"", "\"turn_aborted\""]
        guard kinds.contains(where: { AgentBytes.contains(line, $0) })
                || (includeTotals && AgentBytes.contains(line, "\"token_count\"")),
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = json["payload"] as? [String: Any] else { return nil }
        let time = (json["timestamp"] as? String).flatMap { AgentTimestamp.parse(Array($0.utf8)) }
        func text(_ key: String) -> String? { (payload[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch json["type"] as? String {
        case "session_meta":
            return .session(directory: text("cwd"))
        case "turn_context":
            return .context(model: text("model"), directory: text("cwd"))
        case "token_usage_record":
            guard let usage = payload["usage"] as? [String: Any] else { return nil }
            let key = text("response_id") ?? "\(text("turn_id") ?? "")\u{0}\(json["timestamp"] as? String ?? "")"
            return .usage(key: key, tokens: tokens(usage), time: time)
        case "event_msg":
            switch payload["type"] as? String {
            case "task_started":
                return .started(seconds(payload["started_at"]) ?? time)
            case "task_complete":
                let duration = (payload["duration_ms"] as? NSNumber).map { $0.doubleValue / 1000 }
                return .completed(at: seconds(payload["completed_at"]) ?? time, duration: duration)
            case "turn_aborted":
                return .aborted(time)
            case "token_count":
                let info = payload["info"] as? [String: Any]
                let last = (info?["last_token_usage"] as? [String: Any]).map(tokens)
                let total = (info?["total_token_usage"] as? [String: Any]).map(tokens)
                guard last != nil || total != nil else { return nil }
                return .totals(last: last, total: total, time: time)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Codex counts cached input and cache writes inside `input_tokens`, and reasoning inside
    /// `output_tokens` (its total is input plus output), so both are split out once.
    static func tokens(_ usage: [String: Any]) -> AgentTokens {
        let cached = ClaudeLogLine.int(usage["cached_input_tokens"])
        let writes = ClaudeLogLine.int(usage["cache_write_input_tokens"])
        return AgentTokens(input: max(0, ClaudeLogLine.int(usage["input_tokens"]) - cached - writes),
                           cacheWrite5m: writes, cacheRead: cached, output: ClaudeLogLine.int(usage["output_tokens"]))
    }

    /// Unix seconds or milliseconds.
    static func seconds(_ value: Any?) -> Date? {
        guard let number = (value as? NSNumber)?.doubleValue, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
    }
}
