import AppKit
import AVFoundation
import IslandKit
import ImageIO
import UniformTypeIdentifiers

/// Encoding and file work for captures. Everything here is safe off the main thread, and the heavy
/// parts (encoding, writing, thumbnails) are only ever called there.
enum CaptureFiles {
    /// `~/Library/Caches/<bundle id>/Captures`: the history and the transfer copies.
    static var cachesRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "in.prerakgada.MenuSprite", isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
    }

    static var historyFolder: URL { cachesRoot.appendingPathComponent("History", isDirectory: true) }
    static var transfersFolder: URL { cachesRoot.appendingPathComponent("Transfers", isDirectory: true) }

    /// A PNG carrying the display's resolution (scale × 72 dpi), so it opens at its real size.
    static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * max(scale, 1)
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A copy no larger than `pixels` on its long side.
    static func downscaled(_ image: CGImage, pixels: CGFloat) -> CGImage? {
        let size = CapturePreviewLayout.fitted(CGSize(width: image.width, height: image.height),
                                               in: CGSize(width: pixels, height: pixels))
        guard size.width > 0, size.height > 0 else { return nil }
        if Int(size.width) == image.width, Int(size.height) == image.height { return image }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    /// The history's thumbnail: at most 360 px.
    static func thumbnail(_ image: CGImage) -> Data? {
        downscaled(image, pixels: 360).flatMap { png($0, scale: 1) }
    }

    /// A PNG's size in points, from the resolution it was saved with.
    static func pointSize(of data: Data, image: CGImage) -> CGSize {
        var scale: CGFloat = 1
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 0 {
            scale = max(1, CGFloat(dpi) / 72)
        }
        return CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    /// For apps that paste only TIFF.
    static func tiff(_ png: Data) -> Data? { NSBitmapImageRep(data: png)?.tiffRepresentation }

    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The first frame of a recording, at most 360 px.
    static func firstFrame(of url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        guard let frame = try? await generator.image(at: .zero).image else { return nil }
        return png(frame, scale: 1)
    }

    /// Saves a screenshot into `folder` under a fresh name and tells Spotlight it is a screen capture.
    static func save(_ png: Data, date: Date, in folder: URL) throws -> URL {
        let manager = FileManager.default
        guard let name = CaptureNaming.unique(base: CaptureNaming.baseName(.screenshot, date: date), fileExtension: "png",
                                              exists: { manager.fileExists(atPath: folder.appendingPathComponent($0).path) }) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let url = folder.appendingPathComponent(name)
        try png.write(to: url, options: .withoutOverwriting)
        markAsScreenCapture(url)
        return url
    }

    /// A fresh, unused path for a new recording.
    static func recordingURL(date: Date, in folder: URL) -> URL? {
        let manager = FileManager.default
        return CaptureNaming.unique(base: CaptureNaming.baseName(.recording, date: date), fileExtension: "mov",
                                    exists: { manager.fileExists(atPath: folder.appendingPathComponent($0).path) })
            .map { folder.appendingPathComponent($0) }
    }

    static func markAsScreenCapture(_ url: URL) {
        guard let value = try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0) else { return }
        _ = value.withUnsafeBytes { bytes in
            setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", bytes.baseAddress, bytes.count, 0, 0)
        }
    }

    /// A named copy in the private transfer folder, for the clipboard and for drags, so what lands in
    /// Finder carries the capture's real name. The folder is pruned first.
    static func transferCopy(_ data: Data, named name: String) throws -> URL {
        let folder = try prepareTransfers()
        let slot = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = slot.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// The same, copying a file already on disk rather than reading it into memory.
    static func transferCopy(of source: URL, named name: String) throws -> URL {
        let folder = try prepareTransfers()
        let slot = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = slot.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func prepareTransfers() throws -> URL {
        let manager = FileManager.default
        let folder = transfersFolder
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let slots = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey])) ?? []
        var files: [CaptureTransferFile] = []
        for slot in slots {
            let values = try? slot.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { continue }
            let bytes = ((try? manager.contentsOfDirectory(at: slot, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            files.append(CaptureTransferFile(name: slot.lastPathComponent, modified: values?.contentModificationDate ?? .distantPast, bytes: bytes))
        }
        for name in CaptureTransfers.expired(files, now: Date()) {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
        return folder
    }

    /// Free space where recordings are written, as the system reports it for important files.
    static func freeSpace(at folder: URL) -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}

/// The general pasteboard: one item carrying the file, the PNG and a TIFF, so every kind of app can
/// paste a screenshot.
@MainActor
enum CapturePasteboard {
    static func copyImage(file: URL, png: Data, tiff: Data?) {
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        item.setData(png, forType: .png)
        if let tiff { item.setData(tiff, forType: .tiff) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    static func copyFile(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }
}
