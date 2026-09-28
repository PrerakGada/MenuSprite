import Darwin
import Foundation
import IslandKit
import os

/// Where the watched folder comes from.
enum DownloadFolderSource: Sendable, Equatable {
    /// The authority saved when the person chose the folder (a security-scoped bookmark).
    case bookmark(Data)
    /// A plain folder: only the off-screen render harness uses this, with a temporary folder.
    case path(URL)
}

/// What the watcher hands the main actor after a scan or a progress batch. Immutable values only.
struct DownloadReport: Sendable {
    var available = true
    var transfers: [DownloadTransfer] = []
    var partials: [DownloadPartial] = []
    var files: [DownloadFolderEntry] = []
    /// Downloads proven finished since the previous report.
    var completions: [DownloadCompletion] = []
}

/// Watches the top level of one folder for downloads, entirely off the main thread.
///
/// Three inputs feed it: a kernel-event source on the folder (and one on each partial file) that
/// schedules a scan 0.3 s later, coalesced; the system's cross-process file-progress channel that
/// browsers publish to so Finder can draw progress bars, coalesced to 50 ms; and the proofs in
/// `DownloadProof`, so nothing is called finished on a guess. No polling: an idle folder costs one
/// kqueue source and no wakeups. Every file read happens on `queue`, and every property after the
/// lock is confined to it. `stop()` never waits for the queue.
final class DownloadWorker: @unchecked Sendable {
    private struct Shared {
        var stopped = false
        var subscriber: Subscription?
        var nextID = 0
        var live = 0
    }

    /// The progress channel's opaque subscription token.
    private struct Subscription: @unchecked Sendable { let token: Any }

    private static let scanDelay: TimeInterval = 0.3
    private static let progressDelay: TimeInterval = 0.05
    private static var eventMask: DispatchSource.FileSystemEvent { [.write, .extend, .attrib, .rename, .delete, .revoke] }

    private let queue = DispatchQueue(label: "in.prerakgada.MenuSprite.island.downloads", qos: .utility)
    private let source: DownloadFolderSource
    private let deliver: @Sendable (DownloadReport) -> Void
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    private var folder: URL?
    private var folderAliases: [URL] = []
    private var scoped: URL?
    private var folderEvents: DispatchSourceFileSystemObject?
    private var partialEvents: [String: DispatchSourceFileSystemObject] = [:]
    private var scanScheduled = false
    private var report = DownloadReport()
    private var partialsByPath: [String: DownloadPartial] = [:]
    private var publications: [Int: Publication] = [:]
    private var progress = DownloadBatch<Int, ProgressSnapshot>()
    private var proven: [DownloadCompletion] = []

    init(source: DownloadFolderSource, deliver: @escaping @Sendable (DownloadReport) -> Void) {
        self.source = source
        self.deliver = deliver
    }

    func start() { queue.async { self.open() } }

    /// Stops at once from any thread: the progress subscription goes now, the kernel sources and the
    /// folder authority are released on the queue after any read already under way.
    func stop() {
        let subscription = shared.withLock { state -> Subscription? in
            state.stopped = true
            defer { state.subscriber = nil }
            return state.subscriber
        }
        if let subscription { Progress.removeSubscriber(subscription.token) }
        queue.async { self.teardown() }
    }

    private var isStopped: Bool { shared.withLock { $0.stopped } }

    // MARK: Folder

