import AppKit
import CryptoKit
import ImageIO
import IslandKit

/// Whether MenuSprite may read what other apps copy without macOS asking. Since macOS 15.4 the
/// general pasteboard asks the person before an app reads it programmatically, unless they chose
/// "Allow" for the app in Privacy & Security › Paste from Other Apps.
enum ClipboardReadAccess: Equatable, Sendable {
    /// "Allow": reads happen silently.
    case allowed
    /// Never asked yet: the first read would raise the system alert, and MenuSprite is not listed.
    case notAsked
    /// "Ask": every read raises the system alert.
    case asks
    /// "Deny": reads return nothing.
    case denied

    init(_ behavior: NSPasteboard.AccessBehavior) {
        switch behavior {
        case .alwaysAllow: self = .allowed
        case .default: self = .notAsked
        case .ask: self = .asks
        case .alwaysDeny: self = .denied
        @unknown default: self = .asks
        }
    }

    var allowsAutomaticReads: Bool { self == .allowed }
}

struct ClipboardReadOptions: Sendable {
    var includeMedia: Bool
    var skipSensitive: Bool
}

/// A copied image, already a PNG, with a small thumbnail made while it was in hand.
struct ClipboardCapturedImage: @unchecked Sendable {
    let png: Data
    let sha256: String
    let width: Int
    let height: Int
    let thumbnail: CGImage?
}

/// What one read found.
enum ClipboardReadResult: Sendable {
    /// The count matched; nothing was read.
    case unchanged
    /// macOS would ask (or refuse): nothing was read.
    case blocked(ClipboardReadAccess)
    /// Marked private, sensitive-looking, empty, or too large: nothing is kept.
    case skipped
    case text(String, rtf: Data?)
    case image(ClipboardCapturedImage)
    case files([String])
}

/// All pasteboard access for the history runs on one serial queue off the main thread, so a
/// stalled pasteboard server can never freeze typing.
enum ClipboardPasteboard {
    static let queue = DispatchQueue(label: "in.prerakgada.MenuSprite.clipboard.pasteboard", qos: .utility)
    static let maximumPNG = 16 << 20
    static let maximumTIFF = 64 << 20
    static let maximumRTF = 2 << 20
    static let maximumFiles = 100
    static let thumbnailPixels = 480

