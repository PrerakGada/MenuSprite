import Foundation
import SQLite3

public struct WorkFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct WorkSnapshot: Sendable {
    public var entries: [WorkInterval]
    public var lastRecorded: Date?
    public var count: Int { entries.count }
}

public enum WorkRepository {
    /// Open read-only, including the live WAL. Never migrate, lock the writer, or copy a bare DB.
    public static func read(_ url: URL) throws -> WorkSnapshot {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw WorkFailure("Cannot read the tracking database. Choose your paneclock.db file and try again.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        var statement: OpaquePointer?
        let sql = "SELECT id,start_ts,end_ts,active_seconds,project,client,path,attribution FROM intervals ORDER BY start_ts"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WorkFailure("This file does not contain readable paneclock intervals. Choose a paneclock database.")
        }
        defer { sqlite3_finalize(statement) }
        func string(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var entries: [WorkInterval] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            let start = sqlite3_column_double(statement, 1), end = sqlite3_column_double(statement, 2)
            let seconds = sqlite3_column_double(statement, 3)
            guard start.isFinite, end.isFinite, seconds.isFinite, end >= start, seconds >= 0,
                  seconds <= end - start + 1 else {
                throw WorkFailure("The source contains an invalid time interval (row \(sqlite3_column_int64(statement, 0))). Its totals need review in paneclock.")
            }
            entries.append(WorkInterval(id: "paneclock:\(sqlite3_column_int64(statement, 0))", start: Date(timeIntervalSince1970: start),
                                        end: Date(timeIntervalSince1970: end), seconds: seconds,
                                        project: string(4).isEmpty ? "Unresolved project" : string(4), client: string(5),
                                        path: string(6), attribution: string(7)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw WorkFailure("The tracking database could not be read completely. Try Refresh; the previous report has been retained.") }
        return WorkSnapshot(entries: entries, lastRecorded: entries.map(\.end).max())
    }
    public static func loadPreferences(_ url: URL) throws -> WorkPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return WorkPreferences() }
        do { return try JSONDecoder().decode(WorkPreferences.self, from: Data(contentsOf: url)) }
        catch { throw WorkFailure("Work settings could not be read. The existing file has been preserved: \(url.path)") }
    }
    public static func savePreferences(_ preferences: WorkPreferences, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: url, options: .atomic)
    }
    public static func validateManual(_ entry: WorkInterval, now: Date = Date()) throws {
        guard !entry.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkFailure("Enter a project and a short description of the work.") }
        guard entry.start < entry.end, entry.end <= now, entry.seconds > 0,
              entry.end.timeIntervalSince(entry.start) <= 24 * 3600,
              abs(entry.seconds - entry.end.timeIntervalSince(entry.start)) < 0.01 else {
            throw WorkFailure("Choose a past time interval of up to 24 hours, with the end after the start.")
        }
    }
}
