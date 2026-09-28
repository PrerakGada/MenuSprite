import CoreGraphics
import Foundation

/// One entry of the recent-captures history. A screenshot keeps a full-resolution copy of itself in
/// the history folder (so one that was only copied can come back) and a small thumbnail; a recording
/// keeps only its path and a thumbnail of its first frame.
public struct RecentCapture: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: CaptureKind
    public var date: Date
    /// Where the capture was saved: the screenshot in the save folder (nil when it was only copied),
    /// or the recording's video.
    public var fileURL: URL?
    /// Names inside the history folder: the cached full image (screenshots only) and the thumbnail.
    public var imageName: String?
    public var thumbnailName: String?
    /// The cached image's size on disk, counted against the history's budget.
    public var imageBytes: Int64
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(id: UUID = UUID(), kind: CaptureKind, date: Date, fileURL: URL? = nil, imageName: String? = nil,
                thumbnailName: String? = nil, imageBytes: Int64 = 0, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.id = id; self.kind = kind; self.date = date; self.fileURL = fileURL; self.imageName = imageName
        self.thumbnailName = thumbnailName; self.imageBytes = imageBytes; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    /// Files in the history folder this entry owns.
    public var ownedNames: [String] { [imageName, thumbnailName].compactMap { $0 } }
    /// The name a copy or drag of this capture carries.
    public var displayName: String {
        fileURL?.lastPathComponent ?? CaptureNaming.fileName(kind, date: date)
    }
}

/// The history's rules, independent of the disk.
public enum RecentCapturesList {
    public static let capacity = 12
    /// Cached screenshot images may use this much; the newest screenshot is kept whatever its size.
    public static let imageBudget: Int64 = 256 << 20

    /// Adds a capture as the newest entry. Re-adding the same saved file replaces its entry.
    public static func inserting(_ entry: RecentCapture, into entries: [RecentCapture]) -> [RecentCapture] {
        let rest = entries.filter { $0.id != entry.id && (entry.fileURL == nil || $0.fileURL?.standardizedFileURL != entry.fileURL?.standardizedFileURL) }
        return limited([entry] + rest)
    }

    /// Newest first, at most 12, and older screenshots left out once cached images would pass the budget.
    public static func limited(_ entries: [RecentCapture]) -> [RecentCapture] {
        var kept: [RecentCapture] = []
        var bytes: Int64 = 0
        var sawScreenshot = false
        for entry in entries.sorted(by: { $0.date > $1.date }) {
            guard kept.count < capacity else { break }
            if entry.kind == .screenshot {
                if sawScreenshot, bytes + entry.imageBytes > imageBudget { continue }
                sawScreenshot = true
                bytes += entry.imageBytes
            }
            kept.append(entry)
        }
        return kept
    }

    /// Drops entries whose file is gone: a screenshot's cached image, or a recording's video. Moved
    /// files are not followed.
    public static func present(_ entries: [RecentCapture], exists: (RecentCapture) -> Bool) -> [RecentCapture] {
        entries.filter(exists)
    }
}

/// The Recent captures rail: 236-pt cards 8 pt apart, in as many rows of at least 88 pt as the page
/// height holds, flowing into further columns that scroll sideways.
public struct CaptureRailLayout: Equatable, Sendable {
    public static let cardWidth: CGFloat = 236
    public static let spacing: CGFloat = 8
    public static let minimumCardHeight: CGFloat = 88
    /// Below this card height the buttons move beside the thumbnail instead of under it.
    public static let roomyCardHeight: CGFloat = 118

    public var rows: Int
    public var cardHeight: CGFloat

    public init(height: CGFloat) {
        rows = max(1, Int((height + Self.spacing) / (Self.minimumCardHeight + Self.spacing)))
        cardHeight = max(0, (height - CGFloat(rows - 1) * Self.spacing) / CGFloat(rows))
    }

    public func columns(for count: Int) -> Int { count == 0 ? 0 : (count + rows - 1) / rows }

    public func contentWidth(for count: Int) -> CGFloat {
        let columns = columns(for: count)
        return columns == 0 ? 0 : CGFloat(columns) * Self.cardWidth + CGFloat(columns - 1) * Self.spacing
    }

    public var isRoomy: Bool { cardHeight >= Self.roomyCardHeight }
}
