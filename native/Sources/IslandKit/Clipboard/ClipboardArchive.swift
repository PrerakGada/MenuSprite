import Foundation

/// The history file's format: `{"version":1,"entries":[…]}`, most recent first, pinned leading. The
/// file is capped by its real encoded size; the oldest unpinned entries go first if it would not fit.
public enum ClipboardArchive {
    public static let version = 1
    public static let maximumBytes = 96 * 1024 * 1024

    public enum Failure: Error, Equatable {
        /// Written by a newer MenuSprite; left untouched.
        case newerVersion(Int)
        /// Not a history file this build understands; left untouched.
        case damaged
        /// Even the pinned entries alone do not fit the cap.
        case tooLarge
    }

    private struct Header: Decodable { var version: Int }
    private struct Body: Decodable { var version: Int; var entries: [ClipboardEntry] }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    /// Encodes `entries`, dropping the oldest unpinned ones if the file would pass `maximumBytes`.
    /// Returns the data and the entries it holds.
    public static func encode(_ entries: [ClipboardEntry], maximumBytes: Int = maximumBytes) throws -> (data: Data, kept: [ClipboardEntry]) {
        let encoder = encoder()
        let head = Data("{\"version\":\(version),\"entries\":[".utf8)
        let tail = Data("]}".utf8)
        var parts = try entries.map { try encoder.encode($0) }
        var kept = entries
        var total = head.count + tail.count + parts.reduce(0) { $0 + $1.count } + max(0, parts.count - 1)
        while total > maximumBytes {
            guard let index = kept.lastIndex(where: { !$0.isPinned }) else { throw Failure.tooLarge }
            total -= parts[index].count + (parts.count > 1 ? 1 : 0)
            parts.remove(at: index)
            kept.remove(at: index)
        }
        var data = Data(capacity: total)
        data.append(head)
        for (index, part) in parts.enumerated() {
            if index > 0 { data.append(UInt8(ascii: ",")) }
            data.append(part)
        }
        data.append(tail)
        return (data, kept)
    }

    public static func decode(_ data: Data) throws -> [ClipboardEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let header = try? decoder.decode(Header.self, from: data) else { throw Failure.damaged }
        guard header.version <= version else { throw Failure.newerVersion(header.version) }
        guard let body = try? decoder.decode(Body.self, from: data) else { throw Failure.damaged }
        return body.entries
    }

    /// Asset files in the history's folders that no entry refers to any more.
    public static func orphans(files: [String], entries: [ClipboardEntry]) -> [String] {
        let referenced = Set(entries.flatMap(\.assetNames))
        return files.filter { !referenced.contains($0) }
    }
}
