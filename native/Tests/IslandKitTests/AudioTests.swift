import Foundation
import Testing
@testable import IslandKit

// MARK: Media key decoding

@Test func mediaKeyDataCarriesCodeStateAndRepeat() {
    let down = IslandMediaKeyEvent(data1: (0 << 16) | (0x0A << 8))
    #expect(down == IslandMediaKeyEvent(code: IslandMediaKey.volumeUp, state: .down))
    let repeatDown = IslandMediaKeyEvent(data1: (1 << 16) | (0x0A << 8) | 1)
    #expect(repeatDown == IslandMediaKeyEvent(code: IslandMediaKey.volumeDown, state: .down, isRepeat: true))
    #expect(IslandMediaKeyEvent(data1: (7 << 16) | (0x0B << 8)).state == .up)
    #expect(IslandMediaKeyEvent(data1: (7 << 16) | (0x05 << 8)).state == .unknown)
    #expect(IslandMediaKeyEvent(data1: down.data1) == down)
}

// MARK: Volume keys

private let visible = IslandVolumeKeyGate.Conditions(routed: true, showsNotices: true, hasVolume: true, hasMute: true)
private func key(_ code: Int, _ state: IslandMediaKeyEvent.State, repeating: Bool = false) -> IslandMediaKeyEvent {
    IslandMediaKeyEvent(code: code, state: state, isRepeat: repeating)
}
private let up = IslandMediaKey.volumeUp, down = IslandMediaKey.volumeDown, mute = IslandMediaKey.mute

@Test func disabledIslandLeavesNativeVolumeKeysAlone() {
    let gate = Ref(IslandVolumeKeyGate())
    var off = visible; off.routed = false
    #expect(gate.value.handle(key(up, .down), modifiers: [], conditions: off) == .pass)
    #expect(gate.value.handle(key(up, .up), modifiers: [], conditions: off) == .pass)
}

@Test func upAndDownStepOnceAndTheirReleasesAreConsumed() {
    let gate = Ref(IslandVolumeKeyGate())
    #expect(gate.value.handle(key(up, .down), modifiers: [], conditions: visible) == .step(up: true, fine: false))
    #expect(gate.value.handle(key(up, .up), modifiers: [], conditions: visible) == .consume)
    #expect(gate.value.handle(key(down, .down), modifiers: [], conditions: visible) == .step(up: false, fine: false))
    // Down releases without stepping again.
    #expect(gate.value.handle(key(down, .up), modifiers: [], conditions: visible) == .consume)
}

@Test func nativePressKeepsItsNativeRelease() {
    let gate = Ref(IslandVolumeKeyGate())
    var hidden = visible; hidden.showsNotices = false
    #expect(gate.value.handle(key(up, .down), modifiers: [], conditions: hidden) == .pass)
    // Revealing mid-hold never takes over the held native key, and macOS gets its release.
    #expect(gate.value.handle(key(up, .down, repeating: true), modifiers: [], conditions: visible) == .pass)
    #expect(gate.value.handle(key(up, .up), modifiers: [], conditions: visible) == .pass)
    // The next fresh visible press can use the island.
    #expect(gate.value.handle(key(up, .down), modifiers: [], conditions: visible) == .step(up: true, fine: false))
}

@Test func outputsWithoutSoftwareVolumeKeepNativeVolumeKeys() {
    let gate = Ref(IslandVolumeKeyGate())
    var noVolume = visible; noVolume.hasVolume = false
    #expect(gate.value.handle(key(up, .down), modifiers: [], conditions: noVolume) == .pass)
    // Mute works without software volume.
    #expect(gate.value.handle(key(mute, .down), modifiers: [], conditions: noVolume) == .toggleMute)
}

@Test func unsupportedMuteStaysNative() {
    let gate = Ref(IslandVolumeKeyGate())
    var noMute = visible; noMute.hasMute = false
    #expect(gate.value.handle(key(mute, .down), modifiers: [], conditions: noMute) == .pass)
}

@Test func optionAloneAndCommandOrControlStayWithMacOS() {
    let gate = Ref(IslandVolumeKeyGate())
    #expect(gate.value.handle(key(up, .down), modifiers: [.option], conditions: visible) == .pass)
    #expect(gate.value.handle(key(up, .down), modifiers: [.command], conditions: visible) == .pass)
    #expect(gate.value.handle(key(up, .down), modifiers: [.control, .shift], conditions: visible) == .pass)
    // Option + Shift reaches the island as a fine step.
    #expect(gate.value.handle(key(up, .down), modifiers: [.option, .shift], conditions: visible) == .step(up: true, fine: true))
}

