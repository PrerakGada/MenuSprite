import Foundation
import IslandKit

/// The Downloads section's live state on the main actor: the merged list, the download the closed
/// island shows, and the just-finished items. Everything arrives as immutable reports from the
/// worker; a generation number drops reports from a watcher that was already stopped, so a queued
/// callback can never repopulate the list after a stop. The main thread only merges values.
@MainActor
final class DownloadsModel: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    /// The folder could not be resolved, read or kept (lost, renamed, unmounted, or the chosen one
    /// could not be saved).
    @Published private(set) var isUnavailable = false
    /// The newest active download: what the closed island shows.
    @Published private(set) var active: DownloadItem?
    /// The first report since watching began has arrived (until then the list is unknown, not empty).
    @Published private(set) var isLoaded = false

    /// A download was proven finished.
    var onCompletion: (DownloadCompletion) -> Void = { _ in }
    /// The active download, the folder's availability, or whether the list is empty changed.
    var onChange: () -> Void = {}

    private var worker: DownloadWorker?
    private var generation = 0
    private var latest = DownloadReport()
    private var finished: [DownloadCompletion] = []
    private var finishedClear: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var expiryDate: Date?

    var isWatching: Bool { worker != nil }

    func start(_ source: DownloadFolderSource) {
        stop()
        let generation = generation
        let worker = DownloadWorker(source: source) { [weak self] report in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(report, generation: generation) } }
        }
        self.worker = worker
        worker.start()
    }

    /// Stops watching and drops everything read.
    func stop() {
        generation += 1
        worker?.stop()
        worker = nil
        latest = DownloadReport()
        finished = []
        finishedClear?.cancel()
        finishedClear = nil
        isLoaded = false
        refresh()
    }

    /// Marks the folder unavailable (and stops) or clears the mark before trying again.
    func setUnavailable(_ unavailable: Bool) {
        if unavailable { stop() }
        guard isUnavailable != unavailable else { return }
        isUnavailable = unavailable
        onChange()
    }

    private func receive(_ report: DownloadReport, generation: Int) {
        guard generation == self.generation else { return }
        guard report.available else { return setUnavailable(true) }
        latest = report
        isLoaded = true
        for completion in report.completions where DownloadMerge.isNew(completion, in: finished) {
            finished = DownloadMerge.adding(completion, to: finished)
            onCompletion(completion)
        }
        if !report.completions.isEmpty { scheduleFinishedClear() }
        refresh()
    }

    private func refresh() {
        let now = Date()
        let merged = DownloadMerge.items(transfers: latest.transfers, partials: latest.partials, files: latest.files,
                                         finished: finished, now: now)
        let emptinessChanged = merged.isEmpty != items.isEmpty
        if merged != items { items = merged }
        let current = merged.first(where: \.isActive)
        let activeChanged = current != active
        if activeChanged { active = current }
        if emptinessChanged || activeChanged { onChange() }
        scheduleExpiry(now: now)
    }

    /// Just-finished items stay 15 s after the latest completion; the files remain listed as folder entries.
    private func scheduleFinishedClear() {
        finishedClear?.cancel()
        finishedClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DownloadMerge.finishedLifetime))
            guard !Task.isCancelled, let self else { return }
            self.finished = []
            self.refresh()
        }
    }

    /// One timer, set for the moment the next partial has been quiet for two minutes.
    private func scheduleExpiry(now: Date) {
        let next = DownloadMerge.nextExpiry(of: latest.partials, now: now)
        guard next != expiryDate else { return }
        expiryDate = next
        expiry?.cancel()
        guard let next else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow + 0.05)))
            guard !Task.isCancelled, let self else { return }
            self.expiryDate = nil
            self.refresh()
        }
    }
}
