import Foundation

/// One billable request found in a log, already reduced to the fields spend needs. The hash identifies
/// the request so a replay of the same request — in this file or another — is only ever counted once.
struct ScanEvent: Sendable, Equatable {
    var hash: UInt64
    var day: Int32
    var model: String
    var tokens: TokenBreakdown
}

struct ScanResult: Sendable, Equatable {
    var events: [ScanEvent] = []
    /// Lines too large to be worth parsing; counted so the docs can be honest about what was skipped.
    var skipped = 0
}

/// Reads the CLIs' JSONL session logs. Streams line by line, parses only the lines that can carry
/// usage, and never retains log text.
enum SpendLogScanner {
    /// A single line larger than this is media or a pathological paste, not a usage record.
    static let maxLineBytes = 2 * 1024 * 1024
    private static let chunkBytes = 1 << 20

    static func scan(_ url: URL, provider: AIProvider, calendar: Calendar) throws -> ScanResult {
        switch provider {
        case .claude: return try scanClaude(url, calendar: calendar)
        case .codex: return try scanCodex(url, calendar: calendar)
        }
    }

    // MARK: Claude

    /// Assistant lines carry `message.usage`. The same request appears more than once — about 2.2 lines
    /// per request in these logs — so events are keyed by `(message.id, requestId)` and merged.
    static func scanClaude(_ url: URL, calendar: Calendar) throws -> ScanResult {
        var result = ScanResult()
        var byKey: [UInt64: ScanEvent] = [:]
        try forEachLine(url, skipped: &result.skipped) { line in
            guard contains(line, "\"usage\""), contains(line, "\"assistant\"") else { return }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let timestamp = (object["timestamp"] as? String).flatMap(CredentialJSON.date(iso8601:)),
                  let day = dayNumber(timestamp, calendar: calendar) else { return }
            let model = (message["model"] as? String) ?? "unknown"
            // A line without a requestId still identifies its request by message id alone.
            let key = hash("\(message["id"] as? String ?? "")\u{0}\(object["requestId"] as? String ?? "")")
            var tokens = TokenBreakdown(input: int(usage["input_tokens"]),
                                        cacheRead: int(usage["cache_read_input_tokens"]),
                                        output: int(usage["output_tokens"]))
            // Newer lines split cache writes by TTL; older ones report one aggregate, billed as 5-minute.
            if let creation = usage["cache_creation"] as? [String: Any] {
                tokens.cacheWrite5m = int(creation["ephemeral_5m_input_tokens"])
                tokens.cacheWrite1h = int(creation["ephemeral_1h_input_tokens"])
            } else {
                tokens.cacheWrite5m = int(usage["cache_creation_input_tokens"])
            }
            guard tokens.total > 0 else { return }
            // Keep the first sighting: repeats of one request carry the same totals.
            if byKey[key] == nil { byKey[key] = ScanEvent(hash: key, day: day, model: model, tokens: tokens) }
        }
        result.events = Array(byKey.values)
        return result
    }

    // MARK: Codex

    /// `token_usage_record.payload.usage` is that request's own usage. The sibling `turn_token_usage`
    /// and `thread_token_usage` are running totals for the turn and thread — summing those would count
    /// every earlier request in the turn again. The model comes from the most recent `turn_context`.
    static func scanCodex(_ url: URL, calendar: Calendar) throws -> ScanResult {
        var result = ScanResult()
        var byKey: [UInt64: ScanEvent] = [:]
        var model = "unknown"
        var sequence = 0
        try forEachLine(url, skipped: &result.skipped) { line in
            guard contains(line, "\"turn_context\"") || contains(line, "\"token_usage_record\"")
                    || contains(line, "\"session_meta\"") else { return }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { return }
            switch object["type"] as? String {
            case "turn_context", "session_meta":
                if let name = payload["model"] as? String, !name.isEmpty { model = name }
            case "token_usage_record":
                guard let usage = payload["usage"] as? [String: Any],
                      let timestamp = (object["timestamp"] as? String).flatMap(CredentialJSON.date(iso8601:)),
                      let day = dayNumber(timestamp, calendar: calendar) else { return }
                // Cached input is reported inside `input_tokens`, so bill the remainder at the input rate.
                let cached = int(usage["cached_input_tokens"])
                let input = max(0, int(usage["input_tokens"]) - cached)
                let tokens = TokenBreakdown(input: input,
                                            cacheWrite5m: int(usage["cache_write_input_tokens"]),
                                            cacheRead: cached,
                                            output: int(usage["output_tokens"]) + int(usage["reasoning_output_tokens"]))
                guard tokens.total > 0 else { return }
                // Records without a response id are still distinct requests; fall back to their order.
                let identity = (payload["response_id"] as? String).map { "r:\($0)" }
                    ?? "o:\(url.lastPathComponent):\(sequence)"
                sequence += 1
                let key = hash(identity)
                if byKey[key] == nil { byKey[key] = ScanEvent(hash: key, day: day, model: model, tokens: tokens) }
            default:
                return
            }
        }
        result.events = Array(byKey.values)
        return result
    }

    // MARK: Reading

    /// Streams the file in bounded chunks. Two details keep a multi-gigabyte corpus affordable: consumed
    /// bytes are dropped once per chunk rather than once per line (per-line removal recopies the whole
    /// buffer), and each chunk is parsed inside an autorelease pool — without one, the Foundation
    /// temporaries from millions of JSON lines accumulate until the process holds gigabytes.
    /// A line longer than `maxLineBytes` is dropped without being parsed or retained.
    private static func forEachLine(_ url: URL, skipped: inout Int, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        var overlong = false
        var dropped = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty else { break }
            buffer.append(chunk)
            try autoreleasepool {
                var cursor = buffer.startIndex
                while let newline = buffer[cursor...].firstIndex(of: 0x0A) {
                    let line = buffer[cursor..<newline]
                    cursor = newline + 1
                    // Either the line arrived whole and is too big to be a usage record, or its tail is
                    // landing after the buffer already overflowed. Both are skipped without parsing.
                    if overlong { overlong = false; dropped += 1; continue }
                    if line.count > maxLineBytes { dropped += 1; continue }
                    if !line.isEmpty { try body(line) }
                }
                if cursor > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<cursor) }
                if buffer.count > maxLineBytes {
                    buffer.removeAll(keepingCapacity: false)
                    overlong = true
                }
            }
        }
        if !overlong, !buffer.isEmpty, buffer.count <= maxLineBytes { try body(buffer) }
        else if overlong { dropped += 1 }
        skipped += dropped
    }

    private static func contains(_ line: Data, _ needle: String) -> Bool {
        line.range(of: Data(needle.utf8)) != nil
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }

    /// Whole days between a fixed local midnight and this date's local midnight, so buckets follow the
    /// user's clock and stay one apart across a daylight-saving shift.
    ///
    /// `Calendar.ordinality(of: .day, in: .era,)` looks like the primitive for this and is not: measured
    /// with an Asia/Kolkata calendar it put two instants on the same local day in different buckets and
    /// two instants on different local days in the same one. `startOfDay` does respect the time zone.
    static func dayNumber(_ date: Date, calendar: Calendar) -> Int32? {
        let reference = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        guard let days = calendar.dateComponents([.day], from: reference,
                                                 to: calendar.startOfDay(for: date)).day else { return nil }
        return Int32(clamping: days)
    }

    /// FNV-1a: a stable 64-bit identity for a request key. Never reversed, never stored as text.
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x1000_0000_01b3
        }
        return value
    }
}
