import CoreGraphics
import Foundation

/// What an accessory notice says, independent of how the island draws it.
public struct AccessoryNoticeContent: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case connected
        case lowBattery(Int)
    }

    public var reason: Reason
    public var name: String
    public var kind: AccessoryKind
    /// For withdrawing a queued low-battery warning when the device recovers.
    public var identity: AccessoryIdentity
    /// For dropping a device's queued notices when it disconnects.
    public var address: String?
    public var level: AccessoryLevel

    public static func connected(_ device: AccessoryDevice, kind: AccessoryKind) -> AccessoryNoticeContent {
        AccessoryNoticeContent(reason: .connected, name: device.name, kind: kind,
                               identity: AccessoryIdentity(kind: kind, name: device.name), address: device.address,
                               level: AccessoryLevel())
    }

    public static func lowBattery(_ reading: AccessoryReading) -> AccessoryNoticeContent? {
        guard let percent = reading.level.warningLevel else { return nil }
        return AccessoryNoticeContent(reason: .lowBattery(percent), name: reading.name, kind: reading.kind,
                                      identity: reading.identity, address: reading.address, level: reading.level)
    }

    public var isLowBattery: Bool { if case .lowBattery = reason { true } else { false } }
    public var symbol: String { kind.symbol }

    public var title: String {
        switch reason {
        case .connected: "Connected"
        case .lowBattery(let percent): "Low battery · \(percent)%"
        }
    }

    /// The device's name for a connection; nothing for a low battery, whose right wing is a meter
    /// and whose symbol already says what kind of device it is.
    public var detail: String {
        switch reason {
        case .connected: name
        case .lowBattery: ""
        }
    }

    public var meter: Double? {
        switch reason {
        case .connected: nil
        case .lowBattery(let percent): Double(percent) / 100
        }
    }

    /// What VoiceOver reads: always the device's full name, even when the drawn one is shortened,
    /// and every part an earbud set reported, the case included.
    public var label: String {
        switch reason {
        case .connected:
            return "Connected, \(name)"
        case .lowBattery(let percent):
            var parts = ["Low battery", "\(percent)%", name]
            if level.main == nil, level.left != nil || level.right != nil {
                if let left = level.left { parts.append("left \(left)%") }
                if let right = level.right { parts.append("right \(right)%") }
            }
            if let caseLevel = level.caseLevel { parts.append("case \(caseLevel)%") }
            return parts.joined(separator: ", ")
        }
    }

    /// Connection notices cap their wings so a long name cannot stretch the island; a low-battery
    /// notice is sized by its short title.
    public var maxWing: CGFloat { isLowBattery ? 240 : AccessoryNoticeLayout.maxWing }
}

/// Sizes for accessory notices, and fitting a device name into one wing.
public enum AccessoryNoticeLayout {
    public static let maxWing: CGFloat = 160
    public static let cameraGap: CGFloat = 6
    /// A wing's end padding, as in the island's text-notice wing formula.
    public static let wingPadding: CGFloat = 16
    /// The widest a device name may be drawn: a whole wing less its padding and the camera gap.
    public static var nameWidth: CGFloat { maxWing - wingPadding - cameraGap }

    /// Shortens text in the middle so it fits `width`, keeping both ends: "Alex's Magic…Keyboard"
    /// still says whose it is and what it is. `measure` gives a string's drawn width.
    public static func middleTruncated(_ text: String, width: CGFloat, measure: (String) -> CGFloat) -> String {
        guard measure(text) > width else { return text }
        let characters = Array(text)
        var low = 0, high = characters.count - 1
        var best = "…"
        while low <= high {
            let keep = (low + high) / 2
            let head = String(characters[..<(keep - keep / 2)])
            let tail = String(characters[(characters.count - keep / 2)...])
            let candidate = head.trimmingCharacters(in: .whitespaces) + "…" + tail.trimmingCharacters(in: .whitespaces)
            if measure(candidate) <= width {
                best = candidate
                low = keep + 1
            } else {
                high = keep - 1
            }
        }
        return best
    }
}

/// Accessory notices wait their turn instead of being dropped: a connection banner that arrives
/// during a volume change, or while the island is open, still shows once the slot is free. At most
/// eight wait, each for at most 30 seconds, and one is presented every 4.1 seconds (a notice's four
/// seconds plus a beat).
public struct AccessoryNoticeQueue: Sendable {
    public static let capacity = 8
    public static let lifetime: TimeInterval = 30
    public static let interval: TimeInterval = 4.1

    private var entries: [(notice: AccessoryNoticeContent, queuedAt: Date)] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Adds a notice; when eight are already waiting, the oldest is dropped.
    public mutating func enqueue(_ notice: AccessoryNoticeContent, at date: Date) {
        entries.append((notice, date))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// The next notice to present, after discarding any that waited 30 seconds or more.
    public mutating func next(at date: Date) -> AccessoryNoticeContent? {
        entries.removeAll { date.timeIntervalSince($0.queuedAt) >= Self.lifetime }
        return entries.first?.notice
    }

    /// The next notice was presented.
    public mutating func removeNext() {
        if !entries.isEmpty { entries.removeFirst() }
    }

    /// A fresh reading showed the device recovered before its warning was presented.
    public mutating func withdrawLowBattery(_ identity: AccessoryIdentity) {
        entries.removeAll { $0.notice.isLowBattery && $0.notice.identity == identity }
    }

    /// The device disconnected: nothing about it is worth showing any more.
    public mutating func drop(address: String) {
        entries.removeAll { $0.notice.address == address }
    }

    public mutating func removeAll() { entries.removeAll() }
}
