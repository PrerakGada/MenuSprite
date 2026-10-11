import AgentProtocol
import Foundation

/// What agents could not build without a change to MenuSprite's code, kept as one JSON line per report or
/// resolution in `barriers.jsonl` beside the sprites' folders (the sandbox keeps its own). Reports of the same
/// missing thing, ignoring case and spacing, are one barrier with a count; a report that arrives after the
/// barrier was resolved opens it again as a new one, since the fix evidently did not cover it.
/// Spec: `docs/agent-authoring.md` ("Barriers").
struct BarrierLog {
    let url: URL
    static let fieldLimit = 1000

    /// Every barrier, open ones first (most recently reported first), then resolved ones.
    func read() -> [Barrier] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        var open: [String: Barrier] = [:], latest: [String: String] = [:], closed: [Barrier] = []
        var order: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let entry = try? JSONValue.parse(String(line)), let id = entry["id"]?.string, let time = entry["time"]?.string else { continue }
            switch entry["type"]?.string {
            case "report":
                guard let report = try? entry.decode(BarrierReport.self) else { continue }
                let key = Self.key(report.missing)
                if var barrier = open[key] {
                    barrier.count += 1; barrier.report = Self.merge(barrier.report, report); open[key] = barrier
                } else {
                    open[key] = Barrier(id: id, reported: time, report: report)
                    order.append(key)
                }
                latest[key] = time
            case "resolve":
                guard let key = open.first(where: { $0.value.id == id })?.key, var barrier = open.removeValue(forKey: key) else { continue }
                barrier.resolved = time; barrier.resolution = entry["resolution"]?.string
                closed.append(barrier)
                order.removeAll { $0 == key }
            default: continue
            }
        }
        let openList = order.compactMap { open[$0] }.sorted { (latest[Self.key($0.report.missing)] ?? "") > (latest[Self.key($1.report.missing)] ?? "") }
        return openList + closed.reversed()
    }

    /// Records a report and returns the barrier it now belongs to.
    func report(_ report: BarrierReport) throws -> Barrier {
        var report = report
        report.asked = Self.clean(report.asked); report.missing = Self.clean(report.missing)
        guard !report.asked.isEmpty, !report.missing.isEmpty else {
            throw AgentFailure(.badRequest, "A barrier needs “asked” (what the person wanted) and “missing” (what MenuSprite could not do).")
        }
        report.workaround = report.workaround.map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }
        report.suggestion = report.suggestion.map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }
        report.sprite = report.sprite.map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }
        report.agent = report.agent.map(Self.clean).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
        let area = report.area?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        report.area = BarrierReport.areas.contains(area) ? area : "other"
        var entry = try JSONValue(encoding: report)
        entry = .object([JSONMember("type", "report"), JSONMember("id", .string(Self.newID())), JSONMember("time", .string(Self.now()))]
                        + (entry.members ?? []))
        try append(entry)
        let key = Self.key(report.missing)
        return read().first { $0.resolved == nil && Self.key($0.report.missing) == key }
            ?? Barrier(id: entry["id"]?.string ?? "", reported: Self.now(), report: report)
    }

    /// Closes the open barrier whose id starts with `prefix`.
    func resolve(_ prefix: String, resolution: String) throws -> Barrier {
        let wanted = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = read().filter { $0.resolved == nil && $0.id.lowercased().hasPrefix(wanted) }
        guard !wanted.isEmpty, let barrier = matches.first else { throw AgentFailure(.notFound, "No open barrier has the id “\(prefix)”.") }
        guard matches.count == 1 else { throw AgentFailure(.ambiguous, "“\(prefix)” starts \(matches.count) open barriers' ids; give more of it.") }
        let text = Self.clean(resolution)
        guard !text.isEmpty else { throw AgentFailure(.badRequest, "Say what resolved it (“resolution”), such as the change or version that added it.") }
        try append(.object([JSONMember("type", "resolve"), JSONMember("id", .string(barrier.id)), JSONMember("time", .string(Self.now())),
                            JSONMember("resolution", .string(text))]))
        return read().first { $0.id == barrier.id } ?? barrier
    }

    private func append(_ entry: JSONValue) throws {
        let line = Data((entry.serialized() + "\n").utf8)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch { throw AgentFailure(.internalError, "Could not write \(url.path): \(error.localizedDescription)") }
    }

    /// A repeat report adds to the first rather than replacing it: the first wording stays, and what the first
    /// left out (a workaround, a suggestion, a real area) is taken from the later one.
    static func merge(_ first: BarrierReport, _ later: BarrierReport) -> BarrierReport {
        var merged = first
        merged.workaround = first.workaround ?? later.workaround
        merged.suggestion = first.suggestion ?? later.suggestion
        merged.sprite = first.sprite ?? later.sprite
        merged.agent = first.agent ?? later.agent
        if first.area == nil || first.area == "other" { merged.area = later.area ?? first.area }
        return merged
    }

    static func key(_ missing: String) -> String {
        missing.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
    }
    static func clean(_ text: String) -> String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(fieldLimit)) }
    static func newID() -> String { "b" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(7).lowercased() }
    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
