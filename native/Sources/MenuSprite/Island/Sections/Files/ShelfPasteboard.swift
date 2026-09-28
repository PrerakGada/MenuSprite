import AppKit
import ImageIO
import IslandKit
import UniformTypeIdentifiers

/// Reads what was dropped on the shelf. Plain files, links and text are taken at once; image data and
/// file promises arrive a moment later and keep their place in the drop. Nothing here blocks the
/// main thread on file contents: images are converted and promised files copied on background queues.
@MainActor
enum ShelfPasteboard {
    static let gif = NSPasteboard.PasteboardType(UTType.gif.identifier)
    static let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
    static let heic = NSPasteboard.PasteboardType(UTType.heic.identifier)
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, jpeg, heic]
    static var promiseTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Every type a shelf drop surface registers for.
    static var dropTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, gif] + imageTypes + promiseTypes
    }

    /// Cheap check for a drag in flight: does the pasteboard carry anything the shelf could take?
    static func hasDroppableType(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return !Set(types).isDisjoint(with: dropTypes)
    }

    /// Classifies each pasteboard item in order.
    static func items(in pasteboard: NSPasteboard) -> [(NSPasteboardItem, ShelfPasteboardItem)] {
        let promises = Set(promiseTypes)
        return (pasteboard.pasteboardItems ?? []).map { item in
            let types = Set(item.types)
            let fileURL = item.string(forType: .fileURL).flatMap(URL.init(string:)).flatMap { ($0 as NSURL).filePathURL }
            let link = item.string(forType: .URL).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? nil : $0 }
            return (item, ShelfPasteboardItem(fileURL: fileURL,
                                              isPromise: !types.isDisjoint(with: promises),
                                              hasGIF: types.contains(gif),
                                              hasImage: !types.isDisjoint(with: imageTypes),
                                              url: link,
                                              text: types.contains(.string) ? item.string(forType: .string) : nil))
        }
    }

    static func file(_ url: URL, owned: Bool = false) -> ShelfContent {
        .file(ShelfFile(path: url.standardizedFileURL.path, bookmark: owned ? nil : ShelfStore.bookmark(for: url), owned: owned))
    }
}

/// One drop being delivered: holds the slots in drop order until every late part arrives, then adds
/// the whole drop to the shelf as one tile or pile.
@MainActor
final class ShelfIncomingDrop {
    typealias Finish = @MainActor (_ contents: [ShelfContent], _ failures: Int) -> Void

