import Foundation
import Testing
@testable import AIAccounts

// Every test here builds its own log tree in a temporary directory: no real session log is read and no
// real cache is written.

private let indiaCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    return calendar
}()

private func iso(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)!
}

private struct SpendSandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("menusprite-spend-\(UUID().uuidString)")
    var paths: SpendPaths { .sandbox(root: root) }

    func claudeFile(_ name: String, _ lines: [String]) throws {
        try write(paths.claudeProjects.appendingPathComponent("project", isDirectory: true).appendingPathComponent(name), lines)
    }

    func codexFile(_ name: String, _ lines: [String]) throws {
        try write(paths.codexSessions.appendingPathComponent(name), lines)
    }

    func append(_ url: URL, _ line: String) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func write(_ url: URL, _ lines: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func service(now: Date) -> SpendService {
        SpendService(paths: paths, calendar: indiaCalendar, now: { now }, refreshInterval: 0)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func claudeLine(id: String, request: String, model: String, timestamp: String,
                        input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                        write5m: Int = 0, write1h: Int = 0, splitCache: Bool = true) -> String {
    var usage: [String: Any] = ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": cacheRead]
    if splitCache {
        usage["cache_creation"] = ["ephemeral_5m_input_tokens": write5m, "ephemeral_1h_input_tokens": write1h]
    } else {
        usage["cache_creation_input_tokens"] = write5m
    }
    let object: [String: Any] = ["type": "assistant", "timestamp": timestamp, "requestId": request,
                                 "message": ["id": id, "model": model, "usage": usage]]
    return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

private func codexLine(response: String, timestamp: String, input: Int, cached: Int, output: Int,
                       reasoning: Int = 0, cumulative: Int) -> String {
    let object: [String: Any] = [
        "type": "token_usage_record", "timestamp": timestamp,
        "payload": ["response_id": response,
                    "usage": ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": 0,
                              "output_tokens": output, "reasoning_output_tokens": reasoning,
                              "total_tokens": input + output + reasoning],
                    // Cumulative siblings: counting these instead would multiply the totals.
                    "turn_token_usage": ["input_tokens": cumulative, "output_tokens": cumulative, "total_tokens": cumulative * 2],
                    "thread_token_usage": ["input_tokens": cumulative, "output_tokens": cumulative, "total_tokens": cumulative * 2]]
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

private func codexModelLine(_ model: String, timestamp: String) -> String {
    let object: [String: Any] = ["type": "turn_context", "timestamp": timestamp, "payload": ["model": model]]
    return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

@Test func claudePricesEachTokenClassAtItsOwnRate() async throws {
    let box = SpendSandbox(); defer { box.cleanup() }
    let now = iso("2026-09-13T12:00:00.000Z")
    try box.claudeFile("a.jsonl", [claudeLine(id: "m1", request: "r1", model: "claude-opus-5",
                                              timestamp: "2026-09-13T10:00:00.000Z",
                                              input: 1_000, output: 500, cacheRead: 2_000, write5m: 100)])
    let summary = try #require(await box.service(now: now).scanNow(.claude))
    // input 1000×$5 + 5m write 100×$5×1.25 + read 2000×$0.50 + output 500×$25, per million.
    #expect(abs(summary.today - 0.019125) < 1e-9)
    #expect(summary.tokensToday == 3_600)
    #expect(summary.unpricedModels.isEmpty)
    #expect(summary.topModels.first?.id == "claude-opus-5")
}

/// One-hour cache writes bill at twice the input rate, five-minute writes at 1.25×. The two TTLs
/// dominate different corpora, and an earlier build priced both at 1.25× and understated every total.
@Test func cacheWriteTTLsBillAtTheirOwnMultiples() {
    #expect(ModelPricing.cacheWrite5mMultiplier == 1.25)
    #expect(ModelPricing.cacheWrite1hMultiplier == 2.0)
    let write5m = try! #require(ModelPricing.cost(TokenBreakdown(cacheWrite5m: 1_000_000), model: "claude-opus-5"))
    let write1h = try! #require(ModelPricing.cost(TokenBreakdown(cacheWrite1h: 1_000_000), model: "claude-opus-5"))
    #expect(abs(write5m - 6.25) < 1e-9)
    #expect(abs(write1h - 10.0) < 1e-9)
    // Fable 5.1 reads cache at a published flat rate rather than the standard tenth of input.
    let fableRead = try! #require(ModelPricing.cost(TokenBreakdown(cacheRead: 1_000_000), model: "claude-fable-5-1"))
    let opusRead = try! #require(ModelPricing.cost(TokenBreakdown(cacheRead: 1_000_000), model: "claude-opus-5"))
    #expect(abs(fableRead - 0.25) < 1e-9)
    #expect(abs(opusRead - 0.5) < 1e-9)
}

@Test func repeatedAndReplayedRequestsAreCountedOnce() async throws {
    let box = SpendSandbox(); defer { box.cleanup() }
    let now = iso("2026-09-13T12:00:00.000Z")
    let line = claudeLine(id: "m1", request: "r1", model: "claude-opus-5",
                          timestamp: "2026-09-13T10:00:00.000Z", input: 1_000, output: 0)
    // The same request appears twice in its own file and again in a resumed session's file.
    try box.claudeFile("a.jsonl", [line, line])
    try box.claudeFile("b.jsonl", [line])
    let service = box.service(now: now)
    let summary = try #require(await service.scanNow(.claude))
    #expect(summary.tokensToday == 1_000)
    #expect(abs(summary.today - 0.005) < 1e-9)
    let stats = try #require(await service.statistics(.claude))
    #expect(stats.eventsCounted == 1)
    #expect(stats.duplicatesSkipped == 1)
}

@Test func syntheticWorkCountsTokensAtNoCost() async throws {
    let box = SpendSandbox(); defer { box.cleanup() }
    let now = iso("2026-09-13T12:00:00.000Z")
    try box.claudeFile("a.jsonl", [claudeLine(id: "m1", request: "r1", model: "<synthetic>",
                                              timestamp: "2026-09-13T10:00:00.000Z", input: 900, output: 100)])
    let summary = try #require(await box.service(now: now).scanNow(.claude))
    #expect(summary.today == 0)
    #expect(summary.tokensToday == 1_000)
    #expect(summary.unpricedModels.isEmpty)
}

@Test func datedModelIDsResolveAndUnknownOnesStayUnpriced() async throws {
    let box = SpendSandbox(); defer { box.cleanup() }
    let now = iso("2026-09-13T12:00:00.000Z")
    try box.claudeFile("a.jsonl", [
        claudeLine(id: "m1", request: "r1", model: "claude-haiku-4-5-20251001",
                   timestamp: "2026-09-13T10:00:00.000Z", input: 1_000_000, output: 0),
        claudeLine(id: "m2", request: "r2", model: "claude-imaginary-9",
                   timestamp: "2026-09-13T10:05:00.000Z", input: 2_000, output: 1_000)
    ])
    let summary = try #require(await box.service(now: now).scanNow(.claude))
    #expect(abs(summary.today - 1.0) < 1e-9)                 // haiku input is $1 per million
    #expect(summary.tokensToday == 1_003_000)                 // unpriced tokens still counted
    #expect(summary.unpricedModels == ["claude-imaginary-9"])
    #expect(ModelPricing.cost(TokenBreakdown(input: 10), model: "claude-imaginary-9") == nil)
}

@Test func codexCountsEachRequestOnceAndNeverItsRunningTotals() async throws {
    let box = SpendSandbox(); defer { box.cleanup() }
    let now = iso("2026-09-13T12:00:00.000Z")
    try box.codexFile("s1.jsonl", [
        codexModelLine("gpt-6-astra", timestamp: "2026-09-13T09:00:00.000Z"),
        codexLine(response: "resp1", timestamp: "2026-09-13T09:01:00.000Z", input: 1_000, cached: 400, output: 200, cumulative: 1_200),
        codexLine(response: "resp2", timestamp: "2026-09-13T09:02:00.000Z", input: 1_500, cached: 600, output: 300, cumulative: 3_000),
        // A repeat of the same response id: Codex can log a record twice.
        codexLine(response: "resp2", timestamp: "2026-09-13T09:02:00.000Z", input: 1_500, cached: 600, output: 300, cumulative: 3_000)
    ])
    let service = box.service(now: now)
    let summary = try #require(await service.scanNow(.codex))
    // 1000+200 and 1500+300: the cumulative dictionaries would have reported 4,200 input alone.
    #expect(summary.tokensToday == 3_000)
    #expect(summary.today == 0)
    #expect(summary.unpricedModels == ["gpt-6-astra"])
    #expect(summary.topModels.first?.tokens == 3_000)
}

@Test func daysFollowTheLocalClock() async throws {
    let box = SpendSandbox(); defer { box.cleanup() }
    // 18:35 UTC is 00:05 next day in Asia/Kolkata, so these two lines fall on different local days.
    try box.claudeFile("a.jsonl", [
        claudeLine(id: "m1", request: "r1", model: "claude-opus-5", timestamp: "2026-09-12T18:20:00.000Z", input: 1_000),
        claudeLine(id: "m2", request: "r2", model: "claude-opus-5", timestamp: "2026-09-12T18:40:00.000Z", input: 3_000)
    ])
    let summary = try #require(await box.service(now: iso("2026-09-13T04:00:00.000Z")).scanNow(.claude))
    #expect(summary.tokensToday == 3_000)
    #expect(summary.tokens30Days == 4_000)
    #expect(abs(summary.today - 0.015) < 1e-9)
    #expect(abs(summary.last30Days - 0.02) < 1e-9)
}

@Test func unchangedFilesAreNeverReadTwice() async throws {
    let box = SpendSandbox(); defer { box.cleanup() }
    let now = iso("2026-09-13T12:00:00.000Z")
    try box.claudeFile("a.jsonl", [claudeLine(id: "m1", request: "r1", model: "claude-opus-5",
                                              timestamp: "2026-09-13T10:00:00.000Z", input: 1_000)])
    try box.claudeFile("b.jsonl", [claudeLine(id: "m2", request: "r2", model: "claude-opus-5",
                                              timestamp: "2026-09-13T10:01:00.000Z", input: 1_000)])
    let service = box.service(now: now)
    _ = await service.scanNow(.claude)
    let cold = try #require(await service.statistics(.claude))
    #expect(cold.filesRead == 2)
    _ = await service.scanNow(.claude)
    let warm = try #require(await service.statistics(.claude))
    #expect(warm.filesRead == 0)
    #expect(warm.filesReused == 2)

    let changed = box.paths.claudeProjects.appendingPathComponent("project/b.jsonl")
    try box.append(changed, claudeLine(id: "m3", request: "r3", model: "claude-opus-5",
                                       timestamp: "2026-09-13T10:02:00.000Z", input: 5_000))
    let summary = try #require(await service.scanNow(.claude))
    let incremental = try #require(await service.statistics(.claude))
    #expect(incremental.filesRead == 1)
    #expect(summary.tokensToday == 7_000)
}

/// What the app carries between scans must be the aggregate alone. The per-file records and the
/// ownership index belong in the scan-state file, which is the only one allowed to grow with history.
@Test func onlyTheAggregateSurvivesAScan() async throws {
    let box = SpendSandbox(); defer { box.cleanup() }
    let now = iso("2026-09-13T12:00:00.000Z")
    for index in 0..<30 {
        try box.claudeFile("file\(index).jsonl", (0..<20).map {
            claudeLine(id: "m\(index)-\($0)", request: "r\(index)-\($0)", model: "claude-opus-5",
                       timestamp: "2026-09-13T10:00:00.000Z", input: 100)
        })
    }
    let service = box.service(now: now)
    _ = await service.scanNow(.claude)

    let summaryBytes = try #require(try FileManager.default.attributesOfItem(atPath: box.paths.summaryFile.path)[.size] as? Int)
    let stateBytes = try #require(try FileManager.default.attributesOfItem(atPath: box.paths.scanStateFile.path)[.size] as? Int)
    // One day, one model: the aggregate cannot grow with the number of files, and the state must.
    #expect(summaryBytes < 2_000)
    #expect(stateBytes > summaryBytes)

    // A fresh service reads only the aggregate and still answers without scanning.
    let restarted = SpendService(paths: box.paths, calendar: indiaCalendar, now: { now }, refreshInterval: 86_400)
    let summary = try #require(await restarted.summary(.claude, force: false))
    #expect(summary.tokensToday == 30 * 20 * 100)
    #expect(await restarted.statistics(.claude) == nil)       // answered from the aggregate, no scan run
}

@Test func scanStateSurvivesABinaryRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("menusprite-state-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: url) }
    var state = SpendScanState()
    state.claude.files = [FileRecord(path: "/tmp/a — ünicode.jsonl", size: 12, modified: 1_757_000_000.5,
                                     days: [DayTotals(day: 20_345, models: ["claude-opus-5": TokenBreakdown(input: 1, cacheWrite5m: 2, cacheWrite1h: 3, cacheRead: 4, output: 5)])],
                                     skipped: 7)]
    state.claude.owners = [OwnedKey(hash: .max, owner: 42, day: -1), OwnedKey(hash: 1, owner: 2, day: 20_345)]
    state.claude.scannedAt = 1_757_000_123.25
    state.codex.files = []
    try SpendScanStateStore.save(state, to: url)
    #expect(SpendScanStateStore.load(url) == state)

    // A truncated or foreign file is rebuilt, never half-read.
    try Data("MSSP garbage".utf8).write(to: url)
    #expect(SpendScanStateStore.load(url) == SpendScanState())
}

@Test func aCorruptCacheIsRebuiltRatherThanTrusted() async throws {
    let box = SpendSandbox(); defer { box.cleanup() }
    let now = iso("2026-09-13T12:00:00.000Z")
    try box.claudeFile("a.jsonl", [claudeLine(id: "m1", request: "r1", model: "claude-opus-5",
                                              timestamp: "2026-09-13T10:00:00.000Z", input: 1_000)])
    try FileManager.default.createDirectory(at: box.paths.summaryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a property list".utf8).write(to: box.paths.summaryFile)
    try Data("not scan state".utf8).write(to: box.paths.scanStateFile)
    let summary = try #require(await box.service(now: now).scanNow(.claude))
    #expect(summary.tokensToday == 1_000)
}

@Test func oversizedLinesAreSkippedNotParsed() async throws {
    let box = SpendSandbox(); defer { box.cleanup() }
    let now = iso("2026-09-13T12:00:00.000Z")
    let huge = "{\"type\":\"assistant\",\"filler\":\"" + String(repeating: "x", count: SpendLogScanner.maxLineBytes + 16) + "\"}"
    try box.claudeFile("a.jsonl", [huge, claudeLine(id: "m1", request: "r1", model: "claude-opus-5",
                                                    timestamp: "2026-09-13T10:00:00.000Z", input: 1_000)])
    let service = box.service(now: now)
    let summary = try #require(await service.scanNow(.claude))
    #expect(summary.tokensToday == 1_000)
    let stats = try #require(await service.statistics(.claude))
    #expect(stats.linesSkipped >= 1)
}

@Test func aCancelledScanLeavesTheServiceUsable() async throws {
    let box = SpendSandbox(); defer { box.cleanup() }
    let now = iso("2026-09-13T12:00:00.000Z")
    for index in 0..<40 {
        try box.claudeFile("file\(index).jsonl", (0..<50).map {
            claudeLine(id: "m\(index)-\($0)", request: "r\(index)-\($0)", model: "claude-opus-5",
                       timestamp: "2026-09-13T10:00:00.000Z", input: 10)
        })
    }
    let service = box.service(now: now)
    let task = Task { await service.scanNow(.claude) }
    task.cancel()
    _ = await task.value
    let summary = try #require(await service.scanNow(.claude))
    #expect(summary.tokensToday == 40 * 50 * 10)
}

@Test func spendPathsStayInsideTheirSandbox() {
    let root = URL(fileURLWithPath: "/tmp/menusprite-test")
    let paths = SpendPaths.sandbox(root: root)
    #expect(paths.claudeProjects.path.hasPrefix(root.path))
    #expect(paths.codexSessions.path.hasPrefix(root.path))
    #expect(paths.summaryFile.path.hasPrefix(root.path))
    #expect(paths.scanStateFile.path.hasPrefix(root.path))
    #expect(SpendPaths.standard.claudeProjects.lastPathComponent == "projects")
    #expect(SpendPaths.standard.summaryFile.lastPathComponent == "ai-spend-summary.plist")
}
