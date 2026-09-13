import Foundation

public struct SpendScanStats: Sendable, Equatable {
    public var filesConsidered = 0
    /// Files actually opened and parsed this pass.
    public var filesRead = 0
    /// Files left unread because nothing in them can fall inside the retained window.
    public var filesSkippedByAge = 0
    public var filesReused = 0
    public var eventsCounted = 0
    /// Requests already counted by an earlier file — Claude's replayed history.
    public var duplicatesSkipped = 0
    public var linesSkipped = 0
    /// A file disappeared, so ownership had to be rebuilt from scratch.
    public var rebuilt = false
    public var duration: TimeInterval = 0
}

/// A whole scan: walk the provider's log tree, reuse everything unchanged, write the new scan state
/// back to disk, and hand back only the aggregate.
///
/// Loading and saving scan state happens *inside* this call on purpose. The per-file records and the
/// ownership index are tens of megabytes at this history size; they exist for the duration of the scan
/// and are released with it, so the app's resting cost is the aggregate alone.
enum SpendScanRunner {
    struct Outcome: Sendable {
        var aggregate: SpendAggregate
        var stats: SpendScanStats
    }

    static func run(provider: AIProvider, paths: SpendPaths, cutoffDay: Int32, cutoffDate: Date,
                    calendar: Calendar, now: Date) throws -> Outcome {
        let started = Date()
        var stats = SpendScanStats()
        let files = try discover(paths.root(for: provider))
        stats.filesConsidered = files.count

        var state = SpendScanStateStore.load(paths.scanStateFile)
        let previous = state[provider]

        // A deleted file may have owned requests that also live in a file whose totals were cached
        // without them. Rebuilding is rare and exact; patching would silently undercount.
        let present = Set(files.map(\.path))
        let rebuilt = previous.files.contains { !present.contains($0.path) }
        let base = rebuilt ? ProviderScanState() : previous
        stats.rebuilt = rebuilt

        let records = Dictionary(uniqueKeysWithValues: base.files.map { ($0.path, $0) })
        var owners = Dictionary(uniqueKeysWithValues: base.owners.map { ($0.hash, $0) })
        var updated: [FileRecord] = []
        updated.reserveCapacity(files.count)

        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let identity = SpendLogScanner.hash(file.path)
            if let cached = records[file.path], cached.size == file.size, cached.modified == file.modified {
                stats.filesReused += 1
                var kept = cached
                kept.days = cached.days.filter { $0.day >= cutoffDay }
                updated.append(kept)
                continue
            }
            // Re-reading a file gives up everything it previously owned, so its requests can be
            // re-claimed by it — or, if it lost them, by whoever reads them next.
            owners = owners.filter { $0.value.owner != identity }
            guard file.modified >= cutoffDate.timeIntervalSince1970 else {
                stats.filesSkippedByAge += 1
                updated.append(FileRecord(path: file.path, size: file.size, modified: file.modified, days: [], skipped: 0))
                continue
            }
            stats.filesRead += 1
            // One pool per file as well as per chunk: a file's own parse temporaries go back at its end.
            let scan = try autoreleasepool {
                try SpendLogScanner.scan(URL(fileURLWithPath: file.path), provider: provider, calendar: calendar)
            }
            var days: [Int32: [String: TokenBreakdown]] = [:]
            for event in scan.events where event.day >= cutoffDay {
                if let existing = owners[event.hash], existing.owner != identity {
                    stats.duplicatesSkipped += 1
                    continue
                }
                owners[event.hash] = OwnedKey(hash: event.hash, owner: identity, day: event.day)
                days[event.day, default: [:]][event.model, default: TokenBreakdown()] += event.tokens
                stats.eventsCounted += 1
            }
            stats.linesSkipped += scan.skipped
            updated.append(FileRecord(path: file.path, size: file.size, modified: file.modified,
                                      days: days.map { DayTotals(day: $0.key, models: $0.value) }.sorted { $0.day < $1.day },
                                      skipped: scan.skipped))
        }

        var next = ProviderScanState()
        next.files = updated
        next.owners = owners.values.filter { $0.day >= cutoffDay }.sorted { $0.hash < $1.hash }
        next.scannedAt = now.timeIntervalSince1970
        state[provider] = next
        try? SpendScanStateStore.save(state, to: paths.scanStateFile)

        stats.duration = Date().timeIntervalSince(started)
        return Outcome(aggregate: aggregate(next, now: now), stats: stats)
    }

    /// Folds every file's totals into one per-day, per-model table — the only thing that outlives a scan.
    static func aggregate(_ state: ProviderScanState, now: Date) -> SpendAggregate {
        var days: [Int32: [String: TokenBreakdown]] = [:]
        for record in state.files {
            for totals in record.days {
                for (model, tokens) in totals.models {
                    days[totals.day, default: [:]][model, default: TokenBreakdown()] += tokens
                }
            }
        }
        return SpendAggregate(days: days.map { DayTotals(day: $0.key, models: $0.value) }.sorted { $0.day < $1.day },
                              scannedAt: state.scannedAt ?? now.timeIntervalSince1970)
    }

    /// Totals for the reporting windows. Tokens count every model, including ones no rate covers and
    /// Claude's local `<synthetic>` work; dollars count only what a published rate can price.
    static func summary(provider: AIProvider, aggregate: SpendAggregate, calendar: Calendar,
                        now: Date, partial: Bool) -> SpendSummary {
        let today = SpendLogScanner.dayNumber(now, calendar: calendar) ?? 0
        var dollarsToday = 0.0, dollars7 = 0.0, dollars30 = 0.0
        var tokensToday = 0, tokens30 = 0
        var modelTokens: [String: TokenBreakdown] = [:]
        var unpriced: Set<String> = []

        for totals in aggregate.days where totals.day > today - 30 {
            for (model, tokens) in totals.models {
                let cost = ModelPricing.cost(tokens, model: model)
                if cost == nil { unpriced.insert(ModelPricing.canonical(model)) }
                dollars30 += cost ?? 0
                tokens30 += tokens.total
                modelTokens[model, default: TokenBreakdown()] += tokens
                if totals.day > today - 7 { dollars7 += cost ?? 0 }
                if totals.day == today {
                    dollarsToday += cost ?? 0
                    tokensToday += tokens.total
                }
            }
        }

        let top = modelTokens.map { model, tokens in
            SpendSummary.ModelTotal(id: model, dollars: ModelPricing.cost(tokens, model: model) ?? 0, tokens: tokens.total)
        }.sorted { ($0.dollars, $0.tokens) > ($1.dollars, $1.tokens) }

        return SpendSummary(provider: provider, today: dollarsToday, last7Days: dollars7, last30Days: dollars30,
                            tokensToday: tokensToday, tokens30Days: tokens30, topModels: Array(top.prefix(6)),
                            unpricedModels: unpriced.sorted(),
                            scannedAt: aggregate.scannedAt.map(Date.init(timeIntervalSince1970:)) ?? now,
                            partial: partial)
    }

    private struct DiscoveredFile: Sendable {
        var path: String
        var size: Int64
        var modified: Double
    }

    private static func discover(_ root: URL) throws -> [DiscoveredFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard FileManager.default.fileExists(atPath: root.path),
              let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var files: [DiscoveredFile] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append(DiscoveredFile(path: url.path, size: Int64(values.fileSize ?? 0),
                                        modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return files
    }
}
