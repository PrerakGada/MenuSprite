import Foundation

/// What a history entry holds. Kinds never merge: the same words copied as text and as a file name
/// stay two entries.
public enum ClipboardKind: String, Codable, Sendable {
    case text, image, files
}

/// A stored PNG beside the history file.
public struct ClipboardImage: Codable, Sendable, Hashable {
    /// The file's name in the history's image folder, "<uuid>.png".
    public var file: String
    public var sha256: String
    public var width: Int
    public var height: Int
    public var bytes: Int

    public init(file: String, sha256: String, width: Int, height: Int, bytes: Int) {
        self.file = file; self.sha256 = sha256; self.width = width; self.height = height; self.bytes = bytes
    }

    /// "1280×720", as cards and search show it.
    public var dimensions: String { "\(width)×\(height)" }
}

/// The RTF that came with copied text, kept beside the history so pasting restores the formatting.
public struct ClipboardRichText: Codable, Sendable, Hashable {
    public var file: String
    public var bytes: Int
    public init(file: String, bytes: Int) { self.file = file; self.bytes = bytes }
}

/// One thing that was copied. No source app is ever stored.
public struct ClipboardEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var kind: ClipboardKind
    /// The copied text; empty for images and files.
    public var text: String
    /// Absolute paths, in the order they were copied.
    public var files: [String]
    public var image: ClipboardImage?
    public var rich: ClipboardRichText?
    public var lastUsed: Date
    public var pinnedAt: Date?

    public init(id: UUID = UUID(), kind: ClipboardKind, text: String = "", files: [String] = [], image: ClipboardImage? = nil,
                rich: ClipboardRichText? = nil, lastUsed: Date, pinnedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.files = files; self.image = image; self.rich = rich
        self.lastUsed = lastUsed; self.pinnedAt = pinnedAt
    }

    public static func text(_ text: String, rich: ClipboardRichText? = nil, at date: Date) -> ClipboardEntry {
        ClipboardEntry(kind: .text, text: text, rich: rich, lastUsed: date)
    }

    public static func files(_ paths: [String], at date: Date) -> ClipboardEntry {
        ClipboardEntry(kind: .files, files: paths, lastUsed: date)
    }

    public static func image(_ image: ClipboardImage, at date: Date) -> ClipboardEntry {
        ClipboardEntry(kind: .image, image: image, lastUsed: date)
    }

    public var isPinned: Bool { pinnedAt != nil }

    /// Text by exact string, images by PNG hash, files by the same ordered path list.
    public func duplicates(_ other: ClipboardEntry) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .text: return text == other.text
        case .image: return image?.sha256 != nil && image?.sha256 == other.image?.sha256
        case .files: return files == other.files
        }
    }

    /// Bytes this entry adds to the saved JSON, measured as escaped JSON so a text full of quotes or
    /// control characters counts at the size it really takes (the budget can never overflow the file).
    public var storageBytes: Int {
        Self.escapedBytes(text) + files.reduce(0) { $0 + Self.escapedBytes($1) + 3 } + 320
    }

    /// Files other than the JSON this entry keeps on disk.
    public var assetBytes: Int { (image?.bytes ?? 0) + (rich?.bytes ?? 0) }

    public var assetNames: [String] { [image?.file, rich?.file].compactMap { $0 } }

    /// The size of `text` once written as a JSON string body (slashes are not escaped).
    public static func escapedBytes(_ text: String) -> Int {
        var count = 0
        for byte in text.utf8 {
            switch byte {
            case 0x22, 0x5C, 0x08, 0x0C, 0x0A, 0x0D, 0x09: count += 2
            case 0..<0x20: count += 6
            default: count += 1
            }
        }
        return count
    }
}

/// The history's size limit: a count of unpinned entries. Pinned entries never count.
public enum ClipboardLimit: Hashable, Sendable {
    case count(Int)
    case unlimited

    /// The choices offered, as stored (0 is Unlimited).
    public static let storedChoices = [20, 50, 100, 250, 500, 1000, 10_000, 0]
    public static let standard = ClipboardLimit.count(50)

    /// Unknown stored values fall back to 50.
    public init(stored: Int) {
        guard Self.storedChoices.contains(stored) else { self = .standard; return }
        self = stored == 0 ? .unlimited : .count(stored)
    }

    public var stored: Int {
        switch self {
        case .count(let value): value
        case .unlimited: 0
        }
    }

    public var title: String {
        switch self {
        case .count(let value): value.formatted()
        case .unlimited: "Unlimited"
        }
    }
}
