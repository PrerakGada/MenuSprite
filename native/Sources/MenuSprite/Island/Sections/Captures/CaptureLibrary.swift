import AppKit
import IslandKit

/// The history's disk work, off the main thread and one change at a time.
actor CaptureHistoryStore {
    private let store: RecentCapturesStore
    private var history: RecentCapturesHistory

    init(folder: URL) {
        store = RecentCapturesStore(folder: folder)
        history = RecentCapturesHistory(store: store)
    }

    func reload() -> (entries: [RecentCapture], blocked: Bool) {
        history.reload(exists: exists)
        return (history.entries, !history.isLoaded)
    }

    func add(_ entry: RecentCapture, files: [String: Data]) -> [RecentCapture] {
        history.add(entry, files: files, exists: exists)
        return history.entries
    }

    func remove(_ id: UUID) -> [RecentCapture] {
        history.remove(id, exists: exists)
        return history.entries
    }

    /// A screenshot needs its cached image, a recording its video. Reads `store`, never `history`,
    /// because it runs while `history` is being changed.
    private nonisolated func exists(_ entry: RecentCapture) -> Bool {
        switch entry.kind {
        case .screenshot:
            entry.imageName.map { FileManager.default.fileExists(atPath: store.url(for: $0).path) } ?? false
        case .recording:
            entry.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }
}

/// The Recent captures list the page shows. Thumbnails load on demand into a cache no larger than
/// the history; the full image is read only when a capture is restored, copied or dragged.
@MainActor
final class CaptureLibrary: ObservableObject {
    @Published private(set) var entries: [RecentCapture] = []
    /// True when the history cannot be read safely; captures still save, they just are not listed.
    @Published private(set) var isBlocked = false
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]

    let folder: URL
    private let store: CaptureHistoryStore?
    private var loading: Set<UUID> = []

    init(folder: URL = CaptureFiles.historyFolder) {
        self.folder = folder
        store = CaptureHistoryStore(folder: folder)
    }

    /// Sample data for renders: nothing is read from or written to disk.
    init(preview entries: [RecentCapture], thumbnails: [UUID: NSImage]) {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
        store = nil
        self.entries = entries
        self.thumbnails = thumbnails
    }

    /// Re-reads the index; entries whose file has gone drop out.
    func reload() {
        guard let store else { return }
        Task {
            let result = await store.reload()
            apply(result.entries)
            isBlocked = result.blocked
        }
    }

    /// Records a capture when it is taken. Returns once the history has it (or has refused it).
    func add(_ entry: RecentCapture, files: [String: Data]) async {
        guard let store else { return }
        apply(await store.add(entry, files: files))
    }

    func remove(_ entry: RecentCapture) {
        guard let store else { entries.removeAll { $0.id == entry.id }; return }
        Task { apply(await store.remove(entry.id)) }
    }

    /// The cached full-resolution image of a screenshot.
    func imageURL(for entry: RecentCapture) -> URL? {
        entry.imageName.map { folder.appendingPathComponent($0) }
    }

    /// The thumbnail if it is loaded; otherwise starts loading it and returns nil for now.
    func thumbnail(for entry: RecentCapture) -> NSImage? {
        if let image = thumbnails[entry.id] { return image }
        guard store != nil, let name = entry.thumbnailName, !loading.contains(entry.id) else { return nil }
        loading.insert(entry.id)
        let url = folder.appendingPathComponent(name)
        Task {
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            loading.remove(entry.id)
            guard let data, let image = NSImage(data: data), entries.contains(where: { $0.id == entry.id }) else { return }
            thumbnails[entry.id] = image
        }
        return nil
    }

    /// Thumbnails go when the page does; the list itself is tiny.
    func releaseImages() {
        guard store != nil else { return }
        thumbnails.removeAll()
    }

    private func apply(_ next: [RecentCapture]) {
        entries = next
        let ids = Set(next.map(\.id))
        thumbnails = thumbnails.filter { ids.contains($0.key) }
    }
}
