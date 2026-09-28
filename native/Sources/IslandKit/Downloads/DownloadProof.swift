import Foundation

/// A file as the kernel reports it (`lstat`): which file it is (device and inode), how big, and when
/// it was last written. A rename keeps device and inode; a new download at the same path does not.
public struct DownloadFileIdentity: Hashable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    /// Last write, in seconds since 1970 with the nanoseconds kept.
    public var modified: Double
    public var isRegular: Bool

    public init(device: UInt64, inode: UInt64, size: Int64, modified: Double, isRegular: Bool) {
        self.device = device; self.inode = inode; self.size = size; self.modified = modified; self.isRegular = isRegular
    }

    /// The same file on disk, whatever its size or name now.
    public func isSameFile(as other: DownloadFileIdentity?) -> Bool {
        guard let other else { return false }
        return device == other.device && inode == other.inode
    }
}

/// When a download counts as finished. Nothing is called finished on a guess: an unrelated file that
/// happens to sit at the destination never produces a "Download complete".
public enum DownloadProof {
    /// A published transfer is finished when the publisher says so, a regular file exists at its URL,
    /// that file is not the one that was there when the transfer was first seen, and the URL no longer
    /// carries an in-progress extension.
    public static func publicationFinished(isFinished: Bool, url: URL, current: DownloadFileIdentity?,
                                           baseline: DownloadFileIdentity?) -> Bool {
        guard isFinished, let current, current.isRegular, !DownloadNaming.isPartial(url) else { return false }
        return current != baseline
    }

    /// A publisher moved its transfer to a new URL. It stays the same download only when the file now
    /// at the new URL is the file last seen at the old one, and the old path is gone.
    public static func acceptsMove(lastSeen: DownloadFileIdentity?, moved: DownloadFileIdentity?, oldPathExists: Bool) -> Bool {
        guard !oldPathExists, let moved else { return false }
        return moved.isSameFile(as: lastSeen)
    }

    /// A browser's partial finished when it disappeared and a regular file with its final name exists
    /// that is the same file (a rename keeps the inode).
    public static func partialFinished(partial: DownloadFileIdentity?, partialStillExists: Bool,
                                       final: DownloadFileIdentity?) -> Bool {
        guard !partialStillExists, let partial, let final, final.isRegular else { return false }
        return final.isSameFile(as: partial)
    }
}

/// Which published transfers the island shows, and what it reads from them.
public enum DownloadPublication {
    /// The file operation a publisher declares.
    public enum Operation: Sendable, Equatable {
        case downloading, receiving, other
    }

    /// A publication is shown only while it is not cancelled, is downloading or receiving, and its file
    /// (as published, or with symbolic links resolved) sits directly inside the watched folder.
    public static func accepts(cancelled: Bool, operation: Operation, candidates: [URL], folders: [URL]) -> Bool {
        guard !cancelled, operation != .other else { return false }
        return candidates.contains { candidate in folders.contains { isDirectChild(candidate, of: $0) } }
    }

    /// True for an item directly inside `folder`, never for the folder itself or anything deeper.
    /// Purely textual: `standardizedFileURL` would drop a leading /private only for paths that exist,
    /// so a file not written yet would stop matching its folder.
    public static func isDirectChild(_ url: URL, of folder: URL) -> Bool {
        let child = normalized(url.standardized.path)
        let parent = normalized(folder.standardized.path)
        guard child != parent, !child.isEmpty else { return false }
        return normalized((child as NSString).deletingLastPathComponent) == parent
    }

    /// The fraction worth drawing: only for a determinate transfer with a positive total, clamped 0…1.
    public static func fraction(_ fractionCompleted: Double, total: Int64, indeterminate: Bool) -> Double? {
        guard !indeterminate, total > 0, fractionCompleted.isFinite else { return nil }
        return min(1, max(0, fractionCompleted))
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