    /// One poll: the change count always, the contents only when the ticket allows it.
    static func poll(_ name: NSPasteboard.Name, ticket: ClipboardCaptureGate.Ticket, options: ClipboardReadOptions,
                     completion: @escaping @MainActor @Sendable (Int, ClipboardReadResult) -> Void) {
        queue.async {
            let pasteboard = NSPasteboard(name: name)
            let count = pasteboard.changeCount
            let result = ClipboardCaptureGate.shouldRead(count: count, ticket: ticket) ? read(pasteboard, options: options) : .unchanged
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(count, result) } }
        }
    }

    /// The system's current answer for the general pasteboard. Reading it reads no content.
    static func access(_ name: NSPasteboard.Name, completion: @escaping @MainActor @Sendable (ClipboardReadAccess) -> Void) {
        queue.async {
            let access = ClipboardReadAccess(NSPasteboard(name: name).accessBehavior)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(access) } }
        }
    }

    /// Only after the person pressed "Ask macOS": one read of the copied text (discarded), which is
    /// what makes macOS show its alert and list MenuSprite in Privacy & Security.
    static func askSystem(_ name: NSPasteboard.Name, completion: @escaping @MainActor @Sendable (ClipboardReadAccess) -> Void) {
        queue.async {
            let pasteboard = NSPasteboard(name: name)
            _ = pasteboard.string(forType: .string)
            let access = ClipboardReadAccess(pasteboard.accessBehavior)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(access) } }
        }
    }

    /// Detection order: private markers (read nothing), files, an image, then text.
    static func read(_ pasteboard: NSPasteboard, options: ClipboardReadOptions) -> ClipboardReadResult {
        let access = ClipboardReadAccess(pasteboard.accessBehavior)
        guard access.allowsAutomaticReads else { return .blocked(access) }
        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard !types.isEmpty, !ClipboardPrivacy.skips(types: types) else { return .skipped }
        if options.includeMedia {
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               (1...maximumFiles).contains(urls.count) {
                return .files(urls.map(\.path))
            }
            if let image = readImage(pasteboard, types: types) { return .image(image) }
        }
        let rtf = types.contains(NSPasteboard.PasteboardType.rtf.rawValue)
            ? pasteboard.data(forType: .rtf).flatMap { $0.count <= maximumRTF ? $0 : nil } : nil
        guard let string = pasteboard.string(forType: .string) ?? rtf.flatMap({ NSAttributedString(rtf: $0, documentAttributes: nil)?.string }),
              let text = ClipboardText.normalize(string, webURL: pasteboard.string(forType: .URL)) else { return .skipped }
        if options.skipSensitive && ClipboardPrivacy.looksSensitive(text) { return .skipped }
        return .text(text, rtf: rtf)
    }

    /// A PNG up to 16 MiB, or a TIFF up to 64 MiB turned into a PNG of at most 16 MiB.
    private static func readImage(_ pasteboard: NSPasteboard, types: [String]) -> ClipboardCapturedImage? {
        if types.contains(NSPasteboard.PasteboardType.png.rawValue), let data = pasteboard.data(forType: .png), data.count <= maximumPNG {
            return image(png: data)
        }
        if types.contains(NSPasteboard.PasteboardType.tiff.rawValue), let data = pasteboard.data(forType: .tiff), data.count <= maximumTIFF,
           let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]), png.count <= maximumPNG {
            return image(png: png)
        }
        return nil
    }

    static func image(png: Data) -> ClipboardCapturedImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        return ClipboardCapturedImage(png: png, sha256: hash, width: width, height: height, thumbnail: thumbnail(source))
    }

    static func thumbnail(_ source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Writes an entry back within 5 s of being asked: text (with its RTF), an image as PNG (plus
    /// TIFF), or the files that still exist. A missing image or no remaining files fails the write.
    static func write(_ entry: ClipboardEntry, image: URL?, rich: URL?, to name: NSPasteboard.Name,
                      completion: @escaping @MainActor @Sendable (ClipboardWriteSequence.Outcome) -> Void) {
        let queued = Date()
        queue.async {
            var required: [ClipboardRepresentation] = []
            var optional: [ClipboardRepresentation] = []
            switch entry.kind {
            case .text:
                required = [.string(entry.text)]
                if let rich, let data = try? Data(contentsOf: rich) { optional = [.data(data, type: NSPasteboard.PasteboardType.rtf.rawValue)] }
            case .image:
                if let image, let png = try? Data(contentsOf: image) {
                    required = [.data(png, type: NSPasteboard.PasteboardType.png.rawValue)]
                    if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                        optional = [.data(tiff, type: NSPasteboard.PasteboardType.tiff.rawValue)]
                    }
                }
            case .files:
                let existing = entry.files.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
                if !existing.isEmpty { required = [.fileURLs(existing)] }
            }
            let outcome = ClipboardWriteSequence.perform(required: required, optional: optional,
                                                         on: PasteboardWriter(pasteboard: NSPasteboard(name: name)),
                                                         expired: { Date().timeIntervalSince(queued) > ClipboardCaptureGate.deadline })
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(outcome) } }
        }
    }
}

/// An `NSPasteboard` as the write sequence sees it. Used only on the pasteboard queue.
private struct PasteboardWriter: ClipboardWritable {
    let pasteboard: NSPasteboard

    func clear() -> Int { pasteboard.clearContents() }

    func write(_ representation: ClipboardRepresentation) -> Bool {
        switch representation {
        case .string(let text): pasteboard.setString(text, forType: .string)
        case .data(let data, let type): pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type))
        case .fileURLs(let urls): pasteboard.writeObjects(urls.map { $0 as NSURL })
        }
    }

    var changeCount: Int { pasteboard.changeCount }
}