    private func open() {
        guard !isStopped else { return }
        let url: URL
        switch source {
        case .path(let path):
            url = path
        case .bookmark(let data):
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                          relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { return lose() }
            if resolved.startAccessingSecurityScopedResource() { scoped = resolved }
            url = resolved
        }
        let descriptor = Darwin.open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return lose() }
        folder = url
        // The path as chosen and as resolved (/tmp and /private/tmp are one folder): a publisher may use either.
        folderAliases = Array(Set([url, url.resolvingSymlinksInPath()]))
        let events = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: Self.eventMask, queue: queue)
        events.setEventHandler { [weak self, weak events] in
            guard let self, let events else { return }
            // The folder itself renamed, deleted or unmounted: nothing left to watch.
            if !events.data.isDisjoint(with: [.rename, .delete, .revoke]) { self.lose() } else { self.scheduleScan() }
        }
        events.setCancelHandler { Darwin.close(descriptor) }
        events.resume()
        folderEvents = events
        subscribe(to: url)
        scan()
    }

    /// The folder is gone or unreadable: say so once and stop.
    private func lose() {
        guard !isStopped else { return }
        deliver(DownloadReport(available: false))
        stop()
    }

    private func teardown() {
        folderEvents?.cancel()
        folderEvents = nil
        partialEvents.values.forEach { $0.cancel() }
        partialEvents = [:]
        publications.values.forEach { $0.record.invalidate() }
        publications = [:]
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        folder = nil
    }

    // MARK: Scanning

    private func scheduleScan() {
        guard !scanScheduled, !isStopped else { return }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + Self.scanDelay) { [weak self] in
            guard let self else { return }
            // Cleared before scanning, so an event arriving during this scan queues exactly one more.
            self.scanScheduled = false
            self.scan()
        }
    }

    private func scan() {
        guard let folder, !isStopped else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .addedToDirectoryDateKey,
                                         .creationDateKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]) else { return lose() }
        var files: [DownloadFolderEntry] = []
        var partials: [DownloadPartial] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            let isDirectory = values.isDirectory == true
            guard isDirectory || values.isRegularFile == true else { continue }
            if let partial = DownloadNaming.partial(url.lastPathComponent), partial.kind.isBundle == isDirectory {
                let identity = Self.identity(at: url)
                let modified = identity.map { Date(timeIntervalSince1970: $0.modified) } ?? values.contentModificationDate ?? .distantPast
                partials.append(DownloadPartial(url: url, kind: partial.kind, identity: identity, modified: modified))
                continue
            }
            let date = values.addedToDirectoryDate ?? values.creationDate ?? values.contentModificationDate ?? .distantPast
            files.append(DownloadFolderEntry(url: url, date: date, isDirectory: isDirectory))
        }
        partials = DownloadMerge.newest(partials, limit: DownloadMerge.partialLimit, date: \.modified)
        let current = Set(partials.map(\.url.path))
        for (path, old) in partialsByPath where !current.contains(path) {
            let final = old.finalURL
            let finalIdentity = Self.lstat(final)
            if DownloadProof.partialFinished(partial: old.identity, partialStillExists: Self.lstat(old.url) != nil, final: finalIdentity),
               let finalIdentity {
                complete(final, finalIdentity)
            }
        }
        partialsByPath = Dictionary(uniqueKeysWithValues: partials.map { ($0.url.path, $0) })
        watchPartials(partials)
        report.partials = partials
        report.files = DownloadMerge.newest(files, limit: DownloadMerge.listLimit, date: \.date)
        emit()
    }

    /// One kernel source per partial (and per Safari payload), so growth inside a file triggers a scan;
    /// a folder's own events only report entries appearing and disappearing.
    private func watchPartials(_ partials: [DownloadPartial]) {
        var wanted = Set<String>()
        for partial in partials {
            wanted.insert(partial.url.path)
            if let payload = DownloadNaming.payloadURL(inBundle: partial.url) { wanted.insert(payload.path) }
        }
        for (path, events) in partialEvents where !wanted.contains(path) {
            events.cancel()
            partialEvents[path] = nil
        }
        for path in wanted where partialEvents[path] == nil {
            let descriptor = Darwin.open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let events = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: Self.eventMask, queue: queue)
            events.setEventHandler { [weak self] in self?.scheduleScan() }
            events.setCancelHandler { Darwin.close(descriptor) }
            events.resume()
            partialEvents[path] = events
        }
    }

    // MARK: Published progress

    private func subscribe(to folder: URL) {
        let subscription = Subscription(token: Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
            self?.published(progress)
        })
        let kept = shared.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.subscriber = subscription
            return true
        }
        if !kept { Progress.removeSubscriber(subscription.token) }
    }

    /// Called by the channel on its own thread. Captures the publication as a value at once and hands
    /// it to the queue; at most 32 publications are observed.
    private func published(_ progress: Progress) -> Progress.UnpublishingHandler? {
        let id = shared.withLock { state -> Int? in
            guard !state.stopped, state.live < DownloadMerge.publicationLimit else { return nil }
            state.live += 1
            state.nextID += 1
            return state.nextID
        }
        guard let id else { return nil }
        let record = PublicationRecord(id: id, progress: progress)
        let initial = ProgressSnapshot(progress)
        record.observe { [weak self, weak record] in
            guard let self, let record, !self.isStopped else { return }
            let snapshot = ProgressSnapshot(record.progress)
            self.queue.async { self.changed(record.id, snapshot) }
        }
        queue.async { self.register(record, initial) }
        return { [weak self] in
            guard let self else { return }
            let final = ProgressSnapshot(record.progress)
            self.shared.withLock { $0.live -= 1 }
            self.queue.async { self.retire(record, final) }
        }
    }

    private func register(_ record: PublicationRecord, _ snapshot: ProgressSnapshot) {
        guard !isStopped else { return record.invalidate() }
        publications[record.id] = Publication(record: record, firstSeen: Date())
        apply(snapshot, to: record.id)
        emit()
    }

    private func changed(_ id: Int, _ snapshot: ProgressSnapshot) {
        guard !isStopped, publications[id] != nil else { return }
        guard progress.record(snapshot, for: id) else { return }
        queue.asyncAfter(deadline: .now() + Self.progressDelay) { [weak self] in self?.flushProgress() }
    }

    private func flushProgress() {
        let batch = progress.flush()
        guard !isStopped, !batch.isEmpty else { return }
        for (id, snapshot) in batch { apply(snapshot, to: id) }
        emit()
    }

    /// Unpublishing carries the final evidence (often "finished" at the renamed file): apply it now,
    /// without waiting for the coalescing delay.
    private func retire(_ record: PublicationRecord, _ final: ProgressSnapshot) {
        _ = progress.take(record.id)
        record.invalidate()
        guard !isStopped, publications[record.id] != nil else { return }
        apply(final, to: record.id)
        publications[record.id] = nil
        emit()
    }

    private func apply(_ snapshot: ProgressSnapshot, to id: Int) {
        guard var publication = publications[id] else { return }
        publication.snapshot = snapshot
        let candidates = snapshot.url.map { [$0, $0.resolvingSymlinksInPath()] } ?? []
        publication.visible = DownloadPublication.accepts(cancelled: snapshot.isCancelled, operation: snapshot.operation,
                                                          candidates: candidates, folders: folderAliases)
        if publication.visible, let url = snapshot.url {
            let current = Self.identity(at: url)
            if let previous = publication.url {
                if previous.path != url.path,
                   !DownloadProof.acceptsMove(lastSeen: publication.lastSeen, moved: current,
                                              oldPathExists: Self.lstat(previous) != nil) {
                    // Not the file it was following: judge completion against what is here now.
                    publication.baseline = current
                }
            } else {
                publication.baseline = current
            }
            publication.url = url
            if let current { publication.lastSeen = current }
            if !publication.done,
               DownloadProof.publicationFinished(isFinished: snapshot.isFinished, url: url, current: current,
                                                 baseline: publication.baseline),
               let current {
                publication.done = true
                complete(url, current)
            }
        }
        publications[id] = publication
    }

    // MARK: Reporting

    private func complete(_ url: URL, _ identity: DownloadFileIdentity) {
        let completion = DownloadCompletion(url: url, date: Date(), identity: identity)
        guard DownloadMerge.isNew(completion, in: proven) else { return }
        proven = Array(([completion] + proven).prefix(DownloadMerge.publicationLimit))
        report.completions.append(completion)
    }

    private func emit() {
        guard !isStopped else { return }
        let transfers = publications.values.compactMap { publication -> DownloadTransfer? in
            let snapshot = publication.snapshot
            guard publication.visible, !publication.done, !snapshot.isFinished, let url = publication.url else { return nil }
            let received = publication.lastSeen.flatMap { $0.isRegular ? $0.size : nil }
            return DownloadTransfer(url: url, fraction: snapshot.fraction, bytes: snapshot.bytes ?? received,
                                    isPaused: snapshot.isPaused, firstSeen: publication.firstSeen)
        }
        report.transfers = DownloadMerge.newest(transfers, limit: DownloadMerge.publicationLimit, date: \.firstSeen)
        let out = report
        report.completions = []
        deliver(out)
    }

    // MARK: File identity

    /// The growing file behind a path: Safari's payload for a `.download` bundle, else the path itself.
    private static func identity(at url: URL) -> DownloadFileIdentity? {
        guard let identity = lstat(url) else { return nil }
        if !identity.isRegular, let payload = DownloadNaming.payloadURL(inBundle: url) { return lstat(payload) }
        return identity
    }

    private static func lstat(_ url: URL) -> DownloadFileIdentity? {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return nil }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return DownloadFileIdentity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
                                    size: Int64(info.st_size), modified: modified,
                                    isRegular: (info.st_mode & S_IFMT) == S_IFREG)
    }
}