    private var arrivals: ShelfArrivals<ShelfContent>
    private let finish: Finish
    private(set) var finished = false
    private var promiseFolder: URL?
    private var timeout: Task<Void, Never>?
    /// Promise receipts are copied one at a time off the main thread.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "in.prerakgada.MenuSprite.shelf-promises"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    private init(arrivals: ShelfArrivals<ShelfContent>, finish: @escaping Finish) {
        self.arrivals = arrivals
        self.finish = finish
    }

    /// Plans the drop and starts every late part. A drop with nothing usable, or more than the shelf
    /// has room for, is refused before anything is read or copied. The returned drop is still arriving.
    static func start(_ pasteboard: NSPasteboard, location: ShelfLocation?, capacityLeft: Int,
                      finish: @escaping Finish) -> (drop: ShelfIncomingDrop?, accepted: Bool, full: Bool) {
        let entries = ShelfPasteboard.items(in: pasteboard)
        var receivers = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        // Receivers come back for promise-capable items in item order; skip the ones taken as real files.
        var candidates: [(ShelfCandidate, NSPasteboardItem, NSFilePromiseReceiver?)] = []
        var seenFiles = Set<String>()
        for (item, reading) in entries {
            let receiver = reading.isPromise && !receivers.isEmpty ? receivers.removeFirst() : nil
            guard let candidate = ShelfIntake.candidate(for: reading) else { continue }
            if case .file(let url) = candidate, !seenFiles.insert(url.path).inserted { continue }
            candidates.append((candidate, item, receiver))
        }
        guard !candidates.isEmpty else { return (nil, false, false) }
        let slots: [ShelfArrivals<ShelfContent>.Slot] = candidates.map { candidate, _, receiver in
            switch candidate {
            case .file(let url): .ready([ShelfPasteboard.file(url)])
            case .link(let url): .ready([.link(url)])
            case .text(let text): .ready([.text(text)])
            case .gif, .image: .waiting(expected: 1)
            case .promise: .waiting(expected: max(1, receiver?.fileTypes.count ?? 1))
            }
        }
        let drop = ShelfIncomingDrop(arrivals: ShelfArrivals(slots), finish: finish)
        guard drop.arrivals.plannedCount <= capacityLeft else { return (nil, false, true) }
        for (index, (candidate, item, receiver)) in candidates.enumerated() {
            switch candidate {
            case .gif: drop.convertImage(item, slot: index, location: location, gif: true)
            case .image: drop.convertImage(item, slot: index, location: location, gif: false)
            case .promise: drop.receive(receiver, slot: index, location: location)
            case .file, .link, .text: break
            }
        }
        drop.finishIfComplete()
        if !drop.finished {
            drop.timeout = Task { [weak drop] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let drop else { return }
                drop.arrivals.finishWaiting()
                drop.finishIfComplete()
            }
        }
        return (drop.finished ? nil : drop, true, false)
    }

    /// The shelf stopped: anything still arriving is dropped.
    func cancel() {
        arrivals.cancel()
        timeout?.cancel()
        cleanUp()
        finished = true
    }

    private func deliver(_ content: ShelfContent?, slot: Int) {
        guard arrivals.deliver(content, to: slot) else { return }
        finishIfComplete()
    }

    private func finishIfComplete() {
        guard !finished, arrivals.isComplete else { return }
        finished = true
        timeout?.cancel()
        cleanUp()
        if !arrivals.isCancelled { finish(arrivals.values, arrivals.failures) }
    }

    private func cleanUp() {
        guard let folder = promiseFolder else { return }
        promiseFolder = nil
        Self.queue.addOperation { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Image data

    /// Image data with no file behind it becomes a PNG (or stays a GIF) in private storage.
    private func convertImage(_ item: NSPasteboardItem, slot: Int, location: ShelfLocation?, gif: Bool) {
        let type = gif ? ShelfPasteboard.gif : ShelfPasteboard.imageTypes.first { item.data(forType: $0) != nil }
        guard let location, let type, let data = item.data(forType: type) else { deliver(nil, slot: slot); return }
        let stem = item.string(forType: .URL).flatMap(URL.init(string:))?.deletingPathExtension().lastPathComponent
        let name = (stem?.isEmpty == false ? stem! : "Image") + (gif ? ".gif" : ".png")
        let convert = !gif && type != .png
        Task { [weak self] in
            let content = await Task.detached(priority: .utility) {
                Self.writeImage(data, png: convert, name: name, location: location)
            }.value
            self?.deliver(content, slot: slot)
        }
    }

    nonisolated private static func writeImage(_ data: Data, png convert: Bool, name: String, location: ShelfLocation) -> ShelfContent? {
        guard let folder = try? location.newPayloadFolder() else { return nil }
        let url = folder.appendingPathComponent(name)
        var output = data
        if convert {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            output = buffer as Data
        }
        guard (try? output.write(to: url)) != nil else { try? FileManager.default.removeItem(at: folder); return nil }
        ShelfLocation.makePrivateFile(url)
        return .file(ShelfFile(path: url.path, owned: true))
    }

    // MARK: File promises

    /// Mail attachments, browser downloads and the like: delivered into a fresh owner-only folder,
    /// then each file is copied into private storage inside its own callback, keeping its exact name.
    private func receive(_ receiver: NSFilePromiseReceiver?, slot: Int, location: ShelfLocation?) {
        guard let receiver, let location else { deliver(nil, slot: slot); return }
        if promiseFolder == nil {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("MenuSprite-Shelf-\(UUID().uuidString)", isDirectory: true)
            guard (try? ShelfLocation.makePrivateFolder(folder)) != nil else { deliver(nil, slot: slot); return }
            promiseFolder = folder
        }
        guard let folder = promiseFolder else { return }
        receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: Self.queue) { @Sendable [weak self] url, error in
            let content = Self.adopt(url, folder: folder, failed: error != nil, location: location)
            Task { @MainActor in self?.deliver(content, slot: slot) }
        }
    }

    nonisolated private static func adopt(_ url: URL, folder: URL, failed: Bool, location: ShelfLocation) -> ShelfContent? {
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        guard ShelfPromiseRules.accepts(url, folder: folder, isSymlink: isLink, failed: failed),
              let payload = try? location.newPayloadFolder() else { return nil }
        let target = payload.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            try? FileManager.default.removeItem(at: payload)
            return nil
        }
        ShelfLocation.makePrivateFile(target)
        return .file(ShelfFile(path: target.path, owned: true))
    }
}
