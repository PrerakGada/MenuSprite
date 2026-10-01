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
    /// Whether the pack is charging and its signed current in mA (negative while discharging).
    func batteryFlow() -> (charging: Bool, amperage: Int)?
    func readLED() -> MagSafeLED?
    func writeLED(_ value: MagSafeLED) throws
    func fans() -> [FanState]
    /// Holds one fan at `rpm`, or hands it back to macOS when nil.
    func writeFan(_ index: Int, rpm: Double?) throws
}
public extension PowerHardware {
    func batteryFlow() -> (charging: Bool, amperage: Int)? { nil }
    func readLED() -> MagSafeLED? { nil }
    func writeLED(_ value: MagSafeLED) throws { throw PowerFailure("MagSafe LED control is unavailable") }
    func fans() -> [FanState] { [] }
    func writeFan(_ index: Int, rpm: Double?) throws { throw PowerFailure("Fan control is unavailable") }
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
    /// SMC key metadata. The attributes byte carries the write-permission bit,
    /// and a key can be present and readable yet refuse every write with SMC
    /// error 0x86. Treating presence alone as capability is what previously let
    /// this backend offer controls the firmware does not actually accept.
    struct KeyInfo: Equatable {
        let size: Int
        let attributes: UInt8
        var type = ""
        var writable: Bool { attributes & 0x40 != 0 }
    }
    private var infos: [String: KeyInfo?] = [:]
    func info(_ key: String) -> KeyInfo? {
        if let cached = infos[key] { return cached }
        var result: KeyInfo?
        if let data = packet(9,key) {
            let size = (0..<4).reduce(0) { $0 | Int(data[28+$1]) << ($1*8) }
            let code = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[32+$1]) << ($1*8) }
            let type = String(bytes: [24,16,8,0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? ""
            if (1...32).contains(size) { result = KeyInfo(size: size, attributes: data[36], type: type) }
        }
        infos[key] = result
        return result
    }
    private func size(_ key: String) -> Int? { info(key)?.size }
    /// A control key must be the right width *and* accept writes.
    private func control(_ key: String, _ width: Int) -> Bool {
        guard let info = info(key) else { return false }
        return info.size == width && info.writable
    }
    public func read(_ key: String) -> [UInt8]? {
        guard let size = size(key), let data = packet(5,key,size:size) else { return nil }
        return Array(data[48..<48+size])
    }
    /// Writable one-byte charge-inhibit pairs. Recent Apple Silicon firmware
    /// also publishes read-only `CHIB`/`CHIC` keys that look like this pair and
    /// refuse every write, so the writable check above is what separates them.
    static let inhibitPairs = [["CH0B", "CH0C"]]
    public var chargeKeys: [String] {
        // New range-control firmware has different semantics. Remain unavailable
        // until that backend is validated; never fall back to legacy writes there.
        if size("bfF0") != nil && size("bfE0") != nil { return [] }
        if let pair = Self.inhibitPairs.first(where: { $0.allSatisfy { control($0,1) } }) { return pair }
        return control("CHTE",4) ? ["CHTE"] : []
    }
    /// The adapter switch must never be a key already claimed as a charge
    /// control, or stopping charge and cutting the adapter become one action.
    public var adapterKey: String? {
        let charge = Set(chargeKeys)
        return ["CH0I", "CH0J", "CHIE"].first { control($0,1) && !charge.contains($0) }
    }
    public func snapshot() -> PowerSnapshot {
        var s = PowerSnapshot()
        if let b = read("BUIC"), b.count == 1, b[0] <= 100 { s.percent = Int(b[0]) }
        if let b = read("AC-W"), b.count == 1 { s.pluggedIn = Int8(bitPattern:b[0]) > 0 }
        s.chargeCurrent = little32("CHBI")
        s.batteryVoltage = little32("CHBV")
        let keys = chargeKeys
        let adapter = adapterKey
        s.chargeSupported = !keys.isEmpty
        // Running from the battery with the cable in needs only the adapter
        // switch. It is deliberately independent of the charge keys, because
        // this firmware publishes one and not the other.
        s.dischargeSupported = adapter != nil && s.pluggedIn != nil
        let states = keys.compactMap { read($0) }
        if !keys.isEmpty, states.count == keys.count { s.chargingAllowed = states.allSatisfy { $0.allSatisfy { $0 == 0 } } }
        if let key = adapter, let b = read(key) { s.adapterEnabled = b.allSatisfy { $0 == 0 } }
        s.capability = Self.capability(charge: keys, adapter: adapter)
        return s
    }
    static func capability(charge: [String], adapter: String?) -> String {
        switch (charge.isEmpty, adapter) {
        case (false, let adapter):
            return "Detected \(charge.joined(separator: "+"))\(adapter.map { " / \($0)" } ?? "") · administrator helper required"
        case (true, .some(let adapter)):
            return "This firmware exposes only the adapter switch (\(adapter)). Running from the battery with the cable connected works; holding a charge limit does not, because no writable charge-inhibit key is published."
        case (true, .none):
            return "Charge control unavailable for this firmware"
        }
    }
    private func little32(_ key: String) -> Int? {
        guard let b = read(key), b.count == 4 else { return nil }
        return (0..<4).reduce(0) { $0 | Int(b[$1]) << ($1 * 8) }
    }
    public func chargeValues(allow: Bool) -> [String: [UInt8]] {
        Dictionary(uniqueKeysWithValues: chargeKeys.map { ($0, $0 == "CHTE" ? [allow ? 0 : 1,0,0,0] : [allow ? 0 : 2]) })
    }
    public func adapterValues(allow: Bool) -> [String: [UInt8]] {
        guard let key = adapterKey else { return [:] }
        return [key: [allow ? 0 : (key == "CHIE" ? 8 : 1)]]
    }
    public func batteryFlow() -> (charging: Bool, amperage: Int)? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func property(_ name: String) -> Any? { IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        guard let raw = property("InstantAmperage") as? NSNumber else { return nil }
        // The registry stores the signed current as an unsigned 64-bit value.
        return ((property("IsCharging") as? Bool) ?? false, Int(truncatingIfNeeded: raw.int64Value))
    }
    public func readLED() -> MagSafeLED? { read("ACLC").flatMap { $0.count == 1 ? MagSafeLED(rawValue: $0[0]) : nil } }
    /// Only the connector LED key, only the known values; no other key can be reached here.
    public func writeLED(_ value: MagSafeLED) throws {
        guard geteuid() == 0 else { throw PowerFailure("Administrator helper is required") }
        guard control("ACLC", 1) else { throw PowerFailure("This Mac publishes no writable MagSafe LED control") }
        guard packet(6, "ACLC", bytes: [value.rawValue], size: 1) != nil else { throw PowerFailure("Firmware refused the MagSafe LED change") }
    }
    public func writeControl(_ key: String, _ bytes: [UInt8]) throws {
        guard geteuid() == 0 else { throw PowerFailure("Administrator helper is required") }
        let permitted = chargeKeys + (adapterKey.map { [$0] } ?? [])
        guard permitted.contains(key), size(key) == bytes.count else { throw PowerFailure("Unsupported control key or size") }
        let allowed = chargeValues(allow:true).merging(adapterValues(allow:true)) { $1 }[key]
        let inhibited = chargeValues(allow:false).merging(adapterValues(allow:false)) { $1 }[key]
        guard bytes == allowed || bytes == inhibited else { throw PowerFailure("Unrecognized firmware control state; refusing to write") }
        guard info(key)?.writable == true else { throw PowerFailure("Firmware publishes \(key) as read-only; refusing to write") }
        guard packet(6,key,bytes:bytes,size:bytes.count) != nil, read(key) == bytes else { throw PowerFailure("Firmware did not confirm \(key); control stopped") }
    }