@Test func playAndBrightnessKeysNeverEnterTheVolumePath() {
    let gate = Ref(IslandVolumeKeyGate())
    for code in [IslandMediaKey.play, IslandMediaKey.brightnessUp, IslandMediaKey.brightnessDown, IslandMediaKey.illuminationUp] {
        #expect(gate.value.handle(key(code, .down), modifiers: [], conditions: visible) == .pass)
        #expect(gate.value.handle(key(code, .up), modifiers: [], conditions: visible) == .pass)
    }
}

@Test func unknownKeyStatesPassThrough() {
    let gate = Ref(IslandVolumeKeyGate())
    #expect(gate.value.handle(key(up, .unknown), modifiers: [], conditions: visible) == .pass)
}

@Test func heldMuteTogglesOnceAndReleasesWithoutTogglingAgain() {
    let gate = Ref(IslandVolumeKeyGate())
    #expect(gate.value.handle(key(mute, .down), modifiers: [], conditions: visible) == .toggleMute)
    #expect(gate.value.handle(key(mute, .down, repeating: true), modifiers: [], conditions: visible) == .consume)
    #expect(gate.value.handle(key(mute, .down, repeating: true), modifiers: [], conditions: visible) == .consume)
    #expect(gate.value.handle(key(mute, .up), modifiers: [], conditions: visible) == .consume)
}

@Test func heldIslandKeyKeepsWorkingThroughVisibilityChangesAndIsReleasedAfterHiding() {
    let gate = Ref(IslandVolumeKeyGate())
    var hidden = visible; hidden.showsNotices = false
    #expect(gate.value.handle(key(up, .down), modifiers: [], conditions: visible) == .step(up: true, fine: false))
    #expect(gate.value.handle(key(up, .down, repeating: true), modifiers: [], conditions: hidden) == .step(up: true, fine: false))
    #expect(gate.value.handle(key(up, .up), modifiers: [], conditions: hidden) == .consume)
    // After its release, a hidden island starts the next press natively.
    #expect(gate.value.handle(key(up, .down), modifiers: [], conditions: hidden) == .pass)
}

@Test func losingTheControlMidHoldSwallowsRepeatsAndOwnsTheRelease() {
    let gate = Ref(IslandVolumeKeyGate())
    #expect(gate.value.handle(key(down, .down), modifiers: [], conditions: visible) == .step(up: false, fine: false))
    var lost = visible; lost.hasVolume = false
    #expect(gate.value.handle(key(down, .down, repeating: true), modifiers: [], conditions: lost) == .consume)
    var off = visible; off.routed = false
    #expect(gate.value.handle(key(down, .down, repeating: true), modifiers: [], conditions: off) == .consume)
    #expect(gate.value.handle(key(down, .up), modifiers: [], conditions: off) == .consume)
}

@Test func volumeStepsAreASixteenthOrASixtyFourthAndClamp() {
    #expect(IslandVolumeStep.apply(current: 0.5, muted: false, up: true, fine: false).volume == 0.5625)
    #expect(IslandVolumeStep.apply(current: 0.5, muted: false, up: false, fine: true).volume == 0.5 - 1.0 / 64)
    #expect(IslandVolumeStep.apply(current: 1, muted: false, up: true, fine: false).volume == 1)
    #expect(IslandVolumeStep.apply(current: 0.01, muted: false, up: false, fine: false).volume == 0)
    // From muted the step starts at 0, and raising above 0 unmutes.
    let raised = IslandVolumeStep.apply(current: 0.8, muted: true, up: true, fine: false)
    #expect(raised.volume == 0.0625 && raised.unmute)
    let lowered = IslandVolumeStep.apply(current: 0.8, muted: true, up: false, fine: false)
    #expect(lowered.volume == 0 && !lowered.unmute)
    #expect(IslandVolumeStep.apply(current: .nan, muted: false, up: true, fine: false).volume == 0.0625)
}

