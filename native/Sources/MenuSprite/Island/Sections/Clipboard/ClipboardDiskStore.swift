import Foundation
import IslandKit

/// The history on disk: `history.json` beside `Images/<uuid>.png` and `Rich/<uuid>.rtf`, all
/// owner-only (folders 0700, files 0600) in Application Support, not encrypted. Every read and write
/// runs in order on one utility queue, so an asset is on disk before the history that refers to it,
/// and files no entry refers to are swept after each save and after loading.
final class ClipboardDiskStore: Sendable {
    enum LoadResult: Sendable {
        case loaded([ClipboardEntry])
        case missing
        /// The file exists but could not be read, is damaged or is from a newer build. It is left as
        /// it is and nothing is saved over it.
        case failed
    }

    enum SaveResult: Sendable {
        /// Saved; `kept` is what fitted the file's size cap.
        case saved(kept: [ClipboardEntry])
        case failed
    }

    let historyURL: URL
    let imagesFolder: URL
    let richFolder: URL
    private let queue = DispatchQueue(label: "in.prerakgada.MenuSprite.clipboard.store", qos: .utility)

    init(folder: URL) {
        historyURL = folder.appendingPathComponent("history.json")
        imagesFolder = folder.appendingPathComponent("Images", isDirectory: true)
        richFolder = folder.appendingPathComponent("Rich", isDirectory: true)
    }

    static var standardFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuSprite/Clipboard", isDirectory: true)
    }

    func imageURL(_ image: ClipboardImage?) -> URL? { image.map { imagesFolder.appendingPathComponent($0.file) } }
    func richURL(_ rich: ClipboardRichText?) -> URL? { rich.map { richFolder.appendingPathComponent($0.file) } }

    func load(completion: @escaping @MainActor @Sendable (LoadResult) -> Void) {
        queue.async { [self] in
            let result: LoadResult
            switch IslandPrivateFile.read(historyURL) {
            case .missing: result = .missing
            case .unreadable: result = .failed
            case .data(let data):
                if let entries = try? ClipboardArchive.decode(data) {
                    sweep(keeping: entries)
                    result = .loaded(entries)
                } else {
                    result = .failed
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Queues a new image or rich-text file; it lands before any later save.
    func writeAsset(_ data: Data, to url: URL) {
        queue.async { try? IslandPrivateFile.write(data, to: url, verify: false) }
    }

    func save(_ entries: [ClipboardEntry], completion: @escaping @MainActor @Sendable (SaveResult) -> Void) {
        queue.async { [self] in
            var result = SaveResult.failed
            if let (data, kept) = try? ClipboardArchive.encode(entries),
               (try? IslandPrivateFile.write(data, to: historyURL, verify: false)) != nil {
                sweep(keeping: kept)
                result = .saved(kept: kept)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// "Clear history": the file and every stored image and rich text, pinned included.
    func erase(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let manager = FileManager.default
            for url in [historyURL, imagesFolder, richFolder] where manager.fileExists(atPath: url.path) {
                try? manager.removeItem(at: url)
            }
            let gone = !manager.fileExists(atPath: historyURL.path)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(gone) } }
        }
    }

    private func sweep(keeping entries: [ClipboardEntry]) {
        let manager = FileManager.default
        for folder in [imagesFolder, richFolder] {
            guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in ClipboardArchive.orphans(files: names, entries: entries) {
                try? manager.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }
}
