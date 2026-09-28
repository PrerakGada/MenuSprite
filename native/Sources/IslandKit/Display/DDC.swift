import Foundation

/// DDC/CI framing and pacing for external monitors' luminance.
public enum IslandDDC {
    public static let chipAddress: UInt32 = 0x37
    public static let dataAddress: UInt32 = 0x51
    /// VCP code for luminance.
    public static let luminance: UInt8 = 0x10
    public static let replyLength = 11

    // Field-proven pacing: some monitors drop their signal until power-cycled when commands arrive faster.
    public static let pauseBeforeWrite: TimeInterval = 0.010
    public static let writeRepeats = 2
    public static let retries = 4
    public static let retryDelay: TimeInterval = 0.020
    public static let pauseBeforeReply: TimeInterval = 0.050
    public static let commandSpacing: TimeInterval = 0.050

    /// [0x80 | (payload length + 1), payload length, payload…, checksum]. The checksum is the XOR of the
    /// packet's bytes seeded with 0x6E, further XORed with 0x51 when the payload is longer than one byte.
    public static func packet(_ payload: [UInt8]) -> [UInt8] {
        let bytes = [0x80 | UInt8(payload.count + 1), UInt8(payload.count)] + payload
        var checksum: UInt8 = 0x6E
        for byte in bytes { checksum ^= byte }
        if payload.count > 1 { checksum ^= 0x51 }
        return bytes + [checksum]
    }

    public static func setPacket(code: UInt8 = luminance, value: UInt16) -> [UInt8] {
        packet([code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    public static func getPacket(code: UInt8 = luminance) -> [UInt8] { packet([code]) }

    public struct Reading: Equatable, Sendable {
        public var current: UInt16
        public var maximum: UInt16

        public init(current: UInt16, maximum: UInt16) {
            self.current = current
            self.maximum = maximum
        }

        /// 0…1 of the monitor's own range.
        public var level: Double { min(1, Double(current) / Double(max(1, maximum))) }
    }

    /// An 11-byte reply, checksum-seeded with 0x50: maximum in bytes 6–7, current in bytes 8–9
    /// (big-endian). A maximum of 0 means 100. nil for a short, corrupt or foreign reply.
    public static func parseReply(_ bytes: [UInt8], code: UInt8 = luminance) -> Reading? {
        guard bytes.count >= replyLength else { return nil }
        var checksum: UInt8 = 0x50
        for byte in bytes[0..<(replyLength - 1)] { checksum ^= byte }
        guard checksum == bytes[replyLength - 1], bytes[4] == code else { return nil }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        return Reading(current: current, maximum: maximum == 0 ? 100 : maximum)
    }

    /// The raw value for a 0…1 level on a monitor with this maximum.
    public static func value(level: Double, maximum: UInt16) -> UInt16 {
        let clamped = level.isFinite ? min(1, max(0, level)) : 0
        return UInt16((clamped * Double(maximum)).rounded())
    }
}

/// What identifies a display, from CoreGraphics on one side and the IORegistry on the other.
public struct IslandDisplayIdentity: Equatable, Sendable {
    /// The framebuffer's IORegistry path (the display's `IODisplayLocation`).
    public var location: String?
    public var vendor: UInt32?
    public var product: UInt32?
    public var serial: UInt32?
    public var name: String?

    public init(location: String? = nil, vendor: UInt32? = nil, product: UInt32? = nil, serial: UInt32? = nil, name: String? = nil) {
        self.location = location
        self.vendor = vendor
        self.product = product
        self.serial = serial
        self.name = name
    }
}

/// Pairs displays with DDC services by a score over their identities.
public enum IslandDisplayMatching {
    public static let locationScore = 100
    /// Without a location match, a pair needs at least vendor and product.
    public static let minimumScore = 8

    public static func score(display: IslandDisplayIdentity, service: IslandDisplayIdentity) -> Int {
        if let a = display.location, let b = service.location, !a.isEmpty, a == b { return locationScore }
        func same(_ a: UInt32?, _ b: UInt32?) -> Bool {
            guard let a, let b, a != 0 else { return false }
            return a == b
        }
        var score = 0
        if same(display.vendor, service.vendor) { score += 4 }
        if same(display.product, service.product) { score += 4 }
        if same(display.serial, service.serial) { score += 2 }
        if let a = display.name, let b = service.name, !a.isEmpty,
           a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { score += 1 }
        return score
    }

    /// Display index → service index. Best pairs first; ties keep the order both lists were found in,
    /// so two identical monitors pair up in port order.
    public static func match(displays: [IslandDisplayIdentity], services: [IslandDisplayIdentity]) -> [Int: Int] {
        var candidates: [(score: Int, display: Int, service: Int)] = []
        for (d, display) in displays.enumerated() {
            for (s, service) in services.enumerated() {
                let score = score(display: display, service: service)
                if score >= minimumScore { candidates.append((score, d, s)) }
            }
        }
        candidates.sort { ($0.score, -$0.display, -$0.service) > ($1.score, -$1.display, -$1.service) }
        var result: [Int: Int] = [:]
        var usedServices = Set<Int>()
        for candidate in candidates where result[candidate.display] == nil && !usedServices.contains(candidate.service) {
            result[candidate.display] = candidate.service
            usedServices.insert(candidate.service)
        }
        return result
    }
}
