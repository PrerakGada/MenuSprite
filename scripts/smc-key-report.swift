// Read-only AppleSMC key report for charge-control work.
//
// Enumerates every SMC key this Mac publishes and prints the charge/battery ones with
// their sizes and current values. It WRITES NOTHING: only commands 5 (read), 8 (read by
// index) and 9 (key info) are issued, and there is no code path here that can write.
//
//   swiftc -O scripts/smc-key-report.swift -o /tmp/smc-key-report && /tmp/smc-key-report
//
// Some keys publish a name in the index but refuse a size query to an unprivileged
// process; those print "size: -" while still proving the key exists. Run it under sudo
// to see those sizes. Findings for Nebula are recorded in docs/power-controls.md.
import Foundation
import IOKit

final class SMC {
    var connection: io_connect_t = 0
    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
    }
    func debugCall(_ input: inout [UInt8]) -> [UInt8]? { call(&input) }
    private func call(_ input: inout [UInt8]) -> [UInt8]? {
        guard connection != 0 else { return nil }
        var output = [UInt8](repeating: 0, count: 80), count = 80
        let r = input.withUnsafeBytes { a in output.withUnsafeMutableBytes { b in
            IOConnectCallStructMethod(connection, 2, a.baseAddress, 80, b.baseAddress, &count) } }
        return r == KERN_SUCCESS && count == 80 && output[40] == 0 ? output : nil
    }
    private func code(_ key: String) -> UInt32 { key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    func packet(_ command: UInt8, _ key: String, size: Int = 0) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: 80)
        let c = code(key)
        for b in 0..<4 { input[b] = UInt8(truncatingIfNeeded: c >> (b * 8)); input[28+b] = UInt8(truncatingIfNeeded: size >> (b * 8)) }
        input[42] = command
        return call(&input)
    }
    func keyName(at index: Int) -> String? {
        var input = [UInt8](repeating: 0, count: 80)
        input[42] = 8
        for b in 0..<4 { input[44+b] = UInt8(truncatingIfNeeded: index >> (b * 8)) }
        guard let out = call(&input) else { return nil }
        // The key field comes back in the same slot the request uses; try both orders
        // and keep whichever is four printable ASCII characters.
        for bytes in [(0..<4).map({ out[3 - $0] }), Array(out[0..<4])] {
            if bytes.allSatisfy({ (0x20...0x7e).contains($0) }) { return String(decoding: bytes, as: UTF8.self) }
        }
        return nil
    }
    func size(_ key: String) -> Int? {
        guard let d = packet(9, key) else { return nil }
        let s = (0..<4).reduce(0) { $0 | Int(d[28+$1]) << ($1*8) }
        return (1...32).contains(s) ? s : nil
    }
    func read(_ key: String) -> [UInt8]? {
        guard let s = size(key), let d = packet(5, key, size: s) else { return nil }
        return Array(d[48..<48+s])
    }
}
let smc = SMC()
guard smc.connection != 0 else { print("Could not open AppleSMC"); exit(1) }
print("running as uid \(geteuid())")
guard let countBytes = smc.read("#KEY"), countBytes.count == 4 else { print("#KEY unreadable"); exit(1) }
let count = countBytes.reduce(0) { $0 << 8 | Int($1) }
print("keys reported: \(count)\n")
var interesting: [(String, Int?, [UInt8]?)] = []
for index in 0..<count {
    guard let name = smc.keyName(at: index) else { continue }
    guard name.hasPrefix("CH") || name.hasPrefix("bf") || name.hasPrefix("BF") || name == "AC-W" || name == "BUIC" else { continue }
    interesting.append((name, smc.size(name), smc.read(name)))
}
for (name, size, value) in interesting {
    print(name.padding(toLength: 6, withPad: " ", startingAt: 0),
          "size:", size.map(String.init) ?? "-",
          "value:", value.map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "-")
}
print("\nfound \(interesting.count) charge/battery-control keys")
