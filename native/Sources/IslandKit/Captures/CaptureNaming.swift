import Foundation

/// A screenshot or a screen recording.
public enum CaptureKind: String, Codable, Sendable {
    case screenshot, recording

    public var title: String { self == .screenshot ? "Screenshot" : "Recording" }
    public var fileExtension: String { self == .screenshot ? "png" : "mov" }
}

/// File names for saved captures: "Screenshot 2026-09-28 at 14.03.22.png", the same digits whatever
/// the language, with " 2", " 3" … added when the name is taken.
public enum CaptureNaming {
    public static let maximumCopies = 9999

    public static func baseName(_ kind: CaptureKind, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(kind.title) \(formatter.string(from: date))"
    }

    public static func fileName(_ kind: CaptureKind, date: Date, timeZone: TimeZone = .current) -> String {
        "\(baseName(kind, date: date, timeZone: timeZone)).\(kind.fileExtension)"
    }

    /// The first free name: "base.ext", then "base 2.ext" up to "base 9999.ext"; nil when all are taken.
    public static func unique(base: String, fileExtension: String, exists: (String) -> Bool) -> String? {
        let first = "\(base).\(fileExtension)"
        if !exists(first) { return first }
        for copy in 2...maximumCopies {
            let name = "\(base) \(copy).\(fileExtension)"
            if !exists(name) { return name }
        }
        return nil
    }
}

/// A file in the private folder that backs clipboard copies and drags of captures.
public struct CaptureTransferFile: Equatable, Sendable {
    public var name: String
    public var modified: Date
    public var bytes: Int64
    public init(name: String, modified: Date, bytes: Int64) { self.name = name; self.modified = modified; self.bytes = bytes }
}

/// The transfer folder is pruned to a day, 100 files and 256 MiB, newest kept first.
public enum CaptureTransfers {
    public static let maximumAge: TimeInterval = 24 * 60 * 60
    public static let maximumCount = 100
    public static let maximumBytes: Int64 = 256 << 20

    /// Names to delete.
    public static func expired(_ files: [CaptureTransferFile], now: Date) -> Set<String> {
        var doomed = Set<String>()
        var count = 0
        var bytes: Int64 = 0
        for file in files.sorted(by: { $0.modified > $1.modified }) {
            if now.timeIntervalSince(file.modified) > maximumAge || count >= maximumCount || bytes + file.bytes > maximumBytes {
                doomed.insert(file.name)
            } else {
                count += 1
                bytes += file.bytes
            }
        }
        return doomed
    }
}