@Test func mutedVolumeReadsZeroWithTheSlashSymbol() {
    #expect(IslandLevelReadout.volume(level: 0.6, muted: true) == ("speaker.slash.fill", 0))
    #expect(IslandLevelReadout.volume(level: 0, muted: false).symbol == "speaker.slash.fill")
    #expect(IslandLevelReadout.volume(level: 0.42, muted: false) == ("speaker.wave.2.fill", 0.42))
    #expect(IslandLevelReadout.percent(0.444) == 44)
    #expect(IslandLevelReadout.percent(1.3) == 100)
    #expect(IslandLevelReadout.percent(.infinity) == 0)
}

// MARK: Volume feedback

@Test func startingObservationIsSilent() {
    let feedback = Ref(IslandVolumeFeedback())
    feedback.value.start(lifetime: 1)
    #expect(feedback.value.receive(.init(lifetime: 1, level: 0.5, muted: false), isOpen: false, now: 0) == false)
    #expect(feedback.value.receive(.init(lifetime: 1, level: 0.6, muted: false), isOpen: false, now: 1) == true)
}

@Test func outputSwitchIsSilentAtAnyLevelOrMuteAndTheFirstRealChangeShowsOnce() {
    let feedback = Ref(IslandVolumeFeedback())
    feedback.value.start(lifetime: 1)
    _ = feedback.value.receive(.init(lifetime: 1, level: 0.5, muted: false), isOpen: false, now: 0)
    feedback.value.outputChanged(lifetime: 2)
    #expect(feedback.value.receive(.init(lifetime: 2, level: 0.2, muted: true), isOpen: false, now: 1) == false)
    #expect(feedback.value.receive(.init(lifetime: 2, level: 0.3, muted: false), isOpen: false, now: 2) == true)
    #expect(feedback.value.receive(.init(lifetime: 2, level: 0.3, muted: false), isOpen: false, now: 3) == false)
}

@Test func firstMuteChangeAfterAnEqualLevelSwitchIsNotSwallowed() {
    let feedback = Ref(IslandVolumeFeedback())
    feedback.value.start(lifetime: 1)
    _ = feedback.value.receive(.init(lifetime: 1, level: 0.5, muted: false), isOpen: false, now: 0)
    feedback.value.outputChanged(lifetime: 2)
    #expect(feedback.value.receive(.init(lifetime: 2, level: 0.5, muted: false), isOpen: false, now: 1) == false)
    #expect(feedback.value.receive(.init(lifetime: 2, level: 0.5, muted: true), isOpen: false, now: 2) == true)
}

@Test func supersededAndDelayedReadingsCannotFlash() {
    let feedback = Ref(IslandVolumeFeedback())
    feedback.value.start(lifetime: 1)
    _ = feedback.value.receive(.init(lifetime: 1, level: 0.5, muted: false), isOpen: false, now: 0)
    // A quick reconnect to the same output re-baselines before the queued reading lands.
    feedback.value.outputChanged(lifetime: 2)
    #expect(feedback.value.receive(.init(lifetime: 1, level: 0.9, muted: false), isOpen: false, now: 1) == false)
    #expect(feedback.value.receive(.init(lifetime: 2, level: 0.9, muted: false), isOpen: false, now: 2) == false)
}

@Test func anExplicitKeyShowsEvenWhenTheLevelDidNotChange() {
    let feedback = Ref(IslandVolumeFeedback())
    feedback.value.start(lifetime: 1)
    _ = feedback.value.receive(.init(lifetime: 1, level: 1, muted: false), isOpen: false, now: 0)
    #expect(feedback.value.keyPressed(level: 1, muted: false) == true)
    // Its echo is silent.
    #expect(feedback.value.receive(.init(lifetime: 1, level: 1, muted: false), isOpen: false, now: 0.1) == false)
}

@Test func openIslandKeepsItsOwnAdjustmentOutOfTheHeaderForOneSecond() {
    let feedback = Ref(IslandVolumeFeedback())
    feedback.value.start(lifetime: 1)
    _ = feedback.value.receive(.init(lifetime: 1, level: 0.5, muted: false), isOpen: true, now: 0)
    feedback.value.expect(level: 0.6, muted: false, own: true, now: 10)
    // The driver settles slightly differently within the second: still the island's own change.
    #expect(feedback.value.receive(.init(lifetime: 1, level: 0.61, muted: false), isOpen: true, now: 10.5) == false)
    // A key right after still shows; a change after the moment shows again.
    #expect(feedback.value.keyPressed(level: 0.66, muted: false) == true)
    #expect(feedback.value.receive(.init(lifetime: 1, level: 0.2, muted: false), isOpen: true, now: 11.2) == true)
    // Other changes show in the open header.
    #expect(feedback.value.receive(.init(lifetime: 1, level: 0.3, muted: false), isOpen: true, now: 20) == true)
}

