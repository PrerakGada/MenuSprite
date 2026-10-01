import CoreBluetooth
import CoreWLAN
import Darwin
import Foundation
import IOBluetooth
import IOKit
import SystemConfiguration

/// Reads the Wi-Fi link and Bluetooth accessories from macOS, and changes them for the boards.
///
/// Wi-Fi comes from CoreWLAN, which needs no permission except for the network's name (Location).
/// Bluetooth comes from IOBluetooth, which macOS gates behind the Bluetooth permission: nothing here
/// touches IOBluetooth until that permission is granted, so a sprite can never raise the prompt by
/// itself; the Bluetooth board asks, when Prerak clicks Allow. Each read is a handful of cheap calls
/// (about 25 ms for Wi-Fi), made only while a sprite, board or preview shows these readings.
public enum ConnectivityReader {

    // MARK: Wi-Fi

    public static func wifi() -> WiFiSnapshot? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        let name = interface.interfaceName ?? "en0"
        var snapshot = WiFiSnapshot(interface: name, powered: interface.powerOn())
        guard snapshot.powered else { return snapshot }
        let rssi = interface.rssiValue()
        // An interface that has not joined anything reports no channel and an RSSI of zero.
        guard let channel = interface.wlanChannel(), rssi != 0 else { return snapshot }
        snapshot.associated = true
        snapshot.network = interface.ssid()
        snapshot.rssi = rssi
        let noise = interface.noiseMeasurement()
        snapshot.noise = noise == 0 ? nil : noise
        let rate = interface.transmitRate()
        snapshot.linkRate = rate > 0 ? rate : nil
        snapshot.channel = channel.channelNumber
        snapshot.band = WiFiBand(coreWLAN: channel.channelBand.rawValue)
        snapshot.channelWidth = WiFiSignal.width(channel.channelWidth.rawValue)
        snapshot.standard = WiFiSignal.standard(phy: interface.activePHYMode().rawValue, band: snapshot.band)
        snapshot.security = WiFiSignal.security(interface.security().rawValue)
        snapshot.address = ipv4(name)
        snapshot.router = router(for: name)
        return snapshot
    }

    /// Turns the Wi-Fi radio on or off. macOS allows it for the signed-in user unless an administrator
    /// has required authorization for it in Wi-Fi settings.
    public static func setWiFiPower(_ on: Bool) throws {
        guard let interface = CWWiFiClient.shared().interface() else { throw ConnectivityError.noWiFi }
        try interface.setPower(on)
    }

    /// Networks in range, one row per name. Takes a few seconds and blocks: call it off the main thread.
    /// Names are empty without Location access, so the list is empty then too.
    public static func scan() throws -> [WiFiNetwork] {
        guard let interface = CWWiFiClient.shared().interface() else { throw ConnectivityError.noWiFi }
        let known = Set(knownNetworkNames())
        let found = try interface.scanForNetworks(withName: nil)
        return WiFiNetwork.merged(found.map { network in
            WiFiNetwork(name: network.ssid ?? "", rssi: network.rssiValue,
                        band: network.wlanChannel.flatMap { WiFiBand(coreWLAN: $0.channelBand.rawValue) },
                        secure: !network.supportsSecurity(.none), known: known.contains(network.ssid ?? ""))
        })
    }

    /// Joins a network this Mac already knows, so its saved password is used. Blocks for a few seconds.
    public static func join(_ name: String) throws {
        guard let interface = CWWiFiClient.shared().interface() else { throw ConnectivityError.noWiFi }
        guard let network = try interface.scanForNetworks(withName: name).max(by: { $0.rssiValue < $1.rssiValue }) else {
            throw ConnectivityError.notInRange(name)
        }
        try interface.associate(to: network, password: nil)
    }

    public static func knownNetworkNames() -> [String] {
        guard let profiles = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles.array as? [CWNetworkProfile] else { return [] }
        return profiles.compactMap(\.ssid)
    }

    private static func ipv4(_ interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: entry.pointee.ifa_name) == interface, let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }

    /// The default route's router, when that route goes out through Wi-Fi.
    private static func router(for interface: String) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "MenuSprite" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              global["PrimaryInterface"] as? String == interface else { return nil }
        return global["Router"] as? String
    }

    // MARK: Bluetooth

    public static var bluetoothAccess: BluetoothAccess {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public static func bluetooth() -> BluetoothSnapshot {
        let access = bluetoothAccess
        guard access == .allowed else { return BluetoothSnapshot(access: access) }
        let powered = BluetoothPower.get() == 1
        let hidLevels = hidBatteryLevels()
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let devices = paired.map { device -> BluetoothDevice in
            let name = device.nameOrAddress ?? device.addressString ?? "Device"
            let address = normalized(device.addressString ?? name)
            let vendor = integer(device, "vendorID")
            let kind = BluetoothDeviceKind.classify(name: name, vendorApple: vendor == 0x004C,
                                                    productID: integer(device, "productID"),
                                                    majorClass: Int(device.deviceClassMajor), minorClass: Int(device.deviceClassMinor))
            let connected = device.isConnected()
            var battery = BluetoothBattery()
            if connected {
                battery.left = BluetoothBattery.level(integer(device, "batteryPercentLeft"))
                battery.right = BluetoothBattery.level(integer(device, "batteryPercentRight"))
                battery.chargingCase = BluetoothBattery.level(integer(device, "batteryPercentCase"))
                battery.single = BluetoothBattery.level(integer(device, "batteryPercentSingle"))
                    ?? BluetoothBattery.level(integer(device, "batteryPercentCombined"))
                    ?? hidLevels[address]
            }
            return BluetoothDevice(address: address, name: name, kind: kind, connected: connected, battery: battery)
        }
        return BluetoothSnapshot(access: access, powered: powered, devices: devices)
    }

    public static func setBluetoothPower(_ on: Bool) throws {
        guard bluetoothAccess == .allowed else { throw ConnectivityError.bluetoothAccess }
        guard BluetoothPower.set(on ? 1 : 0) else { throw ConnectivityError.unsupported }
    }

    /// Connects or disconnects a paired device. Connecting blocks for up to the page timeout (a few
    /// seconds when the device is away): call it off the main thread.
    public static func setConnected(_ address: String, _ connect: Bool) throws {
        guard bluetoothAccess == .allowed else { throw ConnectivityError.bluetoothAccess }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let device = paired.first(where: { normalized($0.addressString ?? "") == address }) else { throw ConnectivityError.unknownDevice }
        let status = connect ? device.openConnection() : device.closeConnection()
        guard status == kIOReturnSuccess else { throw ConnectivityError.failed(status) }
    }

    /// A private IOBluetooth getter read through KVC, only if this macOS has it: an unknown key would throw.
    private static func integer(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)) else { return nil }
        return (device.value(forKey: key) as? NSNumber)?.intValue
    }

    static func normalized(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    /// Battery levels Apple keyboards, mice and trackpads publish in the I/O registry, by Bluetooth address.
    private static func hidBatteryLevels() -> [String: Int] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var levels: [String: Int] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard let address = property("DeviceAddress") as? String,
                  let level = BluetoothBattery.level((property("BatteryPercent") as? NSNumber)?.intValue) else { continue }
            levels[normalized(address)] = level
        }
        return levels
    }
}

