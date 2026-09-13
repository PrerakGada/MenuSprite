import Foundation
import Testing
import SQLite3
@testable import WorkTracking

private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private let now = instant("2026-09-12T13:00:00Z")

@Test func midnightIsClippedAndSplitInIST() {
    let entry = WorkInterval(start: instant("2026-09-11T18:00:00Z"), end: instant("2026-09-11T19:00:00Z"), seconds: 1800, project: "Example Project")
    let projects = WorkReport.projects([entry], preferences: WorkPreferences(), range: WorkReport.range(.today, now: now), now: now)
    #expect(projects.count == 1)
    #expect(projects[0].seconds == 900)
    let all = WorkReport.projects([entry], preferences: WorkPreferences(), range: WorkReport.range(.all, now: now), now: now)
    let days = WorkReport.daily(all)
    #expect(days.count == 2)
    #expect(days.map(\.seconds) == [900, 900])
    #expect(days.reduce(0) { $0 + $1.seconds } == all[0].seconds)
}

@Test func futureTimeAndNonoverlappingIntervalsAreExcluded() {
    let entry = WorkInterval(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600), seconds: 1800, project: "A")
    #expect(WorkReport.clipped(entry, to: WorkReport.range(.today, now: now), now: now)?.seconds == 900)
    #expect(WorkReport.clipped(entry, to: DateInterval(start: now.addingTimeInterval(-7200), end: entry.start), now: now) == nil)
}

@Test func billingNeverInventsRatesOrCombinesProjectIdentities() {
    let a = WorkInterval(start: now.addingTimeInterval(-3600), end: now, seconds: 1800, project: "Shared", client: "A")
    let b = WorkInterval(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600), seconds: 3600, project: "Shared", client: "B")
    var preferences = WorkPreferences()
    var rows = WorkReport.projects([a, b], preferences: preferences, range: WorkReport.range(.all, now: now), now: now)
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { !$0.billable && $0.amount == nil })
    preferences.projects[a.projectID] = WorkProjectSettings(client: "Client A", billable: true)
    preferences.projects[b.projectID] = WorkProjectSettings(billable: true)
    preferences.rates["Client A"] = WorkRate(hourly: 5000, currency: "INR")
    rows = WorkReport.projects([a, b], preferences: preferences, range: WorkReport.range(.all, now: now), now: now)
    #expect(rows.first { $0.id == a.projectID }?.amount == 2500)
    #expect(rows.first { $0.id == b.projectID }?.amount == nil)
    #expect(rows.reduce(0) { $0 + $1.seconds } == 5400)
}

@Test func settingsRoundTripAndCorruptionIsNotReset() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("settings.json")
    var preferences = WorkPreferences(sourcePath: "fixture.db")
    preferences.rates["Client"] = WorkRate(hourly: Decimal(string: "2500.25")!, currency: "INR")
    preferences.manual = [WorkInterval(start: now.addingTimeInterval(-900), end: now, seconds: 900, project: "Meeting", note: "Review", manual: true)]
    try WorkRepository.savePreferences(preferences, to: url)
    let loaded = try WorkRepository.loadPreferences(url)
    #expect(loaded.rates == preferences.rates)
    #expect(loaded.manual == preferences.manual)
    try Data("broken".utf8).write(to: url)
    #expect(throws: WorkFailure.self) { try WorkRepository.loadPreferences(url) }
    #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
}

@Test func manualTimeRejectsReversedFutureAndEmptyEntries() throws {
    let valid = WorkInterval(start: now.addingTimeInterval(-900), end: now, seconds: 900, project: "A", note: "Call", manual: true)
    try WorkRepository.validateManual(valid, now: now)
    var entry = valid; entry.end = entry.start
    #expect(throws: WorkFailure.self) { try WorkRepository.validateManual(entry, now: now) }
    entry = valid; entry.note = " "
    #expect(throws: WorkFailure.self) { try WorkRepository.validateManual(entry, now: now) }
    entry = valid; entry.end = now.addingTimeInterval(100)
    #expect(throws: WorkFailure.self) { try WorkRepository.validateManual(entry, now: now) }
}

@Test func exportPreservesQuotesMultilineAndNeutralizesFormulaInjection() {
    let entry = WorkInterval(start: now.addingTimeInterval(-60), end: now, seconds: 60, project: "=SUM(A1)", client: "A,\"B\"", note: "A\nB", manual: true)
    let range = WorkReport.range(.all, now: now)
    let rows = WorkReport.projects([entry], preferences: WorkPreferences(), range: range, now: now)
    let csv = WorkReport.csv(rows, range: range, detail: true)
    #expect(csv.contains("\"'=SUM(A1)\""))
    #expect(csv.contains("\"A,\"\"B\"\"\""))
    #expect(csv.contains("\"A\nB\""))
    #expect(csv.contains("+05:30"))
    let summary = WorkReport.csv(rows, range: range, detail: false)
    #expect(summary.contains("\"Non-billable\""))
    #expect(summary.contains("\"Not connected\""))
}

@Test func readerIncludesWALAndNeverWritesSource() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("source.db")
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE intervals(id INTEGER,start_ts REAL,end_ts REAL,active_seconds REAL,project TEXT,client TEXT,path TEXT,attribution TEXT); INSERT INTO intervals VALUES(1,100,200,50,'A',NULL,'/test','rule');", nil, nil, nil) == SQLITE_OK)
    let before = try Data(contentsOf: url)
    let walURL = URL(fileURLWithPath: url.path + "-wal")
    let wal = try Data(contentsOf: walURL)
    let result = try WorkRepository.read(url)
    #expect(result.count == 1)
    #expect(result.entries[0].seconds == 50)
    #expect(result.entries[0].client == "")
    #expect(try Data(contentsOf: url) == before)
    #expect(try Data(contentsOf: walURL) == wal)
    #expect(sqlite3_exec(db, "INSERT INTO intervals VALUES(2,100,200,-1,'A',NULL,'/test','rule');", nil, nil, nil) == SQLITE_OK)
    #expect(throws: WorkFailure.self) { try WorkRepository.read(url) }
}
