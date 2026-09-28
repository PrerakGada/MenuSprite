import AppKit
import ImageIO
import SwiftUI

/// Card thumbnails: decoded off the main thread, two at a time, at most 480 px, and dropped when
/// their row leaves before they finish. At most 120 are kept (48 MiB), least recently used first out.
@MainActor
final class ClipboardThumbnails {
    static let maximumCount = 120
    static let maximumBytes = 48 << 20

    private struct Item { let image: NSImage; let bytes: Int }
    private var items: [String: Item] = [:]
    private var order: [String] = []
    private var bytes = 0
    private let permits = ThumbnailPermits(count: 2)

    func cached(_ key: String) -> NSImage? {
        guard let item = items[key] else { return nil }
        touch(key)
        return item.image
    }

    /// A thumbnail made while the copy was in hand, so a fresh card never waits for the disk.
    func seed(_ key: String, _ image: CGImage) { store(key, image) }

    /// Loads (or returns) the thumbnail of the image at `url`. Nil on failure or when cancelled.
    func thumbnail(_ key: String, url: URL) async -> NSImage? {
        if let cached = cached(key) { return cached }
        await permits.acquire()
        defer { Task { await permits.release() } }
        guard !Task.isCancelled else { return nil }
        let loaded = await Task.detached(priority: .utility) { () -> SendableImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = ClipboardPasteboard.thumbnail(source) else { return nil }
            return SendableImage(image: image)
        }.value
        guard let loaded, !Task.isCancelled else { return nil }
        return store(key, loaded.image)
    }

    func removeAll() {
        items = [:]
        order = []
        bytes = 0
    }

    @discardableResult
    private func store(_ key: String, _ image: CGImage) -> NSImage {
        let cost = image.bytesPerRow * image.height
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        if let old = items[key] { bytes -= old.bytes }
        items[key] = Item(image: result, bytes: cost)
        bytes += cost
        touch(key)
        while (order.count > Self.maximumCount || bytes > Self.maximumBytes), let oldest = order.first {
            order.removeFirst()
            bytes -= items.removeValue(forKey: oldest)?.bytes ?? 0
        }
        return result
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

private struct SendableImage: @unchecked Sendable { let image: CGImage }

/// Lets at most `count` thumbnails decode at once.
private actor ThumbnailPermits {
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(count: Int) { available = count }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { available += 1 } else { waiting.removeFirst().resume() }
    }
}

/// A card's image: the cached thumbnail, loaded when the row appears and cancelled when it leaves.
struct ClipboardThumbnailView: View {
    let key: String
    let url: URL?
    let thumbnails: ClipboardThumbnails
    let fallback: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Text(fallback)
                    .font(.system(size: 12))
                    .foregroundStyle(IslandStyle.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: key) {
            if let cached = thumbnails.cached(key) { image = cached; return }
            guard let url else { return }
            image = await thumbnails.thumbnail(key, url: url)
        }
    }
}
