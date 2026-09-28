import Foundation
import IslandKit

/// A place in one session log: how far it has been read, which file that was, and the start of a
/// line still being written. Only bytes appended after it are ever read again.
struct AgentLogCursor: Sendable {
    let url: URL
    var offset: UInt64
    var inode: UInt64
    var modified: Date
    var pending = Data()
    /// Skipping to the end of a line: a mid-file start, or a line over the size cap.
    var discarding = false
}

struct AgentFileInfo: Sendable {
    var size: UInt64
    var inode: UInt64
    var modified: Date
}

/// Reads the tails of the agents' session logs. Never a whole history: a turn's own bytes (bounded)
/// when it is first seen, then only what was appended. Called on the agents queue only.
enum AgentLogReader {
    static let chunkBytes = 1 << 20
    /// A line longer than this is a pasted file or media, not something the island needs.
    static let lineCap = 16 << 20
    static let probeBytes = 65_536

    static func info(_ url: URL) -> AgentFileInfo? {
        var status = stat()
        guard stat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        let modified = Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000
        return AgentFileInfo(size: UInt64(status.st_size), inode: UInt64(status.st_ino), modified: Date(timeIntervalSince1970: modified))
    }

    /// A cursor at `offset`; anywhere but the start skips to the next whole line.
    static func cursor(_ url: URL, at offset: UInt64, info: AgentFileInfo) -> AgentLogCursor {
        AgentLogCursor(url: url, offset: offset, inode: info.inode, modified: info.modified, discarding: offset > 0)
    }

    /// A cursor at the end: nothing already written will be read.
    static func cursorAtEnd(_ url: URL, info: AgentFileInfo) -> AgentLogCursor {
        AgentLogCursor(url: url, offset: info.size, inode: info.inode, modified: info.modified)
    }

    /// Hands over each complete line appended since the cursor. A replaced or shortened file is read
    /// again from its start. Returns false when the file is gone.
    @discardableResult
    static func readAppended(_ cursor: inout AgentLogCursor, _ body: (Data) -> Void) -> Bool {
        guard let info = info(cursor.url) else { return false }
        if info.inode != cursor.inode || info.size < cursor.offset {
            cursor.offset = 0
            cursor.inode = info.inode
            cursor.pending = Data()
            cursor.discarding = false
        }
        cursor.modified = info.modified
        guard info.size > cursor.offset, let handle = try? FileHandle(forReadingFrom: cursor.url) else { return true }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: cursor.offset)) != nil else { return true }
        var remaining = info.size - cursor.offset
        while remaining > 0 {
            guard let chunk = try? handle.read(upToCount: Int(min(UInt64(chunkBytes), remaining))), !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count)
            cursor.offset += UInt64(chunk.count)
            autoreleasepool { split(chunk, into: &cursor, body) }
        }
        return true
    }

    private static func split(_ chunk: Data, into cursor: inout AgentLogCursor, _ body: (Data) -> Void) {
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 0x0A) {
            if cursor.discarding {
                cursor.discarding = false
            } else if cursor.pending.isEmpty {
                if newline > start, newline - start <= lineCap { body(chunk[start..<newline]) }
            } else if cursor.pending.count + (newline - start) <= lineCap {
                cursor.pending.append(chunk[start..<newline])
                body(cursor.pending)
                cursor.pending = Data()
            } else {
                cursor.pending = Data()
            }
            start = newline + 1
        }
        guard start < chunk.endIndex, !cursor.discarding else { return }
        if cursor.pending.count + (chunk.endIndex - start) > lineCap {
            // An oversized line holds nothing while it is skipped, even across later chunks.
            cursor.pending = Data()
            cursor.discarding = true
        } else {
            cursor.pending.append(chunk[start...])
        }
    }

    /// Where to start reading a turn that began at `start`: the latest point, looking back at most
    /// `cap` bytes in growing steps, whose first timestamped line is older. `complete` is false when
    /// the turn began further back than the cap.
    static func offset(before start: Date, url: URL, size: UInt64, cap: UInt64) -> (offset: UInt64, complete: Bool) {
        var window: UInt64 = 262_144
        while true {
            if window >= size { return (0, true) }
            if window > cap { return (size - cap, false) }
            let offset = size - window
            if let time = firstTimestamp(url, at: offset), time < start { return (offset, true) }
            window *= 4
        }
    }

    /// Where to start reading so the last of `markers` is included, looking back at most `cap` bytes.
    static func offset(containingLastOf markers: [StaticString], url: URL, size: UInt64, cap: UInt64) -> (offset: UInt64, found: Bool) {
        var window: UInt64 = 1 << 20
        while true {
            let span = min(window, size, cap)
            let offset = size - span
            if let data = read(url, at: offset, count: Int(span)), markers.contains(where: { AgentBytes.contains(data, $0) }) {
                return (offset, true)
            }
            if span == size { return (0, false) }
            if window >= cap { return (offset, false) }
            window *= 4
        }
    }

    /// The newest timestamp in the last 256 KiB: when the log last recorded work.
    static func lastTimestamp(_ url: URL, size: UInt64) -> Date? {
        let span = min(size, 262_144)
        guard let data = read(url, at: size - span, count: Int(span)) else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            if let time = AgentBytes.timestamp(in: line) { return time }
        }
        return nil
    }

    private static func firstTimestamp(_ url: URL, at offset: UInt64) -> Date? {
        guard let data = read(url, at: offset, count: probeBytes) else { return nil }
        // The first piece is the tail of a line cut by the offset, and the last may be incomplete.
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false).dropFirst().dropLast() {
            if let time = AgentBytes.timestamp(in: line) { return time }
        }
        return nil
    }

    private static func read(_ url: URL, at offset: UInt64, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: count)
    }
}
