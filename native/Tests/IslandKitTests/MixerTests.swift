import CoreAudio
import Foundation
import Testing

@testable import IslandKit

/// An AudioBufferList of interleaved float buffers with the given channel counts, freed on deinit.
private final class TestBuffers {
    let list: UnsafeMutableAudioBufferListPointer
    let shape: [Int]
    let frames: Int

    init(_ shape: [Int], frames: Int, fill: Float = 0) {
        self.shape = shape
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: shape.count)
        for (index, channels) in shape.enumerated() {
            let count = max(1, channels * frames)
            let data = UnsafeMutablePointer<Float>.allocate(capacity: count)
            data.initialize(repeating: fill, count: count)
            list[index] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(channels * frames * 4), mData: data)
        }
    }

    deinit {
        for buffer in list { buffer.mData?.deallocate() }
        free(list.unsafeMutablePointer)
    }

    var totalChannels: Int { shape.reduce(0, +) }

    private func locate(_ channel: Int) -> (buffer: Int, index: Int) {
        var rest = channel
        for (buffer, count) in shape.enumerated() {
            if rest < count { return (buffer, rest) }
            rest -= count
        }
        fatalError("channel out of range")
    }

    subscript(channel: Int, frame: Int) -> Float {
        get {
            let (buffer, index) = locate(channel)
            return list[buffer].mData!.assumingMemoryBound(to: Float.self)[frame * shape[buffer] + index]
        }
        set {
            let (buffer, index) = locate(channel)
            list[buffer].mData!.assumingMemoryBound(to: Float.self)[frame * shape[buffer] + index] = newValue
        }
    }

    func fill(_ signal: (_ channel: Int, _ frame: Int) -> Float) {
        for channel in 0..<totalChannels { for frame in 0..<frames { self[channel, frame] = signal(channel, frame) } }
    }

    func channel(_ channel: Int) -> [Float] { (0..<frames).map { self[channel, $0] } }
}

/// Runs a signal through a limiter in chunks and returns every channel's output.
private func limit(_ signal: [[Float]], chunks: [Int]? = nil, capacity: Int? = nil, rate: Double = 48_000) -> [[Float]] {
    let channels = signal.count, frames = signal[0].count
    var limiter = MixerLimiter(capacity: capacity ?? channels)
    defer { limiter.deallocate() }
    let coefficient = MixerLimiter.releaseCoefficient(sampleRate: rate)
    var output = Array(repeating: [Float](), count: channels)
    var start = 0
    var sizes = chunks ?? [frames]
    while start < frames {
        let size = min(sizes.isEmpty ? frames - start : sizes.removeFirst(), frames - start)
        let buffers = TestBuffers([channels], frames: size)
        buffers.fill { signal[$0][start + $1] }
        limiter.process(buffers.list, frames: size, releaseCoefficient: coefficient)
        for channel in 0..<channels { output[channel] += buffers.channel(channel) }
        start += size
    }
    return output
}

private func sine(_ frames: Int, amplitude: Float, step: Double = 0.05, phase: Double = 0) -> [Float] {
    (0..<frames).map { Float(sin(Double($0) * step + phase)) * amplitude }
}

private let delay = MixerLimiter.lookahead

private let ceiling = MixerLimiter.ceiling + 1e-6

private let speakers = "BuiltInSpeakerDevice"

private let headset = "AirPods-UID"

private func needs(hasAudio: Bool = true, gain: Double? = nil, route: String? = nil, available: Set<String> = [speakers, headset]) -> Bool {
    let target = MixerTarget(route: route, available: available, defaultOutput: speakers)
    return MixerEnginePolicy.needsEngine(hasAudio: hasAudio, target: target, defaultOutput: speakers, savedGain: gain, savedRoute: route)
}

private func app(_ id: String, name: String? = nil, key: String?? = .none, objects: [UInt32] = [1], playing: Bool = false) -> MixerApp {
    MixerApp(id: id, storageKey: key ?? id, name: name ?? id, bundleID: id, pid: 100, objects: objects, isPlaying: playing, isBypassed: false)
}

private struct ProcessTree {
    var responsible: [Int32: Int32] = [:]
    var parents: [Int32: Int32] = [:]
    var apps: Set<Int32> = []
    func owner(_ pid: Int32) -> Int32? {
        MixerAttribution.owner(of: pid, responsible: { responsible[$0] }, parent: { parents[$0] }, isRegularApp: { apps.contains($0) })
    }
}

private func named(_ keys: [String]) -> [MixerApp] { keys.map { app($0) } }

/// Seconds from the end of the hold until the gain is back above 0.9, after one loud frame.
private func recoverySeconds(rate: Double, coefficientRate: Double) -> Double {
    var limiter = MixerLimiter(capacity: 1)
    defer { limiter.deallocate() }
    let coefficient = MixerLimiter.releaseCoefficient(sampleRate: coefficientRate)
    let buffers = TestBuffers([1], frames: 1)
    buffers[0, 0] = 1.888
    limiter.process(buffers.list, frames: 1, releaseCoefficient: coefficient)
    var previous = limiter.gain, rising = 0, frames = 0
    while !(rising > 0 && limiter.gain >= 0.9), frames < 10_000_000 {
        buffers[0, 0] = 0
        limiter.process(buffers.list, frames: 1, releaseCoefficient: coefficient)
        if rising > 0 || limiter.gain > previous { rising += 1 }
        previous = limiter.gain
        frames += 1
    }
    return Double(rising) / rate
}

private func render(_ renderer: MixerRenderer, input: TestBuffers, output: TestBuffers) {
    renderer.render(input: UnsafePointer(input.list.unsafePointer), output: output.list.unsafeMutablePointer)
}

@Suite("Volume mixer")
struct MixerTests {
    // MARK: - Levels and the percentage field
    @Test func percentFieldRejectsNonNumbersAndNonFiniteNumbers() {
        for text in ["", "abc", "inf", "-inf", "nan", "1e3", "0x10", "--5", "5.5.5", "%", "12a", "∞"] {
            #expect(MixerLevel.parsePercent(text, maximum: 2, decimalSeparator: ".") == nil, "\(text)")
        }
    }

