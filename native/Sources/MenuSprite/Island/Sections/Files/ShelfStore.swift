import Foundation
import IslandKit

/// Where the shelf keeps its list and the files it owns. Everything is owner-only: folders 0700,
/// files 0600, re-applied after every write.
struct ShelfLocation: Sendable {
    let folder: URL
    var file: URL { folder.appendingPathComponent("shelf.json") }
    var payloads: URL { folder.appendingPathComponent("Payloads", isDirectory: true) }

    static let standard = ShelfLocation(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MenuSprite/Shelf", isDirectory: true))

    /// A fresh private folder for one owned payload (a converted image, a received promise).
    func newPayloadFolder() throws -> URL {
        let folder = payloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.makePrivateFolder(folder)
        return folder
    }

    /// Only folders MenuSprite created under Payloads are ever deleted.
    func ownsPayload(_ path: String) -> Bool {
        let base = payloads.standardizedFileURL.pathComponents
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return parts.count > base.count + 1 && Array(parts.prefix(base.count)) == base
    }

    /// The payload's own folder (Payloads/<id>), which holds just that payload.
    func payloadFolder(of path: String) -> URL? {
        guard ownsPayload(path) else { return nil }
        let base = payloads.standardizedFileURL.pathComponents.count
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return payloads.appendingPathComponent(parts[base], isDirectory: true)
    }

    static func makePrivateFolder(_ url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func makePrivateFile(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: isDirectory.boolValue ? 0o700 : 0o600], ofItemAtPath: url.path)
    }
}

