import AppKit
import UniformTypeIdentifiers
import WorkTracking

@MainActor
final class WorkStore: ObservableObject {
    @Published private(set) var source: [WorkInterval] = []
    @Published private(set) var preferences = WorkPreferences()
    @Published private(set) var projects: [WorkProject] = []
    @Published private(set) var loading = false
    @Published private(set) var lastRecorded: Date?
    @Published private(set) var loadedAt: Date?
    @Published var error: String?
    @Published var notice: String?
    @Published var period: WorkPeriod = .month { didSet { rebuild() } }
    @Published var from = WorkReport.calendar.startOfDay(for: Date()) { didSet { rebuild() } }
    @Published var through = Date() { didSet { rebuild() } }
    @Published var client: String?
    @Published var search = ""
    @Published var selectedProject: String?
    @Published var showManual = false
    @Published var billingProject: WorkProject?
    @Published var showSource = false
    @Published var showAI = false
    @Published private(set) var removedEntry: WorkInterval?
    private let preferencesURL: URL
    private var settingsReadable = true
    private var refreshTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private(set) var isOpen = false

    init(preferencesURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MenuSprite/work-report.json")) {
        self.preferencesURL = preferencesURL
        do { preferences = try WorkRepository.loadPreferences(preferencesURL) }
        catch { settingsReadable = false; self.error = error.localizedDescription }
        rebuild()
    }
    var range: DateInterval {
        let range = WorkReport.range(period, from: from, through: through)
        guard period == .all else { return range }
        guard let first = (source + preferences.manual).map(\.start).min() else { return WorkReport.range(.today) }
        return DateInterval(start: WorkReport.calendar.startOfDay(for: first), end: range.end)
    }
    var filtered: [WorkProject] {
        projects.filter {
            (client == nil || $0.client == client) && (search.isEmpty || "\($0.name) \($0.client)".localizedStandardContains(search))
        }
    }
    var clients: [String] { Set(projects.map(\.client).filter { !$0.isEmpty }).sorted() }
    var selected: WorkProject? { filtered.first { $0.id == selectedProject } }
    var tracked: Double { filtered.reduce(0) { $0 + $1.seconds } }
    var billable: Double { filtered.filter(\.billable).reduce(0) { $0 + $1.seconds } }
    var unassigned: Double { projects.filter { $0.client.isEmpty }.reduce(0) { $0 + $1.seconds } }
    var unrated: Int { filtered.filter { $0.billable && $0.rate == nil }.count }
    var amountSummary: String {
        var totals: [String: Decimal] = [:]
        for project in filtered { if let amount = project.amount, let rate = project.rate { totals[rate.currency, default: 0] += amount } }
        return totals.isEmpty ? "No priced work" : totals.sorted { $0.key < $1.key }.map { WorkReport.money($0.value, currency: $0.key) }.joined(separator: " + ")
    }
    func opened() {
        guard !isOpen else { return }
        isOpen = true; refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                self?.refresh()
            }
        }
    }
    func closed() {
        isOpen = false; refreshTask?.cancel(); refreshTask = nil
        loadTask?.cancel(); loadTask = nil
        source = []; projects = []; loading = false
    }
    func refresh(sourcePath: String? = nil) {
        guard settingsReadable else { return }
        loadTask?.cancel(); loading = true
        let path = sourcePath ?? preferences.sourcePath
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<WorkSnapshot, Error> in
                Result { try WorkRepository.read(URL(fileURLWithPath: path)) }
            }.value
            guard !Task.isCancelled, let self else { return }
            loading = false
            switch result {
            case .success(let snapshot):
                if sourcePath != nil {
                    var next = preferences; next.sourcePath = path
                    guard persist(next) else { return }
                }
                source = snapshot.entries; lastRecorded = snapshot.lastRecorded; loadedAt = Date(); error = nil
                rebuild()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    func rebuild() {
        projects = WorkReport.projects(source, preferences: preferences, range: range)
    }
    @discardableResult private func persist(_ next: WorkPreferences) -> Bool {
        guard settingsReadable else { return false }
        do { try WorkRepository.savePreferences(next, to: preferencesURL); preferences = next; rebuild(); return true }
        catch { self.error = "Changes were not saved: \(error.localizedDescription)"; return false }
    }
    @discardableResult func configure(_ project: WorkProject, client: String, billable: Bool, hourly: String, currency: String) -> Bool {
        let client = client.trimmingCharacters(in: .whitespacesAndNewlines)
        let hourly = hourly.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !billable || !client.isEmpty else { error = "Assign a client before marking this project billable."; return false }
        var next = preferences
        next.projects[project.id] = WorkProjectSettings(client: client, billable: billable)
        if !hourly.isEmpty {
            guard hourly.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
                  let rate = Decimal(string: hourly, locale: Locale(identifier: "en_US_POSIX")), rate >= 0, rate <= 1_000_000_000,
                  !client.isEmpty else { error = "Enter a client and a non-negative hourly rate with up to two decimal places."; return false }
            next.rates[client] = WorkRate(hourly: rate, currency: currency)
        } else { next.rates.removeValue(forKey: client) }
        guard persist(next) else { return false }
        notice = "Saved billing settings for \(project.name)."; return true
    }
    func overlaps(_ entry: WorkInterval) -> Bool {
        (source + preferences.manual).contains { $0.seconds > 0 && $0.start < entry.end && $0.end > entry.start }
    }
    @discardableResult func addManual(_ entry: WorkInterval, allowOverlap: Bool) -> Bool {
        do { try WorkRepository.validateManual(entry) } catch { self.error = error.localizedDescription; return false }
        guard allowOverlap || !overlaps(entry) else { error = "This overlaps recorded time. Review the interval and confirm the overlap before saving."; return false }
        var next = preferences; next.manual.append(entry)
        guard persist(next) else { return false }
        notice = "Added \(WorkReport.hours(entry.seconds)) for \(entry.project)."; return true
    }
    func removeManual(_ id: String) {
        guard let entry = preferences.manual.first(where: { $0.id == id }) else { return }
        var next = preferences; next.manual.removeAll { $0.id == id }
        if persist(next) { removedEntry = entry; notice = "Removed the manual entry." }
    }
    func undoRemove() {
        guard let entry = removedEntry else { return }
        var next = preferences; next.manual.append(entry)
        if persist(next) { removedEntry = nil; notice = "Restored the manual entry." }
    }
    func chooseSource() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Choose paneclock database"; panel.message = "MenuSprite reads the intervals without changing the source database."
        panel.directoryURL = URL(fileURLWithPath: preferences.sourcePath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        refresh(sourcePath: url.path)
    }
    func export(detail: Bool) {
        guard !filtered.isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "MenuSprite-\(detail ? "time-entries" : "work-report")-\(Self.day(range.start)).csv"
        panel.title = "Export \(detail ? "time entries" : "project summary")"
        panel.message = "Exports the current client, search and date filters. Amounts are estimates. AI accounting is not connected."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try WorkReport.csv(filtered, range: range, detail: detail).write(to: url, atomically: true, encoding: .utf8)
            notice = "Exported \(url.lastPathComponent)."
        } catch { self.error = "Export failed: \(error.localizedDescription)" }
    }
    static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.calendar = WorkReport.calendar; f.timeZone = WorkReport.calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