@Test func aClosedIslandShowsEveryChange() {
    let feedback = Ref(IslandVolumeFeedback())
    feedback.value.start(lifetime: 1)
    _ = feedback.value.receive(.init(lifetime: 1, level: 0.5, muted: false), isOpen: false, now: 0)
    feedback.value.expect(level: 0.5, muted: false, own: true, now: 1)
    #expect(feedback.value.receive(.init(lifetime: 1, level: 0.7, muted: false), isOpen: false, now: 1.2) == true)
}

@Test func stoppingObservationCancelsFeedback() {
    let feedback = Ref(IslandVolumeFeedback())
    feedback.value.start(lifetime: 1)
    _ = feedback.value.receive(.init(lifetime: 1, level: 0.5, muted: false), isOpen: false, now: 0)
    feedback.value.stop()
    #expect(feedback.value.receive(.init(lifetime: 1, level: 0.9, muted: false), isOpen: false, now: 1) == false)
    #expect(feedback.value.keyPressed(level: 0.9, muted: false) == false)
}

@Test func burstsSettleThirtyMillisecondsAfterTheLastCallback() {
    #expect(IslandVolumeFeedback.readDelay == 0.03)
}

// MARK: Output writes

private func request(_ lifetime: Int, volume: Double? = nil, muted: Bool? = nil, waiter: Int, device: UInt32 = 7) -> IslandOutputWriteQueue.Request {
    .init(device: device, lifetime: lifetime, volume: volume, muted: muted, waiters: [waiter])
}

@Test func oneWriteInFlightAndTheNewestQueuedLevelAppliesOnce() {
    let queue = Ref(IslandOutputWriteQueue())
    #expect(queue.value.submit(request(1, volume: 0.2, waiter: 1)).start?.volume == 0.2)
    #expect(queue.value.submit(request(1, volume: 0.3, waiter: 2)).start == nil)
    #expect(queue.value.submit(request(1, volume: 0.4, waiter: 3)).start == nil)
    // An old read cannot overwrite the newest pending adjustment.
    #expect(queue.value.isBusy(lifetime: 1))
    let next = queue.value.finish(currentLifetime: 1)
    #expect(next.start == .init(device: 7, lifetime: 1, volume: 0.4, muted: nil, waiters: [2, 3]))
    #expect(queue.value.finish(currentLifetime: 1) == .init())
    #expect(!queue.value.isBusy(lifetime: 1))
}

@Test func aMuteAfterALevelKeepsBoth() {
    let queue = Ref(IslandOutputWriteQueue())
    _ = queue.value.submit(request(1, volume: 0.1, waiter: 1))
    _ = queue.value.submit(request(1, volume: 0.5, waiter: 2))
    _ = queue.value.submit(request(1, muted: true, waiter: 3))
    let next = queue.value.finish(currentLifetime: 1).start
    #expect(next?.volume == 0.5 && next?.muted == true)
}

@Test func newOutputPublishesWhileAnOldWriteRunsAndItsAdjustmentSurvives() {
    let queue = Ref(IslandOutputWriteQueue())
    _ = queue.value.submit(request(1, volume: 0.1, waiter: 1))
    #expect(!queue.value.isBusy(lifetime: 2))
    _ = queue.value.submit(request(2, volume: 0.6, waiter: 2, device: 9))
    let next = queue.value.finish(currentLifetime: 2)
    #expect(next.start?.lifetime == 2 && next.start?.volume == 0.6)
}

