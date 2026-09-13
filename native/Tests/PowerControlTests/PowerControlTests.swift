import Foundation
import Testing
@testable import PowerControl

@Test func chargeBandHysteresis() throws {
    let band = ChargeBand(lower:50,upper:55)
    for percent in 0...100 {
        for allowed in [false,true] {
            let d = try #require(BatteryPolicy.decide(mode:.maintain,band:band,percent:percent,chargingAllowed:allowed))
            #expect(d.adapter && d.mode == .maintain)
            #expect(d.charge == (percent <= 50 ? true : (percent >= 55 ? false : allowed)))
        }
    }
}
@Test func topUpReturnsToLimitWithoutForcedDischarge() throws {
    let band = ChargeBand()
    for percent in 20..<100 {
        let d = try #require(BatteryPolicy.decide(mode:.topUp,band:band,percent:percent,chargingAllowed:false))
        #expect(d.mode == .topUp && d.adapter && d.charge)
    }
    let done = try #require(BatteryPolicy.decide(mode:.topUp,band:band,percent:100,chargingAllowed:true))
    #expect(done.mode == .maintain && done.adapter && !done.charge)
}
@Test func dischargeReconnectsAtLimit() throws {
    let band = ChargeBand()
    for percent in 56...100 {
        let d = try #require(BatteryPolicy.decide(mode:.discharge,band:band,percent:percent,chargingAllowed:true))
        #expect(d.mode == .discharge && !d.adapter && !d.charge)
    }
    let done = try #require(BatteryPolicy.decide(mode:.discharge,band:band,percent:55,chargingAllowed:false))
    #expect(done.mode == .maintain && done.adapter && !done.charge)
}
@Test func unknownAndInvalidInputsCannotChooseAWritingDecision() {
    for band in [ChargeBand(lower:55,upper:55),.init(lower:90,upper:50),.init(lower:19,upper:55),.init(lower:20,upper:101)] {
        #expect(BatteryPolicy.decide(mode:.maintain,band:band,percent:50,chargingAllowed:true) == nil)
    }
    for percent in [-1,101] { #expect(BatteryPolicy.decide(mode:.maintain,band:.init(),percent:percent,chargingAllowed:true) == nil) }
    #expect(BatteryPolicy.decide(mode:.off,band:.init(),percent:55,chargingAllowed:true) == nil)
}
@Test func requestRejectsUnknownCommands() {
    #expect((try? JSONDecoder().decode(PowerRequest.self,from:Data("{\"action\":\"writeSMC\"}".utf8))) == nil)
}

private final class FakeHardware: PowerHardware {
    var values: [String:[UInt8]] = ["CHTE":[0,0,0,0],"CHIE":[0]]
    var percent = 82
    var plugged = true
    var failOn: String?
    var writes: [String] = []
    func read(_ key: String) -> [UInt8]? { values[key] }
    func snapshot() -> PowerSnapshot {
        var s = PowerSnapshot(); s.percent = percent; s.pluggedIn = plugged
        s.chargeSupported = true; s.dischargeSupported = true
        s.chargingAllowed = values["CHTE"] == [0,0,0,0]
        return s
    }
    func chargeValues(allow: Bool) -> [String:[UInt8]] { ["CHTE":[allow ? 0 : 1,0,0,0]] }
    func adapterValues(allow: Bool) -> [String:[UInt8]] { ["CHIE":[allow ? 0 : 8]] }
    func writeControl(_ key: String, _ bytes: [UInt8]) throws {
        if failOn == key { failOn = nil; throw PowerFailure("Injected failure") }
        values[key] = bytes; writes.append(key)
    }
}
private func recoveryURL() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    return dir.appendingPathComponent("recovery.json")
}
@Test @MainActor func partialHardwareWriteFailureRestoresOriginalValues() throws {
    let h = FakeHardware(), url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
    let c = PowerController(hardware:h,recoveryURL:url,execute:{ _,_ in "" })
    h.failOn = "CHIE"
    let response = c.handle(.init(.battery,mode:.discharge))
    #expect(response.mode == .off && response.error != nil)
    #expect(h.values == ["CHTE":[0,0,0,0],"CHIE":[0]])
    #expect(!c.needsRecovery)
}
@Test @MainActor func crashRecoveryAndExternalChangesArePreserved() throws {
    let h = FakeHardware(), url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
    let first = PowerController(hardware:h,recoveryURL:url,execute:{ _,_ in "" })
    #expect(first.handle(.init(.battery,mode:.discharge)).mode == .discharge)
    first.timer?.invalidate() // Simulate a crash; leave the journal and hardware intact.
    let recovered = PowerController(hardware:h,recoveryURL:url,execute:{ _,_ in "" })
    #expect(!recovered.needsRecovery)
    #expect(h.values == ["CHTE":[0,0,0,0],"CHIE":[0]])
    _ = recovered.handle(.init(.battery,mode:.maintain))
    h.values["CHTE"] = [0,0,0,0] // Another controller took over.
    let before = h.writes.count
    try recovered.restoreAll()
    #expect(h.writes.count == before) // No write over a value MenuSprite no longer owns.
    recovered.timer?.invalidate()
}
@Test @MainActor func watchdogAndUnplugRestoreControls() throws {
    let h = FakeHardware(), url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
    let c = PowerController(hardware:h,recoveryURL:url,execute:{ _,_ in "" })
    _ = c.handle(.init(.battery,mode:.discharge))
    c.lastHeartbeat = .distantPast; c.tick()
    #expect(c.mode == .off && !c.needsRecovery && h.values["CHIE"] == [0])
    _ = c.handle(.init(.battery,mode:.discharge)); h.plugged = false; c.tick()
    #expect(c.mode == .off && !c.needsRecovery && h.values["CHIE"] == [0])
}
@Test @MainActor func existingSleepDisableIsNeverClaimedOrCleared() throws {
    let h = FakeHardware(), url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
    var writes = 0
    let c = PowerController(hardware:h,recoveryURL:url,execute:{ _,args in
        if args == ["-g"] { return "SleepDisabled 1" }
        writes += 1; return ""
    })
    let response = c.handle(.init(.startLid))
    #expect(!response.lidActive && response.error != nil)
    try c.restoreAll()
    #expect(writes == 0)
}
@Test @MainActor func closedLidRestoresOnlyItsOwnSetting() throws {
    let h = FakeHardware(), url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
    var disabled = false
    let c = PowerController(hardware:h,recoveryURL:url,execute:{ _,args in
        if args == ["-g"] { return "SleepDisabled \(disabled ? 1 : 0)" }
        if args.first == "disablesleep" { disabled = args.last == "1" }
        return ""
    })
    #expect(c.handle(.init(.startLid)).lidActive && disabled)
    c.lastHeartbeat = .distantPast; c.tick()
    #expect(!disabled && !c.needsRecovery)
}