public enum ConnectivityError: LocalizedError {
    case noWiFi, notInRange(String), bluetoothAccess, unknownDevice, unsupported, failed(IOReturn)
    public var errorDescription: String? {
        switch self {
        case .noWiFi: "This Mac has no Wi-Fi interface."
        case .notInRange(let name): "“\(name)” is not in range."
        case .bluetoothAccess: "MenuSprite does not have Bluetooth access."
        case .unknownDevice: "That device is no longer paired."
        case .unsupported: "This macOS does not allow switching Bluetooth from an app."
        case .failed(let status): status == kIOReturnTimeout ? "The device did not answer. Is it on and nearby?" : "macOS refused (\(String(format: "0x%08x", status)))."
        }
    }
}

/// IOBluetooth's controller power switch: exported C functions with no header, looked up once.
enum BluetoothPower {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void
    nonisolated(unsafe) private static let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    nonisolated(unsafe) private static let getter = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState").map { unsafeBitCast($0, to: Getter.self) }
    nonisolated(unsafe) private static let setter = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState").map { unsafeBitCast($0, to: Setter.self) }
    static func get() -> Int32 { getter?() ?? 0 }
    static func set(_ value: Int32) -> Bool {
        guard let setter else { return false }
        setter(value)
        return true
    }
}
