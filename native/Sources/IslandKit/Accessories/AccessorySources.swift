import Foundation

/// A battery value as sources spell it: a number, or a string such as "87%". Rounded; anything
/// outside 0…100 is not a reading.
public enum AccessoryPercent {
    public static func parse(_ value: Any?) -> Int? {
        let number: Double?
        switch value {
        case let value as NSNumber: number = value.doubleValue
        case let value as String:
            number = Double(value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "%")))
        default: number = nil
        }
        guard let number, number.isFinite else { return nil }
        let rounded = Int(number.rounded())
        return (0...100).contains(rounded) ? rounded : nil
    }
}

/// HID accessories that report their own battery in the IORegistry (Magic Keyboard, Mouse and
/// Trackpad, and others that follow Apple's keys). Readable without any permission.
public enum AccessoryRegistry {
    public static let classes = ["AppleDeviceManagementHIDEventService", "IOHIDDevice"]
    public static let batteryKeys = ["BatteryPercent", "BatteryPercentRemaining", "BatteryLevel", "Battery Level", "Battery"]
    static let nameKeys = ["Product", "ProductName", "DeviceName", "IOProviderClass"]
    static let idKeys = ["SerialNumber", "DeviceAddress", "LocationID", "ProductID", "VendorID"]
    static let builtInKeys = ["Built-In", "BuiltIn"]
    static let usageKeys = ["PrimaryUsagePage", "PrimaryUsage"]
    /// Every property a reading needs, so a reader fetches only these rather than a device's whole
    /// (large) property table.
    public static let keys = batteryKeys + nameKeys + idKeys + builtInKeys + usageKeys

    /// A reading from one registry entry's properties, or nil for built-in devices and entries with
    /// no valid level.
    public static func reading(_ properties: [String: Any], entryID: UInt64, observedAt: Date) -> AccessoryReading? {
        guard !builtInKeys.contains(where: { (properties[$0] as? NSNumber)?.boolValue == true }),
              let percent = batteryKeys.lazy.compactMap({ AccessoryPercent.parse(properties[$0]) }).first else { return nil }
        let name = nameKeys.lazy.compactMap { (properties[$0] as? String)?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let id = idKeys.lazy.compactMap { key -> String? in
            switch properties[key] {
            case let value as String where !value.isEmpty: "\(key):\(value)"
            case let value as NSNumber: "\(key):\(value)"
            default: nil
            }
        }.first ?? "entry:\(entryID)"
        let usage = (properties["PrimaryUsagePage"] as? NSNumber, properties["PrimaryUsage"] as? NSNumber)
        let hint = usage.0.flatMap { page in usage.1.flatMap { AccessoryKind.hidUsage(page: page.intValue, usage: $0.intValue) } }
        return AccessoryReading(id: id, address: address(properties["DeviceAddress"]), name: name,
                                kind: .resolve(name: name, hint: hint), level: AccessoryLevel(main: percent), observedAt: observedAt)
    }

    /// A registry address stored as text or as six bytes.
    public static func address(_ value: Any?) -> String? {
        switch value {
        case let value as String: AccessoryAddress.normalize(value)
        case let value as Data: AccessoryAddress.fromBytes(Array(value))
        default: nil
        }
    }
}

/// The Bluetooth report `system_profiler SPBluetoothDataType -json` prints. It is where earbuds'
/// left, right and case levels come from, and it names each paired device's type, all without
/// Bluetooth permission (the report runs as Apple's own process).
public enum AccessoryBluetoothReport {
    public struct Result: Equatable, Sendable {
        /// Connected devices that report a level.
        public var readings: [AccessoryReading] = []
        /// Every paired device's reported type, by address, for naming the kind of a device that
        /// connects later.
        public var types: [String: AccessoryKind] = [:]
    }

    public static let arguments = ["SPBluetoothDataType", "-json"]

    public static func parse(_ data: Data, observedAt: Date) -> Result? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        var result = Result()
        for controller in controllers {
            for (listKey, connected) in [("device_connected", true), ("device_not_connected", false)] {
                for entry in controller[listKey] as? [[String: Any]] ?? [] {
                    for (name, value) in entry {
                        guard let properties = value as? [String: Any] else { continue }
                        let address = (properties["device_address"] as? String).flatMap(AccessoryAddress.normalize)
                        let reported = ["device_minorType", "device_majorType"].lazy
                            .compactMap { (properties[$0] as? String).flatMap(AccessoryKind.reportedType) }.first
                        if let address, let reported { result.types[address] = reported }
                        guard connected else { continue }
                        let level = level(properties)
                        guard !level.isEmpty else { continue }
                        result.readings.append(AccessoryReading(id: address ?? "name:\(name)", address: address, name: name,
                                                                kind: .resolve(name: name, reported: reported),
                                                                level: level, observedAt: observedAt))
                    }
                }
            }
        }
        return result
    }

    static func level(_ properties: [String: Any]) -> AccessoryLevel {
        let prefix = "device_batteryLevel"
        let known = ["Main", "", "Left", "Right", "Case"].map { prefix + $0 }
        var level = AccessoryLevel(main: AccessoryPercent.parse(properties[prefix + "Main"]) ?? AccessoryPercent.parse(properties[prefix]),
                                   left: AccessoryPercent.parse(properties[prefix + "Left"]),
                                   right: AccessoryPercent.parse(properties[prefix + "Right"]),
                                   caseLevel: AccessoryPercent.parse(properties[prefix + "Case"]))
        level.others = properties.keys.filter { $0.hasPrefix(prefix) && !known.contains($0) }.sorted()
            .compactMap { AccessoryPercent.parse(properties[$0]) }
        return level
    }
}