    // MARK: Fans
    // Apple Silicon publishes per fan: F<n>Ac actual, F<n>Mn/Mx limits and F<n>Tg target (little-endian
    // floats), and a one-byte mode key — `F<n>md` on recent firmware, `F<n>Md` before — where 1 holds
    // the target and 0 hands the fan back to macOS. Measured on Nebula (M5 Max, macOS 27.0.1): both
    // fans' mode and target keys carry the write bit; no `Ftst` unlock key exists.
    private func float(_ key: String) -> Double? {
        guard info(key)?.type == "flt ", let b = read(key), b.count == 4 else { return nil }
        let value = Double(Float(bitPattern: (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[$1]) << ($1 * 8) }))
        return value.isFinite ? value : nil
    }
    private func fanModeKey(_ index: Int) -> String? {
        ["F\(index)md", "F\(index)Md"].first { info($0)?.size == 1 }
    }
    public func fans() -> [FanState] {
        guard let count = read("FNum")?.first else { return [] }
        return (0..<min(Int(count), 10)).compactMap { i in
            guard let rpm = float("F\(i)Ac"), let low = float("F\(i)Mn"), let high = float("F\(i)Mx"), high > low, low >= 0 else { return nil }
            let mode = fanModeKey(i)
            let manual = mode.flatMap { read($0) }.map { $0 != [0] } ?? false
            let controllable = mode.map { info($0)?.writable == true } == true
                && info("F\(i)Tg").map { $0.writable && $0.type == "flt " && $0.size == 4 } == true
            return FanState(index: i, rpm: max(0, rpm), minimum: low, maximum: high, target: float("F\(i)Tg"),
                            manual: manual, controllable: controllable)
        }
    }
    /// Only the fan mode and target keys, only a speed inside the fan's own limits, read back after.
    public func writeFan(_ index: Int, rpm: Double?) throws {
        guard geteuid() == 0 else { throw PowerFailure("Administrator helper is required") }
        guard let fan = fans().first(where: { $0.index == index }), fan.controllable, let mode = fanModeKey(index) else {
            throw PowerFailure("Fan \(index + 1) publishes no writable control")
        }
        guard let rpm else {
            guard packet(6, mode, bytes: [0], size: 1) != nil, read(mode) == [0] else { throw PowerFailure("Firmware did not hand fan \(index + 1) back to macOS") }
            return
        }
        let value = rpm.clamped(fan.minimum, fan.maximum)
        let bits = Float(value).bitPattern
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        // Target before mode: the firmware keeps the last manual target and runs the fan at it the
        // moment the mode flips, so writing the mode first briefly spins to a stale speed.
        // The target reads back about a second later (measured 30 Sep), so the controller confirms it.
        guard packet(6, "F\(index)Tg", bytes: bytes, size: 4) != nil else { throw PowerFailure("Firmware refused a target for fan \(index + 1)") }
        guard packet(6, mode, bytes: [1], size: 1) != nil, read(mode) == [1] else {
            _ = packet(6, mode, bytes: [0], size: 1)
            throw PowerFailure("Firmware refused manual control of fan \(index + 1); handed back to macOS")
        }
    }
}