@Test func switchDuringAWriteKeepsTheNewMuteAndSkipsAStaleUnmute() {
    let queue = Ref(IslandOutputWriteQueue())
    _ = queue.value.submit(request(1, volume: 0.4, waiter: 1))
    _ = queue.value.submit(request(1, muted: false, waiter: 2))
    // The output moves: the stale unmute is discarded, never replayed on the new output.
    #expect(queue.value.invalidate(currentLifetime: 2) == [2])
    let submission = queue.value.submit(request(2, muted: true, waiter: 3, device: 9))
    #expect(submission.start == nil && submission.discarded.isEmpty)
    var settled = [1, 2]
    let next = queue.value.finish(currentLifetime: 2)
    settled += next.start?.waiters ?? []
    #expect(next.start?.muted == true && next.start?.device == 9)
    _ = queue.value.finish(currentLifetime: 2)
    // Both in-progress and new-output requests settle exactly once.
    #expect(settled.sorted() == [1, 2, 3])
}

@Test func aReusedDeviceAfterStopCannotReviveAnOldLifetime() {
    let queue = Ref(IslandOutputWriteQueue())
    _ = queue.value.submit(request(1, volume: 0.1, waiter: 1))
    _ = queue.value.submit(request(1, volume: 0.9, waiter: 2))
    // Stopped and restarted on the same device id: a new lifetime.
    let next = queue.value.finish(currentLifetime: 2)
    #expect(next.start == nil && next.discarded == [2])
}

@Test func abandoningAStuckOutputSettlesEveryWaiterOnce() {
    let queue = Ref(IslandOutputWriteQueue())
    _ = queue.value.submit(request(1, volume: 0.2, waiter: 1))
    _ = queue.value.submit(request(1, muted: true, waiter: 2))
    #expect(queue.value.abandon() == [1, 2])
    #expect(queue.value.isBusy(lifetime: 1) == false)
    #expect(queue.value.abandon().isEmpty)
    // A later write starts at once instead of waiting behind the stuck one.
    #expect(queue.value.submit(request(2, volume: 0.5, waiter: 3)).start?.volume == 0.5)
}

@Test func nonFiniteLevelsNeverReachTheDriver() {
    let queue = Ref(IslandOutputWriteQueue())
    let refused = queue.value.submit(request(1, volume: .nan, waiter: 1))
    #expect(refused.start == nil && refused.discarded == [1])
    #expect(queue.value.submit(request(1, volume: .infinity, muted: true, waiter: 2)).start == .init(device: 7, lifetime: 1, volume: nil, muted: true, waiters: [2]))
    #expect(queue.value.submit(request(1, volume: 1.7, waiter: 3)).start == nil)
    #expect(queue.value.finish(currentLifetime: 1).start?.volume == 1)
}

// MARK: Devices

@Test func headphonesAreRecognisedByNameUIDOrDataSource() {
    #expect(IslandAudioNaming.isHeadphones(name: "Alex’s AirPods Pro", uid: "02-00:output", dataSource: nil))
    #expect(IslandAudioNaming.isHeadphones(name: "MacBook Pro Speakers", uid: "BuiltInSpeakerDevice", dataSource: "Headphones"))
    #expect(IslandAudioNaming.isHeadphones(name: "Sony WH-1000XM5", uid: "x", dataSource: nil))
    #expect(!IslandAudioNaming.isHeadphones(name: "MacBook Pro Speakers", uid: "BuiltInSpeakerDevice", dataSource: "Internal Speakers"))
    #expect(!IslandAudioNaming.isHeadphones(name: "JBL Flip 6", uid: "bt", dataSource: nil))
}

@Test func devicesListDefaultFirstThenByNameThenUID() {
    let devices = [(false, "Studio", "b"), (false, "airpods", "z"), (true, "Speakers", "s"), (false, "Studio", "a")]
    let sorted = devices.sorted { IslandAudioNaming.precedes(($0.0, $0.1, $0.2), ($1.0, $1.1, $1.2)) }
    #expect(sorted.map(\.2) == ["s", "z", "a", "b"])
}

// MARK: Microphone mute

@Test func onlyMenuSpritesOwnAggregatesAreSkipped() {
    #expect(IslandMicMuteRules.isOwnAggregate(.init(uid: "x", name: "MenuSprite Mixer", isAggregate: true)))
    #expect(!IslandMicMuteRules.isOwnAggregate(.init(uid: "y", name: "Studio Aggregate", isAggregate: true)))
    #expect(!IslandMicMuteRules.isOwnAggregate(.init(uid: "z", name: "MenuSprite Mic", isAggregate: false)))
}

