import Foundation
import IOKit

/// Read-only AppleSMC user-client protocol. Firmware keys are not a stable public
/// API; missing or unrecognized values stay unavailable. No write command exists here.
final class SMCReader {
    struct Key { let name: String; let size: Int; let type: String }
    private var connection: io_connect_t = 0
    private var keyInfo: [String: Key] = [:]
    private(set) var failure: String?

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { failure = "AppleSMC is unavailable"; return }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        if result != KERN_SUCCESS { connection = 0; failure = "SMC read access unavailable (\(result))" }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func message(command: UInt8, key: String = "", index: UInt32 = 0, size: Int = 0) -> [UInt8]? {
        guard connection != 0 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        var output = [UInt8](repeating: 0, count: 80)
        func set32(_ value: UInt32, at offset: Int) {
            for byte in 0..<4 { input[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
        }
        set32(key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }, at: 0)
        set32(UInt32(size), at: 28)
        input[42] = command
        set32(index, at: 44)
        var outputSize = 80
        let status = input.withUnsafeBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                IOConnectCallStructMethod(connection, 2, inBytes.baseAddress, 80, outBytes.baseAddress, &outputSize)
            }
        }
        guard status == KERN_SUCCESS, outputSize >= 80, output[40] == 0 else { return nil }
        return output
    }
    private static func little32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
    private static func fourCC(_ number: UInt32) -> String {
        String(bytes: [24,16,8,0].map { UInt8(truncatingIfNeeded: number >> $0) }, encoding: .ascii) ?? ""
    }
    func info(_ name: String) -> Key? {
        if let cached = keyInfo[name] { return cached }
        guard let reply = message(command: 9, key: name) else { return nil }
        let size = Int(Self.little32(reply[28..<32]))
        guard size > 0, size <= 32 else { return nil }
        let result = Key(name: name, size: size, type: Self.fourCC(Self.little32(reply[32..<36])))
        keyInfo[name] = result
        return result
    }
    func read(_ name: String) -> Double? {
        guard let key = info(name), let reply = message(command: 5, key: name, size: key.size) else { return nil }
        return Self.decode(Array(reply[48..<(48 + key.size)]), type: key.type)
    }
    func keys() -> [String] {
        guard let countValue = read("#KEY"), countValue > 0, countValue <= 16384 else { return [] }
        return (0..<Int(countValue)).compactMap { index in
            guard let reply = message(command: 8, index: UInt32(index)) else { return nil }
            let key = Self.fourCC(Self.little32(reply[0..<4]))
            return key.utf8.count == 4 ? key : nil
        }
    }
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        let result: Double?
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            result = Double(Float(bitPattern: little32(bytes[0..<4])))
        case "ui8 ": result = bytes.count == 1 ? Double(bytes[0]) : nil
        case "si8 ": result = bytes.count == 1 ? Double(Int8(bitPattern: bytes[0])) : nil
        case "ui16", "si16":
            guard bytes.count == 2 else { return nil }
            let value = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            result = type == "si16" ? Double(Int16(bitPattern: value)) : Double(value)
        case "ui32", "si32":
            guard bytes.count == 4 else { return nil }
            let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            result = type == "si32" ? Double(Int32(bitPattern: value)) : Double(value)
        default:
            guard bytes.count == 2, type.count == 4,
                  type.hasPrefix("fp") || type.hasPrefix("sp"),
                  let fraction = Int(String(type.suffix(1)), radix: 16) else { return nil }
            let bits = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            result = (type.hasPrefix("sp") ? Double(Int16(bitPattern: bits)) : Double(bits)) / pow(2, Double(fraction))
        }
        guard let result, result.isFinite else { return nil }
        return result
    }
    static func unit(for key: String) -> MetricUnit? {
        if key.first == "T" { return .celsius }
        if key.first == "P" { return .watts }
        if key.first == "V" { return .volts }
        if key.first == "I" { return .amps }
        if key.first == "F", key.count == 4, Int(String(key.dropFirst().prefix(1))) != nil,
           ["Ac", "Mn", "Mx", "Tg"].contains(String(key.suffix(2))) { return .rpm }
        return nil
    }
    static func plausible(_ value: Double, unit: MetricUnit) -> Bool {
        guard value.isFinite else { return false }
        switch unit {
        case .celsius: return value > 0 && value < 150 // zero-valued firmware temperature slots are not live sensors
        case .watts: return value >= 0 && value < 1500
        case .volts: return value >= 0 && value < 100
        case .amps: return abs(value) < 200
        case .rpm: return value >= 0 && value < 30000
        default: return false
        }
    }
}
