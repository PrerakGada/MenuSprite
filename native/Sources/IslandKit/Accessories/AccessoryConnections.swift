import Foundation

/// A connected Bluetooth accessory as one source sees it.
public struct AccessoryDevice: Hashable, Sendable {
    /// Normalised Bluetooth address: the device's identity across sources.
    public var address: String
    public var name: String
    /// What the source itself suggests the device is (a HID usage), used after the name and the
    /// Bluetooth report's type.
    public var hint: AccessoryKind?

    public init(address: String, name: String, hint: AccessoryKind? = nil) {
        self.address = address; self.name = name; self.hint = hint
    }
}

/// Which accessories are connected, and which connections are news. Each source reports its whole
/// current set (keyed by the source's own token for each device entry); a device is connected
/// while any source still reports its address. What was connected when the alerts started, or
/// again after lock and sleep, is recorded silently and never replays a banner.
public struct AccessoryConnections: Sendable {
    public enum Source: String, CaseIterable, Sendable, Hashable {
        /// Bluetooth audio devices in CoreAudio's device list.
        case audio
        /// Bluetooth HID devices in the IORegistry.
        case hid
    }

    public struct Change: Equatable, Sendable {
        /// Devices that just connected, one per address, by name.
        public var connected: [AccessoryDevice] = []
        /// Addresses no source reports any more.
        public var disconnected: [String] = []
    }

    private var present: [Source: [String: AccessoryDevice]] = [:]
    public private(set) var connected: Set<String> = []

    public init() {}

    /// Records a source's current set without announcing any of it.
    public mutating func baseline(_ source: Source, _ devices: [String: AccessoryDevice]) {
        present[source] = Self.usable(devices)
        connected = addresses
    }

    /// A source's new current set. A device whose address was not connected gives one notice however
    /// many sources or duplicate callbacks report it; a device no source reports any more is
    /// disconnected, which re-arms its banner. An empty address never counts, and a device with no
    /// name gives no notice.
    public mutating func update(_ source: Source, _ devices: [String: AccessoryDevice]) -> Change {
        present[source] = Self.usable(devices)
        let now = addresses
        var change = Change()
        var announced = Set<String>()
        let candidates = Source.allCases.flatMap { (present[$0] ?? [:]).sorted { $0.key < $1.key }.map(\.value) }
        for device in candidates where !connected.contains(device.address) && announced.insert(device.address).inserted {
            change.connected.append(device)
        }
        change.connected.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        change.disconnected = connected.subtracting(now).sorted()
        connected = now
        return change
    }

    private var addresses: Set<String> { Set(present.values.flatMap { $0.values.map(\.address) }) }

    private static func usable(_ devices: [String: AccessoryDevice]) -> [String: AccessoryDevice] {
        devices.filter { !$0.value.address.isEmpty && !$0.value.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