@Test func muteUsesTheSwitchElseSavesLevelsAboveTheSilentLevel() {
    let switched = IslandMicDevice(uid: "a", name: "A", muteSwitch: false, levels: [0: 0.5])
    #expect(IslandMicMuteRules.mutePlan(for: switched, alreadyClaimed: false) == .setSwitch)
    let levels = IslandMicDevice(uid: "b", name: "B", levels: [1: 0.6, 2: 0.005])
    #expect(IslandMicMuteRules.mutePlan(for: levels, alreadyClaimed: false) == .zeroLevels(saved: [1: 0.6]))
}

@Test func alreadySilentMicStaysOursOnlyIfWeHeldIt() {
    let silent = IslandMicDevice(uid: "a", name: "A", muteSwitch: true)
    #expect(IslandMicMuteRules.mutePlan(for: silent, alreadyClaimed: false) == .leave(keepClaim: false))
    #expect(IslandMicMuteRules.mutePlan(for: silent, alreadyClaimed: true) == .leave(keepClaim: true))
    let quiet = IslandMicDevice(uid: "b", name: "B", levels: [0: 0.01])
    #expect(IslandMicMuteRules.mutePlan(for: quiet, alreadyClaimed: false) == .leave(keepClaim: false))
}

@Test func unmuteRestoresTheSavedLevelThenFallsBackToThreeQuarters() {
    let silent = IslandMicDevice(uid: "b", name: "B", levels: [1: 0, 2: 0])
    #expect(IslandMicMuteRules.unmutePlan(claim: .levels([1: 0.6, 2: 0.4]), device: silent) == .restore([1: 0.6, 2: 0.4]))
    #expect(IslandMicMuteRules.unmutePlan(claim: .levels([:]), device: silent) == .restore([1: 0.75, 2: 0.75]))
    #expect(IslandMicMuteRules.unmutePlan(claim: .muteSwitch, device: .init(uid: "a", name: "A", muteSwitch: true)) == .clearSwitch)
}

@Test func unmuteLeavesAbsentOrUnreadableDevicesClaimedAndForgetsAudibleOnes() {
    #expect(IslandMicMuteRules.unmutePlan(claim: .levels([0: 0.5]), device: nil) == .keepClaim)
    let audible = IslandMicDevice(uid: "b", name: "B", levels: [0: 0.4])
    #expect(IslandMicMuteRules.unmutePlan(claim: .levels([0: 0.5]), device: audible) == .dropClaim)
}

@Test func unmuteTargetsOnlyTheClaimedDevices() {
    let record = IslandMicMuteRecord(claims: ["b": .muteSwitch, "a": .levels([:])])
    #expect(IslandMicMuteRules.unmuteTargets(record: record) == ["a", "b"])
    #expect(IslandMicMuteRules.unmuteTargets(record: IslandMicMuteRecord()).isEmpty)
}

@Test func anUnreadableRecordTouchesNoMicrophone() {
    // A corrupted record must never open microphones the person muted elsewhere.
    #expect(IslandMicMuteRules.unmuteTargets(record: nil).isEmpty)
    let corrupt = Data("{\"claims\":{\"usb\":{\"bogus\":1}}}".utf8)
    let decoded = try? JSONDecoder().decode(IslandMicMuteRecord.self, from: corrupt)
    #expect(decoded == nil)
    #expect(IslandMicMuteRules.unmuteTargets(record: decoded).isEmpty)
}

@Test func muteVerdictComesFromTheDevicesNotTheRequest() {
    let silent = IslandMicDevice(uid: "built-in", name: "Built-in", muteSwitch: true)
    let live = IslandMicDevice(uid: "usb", name: "USB", levels: [0: 0.6])
    let untouchable = IslandMicDevice(uid: "phone", name: "iPhone")
    #expect(IslandMicMuteRules.verdict(requested: true, present: [silent], claimed: ["built-in"]) == .muted)
    #expect(IslandMicMuteRules.verdict(requested: true, present: [silent, live], claimed: ["built-in"]) == .partlyMuted)
    // A microphone with no mute switch and no readable level cannot be shown as silent.
    #expect(IslandMicMuteRules.verdict(requested: true, present: [silent, untouchable], claimed: []) == .partlyMuted)
    #expect(IslandMicMuteRules.verdict(requested: true, present: [], claimed: []) == .muted)
}