    @Test func percentFieldAcceptsASuffixAndTheLocaleSeparatorAndClamps() {
        #expect(MixerLevel.parsePercent("50", maximum: 2, decimalSeparator: ".") == 0.5)
        #expect(MixerLevel.parsePercent(" 75 % ", maximum: 2, decimalSeparator: ".") == 0.75)
        #expect(MixerLevel.parsePercent("12,5", maximum: 2, decimalSeparator: ",") == 0.125)
        #expect(MixerLevel.parsePercent("12,5", maximum: 2, decimalSeparator: ".") == nil)
        #expect(MixerLevel.parsePercent("250", maximum: MixerLevel.appMaximum, decimalSeparator: ".") == 2)
        #expect(MixerLevel.parsePercent("150", maximum: MixerLevel.systemMaximum, decimalSeparator: ".") == 1)
        #expect(MixerLevel.parsePercent("-5", maximum: 2, decimalSeparator: ".") == 0)
    }

    @Test func levelsWithinHalfAPercentOf100AreUntouched() {
        #expect(MixerLevel.isUnity(1.004))
        #expect(!MixerLevel.isUnity(0.99))
        #expect(MixerLevel.isBoosting(1.2))
        #expect(!MixerLevel.isBoosting(1.004))
        #expect(MixerLevel.clamp(.nan, maximum: 2) == nil)
        #expect(MixerLevel.clamp(.infinity, maximum: 2) == nil)
        #expect(MixerLevel.percent(1.555) == 156)
    }

    @Test func muteRemembersTheLastAudibleLevelOrRestores100() {
        let muted = MixerMute(gain: 0.4).toggled()
        #expect(muted == MixerMute(gain: 0, lastAudible: 0.4))
        #expect(muted.toggled().gain == 0.4)
        #expect(MixerMute(gain: 0).toggled().gain == 1)
    }

    @Test func hundredPercentIsNeverStoredAndMuteRoundTrips() {
        var preferences = MixerPreferences()
        preferences.setGain(1.003, for: "com.spotify.client")
        #expect(preferences.volumes.isEmpty)
        preferences.setGain(1.5, for: "com.spotify.client")
        #expect(preferences.volumes["com.spotify.client"] == 1.5)
        preferences.toggleMute("com.spotify.client")
        #expect(preferences.gain("com.spotify.client") == 0)
        preferences.toggleMute("com.spotify.client")
        #expect(preferences.gain("com.spotify.client") == 1.5)
        preferences.setGain(.nan, for: "com.spotify.client")
        #expect(preferences.gain("com.spotify.client") == 1.5)
        preferences.setGain(1, for: "com.spotify.client")
        #expect(preferences.volumes.isEmpty)
    }

    @Test func storedLevelsDropInvalidEntries() {
        let stored: [String: Any] = ["a": 0.5, "b": 1.0, "c": "loud", " ": 0.2, "d": 9.0, "e": Double.nan]
        #expect(MixerPreferences.cleanVolumes(stored) == ["a": 0.5, "d": 2.0])
        #expect(MixerPreferences.cleanVolumes("not a map").isEmpty)
        #expect(MixerPreferences.cleanStrings(["x": "Name", "y": "  ", "": "z", "w": 3]) == ["x": "Name"])
    }

    @Test func aSystemOutputSwitchClearsRoutesAndKeepsLevels() {
        var preferences = MixerPreferences()
        preferences.setGain(0.4, for: "com.apple.Music")
        preferences.setRoute("AirPods-UID", for: "com.apple.Music")
        preferences.outputSwitched(succeeded: false)
        #expect(preferences.routes == ["com.apple.Music": "AirPods-UID"])
        preferences.outputSwitched(succeeded: true)
        #expect(preferences.routes.isEmpty)
        #expect(preferences.gain("com.apple.Music") == 0.4)
    }

    @Test func deskFadersFollowThePageHeight() {
        let compact = MixerDeskLayout(pageHeight: 180)
        #expect(compact.deskHeight == 140 && compact.track == 54)
        let spacious = MixerDeskLayout(pageHeight: 264)
        #expect(spacious.deskHeight == 224 && spacious.track == 138)
        #expect(MixerDeskLayout(pageHeight: 60).deskHeight == 104)
        #expect(MixerDeskLayout(pageHeight: 60).track == 32)
        #expect(MixerDeskLayout(pageHeight: 600).track == 160)
    }

    @Test func deviceUIDsAreTrimmedAndControlCharactersRejected() {
        #expect(MixerDevice.cleanUID("  BuiltInSpeakerDevice \n") == "BuiltInSpeakerDevice")
        #expect(MixerDevice.cleanUID("   ") == nil)
        #expect(MixerDevice.cleanUID(nil) == nil)
        #expect(MixerDevice.cleanUID("AB\u{0007}CD") == nil)
        #expect(MixerDevice.cleanRoutes(["com.a": " uid-1 ", "com.b": "", " ": "uid-2", "com.c": "x\u{0000}"]) == ["com.a": "uid-1"])
    }

    @Test func defaultOutputAt100IsPassthroughAndChangesUseAnEngine() {
        #expect(!needs())
        #expect(needs(gain: 0.5))
        #expect(needs(gain: 1.8))
        #expect(needs(gain: 0))
        #expect(needs(route: headset))
    }

    @Test func untouchedAppsAreNeverTapped() {
        #expect(!needs(gain: nil, route: nil))
        #expect(!needs(gain: 1.0))
        #expect(!needs(route: speakers))
        #expect(needs(gain: 0.3, route: speakers))
    }

    @Test func aPersistentRowWaitsForAnAudioConnection() {
        #expect(!needs(hasAudio: false, gain: 0.5))
    }

