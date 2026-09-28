import Foundation

/// Who an accessory is for its low-battery episode: its kind and its trimmed, lowercased name. Not
/// a source's identifier, so the same accessory reported by two sources keeps one episode.
public struct AccessoryIdentity: Hashable, Sendable {
    public let kind: AccessoryKind
    public let name: String

    public init(kind: AccessoryKind, name: String) {
        self.kind = kind
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// An accessory's charge, part by part. Earbuds report each bud and their case separately; most
/// other accessories report one level.
public struct AccessoryLevel: Equatable, Sendable {
    public var main: Int?
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?
    /// Any other part the Bluetooth report names.
    public var others: [Int]

    public init(main: Int? = nil, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil, others: [Int] = []) {
        self.main = main; self.left = left; self.right = right; self.caseLevel = caseLevel; self.others = others
    }

    public var isEmpty: Bool { main == nil && left == nil && right == nil && caseLevel == nil && others.isEmpty }

    /// The level that decides a low-battery warning: the device's own level, else its lowest part
    /// other than the charging case. A case at 15% with both buds full is not worth interrupting
    /// for; the buds are what run out mid-call. Nil when only the case reported.
    public var warningLevel: Int? {
        main ?? ([left, right].compactMap { $0 } + others).min()
    }
}

/// One accessory battery reading from one source, stamped with when that source actually read it,
/// so a cached value served again is never mistaken for a new one.
public struct AccessoryReading: Equatable, Sendable {
    /// The source's own identifier (a serial number, a Bluetooth address, a registry entry).
    public var id: String
    /// The Bluetooth address, normalised, when the source reports one.
    public var address: String?
    public var name: String
    public var kind: AccessoryKind
    public var level: AccessoryLevel
    public var observedAt: Date

    public init(id: String, address: String? = nil, name: String, kind: AccessoryKind, level: AccessoryLevel, observedAt: Date) {
        self.id = id; self.address = address; self.name = name; self.kind = kind; self.level = level; self.observedAt = observedAt
    }

    public var identity: AccessoryIdentity { AccessoryIdentity(kind: kind, name: name) }

    /// Several sources' readings as one list. Duplicates are merged by source identifier, then by
    /// name and kind; the freshest reading of a device wins, and the earlier source wins a tie.
    public static func merge(_ sources: [[AccessoryReading]]) -> [AccessoryReading] {
        var result: [AccessoryReading] = []
        var byID: [String: Int] = [:]
        var byIdentity: [AccessoryIdentity: Int] = [:]
        for reading in sources.joined() {
            if let index = byID[reading.id] ?? byIdentity[reading.identity] {
                guard reading.observedAt > result[index].observedAt else { continue }
                result[index] = reading
                byID[reading.id] = index
                byIdentity[reading.identity] = index
            } else {
                byID[reading.id] = result.count
                byIdentity[reading.identity] = result.count
                result.append(reading)
            }
        }
        return result
    }
}

/// Bluetooth addresses as one spelling, whichever source reported them: six lowercase hex pairs
/// joined by colons. CoreAudio spells them with dashes inside a device UID, IORegistry sometimes
/// with dashes, the Bluetooth report with capitals and colons.
public enum AccessoryAddress {
    public static func normalize(_ raw: String) -> String? {
        let parts = raw.trimmingCharacters(in: .whitespaces).lowercased().split { $0 == ":" || $0 == "-" }
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return parts.joined(separator: ":")
    }

    /// A Bluetooth audio device's UID is its address followed by a role, such as
    /// "02-00-00-00-00-01:output".
    public static func fromAudioUID(_ uid: String) -> String? {
        normalize(String(uid.prefix { $0 != ":" }))
    }

    /// Six raw bytes, as some registry entries store an address.
    public static func fromBytes(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 6 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
