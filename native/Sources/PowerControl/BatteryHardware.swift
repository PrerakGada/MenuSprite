import Foundation
import IOKit

/// Firmware access is deliberately separate from monitoring. Only known charge
/// and adapter controls have write methods; no raw-key write crosses XPC.
public protocol PowerHardware: AnyObject {
    func read(_ key: String) -> [UInt8]?
    func snapshot() -> PowerSnapshot
    func chargeValues(allow: Bool) -> [String:[UInt8]]
    func adapterValues(allow: Bool) -> [String:[UInt8]]
    func writeControl(_ key: String, _ bytes: [UInt8]) throws
}
public final class BatteryHardware: PowerHardware {
    private var connection: io_connect_t = 0
    private var sizes: [String: Int] = [:]
    public init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    private func packet(_ command: UInt8, _ key: String, bytes: [UInt8] = [], size: Int = 0) -> [UInt8]? {
        guard connection != 0 else { return nil }
        var input = [UInt8](repeating: 0, count: 80), output = input
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        for b in 0..<4 { input[b] = UInt8(truncatingIfNeeded: code >> (b * 8)); input[28+b] = UInt8(truncatingIfNeeded: size >> (b * 8)) }
        input[42] = command
        for (i,b) in bytes.enumerated() where i < 32 { input[48+i] = b }
        var count = 80
        let result = input.withUnsafeBytes { a in output.withUnsafeMutableBytes { b in
            IOConnectCallStructMethod(connection, 2, a.baseAddress, 80, b.baseAddress, &count)
        }}
        return result == KERN_SUCCESS && count == 80 && output[40] == 0 ? output : nil
    }
    private func size(_ key: String) -> Int? {
        if let size = sizes[key] { return size }
        guard let data = packet(9,key) else { return nil }
        let size = (0..<4).reduce(0) { $0 | Int(data[28+$1]) << ($1*8) }
        guard (1...32).contains(size) else { return nil }
        sizes[key] = size
        return size
    }
    public func read(_ key: String) -> [UInt8]? {
        guard let size = size(key), let data = packet(5,key,size:size) else { return nil }
        return Array(data[48..<48+size])
    }
    public var chargeKeys: [String] {
        // New range-control firmware has different semantics. Remain unavailable
        // until that backend is validated; never fall back to legacy writes there.
        if size("bfF0") != nil && size("bfE0") != nil { return [] }
        if size("CH0B") == 1 && size("CH0C") == 1 { return ["CH0B", "CH0C"] }
        return size("CHTE") == 4 ? ["CHTE"] : []
    }
    public var adapterKey: String? { ["CH0I", "CH0J", "CHIE"].first { size($0) == 1 } }
    public func snapshot() -> PowerSnapshot {
        var s = PowerSnapshot()
        if let b = read("BUIC"), b.count == 1, b[0] <= 100 { s.percent = Int(b[0]) }
        if let b = read("AC-W"), b.count == 1 { s.pluggedIn = Int8(bitPattern:b[0]) > 0 }
        let keys = chargeKeys
        s.chargeSupported = !keys.isEmpty
        s.dischargeSupported = !keys.isEmpty && adapterKey != nil && s.pluggedIn != nil
        let states = keys.compactMap { read($0) }
        if !keys.isEmpty, states.count == keys.count { s.chargingAllowed = states.allSatisfy { $0.allSatisfy { $0 == 0 } } }
        if let key = adapterKey, let b = read(key) { s.adapterEnabled = b.allSatisfy { $0 == 0 } }
        s.capability = keys.isEmpty ? "Charge control unavailable for this firmware" : "Detected \(keys.joined(separator: "+"))\(adapterKey.map { " / \($0)" } ?? "") · administrator helper required"
        return s
    }
    public func chargeValues(allow: Bool) -> [String: [UInt8]] {
        Dictionary(uniqueKeysWithValues: chargeKeys.map { ($0, $0 == "CHTE" ? [allow ? 0 : 1,0,0,0] : [allow ? 0 : 2]) })
    }
    public func adapterValues(allow: Bool) -> [String: [UInt8]] {
        guard let key = adapterKey else { return [:] }
        return [key: [allow ? 0 : (key == "CHIE" ? 8 : 1)]]
    }
    public func writeControl(_ key: String, _ bytes: [UInt8]) throws {
        guard geteuid() == 0 else { throw PowerFailure("Administrator helper is required") }
        let permitted = chargeKeys + (adapterKey.map { [$0] } ?? [])
        guard permitted.contains(key), size(key) == bytes.count else { throw PowerFailure("Unsupported control key or size") }
        let allowed = chargeValues(allow:true).merging(adapterValues(allow:true)) { $1 }[key]
        let inhibited = chargeValues(allow:false).merging(adapterValues(allow:false)) { $1 }[key]
        guard bytes == allowed || bytes == inhibited else { throw PowerFailure("Unrecognized firmware control state; refusing to write") }
        guard packet(6,key,bytes:bytes,size:bytes.count) != nil, read(key) == bytes else { throw PowerFailure("Firmware did not confirm \(key); control stopped") }
    }
}
