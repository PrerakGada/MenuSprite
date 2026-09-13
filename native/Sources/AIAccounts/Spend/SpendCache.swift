import Foundation

/// Per-day, per-model token totals. Used both for one file's contribution and for a provider's
/// whole-window aggregate; the shape is the same, only the scope differs.
struct DayTotals: Sendable, Codable, Equatable {
    var day: Int32
    var models: [String: TokenBreakdown]
}

/// What the app keeps in memory: 35 days times a handful of models per provider — kilobytes. Every
/// reading and every board figure is computed from this, so a scan never has to be in flight.
public struct SpendAggregate: Sendable, Codable, Equatable {
    var days: [DayTotals] = []
    var scannedAt: Double?
}

struct SpendSummaryFile: Sendable, Codable, Equatable {
    static let version = 2
    var version = SpendSummaryFile.version
    var claude = SpendAggregate()
    var codex = SpendAggregate()

    subscript(provider: AIProvider) -> SpendAggregate {
        get { provider == .claude ? claude : codex }
        set { if provider == .claude { claude = newValue } else { codex = newValue } }
    }
}

struct FileRecord: Sendable, Equatable {
    var path: String
    var size: Int64
    var modified: Double
    var days: [DayTotals]
    var skipped: Int

    /// Stable identity for ownership, so adding or removing files never renumbers anyone.
    var identity: UInt64 { SpendLogScanner.hash(path) }
}

/// Which file counted a request first. Claude replays whole conversations into resumed session files —
/// 7% of request keys in one of these projects appear in more than one file — so without this the same
/// work would be billed twice.
struct OwnedKey: Sendable, Equatable {
    var hash: UInt64
    /// `FileRecord.identity` of the owner.
    var owner: UInt64
    var day: Int32
}

/// The large half of the cache: everything needed to decide what to re-read, and nothing the app needs
/// between scans. Lives on disk; loaded inside a scan and released when it ends.
struct ProviderScanState: Sendable, Equatable {
    var files: [FileRecord] = []
    /// Sorted by hash, so ownership is a binary search rather than a dictionary rebuild.
    var owners: [OwnedKey] = []
    var scannedAt: Double?
}

struct SpendScanState: Sendable, Equatable {
    /// Bumping this discards every cached record, which is how a parser fix ships.
    static let parserVersion: UInt32 = 2
    var claude = ProviderScanState()
    var codex = ProviderScanState()

    subscript(provider: AIProvider) -> ProviderScanState {
        get { provider == .claude ? claude : codex }
        set { if provider == .claude { claude = newValue } else { codex = newValue } }
    }
}

extension ProviderScanState {
    func owner(of hash: UInt64) -> OwnedKey? {
        var low = 0, high = owners.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = owners[middle]
            if candidate.hash == hash { return candidate }
            if candidate.hash < hash { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }
}

/// The small file: a property list, because it is kilobytes and readability beats speed there.
enum SpendSummaryStore {
    static func load(_ url: URL) -> SpendSummaryFile {
        guard let data = try? Data(contentsOf: url),
              let file = try? PropertyListDecoder().decode(SpendSummaryFile.self, from: data),
              file.version == SpendSummaryFile.version else { return SpendSummaryFile() }
        return file
    }

    static func save(_ file: SpendSummaryFile, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(try encoder.encode(file), to: url, permissions: 0o600)
    }
}

/// The large file, in a format this module owns end to end.
///
/// `Codable` was the obvious choice and the wrong one: decoding 16,000 file records and 236,000
/// ownership rows through a property list builds an intermediate object graph that costs more memory
/// than the data itself. Fixed-width little-endian records parse straight out of one buffer, which is
/// what keeps a warm pass cheap.
enum SpendScanStateStore {
    private static let magic: [UInt8] = Array("MSSP".utf8)

    static func load(_ url: URL) -> SpendScanState {
        guard let data = try? Data(contentsOf: url) else { return SpendScanState() }
        var reader = BinaryReader(Array(data))
        guard reader.match(magic), let version = reader.u32(), version == SpendScanState.parserVersion,
              let providerCount = reader.u8() else { return SpendScanState() }
        var state = SpendScanState()
        for _ in 0..<providerCount {
            guard let tag = reader.u8(), let provider = AIProvider.allCases.first(where: { $0 == (tag == 0 ? .claude : .codex) }),
                  let decoded = decodeProvider(&reader) else { return SpendScanState() }
            state[provider] = decoded
        }
        return state
    }

