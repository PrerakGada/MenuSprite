import Foundation
import Testing
@testable import PowerControl

/// Two fans shaped like Nebula's (M5 Max): 2317–7826 rpm, both controllable.
private final class FakeFans: PowerHardware {
    var fanStates = [0, 1].map { FanState(index: $0, rpm: 2400, minimum: 2317, maximum: 7826, target: 2400, manual: false, controllable: true) }
    var failOn: Int?
    var writes: [(Int, Double?)] = []
    func read(_ key: String) -> [UInt8]? { nil }
    func snapshot() -> PowerSnapshot { PowerSnapshot() }
    func chargeValues(allow: Bool) -> [String:[UInt8]] { [:] }
    func adapterValues(allow: Bool) -> [String:[UInt8]] { [:] }
    func writeControl(_ key: String, _ bytes: [UInt8]) throws {}
    func fans() -> [FanState] { fanStates }
    func writeFan(_ index: Int, rpm: Double?) throws {
        if failOn == index { failOn = nil; throw PowerFailure("Injected fan failure") }
        writes.append((index, rpm))
        fanStates[index].manual = rpm != nil
        if let rpm { fanStates[index].target = rpm }
    }
}
private func journal() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("recovery.json")
}

@Test func percentIsOfEachFansMaximumAndNeverBelowItsMinimum() {
    let fan = FanState(index: 0, rpm: 0, minimum: 2317, maximum: 7826, target: nil, manual: false, controllable: true)
    #expect(FanPolicy.rpm(percent: 100, for: fan) == 7826)
    #expect(FanPolicy.rpm(percent: 90, for: fan) == 7043)
    #expect(FanPolicy.rpm(percent: 80, for: fan) == 6261)
    #expect(FanPolicy.rpm(percent: 10, for: fan) == 2317)
    #expect(FanPolicy.lowestPercent([fan]) == 30)
    #expect(!FanPolicy.valid(.percent(0)) && !FanPolicy.valid(.percent(101)) && FanPolicy.valid(.automatic))
}

@Test @MainActor func fanTargetRidesOnAnyRequestAndStopAllHandsTheFansBack() throws {
    let h = FakeFans(), url = try journal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let c = PowerController(hardware: h, recoveryURL: url, execute: { _, _ in "" })
    let held = c.handle(.init(.status, fans: .percent(90)))
    #expect(held.fanTarget == .percent(90) && held.error == nil)
    #expect(h.fanStates.allSatisfy { $0.manual && $0.target == 7043 })
    #expect(c.needsRecovery && c.active)
    // The same target again writes nothing.
    let count = h.writes.count
    _ = c.handle(.init(.heartbeat, fans: .percent(90)))
    #expect(h.writes.count == count)
    let released = c.handle(.init(.stopAll))
    #expect(released.fanTarget == .automatic)
    #expect(h.fanStates.allSatisfy { !$0.manual })
    #expect(!c.needsRecovery)
}

@Test @MainActor func automaticHandsBackAndAFailedWriteLeavesNoFanManual() throws {
    let h = FakeFans(), url = try journal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let c = PowerController(hardware: h, recoveryURL: url, execute: { _, _ in "" })
    h.failOn = 1
    let failed = c.handle(.init(.fans, fans: .percent(100)))
    #expect(failed.error != nil && failed.fanTarget == .automatic)
    #expect(h.fanStates.allSatisfy { !$0.manual })
    _ = c.handle(.init(.fans, fans: .percent(100)))
    #expect(h.fanStates.allSatisfy { $0.manual && $0.target == 7826 })
    let auto = c.handle(.init(.fans, fans: .automatic))
    #expect(auto.fanTarget == .automatic && auto.error == nil)
    #expect(h.fanStates.allSatisfy { !$0.manual })
}

@Test @MainActor func anotherFanControllerBlocksManualControl() throws {
    let h = FakeFans(), url = try journal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let c = PowerController(hardware: h, recoveryURL: url, execute: { _, _ in "/Applications/Macs Fan Control.app/Contents/MacOS/Macs Fan Control\n" })
    let response = c.handle(.init(.fans, fans: .percent(80)))
    #expect(response.error?.contains("Macs Fan Control") == true)
    #expect(h.writes.isEmpty && response.fanTarget == .automatic)
}

@Test @MainActor func tickPutsBackASpeedTheFirmwareDropped() throws {
    let h = FakeFans(), url = try journal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let c = PowerController(hardware: h, recoveryURL: url, execute: { _, _ in "" })
    _ = c.handle(.init(.fans, fans: .percent(80)))
    h.fanStates[0].manual = false; h.fanStates[0].target = 3000
    c.tick()
    #expect(h.fanStates[0].manual && h.fanStates[0].target == 6261)
}

@Test @MainActor func aHelperRestartHandsJournaledFansBack() throws {
    let h = FakeFans(), url = try journal()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    _ = PowerController(hardware: h, recoveryURL: url, execute: { _, _ in "" }).handle(.init(.fans, fans: .percent(100)))
    #expect(h.fanStates.allSatisfy { $0.manual })
    let restarted = PowerController(hardware: h, recoveryURL: url, execute: { _, _ in "" })
    #expect(h.fanStates.allSatisfy { !$0.manual })
    #expect(!restarted.needsRecovery)
}

@Test func olderHelpersAndOlderJournalsStillDecode() throws {
    let old = try JSONDecoder().decode(PowerSnapshot.self, from: JSONEncoder().encode(PowerSnapshot()))
    #expect(old.fanTarget == nil)
    let request = try JSONDecoder().decode(PowerRequest.self, from: JSONEncoder().encode(PowerRequest(.status, fans: .percent(85))))
    #expect(request.fans == .percent(85))
    #expect(try JSONDecoder().decode(Recovery.self, from: Data(#"{"original":{},"written":{},"previous":{},"lidOwned":false}"#.utf8)).fansOwned == nil)
}
