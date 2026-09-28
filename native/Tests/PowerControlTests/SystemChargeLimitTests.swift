import Foundation
import Testing
@testable import PowerControl

/// powerd's record, built the way powerd archives it: an outer plist whose `policies` value is an
/// NSKeyedArchiver blob of ChargeCtrlPolicy objects.
private func record(_ policies: [[String: Any]]) throws -> Data {
    var objects: [Any] = ["$null", ["NS.objects": []]]
    objects += policies
    let inner: [String: Any] = ["$version": 100000, "$archiver": "NSKeyedArchiver", "$top": [:], "$objects": objects]
    let archived = try PropertyListSerialization.data(fromPropertyList: inner, format: .binary, options: 0)
    return try PropertyListSerialization.data(fromPropertyList: ["policies": archived, "bootSessionUUID": "x"], format: .binary, options: 0)
}

@Test func enforcedLimitReadsPowerdsPolicy() throws {
    let limit = EnforcedChargeLimit.parse(try record([["soclimit": 55, "drain": true, "terminated": false, "owner": 75367]]))
    #expect(limit == EnforcedChargeLimit(limit: 55, drain: true))
}
@Test func enforcedLimitTakesTheStrictestLivePolicy() throws {
    let data = try record([["soclimit": 80, "drain": false], ["soclimit": 55, "drain": true], ["soclimit": 30, "terminated": true]])
    #expect(EnforcedChargeLimit.parse(data) == EnforcedChargeLimit(limit: 55, drain: true))
}
@Test func noPolicyMeansNoLimit() throws {
    #expect(EnforcedChargeLimit.parse(try record([])) == nil)
    #expect(EnforcedChargeLimit.parse(Data("junk".utf8)) == nil)
}
@Test func magSafeLightFollowsWhatThePackIsDoing() {
    #expect(MagSafeLED.desired(pluggedIn: false, charging: true, amperage: 2000) == .system)
    #expect(MagSafeLED.desired(pluggedIn: nil, charging: false, amperage: nil) == .system)
    #expect(MagSafeLED.desired(pluggedIn: true, charging: true, amperage: 1500) == .amber)
    #expect(MagSafeLED.desired(pluggedIn: true, charging: false, amperage: -1454) == .blinkAmber)
    #expect(MagSafeLED.desired(pluggedIn: true, charging: false, amperage: 0) == .green)
    // Sensor noise around zero is holding, not charging or discharging.
    #expect(MagSafeLED.desired(pluggedIn: true, charging: false, amperage: -20) == .green)
}
@Test func chargeLimitWriteNeedsRoot() {
    guard geteuid() != 0 else { return }
    #expect(throws: PowerFailure.self) { try SystemChargeLimit.write(55) }
}
@Test func chargeLimitRequestRoundTrips() throws {
    let data = try JSONEncoder().encode(PowerRequest(.chargeLimit, limit: 55, led: true))
    let decoded = try JSONDecoder().decode(PowerRequest.self, from: data)
    #expect(decoded.action == .chargeLimit && decoded.limit == 55 && decoded.led == true)
    // A reply from an older helper, without the new fields, still decodes.
    let old = #"{"chargeSupported":false,"dischargeSupported":true,"capability":"x","mode":"off","band":{"lower":50,"upper":55},"lidActive":false,"recoveryPending":false,"helperConnected":true}"#
    let snapshot = try JSONDecoder().decode(PowerSnapshot.self, from: Data(old.utf8))
    #expect(snapshot.ledControl == nil && snapshot.systemLimit == nil)
}

private final class LEDHardware: PowerHardware {
    var plugged = true
    var flow: (charging: Bool, amperage: Int)? = (false, -1400)
    var led: MagSafeLED = .amber
    var ledWrites: [MagSafeLED] = []
    func read(_ key: String) -> [UInt8]? { nil }
    func snapshot() -> PowerSnapshot { var s = PowerSnapshot(); s.percent = 80; s.pluggedIn = plugged; return s }
    func chargeValues(allow: Bool) -> [String: [UInt8]] { [:] }
    func adapterValues(allow: Bool) -> [String: [UInt8]] { [:] }
    func writeControl(_ key: String, _ bytes: [UInt8]) throws {}
    func batteryFlow() -> (charging: Bool, amperage: Int)? { flow }
    func readLED() -> MagSafeLED? { led }
    func writeLED(_ value: MagSafeLED) throws { led = value; ledWrites.append(value) }
}
@Test @MainActor func ledFollowsStateAndIsHandedBackOnStop() throws {
    let h = LEDHardware()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = PowerController(hardware: h, recoveryURL: dir.appendingPathComponent("r.json"), execute: { _, _ in "" })
    _ = c.handle(.init(.status, led: true))
    #expect(h.led == .blinkAmber && c.active)
    h.flow = (true, 2100); c.updateLED()
    #expect(h.led == .amber)
    h.flow = (false, 0); c.updateLED()
    #expect(h.led == .green)
    // macOS rewrote the key underneath: the next tick puts it back.
    h.led = .amber; c.updateLED()
    #expect(h.led == .green)
    // Unplugging hands the LED to macOS but keeps the setting for the next plug-in.
    h.plugged = false; c.updateLED()
    #expect(h.led == .system && c.active)
    h.plugged = true; c.updateLED()
    #expect(h.led == .green)
    // Losing the app hands it back and turns the control off.
    try c.restoreAll()
    #expect(h.led == .system && !c.active)
    c.timer?.invalidate()
}
@Test @MainActor func requestsWithoutTheLEDFieldLeaveItAlone() throws {
    let h = LEDHardware()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = PowerController(hardware: h, recoveryURL: dir.appendingPathComponent("r.json"), execute: { _, _ in "" })
    _ = c.handle(.init(.status))
    #expect(h.ledWrites.isEmpty && !c.active)
    c.timer?.invalidate()
}

@Test func sailingHoldsInsideTheBandAndRechargesBelowIt() {
    // Prerak's example: a 55 limit with a 5% band charges only below 50.
    #expect(Sailing.target(limit: 55, band: 5, percent: 55, recharging: false) == (55, false))
    #expect(Sailing.target(limit: 55, band: 5, percent: 54, recharging: false) == (54, false))
    #expect(Sailing.target(limit: 55, band: 5, percent: 50, recharging: false) == (50, false))
    #expect(Sailing.target(limit: 55, band: 5, percent: 49, recharging: false) == (55, true))
    // Once a recharge starts it runs to the limit, through the band.
    #expect(Sailing.target(limit: 55, band: 5, percent: 52, recharging: true) == (55, true))
    #expect(Sailing.target(limit: 55, band: 5, percent: 55, recharging: true) == (55, false))
    // Above the limit macOS drains to it as before; off means an exact limit.
    #expect(Sailing.target(limit: 55, band: 5, percent: 70, recharging: false) == (55, false))
    #expect(Sailing.target(limit: 55, band: 0, percent: 54, recharging: false) == (55, false))
    #expect(Sailing.target(limit: 55, band: 5, percent: nil, recharging: false) == (55, false))
}
