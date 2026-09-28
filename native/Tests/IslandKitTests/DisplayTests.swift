import Foundation
import Testing
@testable import IslandKit

// MARK: DDC framing

@Test func ddcSetPacketCarriesLengthCodeValueAndChecksum() {
    let packet = IslandDDC.setPacket(value: 0x012C)
    #expect(Array(packet.prefix(5)) == [0x84, 0x03, 0x10, 0x01, 0x2C])
    // Seeded with 0x6E and, for a multi-byte payload, XORed with 0x51.
    #expect(packet[5] == 0x6E ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x01 ^ 0x2C ^ 0x51)
}

@Test func ddcGetPacketHasNoSubAddressInItsChecksum() {
    let packet = IslandDDC.getPacket()
    #expect(packet == [0x82, 0x01, 0x10, 0x6E ^ 0x82 ^ 0x01 ^ 0x10])
}

private func reply(maximum: UInt16, current: UInt16, code: UInt8 = 0x10) -> [UInt8] {
    var bytes: [UInt8] = [0x6E, 0x88, 0x02, 0x00, code, 0x00,
                          UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
    bytes.append(bytes.reduce(0x50, ^))
    return bytes
}

@Test func ddcReplyReadsMaximumAndCurrentBigEndian() {
    #expect(IslandDDC.parseReply(reply(maximum: 100, current: 42)) == .init(current: 42, maximum: 100))
    #expect(IslandDDC.parseReply(reply(maximum: 0x0190, current: 0x00C8))?.level == 0.5)
}

@Test func ddcReplyWithZeroMaximumMeansAHundred() {
    #expect(IslandDDC.parseReply(reply(maximum: 0, current: 30))?.maximum == 100)
}

@Test func ddcRejectsShortCorruptOrForeignReplies() {
    #expect(IslandDDC.parseReply(Array(reply(maximum: 100, current: 42).prefix(10))) == nil)
    var corrupt = reply(maximum: 100, current: 42)
    corrupt[9] ^= 0xFF
    #expect(IslandDDC.parseReply(corrupt) == nil)
    #expect(IslandDDC.parseReply(reply(maximum: 100, current: 42, code: 0x12)) == nil)
}

@Test func ddcValueScalesTheLevelToTheMonitorsRange() {
    #expect(IslandDDC.value(level: 0.5, maximum: 100) == 50)
    #expect(IslandDDC.value(level: 1.4, maximum: 400) == 400)
    #expect(IslandDDC.value(level: .nan, maximum: 100) == 0)
}

@Test func ddcPacingIsFieldProven() {
    #expect(IslandDDC.commandSpacing >= 0.05)
    #expect(IslandDDC.pauseBeforeReply == 0.05)
    #expect(IslandDDC.writeRepeats == 2 && IslandDDC.retries == 4)
}

// MARK: Display matching

@Test func registryLocationWinsOverEverythingElse() {
    let display = IslandDisplayIdentity(location: "IOService:/a/dispext0/IOMobileFramebufferShim", vendor: 1, product: 2)
    let byLocation = IslandDisplayIdentity(location: "IOService:/a/dispext0/IOMobileFramebufferShim")
    let byNumbers = IslandDisplayIdentity(vendor: 1, product: 2, serial: 3)
    #expect(IslandDisplayMatching.match(displays: [display], services: [byNumbers, byLocation]) == [0: 1])
}

@Test func withoutALocationAPairNeedsVendorAndProduct() {
    let display = IslandDisplayIdentity(vendor: 7789, product: 23305, serial: 0, name: "LG ULTRAFINE")
    #expect(IslandDisplayMatching.match(displays: [display], services: [.init(vendor: 7789, name: "LG ULTRAFINE")]).isEmpty)
    #expect(IslandDisplayMatching.match(displays: [display], services: [.init(vendor: 7789, product: 23305)]) == [0: 0])
}

@Test func identicalMonitorsPairInTheOrderTheyWereFound() {
    let twin = IslandDisplayIdentity(vendor: 1, product: 2)
    #expect(IslandDisplayMatching.match(displays: [twin, twin], services: [twin, twin]) == [0: 0, 1: 1])
    // A serial number breaks the tie.
    let a = IslandDisplayIdentity(vendor: 1, product: 2, serial: 10), b = IslandDisplayIdentity(vendor: 1, product: 2, serial: 20)
    #expect(IslandDisplayMatching.match(displays: [a, b], services: [b, a]) == [0: 1, 1: 0])
}

// MARK: Brightness keys

private let routed = IslandBrightnessKeyGate.Conditions(routed: true, showsNotices: true, hasTarget: true)
private func press(_ code: Int, _ state: IslandMediaKeyEvent.State, repeating: Bool = false) -> IslandMediaKeyEvent {
    IslandMediaKeyEvent(code: code, state: state, isRepeat: repeating)
}

@Test func brightnessKeysStepAndDropBothHalvesWhileTheIslandShowsNotices() {
    let gate = Ref(IslandBrightnessKeyGate())
    #expect(gate.value.handle(press(2, .down), modifiers: [], conditions: routed) == .step(up: true, fine: false))
    #expect(gate.value.handle(press(2, .down, repeating: true), modifiers: [], conditions: routed) == .step(up: true, fine: false))
    #expect(gate.value.handle(press(2, .up), modifiers: [], conditions: routed) == .consume)
    #expect(gate.value.handle(press(3, .down), modifiers: [.option, .shift], conditions: routed) == .step(up: false, fine: true))
}

@Test func hiddenIslandLeavesBrightnessKeysToMacOS() {
    let gate = Ref(IslandBrightnessKeyGate())
    var hidden = routed; hidden.showsNotices = false
    #expect(gate.value.handle(press(2, .down), modifiers: [], conditions: hidden) == .pass)
    #expect(gate.value.handle(press(2, .up), modifiers: [], conditions: hidden) == .pass)
}

@Test func brightnessKeysNeedTheIndicatorRoutedAndATarget() {
    let gate = Ref(IslandBrightnessKeyGate())
    var off = routed; off.routed = false
    #expect(gate.value.handle(press(2, .down), modifiers: [], conditions: off) == .pass)
    var none = routed; none.hasTarget = false
    #expect(gate.value.handle(press(3, .down), modifiers: [], conditions: none) == .pass)
    #expect(gate.value.handle(press(2, .down), modifiers: [.option], conditions: routed) == .pass)
    #expect(gate.value.handle(press(IslandMediaKey.volumeUp, .down), modifiers: [], conditions: routed) == .pass)
}

@Test func brightnessStepsAreASixteenthAndClamp() {
    #expect(IslandBrightnessStep.apply(current: 0.5, up: true, fine: false) == 0.5625)
    #expect(IslandBrightnessStep.apply(current: 0.99, up: true, fine: false) == 1)
    #expect(IslandBrightnessStep.apply(current: 0.5, up: false, fine: true) == 0.5 - 1.0 / 64)
}

// MARK: Keyboard light

@Test func onlyNativeIlluminationKeyDownsIncludingRepeatsTriggerARead() {
    #expect(IslandKeyboardLightKeys.triggersRead(press(21, .down), modifiers: []))
    #expect(IslandKeyboardLightKeys.triggersRead(press(22, .down, repeating: true), modifiers: []))
    #expect(IslandKeyboardLightKeys.triggersRead(press(23, .down), modifiers: [.option, .shift]))
    #expect(!IslandKeyboardLightKeys.triggersRead(press(21, .up), modifiers: []))
    #expect(!IslandKeyboardLightKeys.triggersRead(press(21, .down), modifiers: [.command]))
    #expect(!IslandKeyboardLightKeys.triggersRead(press(21, .down), modifiers: [.option]))
    #expect(!IslandKeyboardLightKeys.triggersRead(press(IslandMediaKey.brightnessUp, .down), modifiers: []))
    #expect(IslandKeyboardLightKeys.readDelay == 0.08)
}

@Test func brightnessNeedsControlDisplaysAndKeyboardLightOnlyNeedsABacklight() {
    #expect(IslandDisplayRouting.brightnessReason(controlDisplays: false) == "Enable “Control displays” in its settings.")
    #expect(IslandDisplayRouting.brightnessReason(controlDisplays: true) == nil)
    #expect(IslandDisplayRouting.keyboardLightReason(hasBacklight: true) == nil)
    #expect(IslandDisplayRouting.keyboardLightReason(hasBacklight: false) == "Keyboard backlight control is unavailable on this Mac.")
}

// MARK: External monitor steps

@Test func aStepAfterAPauseReadsTheMonitorFirstAndABurstUsesTheRunningValue() {
    let monitor = Ref(IslandMonitorLevel())
    #expect(monitor.value.needsRead(now: 0))
    let token = monitor.value.beginRead()
    let accepted = monitor.value.finishRead(0.7, token: token, now: 0)
    #expect(accepted)
    #expect(!monitor.value.needsRead(now: 1))
    monitor.value.set(0.6, now: 1)
    #expect(!monitor.value.needsRead(now: 2.5))
    #expect(monitor.value.needsRead(now: 3.5))
}

@Test func aLevelSetWhileTheMonitorWasReadWinsOverTheRead() {
    let monitor = Ref(IslandMonitorLevel())
    let token = monitor.value.beginRead()
    monitor.value.set(0.3, now: 0)
    let accepted = monitor.value.finishRead(0.9, token: token, now: 0.1)
    #expect(!accepted)
    #expect(monitor.value.level == 0.3)
}

@Test func aPhysicalAdjustmentCannotSuppressAStepBackToThePreviousValue() {
    let monitor = Ref(IslandMonitorLevel())
    monitor.value.set(0.5, now: 0)
    // The monitor's own buttons moved it; after a pause the island reads it before stepping.
    #expect(monitor.value.needsRead(now: 10))
    let token = monitor.value.beginRead()
    monitor.value.finishRead(0.5625, token: token, now: 10)
    let target = IslandBrightnessStep.apply(current: monitor.value.level ?? 0, up: false, fine: false)
    #expect(target == 0.5)
}
