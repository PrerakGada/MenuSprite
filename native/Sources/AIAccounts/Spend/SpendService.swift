import Foundation

/// Estimates what the work in the CLIs' own session logs would have cost at published API rates.
/// Nothing here talks to a provider: it reads local logs, prices them, and caches the result. The
/// figure is an estimate of API-rate cost, never money charged — a subscription already covers it.
///
/// The actor holds one thing between scans: a per-day, per-model aggregate for the retained window,
/// which is kilobytes. Per-file records and the request-ownership index — tens of megabytes at this
/// history size — stay on disk and exist only for the life of a scan, because this service lives as
/// long as the app does and MenuSprite's resting footprint is a hard rule.
public actor SpendService: SpendEstimating {
    public static let shared = SpendService()

    /// Days of history kept. The readings report today, 7 days and 30 days; the extra days absorb
    /// time-zone edges without keeping a year of history.
    public static let retentionDays = 35

    private let paths: SpendPaths
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let refreshInterval: TimeInterval
    private var aggregates: SpendSummaryFile
    private var scans: [AIProvider: Task<Void, Never>] = [:]
    private var stats: [AIProvider: SpendScanStats] = [:]

    public init(paths: SpendPaths = .standard, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = Date.init, refreshInterval: TimeInterval = 300) {
        self.paths = paths
        self.calendar = calendar
        self.now = now
        self.refreshInterval = refreshInterval
        aggregates = SpendSummaryStore.load(paths.summaryFile)
    }

    /// Returns what is already known and refreshes in the background. A first scan of a large history
    /// takes minutes, so this never makes the caller wait for one.
    public func summary(_ provider: AIProvider, force: Bool) async -> SpendSummary? {
        let aggregate = aggregates[provider]
        let age = aggregate.scannedAt.map { now().timeIntervalSince1970 - $0 }
        if force || age == nil || age! > refreshInterval { startScan(provider) }
        guard aggregate.scannedAt != nil else { return nil }
        return SpendScanRunner.summary(provider: provider, aggregate: aggregate, calendar: calendar,
                                       now: now(), partial: scans[provider] != nil)
    }

    /// What the last scan left in memory, per local day and model, without ever starting a scan. For
    /// surfaces that must not treat being opened as consent to read the logs.
    public func cachedHistory(_ provider: AIProvider) -> SpendHistory? {
        let aggregate = aggregates[provider]
        guard let scannedAt = aggregate.scannedAt else { return nil }
        let today = SpendLogScanner.dayNumber(now(), calendar: calendar) ?? 0
        let days = aggregate.days.compactMap { totals -> SpendHistory.Day? in
            let ago = Int(today) - Int(totals.day)
            return ago >= 0 ? SpendHistory.Day(daysAgo: ago, models: totals.models) : nil
        }
        return SpendHistory(days: days, scannedAt: Date(timeIntervalSince1970: scannedAt))
    }

    /// Awaits a full pass. Used by tests and the opt-in live measurement, never by the UI.
    @discardableResult
    public func scanNow(_ provider: AIProvider) async -> SpendSummary? {
        startScan(provider)
        await scans[provider]?.value
        return await summary(provider, force: false)
    }

    public func statistics(_ provider: AIProvider) -> SpendScanStats? { stats[provider] }

    private func startScan(_ provider: AIProvider) {
        guard scans[provider] == nil else { return }
        let paths = self.paths, calendar = self.calendar, current = now()
        let cutoffDate = calendar.date(byAdding: .day, value: -Self.retentionDays, to: current) ?? current
        let cutoffDay = SpendLogScanner.dayNumber(cutoffDate, calendar: calendar) ?? 0
        scans[provider] = Task { [weak self] in
            // Detached so the scan's working set belongs to that task and is freed when it returns,
            // rather than living on the actor.
            let outcome = await Task.detached(priority: .utility) { () -> SpendScanRunner.Outcome? in
                try? SpendScanRunner.run(provider: provider, paths: paths, cutoffDay: cutoffDay,
                                         cutoffDate: cutoffDate, calendar: calendar, now: current)
            }.value
            await self?.finish(provider, outcome: outcome)
        }
    }

    private func finish(_ provider: AIProvider, outcome: SpendScanRunner.Outcome?) {
        scans[provider] = nil
        guard let outcome else { return }
        aggregates[provider] = outcome.aggregate
        stats[provider] = outcome.stats
        // Written here rather than in a detached task: it is kilobytes, and a scan that has finished
        // should be durable at that moment. Deferring it meant a crash after a multi-minute scan threw
        // the result away, and left a caller that had awaited the scan looking at no file at all.
        try? SpendSummaryStore.save(aggregates, to: paths.summaryFile)
    }
}

/// A provider's cached per-day, per-model tokens, as `SpendService.cachedHistory` reads them.
public struct SpendHistory: Sendable, Equatable {
    public struct Day: Sendable, Equatable {
        /// 0 is today, 1 yesterday.
        public let daysAgo: Int
        public let models: [String: TokenBreakdown]
    }

    public let days: [Day]
    public let scannedAt: Date
}