    static func save(_ state: SpendScanState, to url: URL) throws {
        var writer = BinaryWriter()
        writer.bytes(magic)
        writer.u32(SpendScanState.parserVersion)
        writer.u8(UInt8(AIProvider.allCases.count))
        for provider in AIProvider.allCases {
            writer.u8(provider == .claude ? 0 : 1)
            encodeProvider(state[provider], into: &writer)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(writer.data, to: url, permissions: 0o600)
    }

    private static func encodeProvider(_ state: ProviderScanState, into writer: inout BinaryWriter) {
        writer.double(state.scannedAt ?? 0)
        writer.u32(UInt32(state.files.count))
        for file in state.files {
            writer.string(file.path)
            writer.i64(file.size)
            writer.double(file.modified)
            writer.i32(Int32(clamping: file.skipped))
            writer.u32(UInt32(file.days.count))
            for day in file.days {
                writer.i32(day.day)
                writer.u32(UInt32(day.models.count))
                for (model, tokens) in day.models {
                    writer.string(model)
                    writer.i64(Int64(tokens.input)); writer.i64(Int64(tokens.cacheWrite5m))
                    writer.i64(Int64(tokens.cacheWrite1h)); writer.i64(Int64(tokens.cacheRead))
                    writer.i64(Int64(tokens.output))
                }
            }
        }
        writer.u32(UInt32(state.owners.count))
        for key in state.owners {
            writer.u64(key.hash); writer.u64(key.owner); writer.i32(key.day)
        }
    }

    private static func decodeProvider(_ reader: inout BinaryReader) -> ProviderScanState? {
        guard let scannedAt = reader.double(), let fileCount = reader.u32() else { return nil }
        var state = ProviderScanState()
        state.scannedAt = scannedAt == 0 ? nil : scannedAt
        state.files.reserveCapacity(Int(fileCount))
        for _ in 0..<fileCount {
            guard let path = reader.string(), let size = reader.i64(), let modified = reader.double(),
                  let skipped = reader.i32(), let dayCount = reader.u32() else { return nil }
            var days: [DayTotals] = []
            days.reserveCapacity(Int(dayCount))
            for _ in 0..<dayCount {
                guard let day = reader.i32(), let modelCount = reader.u32() else { return nil }
                var models: [String: TokenBreakdown] = [:]
                models.reserveCapacity(Int(modelCount))
                for _ in 0..<modelCount {
                    guard let model = reader.string(), let input = reader.i64(), let write5m = reader.i64(),
                          let write1h = reader.i64(), let read = reader.i64(), let output = reader.i64() else { return nil }
                    models[model] = TokenBreakdown(input: Int(input), cacheWrite5m: Int(write5m),
                                                   cacheWrite1h: Int(write1h), cacheRead: Int(read), output: Int(output))
                }
                days.append(DayTotals(day: day, models: models))
            }
            state.files.append(FileRecord(path: path, size: size, modified: modified, days: days, skipped: Int(skipped)))
        }
        guard let ownerCount = reader.u32() else { return nil }
        state.owners.reserveCapacity(Int(ownerCount))
        for _ in 0..<ownerCount {
            guard let hash = reader.u64(), let owner = reader.u64(), let day = reader.i32() else { return nil }
            state.owners.append(OwnedKey(hash: hash, owner: owner, day: day))
        }
        return state
    }
}

struct BinaryWriter {
    private(set) var data = Data()

    mutating func bytes(_ values: [UInt8]) { data.append(contentsOf: values) }
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func i64(_ value: Int64) { u64(UInt64(bitPattern: value)) }
    mutating func double(_ value: Double) { u64(value.bitPattern) }

    /// Length-prefixed UTF-8; paths and model names are both far below the 64 KiB ceiling.
    mutating func string(_ value: String) {
        let utf8 = Array(value.utf8.prefix(Int(UInt16.max)))
        u32(UInt32(utf8.count))
        bytes(utf8)
    }
}

struct BinaryReader {
    private let bytes: [UInt8]
    private var cursor = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func match(_ expected: [UInt8]) -> Bool {
        guard cursor + expected.count <= bytes.count,
              Array(bytes[cursor..<cursor + expected.count]) == expected else { return false }
        cursor += expected.count
        return true
    }

    mutating func u8() -> UInt8? {
        guard cursor < bytes.count else { return nil }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    mutating func u32() -> UInt32? { fixed(UInt32.self).map(UInt32.init(littleEndian:)) }
    mutating func u64() -> UInt64? { fixed(UInt64.self).map(UInt64.init(littleEndian:)) }
    mutating func i32() -> Int32? { u32().map(Int32.init(bitPattern:)) }
    mutating func i64() -> Int64? { u64().map(Int64.init(bitPattern:)) }
    mutating func double() -> Double? { u64().map(Double.init(bitPattern:)) }

    mutating func string() -> String? {
        guard let length = u32(), cursor + Int(length) <= bytes.count else { return nil }
        defer { cursor += Int(length) }
        return String(decoding: bytes[cursor..<cursor + Int(length)], as: UTF8.self)
    }

    private mutating func fixed<T>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard cursor + size <= bytes.count else { return nil }
        defer { cursor += size }
        return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: T.self) }
    }
}
