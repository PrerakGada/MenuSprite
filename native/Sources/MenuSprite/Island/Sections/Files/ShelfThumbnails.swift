import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Small pictures for shelf tiles, decoded only for tiles on screen and dropped when the shelf is
/// hidden. Images use an ImageIO thumbnail at the well's size with caching off, videos a frame at
/// one second (or a tenth of a short clip), everything else its Finder icon redrawn small so the
/// icon's large representations are not kept. No Quick Look.
@MainActor
final class ShelfThumbnails: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    private var loading: Set<String> = []
    /// Renders only: icons by file type, never touching the disk.
    let offline: Bool
    nonisolated static let pixels = 128

    init(offline: Bool = false) { self.offline = offline }

    func image(for path: String) -> NSImage? { images[path] }

    func load(_ path: String) async {
        guard images[path] == nil, loading.insert(path).inserted else { return }
        defer { loading.remove(path) }
        let url = URL(fileURLWithPath: path)
        let type = UTType(filenameExtension: url.pathExtension)
        if offline {
            images[path] = Self.icon(NSWorkspace.shared.icon(for: type ?? .data))
            return
        }
        var picture: CGImage?
        if type?.conforms(to: .image) == true {
            picture = await Task.detached(priority: .utility) { ThumbnailBox(Self.imageThumbnail(url)) }.value.image
        } else if type?.conforms(to: .movie) == true {
            picture = await Task.detached(priority: .utility) { ThumbnailBox(await Self.videoThumbnail(url)) }.value.image
        }
        guard loading.contains(path) else { return }
        if let picture {
            images[path] = NSImage(cgImage: picture, size: NSSize(width: CGFloat(picture.width) / 2, height: CGFloat(picture.height) / 2))
        } else {
            images[path] = Self.icon(NSWorkspace.shared.icon(forFile: path))
        }
    }

    /// Renders only: every icon at once, by file type, so a single-pass render shows them.
    func preload(_ paths: [String]) {
        guard offline else { return }
        for path in paths where images[path] == nil {
            images[path] = Self.icon(NSWorkspace.shared.icon(for: UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) ?? .data))
        }
    }

    /// The shelf left the screen: let the pictures go.
    func purge() {
        images = [:]
        loading = []
    }

    static func icon(_ icon: NSImage) -> NSImage {
        let size = NSSize(width: 48, height: 48)
        return NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect)
            return true
        }.cached(scale: 2)
    }

    nonisolated private static func imageThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: false,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func videoThumbnail(_ url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        let time = CMTime(seconds: min(1, duration.seconds * 0.1), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}

/// Carries a decoded picture back from a background task.
private struct ThumbnailBox: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}

private extension NSImage {
    /// Draws once into a bitmap at `scale` so only that small representation stays in memory.
    func cached(scale: CGFloat) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return self }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