    @Test func aMissingSavedOutputFallsBackToTheDefaultAndIsFlagged() {
        let target = MixerTarget(route: headset, available: [speakers], defaultOutput: speakers)
        #expect(target.uid == speakers && target.routeMissing)
        #expect(!needs(route: headset, available: [speakers]))
        #expect(MixerTarget(route: headset, available: [speakers, headset], defaultOutput: speakers).uid == headset)
        #expect(MixerTarget(route: nil, available: [], defaultOutput: nil).uid == nil)
    }

    @Test func theInactiveFilterChangesNothingUntilEnabled() {
        #expect(MixerListing.isShown(playing: false, gain: 1, routed: false, hideInactive: false))
        #expect(!MixerListing.isShown(playing: false, gain: 1, routed: false, hideInactive: true))
        #expect(MixerListing.isShown(playing: true, gain: 1, routed: false, hideInactive: true))
        #expect(MixerListing.isShown(playing: false, gain: 0.4, routed: false, hideInactive: true))
        #expect(MixerListing.isShown(playing: false, gain: 1, routed: true, hideInactive: true))
    }

    @Test func anyAppCanBeHiddenButARowWithNoIdentityIsAlwaysListed() {
        let hidden = ["com.spotify.client": "Spotify", "ffplay": "ffplay"]
        #expect(MixerListing.isHidden(storageKey: "com.spotify.client", hidden: hidden, showsFinder: true))
        #expect(MixerListing.isHidden(storageKey: "ffplay", hidden: hidden, showsFinder: true))
        #expect(!MixerListing.isHidden(storageKey: "com.apple.Music", hidden: hidden, showsFinder: true))
        #expect(!MixerListing.isHidden(storageKey: nil, hidden: hidden, showsFinder: true))
    }

    @Test func theFinderIsHiddenByItsOwnSwitchNeverTheMap() {
        var hidden: [String: String] = [:]
        var showsFinder = true
        MixerListing.hide(storageKey: MixerListing.finderBundleID, name: "Finder", in: &hidden, showsFinder: &showsFinder)
        #expect(hidden.isEmpty)
        #expect(!showsFinder)
        #expect(MixerListing.isHidden(storageKey: MixerListing.finderBundleID, hidden: hidden, showsFinder: showsFinder))
        MixerListing.hide(storageKey: "com.apple.Music", name: "Music", in: &hidden, showsFinder: &showsFinder)
        #expect(hidden == ["com.apple.Music": "Music"])
    }

    @Test func theFinderRowExistsBeforeQuickLookAndIsNeverDuplicated() {
        let withRow = MixerListing.withFinder([app("com.apple.Music")], showsFinder: true, finderPID: 400)
        #expect(withRow.map(\.id) == ["com.apple.Music", MixerListing.finderBundleID])
        #expect(withRow.last?.hasAudio == false)
        let playing = [app(MixerListing.finderBundleID, objects: [9], playing: true)]
        #expect(MixerListing.withFinder(playing, showsFinder: true, finderPID: 400).count == 1)
        #expect(MixerListing.withFinder([], showsFinder: false, finderPID: 400).isEmpty)
    }

    @Test func appsSortByNameThenIDAndDevicesDefaultFirst() {
        let sorted = MixerListing.alphabetical([app("b", name: "zoom it"), app("z", name: "Arc"), app("a", name: "arc")])
        #expect(sorted.map(\.id) == ["a", "z", "b"])
        let devices = MixerDevice.ordered([.init(uid: "2", name: "Studio", isDefault: false), .init(uid: "1", name: "Studio", isDefault: false),
                                           .init(uid: "0", name: "Zebra", isDefault: true), .init(uid: "3", name: "AirPods", isDefault: false)])
        #expect(devices.map(\.uid) == ["0", "3", "1", "2"])
    }

    @Test func duplicateRowsMergeTheirObjects() {
        let merged = MixerApp.merge([app("com.google.Chrome", objects: [5, 3]), app("com.apple.Music", objects: [7]),
                                     app("com.google.Chrome", objects: [3, 9], playing: true)])
        #expect(merged.map(\.id) == ["com.google.Chrome", "com.apple.Music"])
        #expect(merged[0].objects == [3, 5, 9])
        #expect(merged[0].isPlaying)
    }

    // MARK: - Identity and bypass
    @Test func identityRules() {
        let bundled = MixerIdentity(bundleID: "com.spotify.client", name: "Spotify", pid: 10)
        #expect(bundled.rowID == "com.spotify.client" && bundled.storageKey == "com.spotify.client")
        let bare = MixerIdentity(bundleID: nil, name: "ffplay", pid: 11)
        #expect(bare.rowID == "process:11" && bare.storageKey == "ffplay")
        let twin = MixerIdentity(bundleID: "  ", name: "ffplay", pid: 12)
        #expect(twin.rowID != bare.rowID && twin.storageKey == bare.storageKey)
        let anonymous = MixerIdentity(bundleID: "", name: " \n", pid: 13)
        #expect(anonymous.rowID == "process:13" && anonymous.storageKey == nil)
    }

