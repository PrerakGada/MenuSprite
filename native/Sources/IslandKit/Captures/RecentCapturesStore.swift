import Foundation

/// The recent-captures history on disk: an owner-only folder (0700) holding a JSON index (0600) and
/// the cached images the index names. It never erases captures it cannot account for: an index that
/// is corrupt, unreadable, a symbolic link, or missing while the folder still holds images blocks both
/// loading and saving until it reads cleanly again, and files are removed only after a new index has
/// been written. Cleanup touches only files this store names itself and never follows a link.
public struct RecentCapturesStore: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case unreadableIndex, corruptIndex, symlinkedIndex, missingIndex, writeFailed
    }

    public static let indexName = "index.json"
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    public var indexURL: URL { folder.appendingPathComponent(Self.indexName) }
    public func url(for name: String) -> URL { folder.appendingPathComponent(name) }

    /// Names the store creates: "<uuid>.png" for a cached image and "<uuid>-thumb.png" for a thumbnail.
    public static func isOwnedName(_ name: String) -> Bool {
        guard name.hasSuffix(".png") else { return false }
        var stem = String(name.dropLast(4))
        if stem.hasSuffix("-thumb") { stem = String(stem.dropLast(6)) }
        return UUID(uuidString: stem) != nil
    }

    public static func imageName(for id: UUID) -> String { "\(id.uuidString).png" }
    public static func thumbnailName(for id: UUID) -> String { "\(id.uuidString)-thumb.png" }

    private struct Index: Codable {
        var version = 1
        var entries: [RecentCapture]
    }

    /// Reads the index. The first time, it creates the folder with an empty index, so a later missing
    /// index always means something removed it.
    public func load() -> Result<[RecentCapture], Failure> {
        let manager = FileManager.default
        if !manager.fileExists(atPath: folder.path) {
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try save([])
            } catch {
                return .failure(.writeFailed)
            }
            return .success([])
        }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        switch Self.entryType(indexURL) {
        case .typeSymbolicLink?:
            return .failure(.symlinkedIndex)
        case nil:
            return ownedFiles().isEmpty ? .success([]) : .failure(.missingIndex)
        default:
            break
        }
        guard let data = try? Data(contentsOf: indexURL) else { return .failure(.unreadableIndex) }
        guard let index = try? Self.decoder.decode(Index.self, from: data) else { return .failure(.corruptIndex) }
        return .success(index.entries)
    }

    /// Replaces the index atomically and makes it owner-only again. Refuses a symbolic link.
    public func save(_ entries: [RecentCapture]) throws(Failure) {
        if Self.entryType(indexURL) == .typeSymbolicLink { throw .symlinkedIndex }
        do {
            let data = try Self.encoder.encode(Index(entries: entries))
            try data.write(to: indexURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch {
            throw .writeFailed
        }
    }

    /// Writes one of the store's own files, owner-only.
    public func write(_ data: Data, named name: String) throws(Failure) {
        do {
            try data.write(to: url(for: name), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(for: name).path)
        } catch {
            throw .writeFailed
        }
    }

    /// Deletes the store's own files that no entry names. Links and foreign files are left alone.
    public func removeOrphans(keeping entries: [RecentCapture]) {
        let kept = Set(entries.flatMap(\.ownedNames))
        for name in ownedFiles() where !kept.contains(name) {
            try? FileManager.default.removeItem(at: url(for: name))
        }
    }

    /// Regular files in the folder with names this store creates.
    private func ownedFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { Self.isOwnedName($0) && Self.entryType(url(for: $0)) == .typeRegular }
    }

    /// The type of the item itself, never of what a link points to.
    private static func entryType(_ url: URL) -> FileAttributeType? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.type] as? FileAttributeType
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The history as the app uses it: load before anything is saved, commit the new index before any
/// file is removed, and keep what was last known when a read fails (a read error is not "no history").
public struct RecentCapturesHistory: Sendable {
    public let store: RecentCapturesStore
    public private(set) var entries: [RecentCapture] = []
    /// Why the history is blocked, or nil once it has loaded.
    public private(set) var failure: RecentCapturesStore.Failure?
    public private(set) var isLoaded = false

    public init(store: RecentCapturesStore) { self.store = store }

    /// Loads the index and drops entries whose file is gone (the drop is saved with the next change).
    public mutating func reload(exists: (RecentCapture) -> Bool) {
        switch store.load() {
        case .success(let loaded):
            entries = RecentCapturesList.present(loaded, exists: exists)
            failure = nil
            isLoaded = true
        case .failure(let error):
            failure = error
            isLoaded = false
        }
    }

    /// Records a capture: its files first, then the index, then cleanup of whatever fell out.
    /// Returns false, deleting nothing, when the history is blocked or the index cannot be written.
    @discardableResult
    public mutating func add(_ entry: RecentCapture, files: [String: Data], exists: (RecentCapture) -> Bool) -> Bool {
        if !isLoaded { reload(exists: exists) }
        guard isLoaded else { return false }
        do {
            for (name, data) in files where RecentCapturesStore.isOwnedName(name) {
                try store.write(data, named: name)
            }
        } catch {
            return false
        }
        return commit(RecentCapturesList.inserting(entry, into: entries))
    }

    /// Takes an entry out of the history. A screenshot's cached images go with it; a recording's
    /// video is never touched.
    @discardableResult
    public mutating func remove(_ id: UUID, exists: (RecentCapture) -> Bool) -> Bool {
        if !isLoaded { reload(exists: exists) }
        guard isLoaded else { return false }
        return commit(entries.filter { $0.id != id })
    }

    private mutating func commit(_ next: [RecentCapture]) -> Bool {
        do {
            try store.save(next)
        } catch {
            // Read the disk again before the next change rather than trust what failed to save.
            failure = error
            isLoaded = false
            return false
        }
        entries = next
        store.removeOrphans(keeping: next)
        return true
    }
}
