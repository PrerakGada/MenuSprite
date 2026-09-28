import CoreGraphics
import Foundation
import IOKit
import IslandKit

/// External monitors that accept DDC/CI through the display coprocessor's AV service (Apple silicon).
/// Discovery walks the IORegistry: a framebuffer entry, then the AV service proxy under it, kept only
/// when the proxy's location is External. Every transfer is paced so a monitor keeps its signal, and
/// a channel that takes writes but never answers is remembered as write-only. Confined to the display
/// queue.
final class DDCBus: @unchecked Sendable {
    private struct Channel {
        let service: CFTypeRef
        var writeOnly = false
        var lastCommand: TimeInterval = 0
    }

    private var channels: [CGDirectDisplayID: Channel] = [:]

    /// Finds the DDC services and pairs them with these displays. Returns the displays that got one.
    func assign(_ displays: [CGDirectDisplayID]) -> Set<CGDirectDisplayID> {
        channels = [:]
        guard let symbols = CoreDisplayBridge.symbols, !displays.isEmpty else { return [] }
        let found = discover(symbols)
        let identities = displays.map { display in
            IslandDisplayIdentity(location: CoreDisplayBridge.location(of: display), vendor: CGDisplayVendorNumber(display),
                                  product: CGDisplayModelNumber(display), serial: CGDisplaySerialNumber(display))
        }
        for (displayIndex, serviceIndex) in IslandDisplayMatching.match(displays: identities, services: found.map(\.identity)) {
            channels[displays[displayIndex]] = Channel(service: found[serviceIndex].service)
        }
        return Set(channels.keys)
    }

    func forget() { channels = [:] }

    /// nil when the monitor does not answer (and from then on, for a write-only channel).
    func read(_ display: CGDirectDisplayID) -> IslandDDC.Reading? {
        guard channels[display]?.writeOnly == false else { return nil }
        let result: (reading: IslandDDC.Reading?, wrote: Bool)? = command(display) { service, symbols in
            var wrote = false
            for attempt in 0..<IslandDDC.retries {
                if attempt > 0 { Thread.sleep(forTimeInterval: IslandDDC.retryDelay) }
                guard send(IslandDDC.getPacket(), to: service, symbols) else { continue }
                wrote = true
                Thread.sleep(forTimeInterval: IslandDDC.pauseBeforeReply)
                var bytes = [UInt8](repeating: 0, count: IslandDDC.replyLength)
                if symbols.readI2C(service, IslandDDC.chipAddress, IslandDDC.dataAddress, &bytes, UInt32(bytes.count)) == kIOReturnSuccess,
                   let reading = IslandDDC.parseReply(bytes) {
                    return (reading, true)
                }
            }
            return (nil, wrote)
        }
        if let result, result.reading == nil, result.wrote { channels[display]?.writeOnly = true }
        return result?.reading
    }

    func write(_ level: Double, maximum: UInt16, to display: CGDirectDisplayID) -> Bool {
        let packet = IslandDDC.setPacket(value: IslandDDC.value(level: level, maximum: maximum))
        return command(display) { service, symbols in
            for attempt in 0..<IslandDDC.retries {
                if attempt > 0 { Thread.sleep(forTimeInterval: IslandDDC.retryDelay) }
                if send(packet, to: service, symbols) { return true }
            }
            return false
        } ?? false
    }

    /// One whole command, at least 50 ms after the previous one to the same monitor.
    private func command<Result>(_ display: CGDirectDisplayID, _ body: (CFTypeRef, CoreDisplayBridge.Symbols) -> Result) -> Result? {
        guard let symbols = CoreDisplayBridge.symbols, let channel = channels[display] else { return nil }
        let wait = channel.lastCommand + IslandDDC.commandSpacing - ProcessInfo.processInfo.systemUptime
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        defer { channels[display]?.lastCommand = ProcessInfo.processInfo.systemUptime }
        return body(channel.service, symbols)
    }

    /// Each write is preceded by a short pause and sent twice; true when either was accepted.
    private func send(_ packet: [UInt8], to service: CFTypeRef, _ symbols: CoreDisplayBridge.Symbols) -> Bool {
        var sent = false
        for _ in 0..<IslandDDC.writeRepeats {
            Thread.sleep(forTimeInterval: IslandDDC.pauseBeforeWrite)
            var bytes = packet
            if symbols.writeI2C(service, IslandDDC.chipAddress, IslandDDC.dataAddress, &bytes, UInt32(bytes.count)) == kIOReturnSuccess {
                sent = true
            }
        }
        return sent
    }

    private struct Found {
        let identity: IslandDisplayIdentity
        let service: CFTypeRef
    }

    private func discover(_ symbols: CoreDisplayBridge.Symbols) -> [Found] {
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [Found] = []
        var framebuffer: IslandDisplayIdentity?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            switch IOObjectCopyClass(entry)?.takeRetainedValue() as String? {
            case "AppleCLCD2", "IOMobileFramebufferShim":
                framebuffer = Self.identity(of: entry)
            case "DCPAVServiceProxy":
                guard let identity = framebuffer, Self.property(entry, "Location") as? String == "External",
                      let service = symbols.createService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                found.append(Found(identity: identity, service: service))
                framebuffer = nil
            default:
                continue
            }
        }
        return found
    }

    private static func identity(of framebuffer: io_registry_entry_t) -> IslandDisplayIdentity {
        var path = [CChar](repeating: 0, count: 512)
        let location = IORegistryEntryGetPath(framebuffer, kIOServicePlane, &path) == KERN_SUCCESS
            ? String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self) : nil
        let attributes = (property(framebuffer, "DisplayAttributes") as? [String: Any])?["ProductAttributes"] as? [String: Any]
        func number(_ key: String) -> UInt32? { (attributes?[key] as? NSNumber).map { UInt32(truncatingIfNeeded: $0.int64Value) } }
        return IslandDisplayIdentity(location: location, vendor: number("LegacyManufacturerID"), product: number("ProductID"),
                                     serial: number("SerialNumber"), name: attributes?["ProductName"] as? String)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