@Test @MainActor func unknownOriginalFirmwareStateIsNeverOverwritten() throws {
    let h = FakeHardware(), url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
    h.values["CHTE"] = [9,0,0,0]
    let c = PowerController(hardware:h,recoveryURL:url,execute:{ _,_ in "" })
    let result = c.handle(.init(.battery,mode:.maintain))
    #expect(result.mode == .off && result.error != nil && h.writes.isEmpty)
    #expect(h.values["CHTE"] == [9,0,0,0])
}
@Test @MainActor func corruptRecoveryJournalBlocksControlAndRemoval() throws {
    let h = FakeHardware(), url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
    try Data("broken".utf8).write(to:url)
    let c = PowerController(hardware:h,recoveryURL:url,execute:{ _,_ in "" })
    let result = c.handle(.init(.battery,mode:.discharge))
    #expect(result.recoveryPending && result.error != nil && h.writes.isEmpty)
    #expect(throws:PowerFailure.self) { try c.restoreAll() }
    #expect(try String(contentsOf:url,encoding:.utf8) == "broken")
}

@Test @MainActor func failedUpdateOfAnOwnedValueStillRestoresOriginal() throws {
    let h = FakeHardware(), url = try recoveryURL()
    defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
    let c = PowerController(hardware:h,recoveryURL:url,execute:{ _,_ in "" })
    _ = c.handle(.init(.battery,mode:.maintain))
    #expect(h.values["CHTE"] == [1,0,0,0])
    h.failOn = "CHTE"
    let response = c.handle(.init(.battery,mode:.topUp))
    #expect(response.mode == .off && response.error != nil)
    #expect(h.values["CHTE"] == [0,0,0,0] && !c.needsRecovery)
}

@Test func displayedCeilingDistinguishesTopUpAndInactiveTarget() {
    var snapshot = PowerSnapshot()
    #expect(snapshot.controlCeiling == nil)
    snapshot.mode = .maintain
    #expect(snapshot.controlCeiling == 55)
    snapshot.mode = .topUp
    #expect(snapshot.controlCeiling == 100)
    snapshot.mode = .discharge
    #expect(snapshot.controlCeiling == 55)
}