/// The shelf's items, saved as one JSON array. Restore is asynchronous; nothing is saved before it
/// lands, and a store that only partly decoded is never swept and is backed up before its first
/// rewrite. Writes are coalesced to one per run-loop turn and encoded off the main thread. Owned
/// payloads that leave the shelf are deleted ten minutes later, so an app that just received one by
/// drag can finish reading it. Without a location (renders) the shelf lives in memory only.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var shelf = Shelf()
    @Published private(set) var isLoaded = false
    let location: ShelfLocation?

    private var loadTask: Task<Void, Never>?
    private var loadedCompletely = true
    private var backedUp = false
    private var savePending = false
    private var waiting: [@MainActor () -> Void] = []
    private static let writer = DispatchQueue(label: "in.prerakgada.MenuSprite.shelf-store", qos: .utility)
    nonisolated static let payloadGrace: TimeInterval = 600

    init(location: ShelfLocation?, preview: Shelf? = nil) {
        self.location = location
        if let preview {
            shelf = preview
            isLoaded = true
        } else if location == nil {
            isLoaded = true
        }
    }

    /// Starts the restore (once). Work that needs the list waits for it through `whenLoaded`.
    func load() {
        guard let location, !isLoaded, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            let decoded = await Task.detached(priority: .utility) { () -> ShelfCodec.Decoded? in
                guard let data = try? Data(contentsOf: location.file) else { return nil }
                return ShelfCodec.decode(data)
            }.value
            self?.restored(decoded)
        }
    }

    /// Runs `work` now if the shelf is restored, otherwise as soon as it is.
    func whenLoaded(_ work: @escaping @MainActor () -> Void) {
        if isLoaded { work() } else { waiting.append(work); load() }
    }

    /// Writes anything pending right away and forgets the list (the island stopped).
    func unload() {
        guard location != nil else { return }
        if savePending { flush() }
        loadTask?.cancel()
        loadTask = nil
        waiting = []
        shelf = Shelf()
        isLoaded = false
    }

    /// Changes the shelf, saves it, and schedules deletion of payloads that left it.
    func mutate(_ change: (inout Shelf) -> Void) {
        let before = shelf.ownedPaths
        var copy = shelf
        change(&copy)
        guard copy != shelf else { return }
        shelf = copy
        releasePayloads(before.subtracting(copy.ownedPaths))
        scheduleSave()
    }

    @discardableResult
    func add(_ drop: [ShelfContent]) -> ShelfAddResult {
        var result = ShelfAddResult.empty
        mutate { result = $0.add(drop) }
        if case .added = result { return result }
        // A refused drop leaves none of its owned payloads behind.
        releasePayloads(Set(drop.compactMap { content in
            if case .file(let file) = content, file.owned { return file.path }
            return nil
        }))
        return result
    }

    // MARK: File health

    /// Checks the given tiles' files before a drag or an action: moved files are followed through
    /// their bookmark (no UI, no mounting), files gone for good are removed, files on a disk that is
    /// not mounted stay. Returns the leaves that can be used now.
    func usableLeaves(of ids: Set<UUID>) -> [ShelfItem] {
        let mounted = Self.mountedVolumes()
        var usable: [ShelfItem] = []
        var gone = Set<UUID>()
        var moved: [(UUID, ShelfFile)] = []
        for leaf in shelf.leaves(of: ids) {
            guard let file = leaf.file else { usable.append(leaf); continue }
            switch Self.verdict(for: file, mounted: mounted) {
            case .present: usable.append(leaf)
            case .moved(let path):
                var healed = file
                healed.path = path
                moved.append((leaf.id, healed))
                var item = leaf
                item.content = .file(healed)
                usable.append(item)
            case .offline: break
            case .gone: gone.insert(leaf.id)
            }
        }
        if !moved.isEmpty || !gone.isEmpty {
            mutate { shelf in
                for (id, file) in moved { shelf.updateFile(id, file) }
                shelf.remove(gone)
            }
        }
        return usable
    }

    nonisolated static func verdict(for file: ShelfFile, mounted: Set<String>) -> ShelfFileHealth.Verdict {
        let exists = FileManager.default.fileExists(atPath: file.path)
        var resolved: String?
        if !exists, let bookmark = file.bookmark {
            var stale = false
            resolved = (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale))?.path
            if let path = resolved, !FileManager.default.fileExists(atPath: path) { resolved = nil }
        }
        return ShelfFileHealth.verdict(path: file.path, exists: exists, resolved: resolved, mounted: mounted)
    }

    nonisolated static func mountedVolumes() -> Set<String> {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return Set(volumes.map(\.standardizedFileURL.path))
    }

    /// A reference that finds the file again after a rename or move. MenuSprite is not sandboxed,
    /// so a plain bookmark is enough.
    nonisolated static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    // MARK: Restore and save

    private func restored(_ decoded: ShelfCodec.Decoded?) {
        // An unload while reading cancelled this restore.
        guard loadTask != nil, !isLoaded else { return }
        loadTask = nil
        if let decoded {
            shelf = Shelf(items: decoded.items)
            loadedCompletely = decoded.isComplete
        }
        isLoaded = true
        let pending = waiting
        waiting = []
        pending.forEach { $0() }
        if loadedCompletely { sweep() }
    }

    /// After a complete restore: follow moved files, drop files gone for good, and delete payload
    /// folders nothing refers to any more (older than the grace period).
    private func sweep() {
        guard let location else { return }
        let files = shelf.items.flatMap(\.leaves).compactMap { leaf in leaf.file.map { (leaf.id, $0) } }
        let owned = shelf.ownedPaths
        Task { [weak self] in
            let verdicts = await Task.detached(priority: .utility) { () -> [(UUID, ShelfFileHealth.Verdict)] in
                let mounted = ShelfStore.mountedVolumes()
                ShelfStore.removeOrphanPayloads(in: location, keeping: owned)
                return files.map { ($0.0, ShelfStore.verdict(for: $0.1, mounted: mounted)) }
            }.value
            guard let self, self.isLoaded else { return }
            self.mutate { shelf in
                for (id, verdict) in verdicts {
                    switch verdict {
                    case .moved(let path):
                        if var file = shelf.item(id)?.file { file.path = path; shelf.updateFile(id, file) }
                    case .gone: shelf.remove([id])
                    case .present, .offline: break
                    }
                }
            }
        }
    }

    nonisolated private static func removeOrphanPayloads(in location: ShelfLocation, keeping owned: Set<String>) {
        let manager = FileManager.default
        let kept = Set(owned.compactMap { location.payloadFolder(of: $0)?.lastPathComponent })
        guard let folders = try? manager.contentsOfDirectory(at: location.payloads, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for folder in folders where !kept.contains(folder.lastPathComponent) {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > payloadGrace { try? manager.removeItem(at: folder) }
        }
    }

    private func releasePayloads(_ paths: Set<String>) {
        guard let location else { return }
        let folders = paths.compactMap { location.payloadFolder(of: $0) }
        guard !folders.isEmpty else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.payloadGrace) {
            for folder in folders { try? FileManager.default.removeItem(at: folder) }
        }
    }

    private func scheduleSave() {
        guard location != nil, isLoaded, !savePending else { return }
        savePending = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flush() } }
    }

    private func flush() {
        guard savePending, let location else { return }
        savePending = false
        let snapshot = shelf
        let backup = !loadedCompletely && !backedUp
        backedUp = backedUp || backup
        Self.writer.async {
            do {
                try ShelfLocation.makePrivateFolder(location.folder)
                if backup {
                    let copy = location.folder.appendingPathComponent("shelf-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                    try? FileManager.default.copyItem(at: location.file, to: copy)
                    ShelfLocation.makePrivateFile(copy)
                }
                try ShelfCodec.encode(snapshot).write(to: location.file, options: .atomic)
                ShelfLocation.makePrivateFile(location.file)
            } catch {
                NSLog("MenuSprite shelf: could not save (%@)", error.localizedDescription)
            }
        }
    }
}