@Test func unmuteVerdictIsStillMutedWhileAPresentClaimRemains() {
    let closed = IslandMicDevice(uid: "usb", name: "USB", levels: [0: 0])
    #expect(IslandMicMuteRules.verdict(requested: false, present: [closed], claimed: ["usb"]) == .stillMuted)
    // Muted elsewhere, not by the island: that is the person's choice, and the island is live.
    #expect(IslandMicMuteRules.verdict(requested: false, present: [closed], claimed: []) == .live)
    // A claim for an unplugged headset waits for it to return and does not count now.
    #expect(IslandMicMuteRules.verdict(requested: false, present: [], claimed: ["headset"]) == .live)
    #expect(IslandMicMuteVerdict.live.isApplied && IslandMicMuteVerdict.muted.isApplied)
    #expect(!IslandMicMuteVerdict.partlyMuted.isApplied && !IslandMicMuteVerdict.stillMuted.isApplied)
}

@Test func aggregatesDoNotDecideTheVerdict() {
    let member = IslandMicDevice(uid: "built-in", name: "Built-in", muteSwitch: true)
    let aggregate = IslandMicDevice(uid: "agg", name: "Studio Aggregate", isAggregate: true, levels: [0: 0.8])
    #expect(IslandMicMuteRules.verdict(requested: true, present: [member, aggregate], claimed: ["built-in"]) == .muted)
}

@Test func deviceChangeReassertsTheRequestedStateNotAnOlderOne() {
    let intent = Ref(IslandMicMuteIntent())
    let first = intent.value.request(true)
    _ = intent.value.request(false)
    let change = intent.value.deviceChanged()
    #expect(change.muted == false)
    #expect(!intent.value.isCurrent(first) && intent.value.isCurrent(change.generation))
    #expect(IslandMicMuteIntent.needsListeners(requested: false, claims: 1, applied: true))
    #expect(!IslandMicMuteIntent.needsListeners(requested: false, claims: 0, applied: true))
    // A sweep that did not fully apply keeps listening so the next device change retries it.
    #expect(IslandMicMuteIntent.needsListeners(requested: false, claims: 0, applied: false))
}

@Test func micMuteRecordSurvivesARoundTrip() throws {
    let record = IslandMicMuteRecord(claims: ["usb": .levels([0: 0.5, 1: 0.25]), "built-in": .muteSwitch])
    let decoded = try JSONDecoder().decode(IslandMicMuteRecord.self, from: JSONEncoder().encode(record))
    #expect(decoded == record)
}

// MARK: Driver watchdog

@Test func workFinishingInTimeIsUsedAndLeavesNoTimer() {
    let watchdog = Ref(IslandHALWatchdog(limit: 2))
    let job = watchdog.value.submit(now: 10)
    #expect(watchdog.value.deadline == 12)
    #expect(watchdog.value.finish(job) == true)
    #expect(watchdog.value.deadline == nil)
    #expect(watchdog.value.check(now: 30) == false)
}

@Test func aCallStuckPastTheLimitAbandonsTheQueue() {
    let watchdog = Ref(IslandHALWatchdog(limit: 2))
    let stuck = watchdog.value.submit(now: 0)
    let behind = watchdog.value.submit(now: 0.5)
    #expect(watchdog.value.check(now: 1.9) == false)
    #expect(watchdog.value.check(now: 2) == true)
    #expect(watchdog.value.generation == 1)
    #expect(!watchdog.value.isCurrent(stuck) && !watchdog.value.isCurrent(behind))
    #expect(watchdog.value.deadline == nil)
    // Later work belongs to the fresh queue; the stuck call's late result is not used.
    let fresh = watchdog.value.submit(now: 3)
    #expect(watchdog.value.isCurrent(fresh))
    #expect(watchdog.value.finish(stuck) == false)
    #expect(watchdog.value.finish(fresh) == true)
}

@Test func theDeadlineFollowsTheOldestUnfinishedJob() {
    let watchdog = Ref(IslandHALWatchdog(limit: 2))
    let first = watchdog.value.submit(now: 1)
    _ = watchdog.value.submit(now: 1.5)
    #expect(watchdog.value.deadline == 3)
    _ = watchdog.value.finish(first)
    #expect(watchdog.value.deadline == 3.5)
}

/// A mutable box, so a stateful rule can be driven inside `#expect`.
final class Ref<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