    @Test func zoomAndProAudioHostsAreBypassedAndPlayersAreEligible() {
        for bundle in ["us.zoom.xos", "us.zoom.ZoomClips", "com.apple.logic10", "com.ableton.live", "com.steinberg.cubase13",
                       "com.presonus.studioone6", "com.apple.garageband10", "com.cockos.reaper", "com.bitwig.BitwigStudio"] {
            #expect(MixerBypass.isBypassed(bundleID: bundle, name: nil), "\(bundle)")
        }
        for name in ["zoom.us", "Zoom", "Zoom Workplace"] { #expect(MixerBypass.isBypassed(bundleID: nil, name: name)) }
        for bundle in ["com.apple.Music", "com.spotify.client", "com.google.Chrome", "company.thebrowser.Browser"] {
            #expect(!MixerBypass.isBypassed(bundleID: bundle, name: nil))
        }
        #expect(!MixerBypass.isBypassed(bundleID: nil, name: "Zoomify"))
        #expect(!MixerBypass.isBypassed(bundleID: "com.zoomify.app", name: "Zoomer"))
    }

    @Test func aResponsibleRegularAppIsBilledDirectly() {
        let tree = ProcessTree(responsible: [500: 100], parents: [500: 1], apps: [100])
        #expect(tree.owner(500) == 100)
    }

    @Test func aHelperAnsweringForItselfIsBilledToItsSpawningApp() {
        let tree = ProcessTree(responsible: [500: 500], parents: [500: 450, 450: 100, 100: 1], apps: [100])
        #expect(tree.owner(500) == 100)
    }

    @Test func daemonsEndingAtLaunchdStayUnlisted() {
        let tree = ProcessTree(responsible: [300: 300], parents: [300: 1], apps: [])
        #expect(tree.owner(300) == nil)
    }

    @Test func aFailedParentLookupStopsTheWalk() {
        let tree = ProcessTree(responsible: [500: 500], parents: [:], apps: [100])
        #expect(tree.owner(500) == nil)
    }

    @Test func theWalkStopsBeyondTheDepthCapButFindsAnAppWithinIt() {
        var chain: [Int32: Int32] = [:]
        for pid in Int32(10)..<Int32(20) { chain[pid] = pid + 1 }
        let within = ProcessTree(responsible: [10: 10], parents: chain, apps: [16])
        #expect(within.owner(10) == 16)
        let beyond = ProcessTree(responsible: [10: 10], parents: chain, apps: [17])
        #expect(beyond.owner(10) == nil)
    }

    @Test func aMissingResponsiblePidMapsToNothing() {
        let tree = ProcessTree(responsible: [:], parents: [500: 100], apps: [100])
        #expect(tree.owner(500) == nil)
    }

    @Test func aHelperWhoseResponsibilityIsADaemonFallsBackToItsParentApp() {
        let tree = ProcessTree(responsible: [500: 90], parents: [90: 1, 500: 100, 100: 1], apps: [100])
        #expect(tree.owner(500) == 100)
    }

    // MARK: - Build tokens, recovery, checks
    @Test func buildTokens() throws {
        var tokens = MixerBuildTokens()
        func begin(_ row: String) -> MixerBuildTokens.Token? { tokens.begin(row, now: 0) }
        func finish(_ token: MixerBuildTokens.Token) -> Bool { tokens.finish(token) }
        let first = try #require(begin("music"))
        #expect(begin("music") == nil)
        #expect(finish(first))
        let late = try #require(begin("music"))
        tokens.invalidateAll()
        let fresh = try #require(begin("music"))
        #expect(!finish(late))
        #expect(tokens.isBuilding("music"))
        #expect(finish(fresh))
        let a = try #require(begin("a")), b = try #require(begin("b"))
        tokens.invalidateAll()
        #expect(!finish(a))
        #expect(!finish(b))
    }

    @Test func aBuildPastItsDeadlineIsGivenUpAndItsLateResultRefused() throws {
        var tokens = MixerBuildTokens()
        func check(_ token: MixerBuildTokens.Token, at now: TimeInterval) -> MixerBuildTokens.Deadline { tokens.checkDeadline(token, now: now) }
        func finish(_ token: MixerBuildTokens.Token) -> Bool { tokens.finish(token) }
        let started = tokens.begin("music", now: 100)
        let hung = try #require(started)
        #expect(check(hung, at: 101) == .wait(MixerBuildTokens.deadline - 1))
        #expect(tokens.isBuilding("music"))
        #expect(check(hung, at: 100 + MixerBuildTokens.deadline) == .expired)
        #expect(!tokens.isBuilding("music"))
        #expect(check(hung, at: 200) == .settled)
        #expect(!finish(hung))
    }

    @Test func givingUpABuildNeverTouchesANewerOne() throws {
        var tokens = MixerBuildTokens()
        func begin(_ row: String, at now: TimeInterval) -> MixerBuildTokens.Token? { tokens.begin(row, now: now) }
        func check(_ token: MixerBuildTokens.Token, at now: TimeInterval) -> MixerBuildTokens.Deadline { tokens.checkDeadline(token, now: now) }
        func finish(_ token: MixerBuildTokens.Token) -> Bool { tokens.finish(token) }
        let hung = try #require(begin("music", at: 0))
        #expect(check(hung, at: 10) == .expired)
        let retry = try #require(begin("music", at: 20))
        #expect(!finish(hung))
        #expect(tokens.isBuilding("music"))
        #expect(check(hung, at: 30) == .settled)
        #expect(check(retry, at: 21) == .wait(MixerBuildTokens.deadline - 1))
        #expect(finish(retry))
    }

    @Test func aFinishedOrInvalidatedBuildHasNoDeadline() throws {
        var tokens = MixerBuildTokens()
        func begin(_ row: String) -> MixerBuildTokens.Token? { tokens.begin(row, now: 0) }
        func check(_ token: MixerBuildTokens.Token, at now: TimeInterval) -> MixerBuildTokens.Deadline { tokens.checkDeadline(token, now: now) }
        let done = try #require(begin("a"))
        _ = tokens.finish(done)
        #expect(check(done, at: 60) == .settled)
        let stale = try #require(begin("b"))
        tokens.invalidateAll()
        #expect(check(stale, at: 60) == .settled)
    }

    @Test func aBackwardsClockRestartsTheBuildDeadline() throws {
        var tokens = MixerBuildTokens()
        func check(_ token: MixerBuildTokens.Token, at now: TimeInterval) -> MixerBuildTokens.Deadline { tokens.checkDeadline(token, now: now) }
        let started = tokens.begin("music", now: 50)
        let build = try #require(started)
        #expect(check(build, at: 10) == .wait(MixerBuildTokens.deadline))
        #expect(check(build, at: 10 + MixerBuildTokens.deadline - 1) == .wait(1))
        #expect(check(build, at: 10 + MixerBuildTokens.deadline) == .expired)
    }

    @Test func aHungBuildIsNotRetriedUntilSomethingChanges() {
        var recovery = MixerRecovery()
        let path = MixerEngineConfiguration(objects: [7], device: speakers)
        recovery.recordHang("music", path)
        #expect(!recovery.mayBuild("music", path))
        #expect(recovery.mayBuild("music", MixerEngineConfiguration(objects: [7, 8], device: speakers)))
        #expect(recovery.mayBuild("music", MixerEngineConfiguration(objects: [7], device: headset)))
        #expect(recovery.mayBuild("podcasts", path))
        recovery.reset("music")
        #expect(recovery.mayBuild("music", path))
    }

    @Test func recoveryGivesOneReplacementThenFailsOpen() {
        var recovery = MixerRecovery()
        let path = MixerEngineConfiguration(objects: [4, 2], device: speakers)
        #expect(recovery.mayBuild("music", path))
        recovery.recordDeath("music", path)
        #expect(recovery.mayBuild("music", path))
        recovery.recordDeath("music", MixerEngineConfiguration(objects: [2, 4], device: speakers))
        #expect(!recovery.mayBuild("music", path))
        #expect(recovery.mayBuild("music", MixerEngineConfiguration(objects: [2, 4, 6], device: speakers)))
        recovery.reset("music")
        #expect(recovery.mayBuild("music", path))
    }

    @Test func renderVerdicts() {
        var check = MixerRenderCheck()
        func look(_ playing: Bool, _ count: UInt64, at now: TimeInterval) -> MixerRenderCheck.Verdict {
            check.evaluate("m", playing: playing, count: count, now: now)
        }
        #expect(look(false, 5, at: 0) == .idle)
        #expect(look(true, 5, at: 10) == .recheck(after: 1.5))
        #expect(look(true, 9, at: 11.5) == .recheck(after: 1.5))
        #expect(look(true, 9, at: 12) == .recheck(after: 1))
        #expect(look(true, 9, at: 13) == .wedged)
        #expect(look(true, 9, at: 20) == .recheck(after: 1.5))
        #expect(look(true, 9, at: 5) == .recheck(after: 1.5))
        #expect(look(true, 9, at: 6) == .recheck(after: 0.5))
        #expect(look(false, 9, at: 7) == .idle)
        #expect(look(true, 9, at: 7.1) == .recheck(after: 1.5))
    }

    @Test func aStreamFreezingAfterSuccessIsCaught() {
        var check = MixerRenderCheck()
        func look(_ count: UInt64, at now: TimeInterval) -> MixerRenderCheck.Verdict {
            check.evaluate("m", playing: true, count: count, now: now)
        }
        var count: UInt64 = 0
        var now = 0.0
        for _ in 0..<5 {
            count += 100
            #expect(look(count, at: now) == .recheck(after: 1.5))
            now += 1.5
        }
        #expect(look(count, at: now) == .wedged)
    }

    @Test func objectLossKeepsTheTapForOneWindow() {
        var grace = MixerObjectGrace()
        func decide(_ hasAudio: Bool, at now: TimeInterval) -> MixerObjectGrace.Decision {
            grace.decide("m", hasAudio: hasAudio, now: now)
        }
        #expect(decide(true, at: 0) == .proceed)
        #expect(decide(false, at: 1) == .wait(0.2))
        #expect(decide(true, at: 1.1) == .proceed)
        #expect(decide(false, at: 2) == .wait(0.2))
        #expect(decide(false, at: 2.2) == .release)
        #expect(decide(false, at: 3) == .wait(0.2))
        #expect(decide(false, at: 2.5) == .wait(0.2))
    }

    @Test func refreshSlot() throws {
        var slot = MixerRefreshSlot()
        func begin() -> UInt64? { slot.begin() }
        func finish(_ pass: UInt64) -> [Bool] { let result = slot.finish(pass); return [result.publish, result.runAgain] }
        let first = try #require(begin())
        #expect(begin() == nil)
        #expect(finish(first) == [true, true])
        let second = try #require(begin())
        #expect(finish(second) == [true, false])
        let changed = try #require(begin())
        slot.invalidate()
        #expect(slot.generation > changed)
        #expect(finish(changed) == [false, false])
        let old = try #require(begin())
        _ = begin()
        slot.discard()
        let fresh = try #require(begin())
        #expect(finish(old) == [false, false])
        #expect(slot.isReading)
        #expect(finish(fresh) == [true, false])
    }

    @Test func burstsFoldIntoOneTrailingRefresh() {
        var burst = MixerBurst()
        func request(_ now: TimeInterval) -> MixerBurst.Action { burst.request(now: now) }
        #expect(request(0) == .now)
        guard case .later(let wait) = request(0.05) else { Issue.record("expected a trailing refresh"); return }
        #expect(abs(wait - 0.15) < 1e-9)
        #expect(request(0.1) == MixerBurst.Action.none)
        burst.fired(now: 0.2)
        #expect(request(0.5) == .now)
        #expect(request(0.4) == .now)
    }

    @Test func alphabeticalUntilArranged() {
        #expect(MixerArrangement().order(named(["zed", "alpha", "music"])).map(\.id) == ["alpha", "music", "zed"])
    }

    @Test func movesPersistAcrossClosingAndReopening() {
        var arrangement = MixerArrangement()
        arrangement.move("c", beside: "a", after: false, visible: ["a", "b", "c"])
        let reopened = MixerArrangement.decode(arrangement.data)
        #expect(reopened.order(named(["a", "b", "c"])).map(\.id) == ["c", "a", "b"])
    }

    @Test func closedAndHiddenAppsKeepTheirSlots() {
        var arrangement = MixerArrangement(slots: ["c", "a", "b"])
        arrangement.move("a", beside: "c", after: false, visible: ["c", "a"])
        #expect(arrangement.slots == ["a", "c", "b"])
        #expect(arrangement.order(named(["a", "b", "c"])).map(\.id) == ["a", "c", "b"])
    }

    @Test func pinnedAppsLeadAndReorderIndependently() {
        var arrangement = MixerArrangement()
        let visible = ["a", "b", "c", "d"]
        arrangement.pin("c", visible: visible)
        arrangement.pin("d", visible: arrangement.order(named(visible)).map(\.id))
        #expect(arrangement.order(named(visible)).map(\.id) == ["c", "d", "a", "b"])
        arrangement.move("d", beside: "c", after: false, visible: ["c", "d", "a", "b"])
        #expect(arrangement.order(named(visible)).map(\.id) == ["d", "c", "a", "b"])
        #expect(!arrangement.canStep("c", forward: true, visible: ["d", "c", "a", "b"]))
        #expect(!arrangement.canStep("a", forward: false, visible: ["d", "c", "a", "b"]))
        #expect(arrangement.canStep("a", forward: true, visible: ["d", "c", "a", "b"]))
    }

    @Test func nothingCrossesThePinBoundaryAndDragsNeverPin() {
        var arrangement = MixerArrangement()
        arrangement.pin("c", visible: ["a", "b", "c"])
        let before = arrangement
        arrangement.move("a", beside: "c", after: false, visible: ["c", "a", "b"])
        #expect(arrangement == before)
        arrangement.move("b", beside: "a", after: false, visible: ["c", "a", "b"])
        #expect(arrangement.pinned == ["c"])
    }

    @Test func aVanishedRowAndSameRowTargetsChangeNothing() {
        var arrangement = MixerArrangement(slots: ["a", "b"])
        let before = arrangement
        arrangement.move("gone", beside: "a", after: false, visible: ["a", "b"])
        arrangement.move("a", beside: "gone", after: false, visible: ["a", "b"])
        arrangement.move("a", beside: "a", after: true, visible: ["a", "b"])
        #expect(arrangement == before)
    }

    @Test func unpinningAffectsOneApp() {
        var arrangement = MixerArrangement()
        arrangement.pin("a", visible: ["a", "b", "c"])
        arrangement.pin("b", visible: ["a", "b", "c"])
        arrangement.unpin("a")
        #expect(arrangement.pinned == ["b"])
        #expect(arrangement.order(named(["a", "b", "c"])).map(\.id) == ["b", "a", "c"])
    }

    @Test func newAppsFollowTheArrangedOrder() {
        var arrangement = MixerArrangement()
        arrangement.move("b", beside: "a", after: false, visible: ["a", "b"])
        #expect(arrangement.order(named(["a", "b", "aardvark", "zoo"])).map(\.id) == ["b", "a", "aardvark", "zoo"])
    }

    @Test func dragsInsertBelowTheLastAndAboveTheFirstAndKeepClosedSlots() {
        var arrangement = MixerArrangement(slots: ["a", "b", "c", "d", "e"])
        arrangement.move("a", beside: "e", after: true, visible: ["a", "c", "e"])
        #expect(arrangement.slots == ["b", "c", "d", "e", "a"])
        arrangement.move("e", beside: "b", after: false, visible: ["b", "c", "d", "e", "a"])
        #expect(arrangement.slots == ["e", "b", "c", "d", "a"])
    }

    @Test func invalidSavedArrangementsFallBackAndAreCleaned() {
        #expect(MixerArrangement.decode(nil) == MixerArrangement())
        #expect(MixerArrangement.decode("slots") == MixerArrangement())
        #expect(MixerArrangement.decode(["slots": ["a"]]) == MixerArrangement())
        #expect(MixerArrangement.decode(Data("garbage".utf8)) == MixerArrangement())
        let cleaned = MixerArrangement(slots: ["a", "", "a", " b ", "c"], pinned: ["b", "ghost", ""])
        #expect(cleaned.slots == ["a", "b", "c"])
        #expect(cleaned.pinned == ["b"])
        let json = Data(#"{"slots":["x","x"," ","y"],"pinned":["y","z"]}"#.utf8)
        #expect(MixerArrangement.decode(json) == MixerArrangement(slots: ["x", "y"], pinned: ["y"]))
    }

    @Test func moveLeftAndRightStepPastTheNeighbour() {
        var arrangement = MixerArrangement()
        arrangement.step("b", forward: false, visible: ["a", "b", "c"])
        #expect(arrangement.order(named(["a", "b", "c"])).map(\.id) == ["b", "a", "c"])
        arrangement.step("b", forward: true, visible: ["b", "a", "c"])
        #expect(arrangement.order(named(["a", "b", "c"])).map(\.id) == ["a", "b", "c"])
        let before = arrangement
        arrangement.step("c", forward: true, visible: ["a", "b", "c"])
        #expect(arrangement == before)
    }

    // MARK: - Limiter
    @Test func audioInsideTheCeilingPassesBitIdenticalAfterTheDelay() {
        let input = sine(2048, amplitude: 0.9)
        let output = limit([input, input.map { -$0 }])
        for frame in 0..<2048 {
            let expected: Float = frame < delay ? 0 : input[frame - delay]
            #expect(output[0][frame] == expected)
            #expect(output[1][frame] == -expected)
        }
    }

    @Test func boostedPeaksNeverLeaveTheCeiling() {
        let output = limit([sine(24_000, amplitude: 1.8), sine(24_000, amplitude: 1.95, phase: 1)], chunks: Array(repeating: 512, count: 60))
        #expect(output.allSatisfy { $0.allSatisfy { abs($0) <= ceiling } })
    }

    @Test func aSteadyLoudWaveformIsRiddenNotClipped() {
        let input = sine(16_384, amplitude: 1.5)
        let output = limit([input])[0]
        let tail = (8_000..<16_384)
        let peak = tail.map { abs(output[$0]) }.max() ?? 0
        #expect(peak <= ceiling && peak > 0.93)
        let ratios = tail.filter { abs(input[$0 - delay]) > 0.2 }.map { output[$0] / input[$0 - delay] }
        #expect((ratios.max()! - ratios.min()!) < 1e-4)
    }

    @Test func gainStaysDownAfterALoudStretchAndRecoversToUnityWhenQuiet() {
        let loud = sine(4_800, amplitude: 1.6)
        let quiet = sine(120_000, amplitude: 0.1)
        let input = loud + quiet
        let output = limit([input])[0]
        let justAfter = (4_800 + delay)..<(4_800 + delay + 200)
        let ratios = justAfter.filter { abs(input[$0 - delay]) > 0.05 }.map { output[$0] / input[$0 - delay] }
        #expect(!ratios.isEmpty && ratios.allSatisfy { $0 < 0.9 })
        #expect((input.count - 2_000..<input.count).allSatisfy { output[$0] == input[$0 - delay] })
    }

    @Test func bufferSplitsDoNotChangeTheResult() {
        var input = sine(9_000, amplitude: 1.7)
        for index in stride(from: 0, to: 9_000, by: 1_700) { input[index] = 1.99 }
        let whole = limit([input])
        let split = limit([input], chunks: [1, 255, 256, 257, 1_000, 3, 4_096])
        #expect(whole == split)
    }

    @Test func oneGainPerFrameAcrossChannels() {
        let left = sine(8_192, amplitude: 1.6), right = sine(8_192, amplitude: 0.3, phase: 0.7)
        let output = limit([left, right])
        for frame in 2_000..<8_192 where abs(left[frame - delay]) > 0.1 && abs(right[frame - delay]) > 0.1 {
            let gainLeft = output[0][frame] / left[frame - delay], gainRight = output[1][frame] / right[frame - delay]
            #expect(abs(gainLeft - gainRight) < 1e-5)
        }
    }

    @Test func everySampleStaysInRangeWithRandomLoudAudio() {
        var seed: UInt32 = 12_345
        func next() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed) / Float(UInt32.max) * 4 - 2 }
        let noise = (0..<3).map { _ in (0..<20_000).map { _ in next() } }
        let output = limit(noise, chunks: Array(repeating: 333, count: 70))
        #expect(output.allSatisfy { $0.allSatisfy { abs($0) <= ceiling } })
    }