/// One publication as the worker follows it: the file it was first seen at, the file last seen, and
/// whether it was already proven finished.
private struct Publication {
    let record: PublicationRecord
    let firstSeen: Date
    var snapshot = ProgressSnapshot()
    var url: URL?
    var baseline: DownloadFileIdentity?
    var lastSeen: DownloadFileIdentity?
    var visible = false
    var done = false
}

/// A publication's values, read once where the change arrived, so what is queued can never change.
struct ProgressSnapshot: Sendable {
    var url: URL?
    var operation = DownloadPublication.Operation.other
    var fraction: Double?
    var bytes: Int64?
    var isPaused = false
    var isCancelled = false
    var isFinished = false

    init() {}

    init(_ progress: Progress) {
        // Inside the publishing handler the typed getters can still read nil while the user info
        // already carries the file and its operation, so the user info is the fallback.
        url = progress.fileURL ?? progress.userInfo[.fileURLKey] as? URL
        let kind = progress.fileOperationKind
            ?? (progress.userInfo[.fileOperationKindKey] as? String).map(Progress.FileOperationKind.init(rawValue:))
        switch kind {
        case .downloading?: operation = .downloading
        case .receiving?: operation = .receiving
        default: operation = .other
        }
        fraction = DownloadPublication.fraction(progress.fractionCompleted, total: progress.totalUnitCount,
                                                indeterminate: progress.isIndeterminate)
        // A file-kind progress counts bytes.
        if progress.kind == .file, progress.completedUnitCount > 0 { bytes = progress.completedUnitCount }
        isPaused = progress.isPaused
        isCancelled = progress.isCancelled
        isFinished = progress.isFinished
    }
}

/// The observations on one published progress. Created on the channel's thread; invalidated on the
/// worker's queue when the publication ends or the worker stops.
private final class PublicationRecord: @unchecked Sendable {
    let id: Int
    let progress: Progress
    private var observations: [NSKeyValueObservation] = []

    init(id: Int, progress: Progress) {
        self.id = id
        self.progress = progress
    }

    /// File metadata changes (a new URL) arrive only through the two descriptions.
    func observe(_ changed: @escaping @Sendable () -> Void) {
        observations = [
            progress.observe(\.fractionCompleted) { _, _ in changed() },
            progress.observe(\.isPaused) { _, _ in changed() },
            progress.observe(\.isCancelled) { _, _ in changed() },
            progress.observe(\.isFinished) { _, _ in changed() },
            progress.observe(\.localizedDescription) { _, _ in changed() },
            progress.observe(\.localizedAdditionalDescription) { _, _ in changed() },
        ]
    }

    func invalidate() {
        observations.forEach { $0.invalidate() }
        observations = []
    }
}
