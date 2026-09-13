import Foundation

public struct WorkInterval: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var start: Date
    public var end: Date
    public var seconds: Double
    public var project: String
    public var client: String
    public var path: String
    public var attribution: String
    public var note: String
    public var manual: Bool

    public init(id: String = UUID().uuidString, start: Date, end: Date, seconds: Double,
                project: String, client: String = "", path: String = "", attribution: String = "manual",
                note: String = "", manual: Bool = false) {
        self.id = id; self.start = start; self.end = end; self.seconds = seconds
        self.project = project; self.client = client; self.path = path
        self.attribution = attribution; self.note = note; self.manual = manual
    }
    public var projectID: String { WorkReport.projectID(project: project, client: client) }
}

public struct WorkProjectSettings: Codable, Sendable, Equatable {
    public var client: String?
    public var billable: Bool
    public init(client: String? = nil, billable: Bool = false) { self.client = client; self.billable = billable }
}

public struct WorkRate: Codable, Sendable, Equatable {
    public var hourly: Decimal
    public var currency: String
    public init(hourly: Decimal, currency: String) { self.hourly = hourly; self.currency = currency }
}

public struct WorkPreferences: Codable, Sendable {
    public var sourcePath: String
    public var projects: [String: WorkProjectSettings] = [:]
    public var rates: [String: WorkRate] = [:]
    public var manual: [WorkInterval] = []
    public init(sourcePath: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/paneclock/paneclock.db").path) {
        self.sourcePath = sourcePath
    }
}

public struct WorkProject: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let originalClient: String
    public let client: String
    public let seconds: Double
    public let manualSeconds: Double
    public let billable: Bool
    public let rate: WorkRate?
    public let entries: [WorkInterval]
    public var amount: Decimal? { billable ? rate.map { WorkReport.roundMoney(Decimal(seconds / 3600) * $0.hourly) } : nil }
}

public enum WorkPeriod: String, CaseIterable, Sendable {
    case today = "Today", week = "This week", month = "This month", all = "All history", custom = "Custom"
}

public enum WorkReport {
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        calendar.firstWeekday = 2
        return calendar
    }
    public static func projectID(project: String, client: String) -> String { "\(project.utf8.count):\(project)\(client)" }
    public static func range(_ period: WorkPeriod, now: Date = Date(), from: Date = Date(), through: Date = Date()) -> DateInterval {
        let c = calendar
        let today = c.startOfDay(for: now)
        let tomorrow = c.date(byAdding: .day, value: 1, to: today)!
        switch period {
        case .today: return DateInterval(start: today, end: tomorrow)
        case .week: return DateInterval(start: c.dateInterval(of: .weekOfYear, for: now)!.start, end: tomorrow)
        case .month: return DateInterval(start: c.dateInterval(of: .month, for: now)!.start, end: tomorrow)
        case .all: return DateInterval(start: Date(timeIntervalSince1970: 0), end: tomorrow)
        case .custom:
            let start = c.startOfDay(for: from)
            return DateInterval(start: start, end: c.date(byAdding: .day, value: 1, to: max(start, c.startOfDay(for: through)))!)
        }
    }
    /// Source intervals have aggregate active seconds, not per-second presence. At boundaries,
    /// prorate the recorded activity by the intersecting wall time, exactly as paneclock does.
    public static func clipped(_ entry: WorkInterval, to range: DateInterval, now: Date) -> WorkInterval? {
        let start = max(entry.start, range.start), end = min(entry.end, range.end, now)
        let wall = entry.end.timeIntervalSince(entry.start)
        guard wall > 0, end > start, entry.seconds > 0 else { return nil }
        var result = entry
        result.start = start; result.end = end
        result.seconds = entry.seconds * end.timeIntervalSince(start) / wall
        return result
    }
    public static func projects(_ source: [WorkInterval], preferences: WorkPreferences, range: DateInterval, now: Date = Date()) -> [WorkProject] {
        let entries = (source + preferences.manual).compactMap { clipped($0, to: range, now: now) }
        return Dictionary(grouping: entries, by: \.projectID).map { id, entries in
            let first = entries[0], settings = preferences.projects[id] ?? WorkProjectSettings()
            let client = settings.client ?? first.client
            return WorkProject(id: id, name: first.project, originalClient: first.client, client: client,
                               seconds: entries.reduce(0) { $0 + $1.seconds },
                               manualSeconds: entries.filter(\.manual).reduce(0) { $0 + $1.seconds },
                               billable: settings.billable, rate: preferences.rates[client],
                               entries: entries.sorted { $0.start > $1.start })
        }.sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
    }
    public static func daily(_ projects: [WorkProject]) -> [(date: Date, seconds: Double)] {
        var totals: [Date: Double] = [:]
        for entry in projects.flatMap(\.entries) {
            var day = calendar.startOfDay(for: entry.start)
            while day < entry.end {
                let next = calendar.date(byAdding: .day, value: 1, to: day)!
                if let slice = clipped(entry, to: DateInterval(start: day, end: next), now: entry.end) {
                    totals[day, default: 0] += slice.seconds
                }
                day = next
            }
        }
        return totals.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    public static func roundMoney(_ value: Decimal) -> Decimal {
        var value = value, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return rounded
    }
    public static func hours(_ seconds: Double) -> String {
        if seconds > 0 && seconds < 60 { return "<1m" }
        let minutes = Int((max(0, seconds) / 60).rounded())
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }
    public static func money(_ value: Decimal, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency; formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "en_IN")
        return formatter.string(from: value as NSDecimalNumber) ?? "\(currency) \(value)"
    }
    /// Quote all cells and neutralize spreadsheet formulas in user/source text.
    private static func cell(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.first.map { "=+-@".contains($0) } == true ? "'" + raw : raw
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    public static func csv(_ projects: [WorkProject], range: DateInterval, detail: Bool) -> String {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = calendar.timeZone
        var rows: [[String]] = []
        if detail {
            rows.append(["Client", "Project", "Start (IST)", "End (IST)", "Active seconds", "Source", "Attribution", "Billable", "Note"])
            for project in projects {
                for entry in project.entries {
                    rows.append([project.client, project.name, formatter.string(from: entry.start), formatter.string(from: entry.end),
                                 String(format: "%.6f", entry.seconds), entry.manual ? "Manual" : "paneclock", entry.attribution,
                                 project.billable ? "Yes" : "No", entry.note])
                }
            }
        } else {
            rows.append(["Client", "Project", "From (IST)", "Until exclusive (IST)", "Active hours", "Manual hours", "Billable hours", "Hourly rate", "Currency", "Estimated amount", "Rate status", "AI accounting"])
            for p in projects {
                rows.append([p.client, p.name, formatter.string(from: range.start), formatter.string(from: range.end),
                             String(format: "%.9f", p.seconds / 3600), String(format: "%.9f", p.manualSeconds / 3600),
                             String(format: "%.9f", p.billable ? p.seconds / 3600 : 0),
                             p.rate.map { "\($0.hourly)" } ?? "", p.rate?.currency ?? "", p.amount.map { "\($0)" } ?? "",
                             p.billable ? (p.rate == nil ? "Rate not set" : "Estimate") : "Non-billable", "Not connected"])
            }
        }
        return rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