    @Test func overlappingFuturePeaksAreBothAttenuated() {
        var input = Array(repeating: Float(0.5), count: 4_000)
        input[1_000] = 1.2
        input[1_100] = 1.9
        input[1_150] = -1.5
        let output = limit([input])[0]
        for frame in [1_000, 1_100, 1_150] { #expect(abs(output[frame + delay]) <= ceiling) }
    }

    @Test func nonInterleavedStereoIsLinked() {
        var limiter = MixerLimiter(capacity: 2)
        defer { limiter.deallocate() }
        let buffers = TestBuffers([1, 1], frames: 4_096)
        let left = sine(4_096, amplitude: 1.7), right = sine(4_096, amplitude: 0.4, phase: 2)
        buffers.fill { $0 == 0 ? left[$1] : right[$1] }
        limiter.process(buffers.list, frames: 4_096, releaseCoefficient: MixerLimiter.releaseCoefficient(sampleRate: 48_000))
        for frame in 1_000..<4_096 where abs(left[frame - delay]) > 0.1 && abs(right[frame - delay]) > 0.1 {
            #expect(abs(buffers[0, frame] / left[frame - delay] - buffers[1, frame] / right[frame - delay]) < 1e-5)
        }
    }

    @Test func oneLatencyAcrossNineBuffersAndThirtyThreeChannels() {
        let shape = [1, 2, 3, 4, 5, 6, 4, 4, 4]
        var limiter = MixerLimiter(capacity: 33)
        defer { limiter.deallocate() }
        let buffers = TestBuffers(shape, frames: 1_024)
        #expect(buffers.totalChannels == 33)
        buffers.fill { _, frame in frame == 10 ? 0.5 : 0 }
        limiter.process(buffers.list, frames: 1_024, releaseCoefficient: MixerLimiter.releaseCoefficient(sampleRate: 48_000))
        for channel in 0..<33 {
            #expect(buffers[channel, 10 + delay] == 0.5)
            #expect(buffers.channel(channel).filter { $0 != 0 }.count == 1)
        }
    }

    @Test func aShapeChangeReusesStorageAndStartsAFreshDelayLine() {
        var limiter = MixerLimiter(capacity: 4)
        defer { limiter.deallocate() }
        let address = limiter.storageAddress
        let coefficient = MixerLimiter.releaseCoefficient(sampleRate: 48_000)
        let stereo = TestBuffers([2], frames: 512, fill: 0.3)
        limiter.process(stereo.list, frames: 512, releaseCoefficient: coefficient)
        let mono = TestBuffers([1], frames: 512, fill: 0.2)
        limiter.process(mono.list, frames: 512, releaseCoefficient: coefficient)
        #expect(limiter.storageAddress == address)
        #expect(mono.channel(0).prefix(delay).allSatisfy { $0 == 0 })
        #expect(mono.channel(0).suffix(512 - delay).allSatisfy { $0 == 0.2 })
    }

    @Test func beyondCapacityItLimitsInPlaceSafely() {
        let output = limit([sine(4_096, amplitude: 1.9), sine(4_096, amplitude: 1.9, phase: 1), sine(4_096, amplitude: 0.2), sine(4_096, amplitude: 1.2)],
                           capacity: 2)
        #expect(output.allSatisfy { $0.allSatisfy { abs($0) <= ceiling } })
        #expect(output[2][1] != 0)
    }

    @Test func anUnreadableRateLimitsAt48kHz() {
        let reference = MixerLimiter.releaseCoefficient(sampleRate: 48_000)
        for rate in [nil, 0, -1, Double.nan, Double.infinity] as [Double?] {
            #expect(MixerLimiter.releaseCoefficient(sampleRate: rate) == reference)
        }
    }

    @Test func recoveryTakesTheSameTimeAtAnyRate() {
        let at44 = recoverySeconds(rate: 44_100, coefficientRate: 44_100)
        let at96 = recoverySeconds(rate: 96_000, coefficientRate: 96_000)
        #expect(abs(at44 - at96) / at44 < 0.01)
    }

    @Test func keepingAnOldRatesCoefficientDragsRecoveryOut() {
        let correct = recoverySeconds(rate: 16_000, coefficientRate: 16_000)
        let stale = recoverySeconds(rate: 16_000, coefficientRate: 96_000)
        #expect(stale > correct * 5)
    }

    @Test func renderFrameArithmetic() {
        #expect(MixerRenderer.frames(bytes: 4_096, channels: 2) == 512)
        #expect(MixerRenderer.frames(bytes: 2_048, channels: 1) == 512)
        #expect(MixerRenderer.frames(bytes: 4_096, channels: 0) == 0)
    }

    @Test func theTapIsTheLastBufferWithItsChannelCount() {
        let renderer = MixerRenderer(tapChannels: 2, outputCapacity: 2, sampleRate: 48_000, gain: 1)
        let input = TestBuffers([2, 2], frames: 512)
        input.fill { channel, _ in channel < 2 ? 0.9 : 0.25 }
        let output = TestBuffers([2], frames: 512, fill: 0.7)
        render(renderer, input: input, output: output)
        #expect(output[0, 400] == 0.25 && output[1, 400] == 0.25)
        #expect(output[0, 10] == 0)
        #expect(renderer.cycles == 1)
    }

    @Test func aLoneInputBufferIsAcceptedAndNoMatchGivesSilence() {
        let renderer = MixerRenderer(tapChannels: 2, outputCapacity: 2, sampleRate: 48_000, gain: 1)
        let lone = TestBuffers([1], frames: 512, fill: 0.4)
        let output = TestBuffers([2], frames: 512, fill: 0.7)
        render(renderer, input: lone, output: output)
        #expect(output[0, 300] == 0.4 && output[1, 300] == 0.4)
        let mismatch = TestBuffers([1, 4], frames: 512, fill: 0.4)
        let silent = TestBuffers([2], frames: 512, fill: 0.7)
        render(renderer, input: mismatch, output: silent)
        #expect(silent.channel(0).allSatisfy { $0 == 0 } && silent.channel(1).allSatisfy { $0 == 0 })
        #expect(renderer.cycles == 1)
    }

    @Test func channelMapping() {
        let stereoTap = TestBuffers([2], frames: 512)
        stereoTap.fill { channel, _ in channel == 0 ? 0.2 : 0.4 }
        let renderer = MixerRenderer(tapChannels: 2, outputCapacity: 8, sampleRate: 48_000, gain: 0.5)

        let mono = TestBuffers([1], frames: 512)
        render(renderer, input: stereoTap, output: mono)
        #expect(abs(mono[0, 400] - 0.15) < 1e-6)

        let wide = MixerRenderer(tapChannels: 2, outputCapacity: 8, sampleRate: 48_000, gain: 1)
        let six = TestBuffers([6], frames: 512, fill: 0.7)
        render(wide, input: stereoTap, output: six)
        #expect(six[0, 400] == 0.2 && six[1, 400] == 0.4)
        #expect((2..<6).allSatisfy { six.channel($0).allSatisfy { $0 == 0 } })

        let split = MixerRenderer(tapChannels: 2, outputCapacity: 2, sampleRate: 48_000, gain: 1)
        let planar = TestBuffers([1, 1], frames: 512)
        render(split, input: stereoTap, output: planar)
        #expect(planar[0, 400] == 0.2 && planar[1, 400] == 0.4)

        let monoTap = TestBuffers([1], frames: 512, fill: 0.25)
        let fromMono = MixerRenderer(tapChannels: 1, outputCapacity: 4, sampleRate: 48_000, gain: 1)
        let four = TestBuffers([4], frames: 512, fill: 0.7)
        render(fromMono, input: monoTap, output: four)
        #expect(four[0, 400] == 0.25 && four[1, 400] == 0.25 && four[2, 400] == 0 && four[3, 400] == 0)
    }

    @Test func unwrittenFramesAreSilenced() {
        let renderer = MixerRenderer(tapChannels: 2, outputCapacity: 2, sampleRate: 48_000, gain: 1)
        let tap = TestBuffers([2], frames: 256, fill: 0.3)
        let output = TestBuffers([2], frames: 512, fill: 0.7)
        render(renderer, input: tap, output: output)
        #expect(output.channel(0).suffix(256).allSatisfy { $0 == 0 })
        #expect(output.channel(1).allSatisfy { $0 == 0 })
    }

    @Test func aCycleCountsOnlyWhenTheDeviceReceivedAudio() {
        let renderer = MixerRenderer(tapChannels: 2, outputCapacity: 2, sampleRate: 48_000, gain: 1)
        let empty = TestBuffers([2], frames: 0)
        render(renderer, input: empty, output: TestBuffers([2], frames: 512, fill: 0.7))
        #expect(renderer.cycles == 0)
        let monoTap = MixerRenderer(tapChannels: 1, outputCapacity: 4, sampleRate: 48_000, gain: 1)
        let tap = TestBuffers([1], frames: 512, fill: 0.2)
        render(monoTap, input: tap, output: TestBuffers([0, 0], frames: 512))
        #expect(monoTap.cycles == 0)
        render(monoTap, input: tap, output: TestBuffers([2], frames: 512))
        #expect(monoTap.cycles == 1)
    }

    @Test func gainIsClampedAndNonFiniteGainIsIgnored() {
        let renderer = MixerRenderer(tapChannels: 2, outputCapacity: 2, sampleRate: nil, gain: 0.5)
        renderer.gain = .nan
        #expect(renderer.gain == 0.5)
        renderer.gain = 3
        #expect(renderer.gain == 2)
        renderer.gain = -1
        #expect(renderer.gain == 0)
    }
}
