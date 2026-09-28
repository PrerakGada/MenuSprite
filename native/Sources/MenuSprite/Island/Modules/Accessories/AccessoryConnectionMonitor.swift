import CoreAudio
import Foundation
import IOKit
import IslandKit

/// Watches Bluetooth accessories connect and disconnect without asking for Bluetooth access.
/// IOBluetooth would give every paired device, but on current macOS it runs through CoreBluetooth
/// and prompts for Bluetooth permission; instead, Bluetooth audio devices come from CoreAudio's
/// device list and Bluetooth HID devices (keyboards, mice, trackpads) from IOKit match and
/// terminate notifications. Both are callbacks: nothing polls.
///
/// Everything below runs on one serial queue. Each change is reported as that source's whole
/// current set, keyed by a token per device entry; the first report of each source is its baseline.
final class AccessoryConnectionMonitor: @unchecked Sendable {
    typealias Report = @Sendable (AccessoryConnections.Source, [String: AccessoryDevice], _ isBaseline: Bool) -> Void

    private let queue = DispatchQueue(label: "in.prerakgada.MenuSprite.island.accessories.connections", qos: .utility)
    private let report: Report

    // Confined to `queue`.
    private var isRunning = false
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var hidDevices: [String: AccessoryDevice] = [:]

    init(report: @escaping Report) {
        self.report = report
    }

    func start() { queue.async { self.startOnQueue() } }

    /// Removes every listener. The pending teardown keeps the monitor alive until it has run, and
    /// no callback arrives after it.
    func stop() { queue.async { self.stopOnQueue() } }

    private func startOnQueue() {
        guard !isRunning else { return }
        isRunning = true
        startAudio()
        startHID()
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        isRunning = false
        if let audioListener {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, audioListener)
        }
        audioListener = nil
        iterators.forEach { IOObjectRelease($0) }
        iterators = []
        if let port { IONotificationPortDestroy(port) }
        port = nil
        hidDevices = [:]
    }

    // MARK: Bluetooth audio (CoreAudio)

    private static let devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                                   mElement: kAudioObjectPropertyElementMain)

    private func startAudio() {
        var address = Self.devicesAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.audioChanged() }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr else { return }
        audioListener = listener
        report(.audio, Self.bluetoothAudioDevices(), true)
    }

    private func audioChanged() {
        guard isRunning else { return }
        report(.audio, Self.bluetoothAudioDevices(), false)
    }

    /// Bluetooth audio devices, one entry per CoreAudio device (earbuds appear twice, as input and
    /// output, under one address).
    private static func bluetoothAudioDevices() -> [String: AccessoryDevice] {
        var devices: [String: AccessoryDevice] = [:]
        for id in audioDeviceIDs() {
            let transport = audioUInt32(id, kAudioDevicePropertyTransportType) ?? 0
            guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                  let uid = audioString(id, kAudioDevicePropertyDeviceUID),
                  let address = AccessoryAddress.fromAudioUID(uid),
                  let name = audioString(id, kAudioObjectPropertyName) else { continue }
            devices["audio:\(id)"] = AccessoryDevice(address: address, name: name)
        }
        return devices
    }

    private static func audioDeviceIDs() -> [AudioObjectID] {
        var address = devicesAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func audioUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// CoreAudio hands strings back retained; taking them as retained releases them.
    private static func audioString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: Bluetooth HID (IOKit)

    private func startHID() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, queue)
        self.port = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        var matched: io_iterator_t = 0
        if IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"), { context, iterator in
            guard let context else { return }
            Unmanaged<AccessoryConnectionMonitor>.fromOpaque(context).takeUnretainedValue().hidMatched(iterator, isBaseline: false)
        }, context, &matched) == KERN_SUCCESS {
            iterators.append(matched)
            hidMatched(matched, isBaseline: true)
        }
        var terminated: io_iterator_t = 0
        if IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOHIDDevice"), { context, iterator in
            guard let context else { return }
            Unmanaged<AccessoryConnectionMonitor>.fromOpaque(context).takeUnretainedValue().hidTerminated(iterator)
        }, context, &terminated) == KERN_SUCCESS {
            iterators.append(terminated)
            hidTerminated(terminated)
        }
    }

    /// Drains the iterator (which also re-arms the notification) and adds Bluetooth HID devices.
    /// The earbuds' own accessory-protocol HID entries are left out: CoreAudio names those.
    private func hidMatched(_ iterator: io_iterator_t, isBaseline: Bool) {
        var changed = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard isRunning, let found = Self.bluetoothHID(service) else { continue }
            hidDevices[found.token] = found.device
            changed = true
        }
        if isRunning, changed || isBaseline { report(.hid, hidDevices, isBaseline) }
    }

    private func hidTerminated(_ iterator: io_iterator_t) {
        var changed = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if hidDevices.removeValue(forKey: Self.token(service)) != nil { changed = true }
        }
        if isRunning, changed { report(.hid, hidDevices, false) }
    }

    private static func token(_ service: io_service_t) -> String {
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        return "hid:\(entryID)"
    }

    private static func bluetoothHID(_ service: io_service_t) -> (token: String, device: AccessoryDevice)? {
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let transport = (property("Transport") as? String)?.lowercased(),
              transport.contains("bluetooth"), !transport.contains("aacp") else { return nil }
        let serial = (property("SerialNumber") as? String).flatMap { $0.isEmpty ? nil : "serial:\($0.lowercased())" }
        guard let address = AccessoryRegistry.address(property("DeviceAddress")) ?? serial else { return nil }
        let name = (property("Product") as? String) ?? ""
        let page = (property("PrimaryUsagePage") as? NSNumber)?.intValue ?? 0
        let usage = (property("PrimaryUsage") as? NSNumber)?.intValue ?? 0
        return (token(service), AccessoryDevice(address: address, name: name, hint: .hidUsage(page: page, usage: usage)))
    }
}
