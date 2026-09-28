import CoreGraphics
import Foundation
import Testing
@testable import IslandKit

// MARK: - Protocol

private let revision = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"

private func line(_ json: String) -> Data { Data(json.utf8) }

@Test func commandsAreOneBoundedLineWithTheirContext() throws {
    let data = try #require(MusicWire.encode(.transport(id: 4, action: .next, pid: 812, revision: revision)))
    #expect(data.last == 0x0A)
    let object = try #require(try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
    #expect(object["cmd"] as? String == "next")
    #expect(object["pid"] as? Int == 812)
    #expect(object["revision"] as? String == revision.lowercased())
}

@Test func invalidIdentifiersAndPositionsNeverReachTheAdapter() {
    #expect(MusicWire.encode(.transport(id: 1, action: .toggle, pid: 0, revision: revision)) == nil)
    #expect(MusicWire.encode(.transport(id: 1, action: .toggle, pid: 5, revision: "not-a-uuid")) == nil)
    #expect(MusicWire.encode(.seek(id: 1, pid: 5, revision: revision, position: .nan)) == nil)
    #expect(MusicWire.encode(.seek(id: 1, pid: 5, revision: revision, position: 700_000)) == nil)
    #expect(MusicWire.encode(.target(sequence: 1, follow: MusicSourceKey(pid: 5, bundleID: "a\u{0}b"), extra: [])) == nil)
    #expect(MusicWire.encode(.target(sequence: 1, follow: MusicSourceKey(pid: 5, bundleID: String(repeating: "x", count: 3000)), extra: [])) == nil)
    #expect(MusicWire.encode(.target(sequence: 1, follow: nil, extra: [])) != nil)
}

@Test func playbackRepliesAreSanitisedAndClamped() throws {
    let reply = MusicWire.decode(line("""
    {"type":"playback","seq":2,"pid":812,"bundle":"com.spotify.client","title":"  Song\\nName\\u0007 ","artist":"Band",
     "album":"Record","duration":1e9,"elapsed":-4,"rate":40,"revision":"\(revision)","direct":true,"canNext":false}
    """))
    guard case .playback(let playback)? = reply else { Issue.record("no playback"); return }
    #expect(playback.title == "SongName")
    #expect(playback.duration == MusicWire.maxPosition)
    #expect(playback.elapsed == 0)
    #expect(playback.rate == 16)
    #expect(playback.isPlaying)
    #expect(playback.revision == revision.lowercased())
    #expect(playback.capabilities.canSkipNext == false)
    #expect(playback.capabilities.canSkipPrevious == nil)
}

@Test func aBooleanPidOrAMissingRevisionCannotBindControls() {
    #expect(MusicWire.decode(line(#"{"type":"playback","seq":1,"pid":true,"bundle":"a","title":"t","revision":"\#(revision)"}"#)) == nil)
    #expect(MusicWire.decode(line(#"{"type":"playback","seq":1,"pid":-3,"bundle":"a","title":"t","revision":"\#(revision)"}"#)) == nil)
    #expect(MusicWire.decode(line(#"{"type":"playback","seq":1,"pid":3,"bundle":"a","title":"t"}"#)) == nil)
    #expect(MusicWire.decode(line(#"{"type":"playback","seq":1,"pid":3,"bundle":"a","title":"  ","revision":"\#(revision)"}"#))
            == .empty(sequence: 1))
}

@Test func artworkArrivesAsBytesUnchangedOrMissing() {
    let bytes = Data([1, 2, 3])
    func artwork(_ extra: String) -> MusicArtworkPayload? {
        guard case .playback(let playback)? = MusicWire.decode(line(
            #"{"type":"playback","seq":1,"pid":3,"bundle":"a","title":"t","revision":"\#(revision)"\#(extra)}"#)) else { return nil }
        return playback.artwork
    }
    #expect(artwork(#","artwork":"\#(bytes.base64EncodedString())""#) == .bytes(bytes))
    #expect(artwork(#","artworkUnchanged":true"#) == .unchanged)
    #expect(artwork("") == .missing)
}

@Test func sourceListsAreOrderedAndRejectDuplicatesOrOversize() {
    let ok = MusicWire.decode(line("""
    {"type":"sources","current":9,"sources":[{"pid":9,"bundle":"b","music":true,"playing":true,"track":true},
     {"pid":3,"bundle":"a","display":"com.google.Chrome","name":"Chrome","track":false}]}
    """))
    guard case .sources(let discovery)? = ok else { Issue.record("no sources"); return }
    #expect(discovery.sources.map(\.pid) == [3, 9])
    #expect(discovery.sources[0].displayBundleID == "com.google.Chrome")
    #expect(discovery.current == 9)
    let duplicate = MusicWire.decode(line(#"{"type":"sources","sources":[{"pid":3,"bundle":"a"},{"pid":3,"bundle":"b"}]}"#))
    #expect(duplicate == .sources(MusicDiscovery(current: nil, sources: [])))
    let many = (1...17).map { #"{"pid":\#($0),"bundle":"b\#($0)"}"# }.joined(separator: ",")
    #expect(MusicWire.decode(line(#"{"type":"sources","sources":[\#(many)]}"#)) == .sources(MusicDiscovery(current: nil, sources: [])))
}

@Test func framingSurvivesArbitraryByteBoundaries() {
    var framer = MusicLineFramer(limit: 64)
    let text = Data("héllo\nworld\n".utf8)
    var lines: [Data] = []
    for byte in text { lines += framer.append(Data([byte])) }
    #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["héllo", "world"])
    #expect(framer.append(Data("a\nb\nc".utf8)).count == 2)
    #expect(framer.append(Data("\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["c"])
}

@Test func anOversizeFrameCannotSwallowTheNextCommand() {
    var framer = MusicLineFramer(limit: 8)
    let lines = framer.append(Data("0123456789abcdef\nclose\n".utf8))
    #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["close"])
    // A long unterminated frame is dropped, and framing resumes after its newline.
    #expect(framer.append(Data(repeating: 0x41, count: 100)).isEmpty)
    #expect(framer.append(Data("tail\nnext\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["next"])
}

// MARK: - Selection

private func source(_ pid: Int32, _ bundle: String, music: Bool, playing: Bool, track: Bool = true) -> MusicSource {
    MusicSource(pid: pid, bundleID: bundle, isMusicApp: music, isPlaying: playing, hasTrack: track)
}

private let spotify = source(100, "com.spotify.client", music: true, playing: true)
private let pausedSpotify = source(100, "com.spotify.client", music: true, playing: false)
private let music = source(200, "com.apple.Music", music: true, playing: true)
private let pausedMusic = source(200, "com.apple.Music", music: true, playing: false)
private let video = source(300, "com.google.Chrome", music: false, playing: true)
private let pausedVideo = source(300, "com.google.Chrome", music: false, playing: false)
private func alive(_ key: MusicSourceKey) -> Bool { true }

/// Holds a selection across passes so each pass reads as one expression.
private final class Chooser {
    var selection = MusicSelection()
    func run(_ sources: [MusicSource], current: Int32? = nil, others: Bool = false, now: Double = 0,
             alive: (MusicSourceKey) -> Bool = alive) -> MusicSelectionResult {
        selection.resolve(MusicDiscovery(current: current, sources: sources), includeOthers: others, now: now, alive: alive)
    }
    @discardableResult func choose(_ key: MusicSourceKey?) -> Bool { selection.choose(key) }
}

@Test func automaticKeepsPausedMusicRatherThanTheActiveVideo() {
    let selection = Chooser()
    #expect(selection.run([pausedSpotify, video], current: 300).follow == pausedSpotify.key)
    let optedIn = Chooser()
    #expect(optedIn.run([pausedSpotify, video], current: 300, others: true).follow == video.key)
}

@Test func musicOnlyModeIgnoresVideosEvenWhenTheyOwnTheSession() {
    let selection = Chooser()
    #expect(selection.run([video], current: 300).follow == nil)
    #expect(selection.run([video], current: 300, others: true).follow == video.key)
}

@Test func playingMusicOutranksAPlayingBrowserAndPausedMusic() {
    let selection = Chooser()
    #expect(selection.run([pausedMusic, spotify, video], current: 300, others: true).follow == spotify.key)
}

@Test func newlyPlayingMusicOutranksAnotherAppsPausedTrack() {
    let selection = Chooser()
    #expect(selection.run([pausedSpotify, pausedMusic], current: 100).follow == pausedSpotify.key)
    #expect(selection.run([pausedSpotify, music], current: 100).follow == music.key)
}

@Test func twoPlayingMusicAppsKeepThePreviouslyControlledOneAndTheSystemBreaksTheFirstTie() {
    let selection = Chooser()
    #expect(selection.run([spotify, music], current: 200).follow == music.key)
    #expect(selection.run([spotify, music], current: 100).follow == music.key)
    let fresh = Chooser()
    #expect(fresh.run([spotify, music]).follow == spotify.key)
}

@Test func anUnrelatedPlayingVideoNeverBecomesAFallback() {
    let selection = Chooser()
    // Playing, not the system's session and never followed: not taken even with other apps on.
    #expect(selection.run([video], current: 999, others: true).follow == nil)
}

@Test func anExplicitBrowserChoiceOverridesMusicAndClosingItRestoresAutomatic() {
    let selection = Chooser()
    #expect(selection.choose(video.key))
    #expect(selection.run([spotify, video]).follow == video.key)
    // Pausing the chosen browser keeps its resume control.
    #expect(selection.run([spotify, pausedVideo]).follow == video.key)
    // Closing it restores Automatic.
    let result = selection.run([spotify], alive: { $0 != video.key })
    #expect(result.follow == spotify.key)
    #expect(selection.selection.chosen == nil)
}

@Test func choosingWhatIsAlreadyInEffectChangesNothing() {
    let selection = Chooser()
    #expect(!selection.choose(nil))
    #expect(selection.choose(spotify.key))
    #expect(!selection.choose(spotify.key))
    #expect(selection.choose(nil))
}

@Test func aChosenSourceWithoutATrackBridgesForFiveSeconds() {
    let selection = Chooser()
    selection.choose(video.key)
    let trackless = source(300, "com.google.Chrome", music: false, playing: false, track: false)
    let waiting = selection.run([spotify, trackless], now: 10)
    #expect(waiting.follow == spotify.key)
    #expect(waiting.isBridging)
    #expect(waiting.chosenPID == 300)
    #expect(waiting.listed.map(\.pid) == [100, 300])
    #expect(waiting.nextDeadline == 15)
    // The next track brings it back; seeing a track restarts the wait.
    #expect(selection.run([spotify, video], now: 12).follow == video.key)
    #expect(selection.run([spotify, trackless], now: 13).nextDeadline == 18)
    // Still nothing after five seconds releases the choice.
    let released = selection.run([spotify, trackless], now: 18)
    #expect(released.chosenPID == nil)
    #expect(released.listed.map(\.pid) == [100])
    #expect(selection.selection.chosen == nil)
}

@Test func aChosenSourceThatTimesOutKeepsTheChoiceWithoutStaleControls() {
    let selection = Chooser()
    selection.choose(video.key)
    let result = selection.run([spotify])
    #expect(result.follow == nil)
    #expect(result.chosenPID == 300)
    #expect(selection.selection.extraCandidates.contains(video.key))
    // Recovery restores it.
    #expect(selection.run([spotify, video]).follow == video.key)
}

@Test func aReusedPidCannotKeepAnotherAppsSelection() {
    let selection = Chooser()
    selection.choose(video.key)
    let impostor = source(300, "com.example.Other", music: false, playing: true)
    #expect(selection.run([impostor]).chosenPID == nil)
    #expect(selection.selection.chosen == nil)
}

@Test func onlySourcesWithATrackAreListed() {
    let selection = Chooser()
    let silent = source(400, "com.example.Silent", music: true, playing: false, track: false)
    #expect(selection.run([silent, spotify]).listed.map(\.pid) == [100])
}

@Test func spotifyHelpersAndMusicCategoryAppsCountAsMusic() {
    #expect(MusicAppCategory.isMusicApp(bundleID: "com.spotify.client.helper", parentBundleID: "com.spotify.client", category: nil))
    #expect(MusicAppCategory.isMusicApp(bundleID: "com.example.Tunes", parentBundleID: nil, category: "public.app-category.music"))
    #expect(!MusicAppCategory.isMusicApp(bundleID: "com.google.Chrome", parentBundleID: nil, category: "public.app-category.productivity"))
}

// MARK: - When the reader runs

@Test func theReaderRunsOnlyForSomethingVisibleOrAnEnabledActivity() {
    var demand = MusicReaderDemand()
    demand.islandRunning = true
    demand.sectionShown = true
    #expect(!demand.shouldRun)
    demand.restingMusic = true
    #expect(demand.shouldRun)
    demand.hiddenUntilHover = true
    #expect(!demand.shouldRun)
    demand.musicPageVisible = true
    #expect(demand.shouldRun)
    demand.musicPageVisible = false
    demand.playbackCardVisible = true
    #expect(demand.shouldRun)
    demand.sectionShown = false
    #expect(!demand.shouldRun)
}

@Test func nothingAtRestStopsTheReaderUnlessNewTrackNeedsIt() {
    var settings = IslandSettings()
    settings.enabled = true
    settings.atRest = .nothing
    let off = MusicActivityGate.demand(settings, sectionShown: true, newTrackAvailable: true)
    #expect(!off.resting)
    #expect(off.notices)
    settings.setIndicator(.newTrack, false)
    #expect(!MusicActivityGate.demand(settings, sectionShown: true, newTrackAvailable: true).notices)
}

@Test func compactMusicNeedsTheSectionAtRestAndShowWhilePlaying() {
    var settings = IslandSettings()
    #expect(settings.atRest == .music)
    #expect(!MusicActivityGate.allowsCompactMusic(settings, sectionShown: true))
    settings.enabled = true
    #expect(MusicActivityGate.allowsCompactMusic(settings, sectionShown: true))
    #expect(!MusicActivityGate.allowsCompactMusic(settings, sectionShown: false))
    settings.atRest = .battery
    #expect(MusicActivityGate.allowsCompactMusic(settings, sectionShown: true))
    settings.showPlayingMusic = false
    #expect(!MusicActivityGate.allowsCompactMusic(settings, sectionShown: true))
}

@Test func persistentAdapterFailureStopsAfterTwoRetries() {
    var budget = MusicRestartBudget()
    let r1 = budget.exited(afterRunning: 0.2)
    #expect(r1 == 1)
    let r2 = budget.exited(afterRunning: 0.2)
    #expect(r2 == 2)
    let r3 = budget.exited(afterRunning: 0.2)
    #expect(r3 == nil)
    let r4 = budget.exited(afterRunning: 0.2)
    #expect(r4 == nil)
    // An adapter that ran over a minute earns a fresh budget, and quick exits after that still stop.
    let r5 = budget.exited(afterRunning: 61)
    #expect(r5 == 1)
    let r6 = budget.exited(afterRunning: 1)
    #expect(r6 == 2)
    let r7 = budget.exited(afterRunning: 1)
    #expect(r7 == nil)
}

// MARK: - Timeline, transport and scrubbing

@Test func timesReadAsMinutesThenHours() {
    #expect(MusicTime.format(0) == "0:00")
    #expect(MusicTime.format(75.9) == "1:15")
    #expect(MusicTime.format(3599) == "59:59")
    #expect(MusicTime.format(3725) == "1:02:05")
    #expect(MusicTime.format(.nan) == "0:00")
}

@Test func thePositionAdvancesOnlyWhilePlayingAndStaysInsideTheRecording() {
    #expect(MusicTime.position(elapsed: 10, readAt: 100, now: 103, playing: true, rate: 1, duration: 200) == 13)
    #expect(MusicTime.position(elapsed: 10, readAt: 100, now: 103, playing: false, rate: 1, duration: 200) == 10)
    #expect(MusicTime.position(elapsed: 198, readAt: 100, now: 110, playing: true, rate: 2, duration: 200) == 200)
    #expect(MusicTime.position(elapsed: 10, readAt: 100, now: 102, playing: true, rate: 0.5, duration: nil) == 11)
}

@Test func radioPlayersGetDiscretePlayAndPauseAndOthersKeepToggle() {
    let radio = MusicCapabilities(canPlay: true, canPause: true)
    #expect(MusicPlayPause.action(rate: 1, capabilities: radio) == .pause)
    #expect(MusicPlayPause.action(rate: 0, capabilities: radio) == .play)
    #expect(MusicPlayPause.action(rate: 1, capabilities: MusicCapabilities(canPlay: true, canPause: false)) == .toggle)
    #expect(MusicPlayPause.action(rate: 0, capabilities: MusicCapabilities()) == .toggle)
}

@Test func aReleasedScrubHoldsUntilPlaybackCatchesUpOrOneSecondPasses() {
    var scrub = MusicScrub(revision: "a", value: 30)
    scrub.move(to: 60)
    #expect(scrub.holds(position: 12, readAt: 5, revision: "a", now: 10))
    scrub.release(at: 10)
    scrub.move(to: 90)
    #expect(scrub.value == 60)
    // An old reading far away keeps the thumb; one that lands near it after the release lets go.
    #expect(scrub.holds(position: 12, readAt: 5, revision: "a", now: 10.5))
    #expect(!scrub.holds(position: 61, readAt: 10.3, revision: "a", now: 10.4))
    #expect(!scrub.holds(position: 12, readAt: 5, revision: "a", now: 11))
    // A different recording cancels a scrub at once.
    #expect(!MusicScrub(revision: "a", value: 1).holds(position: nil, readAt: nil, revision: "b", now: 0))
}

// MARK: - New track and covers

@Test func theReadersFirstSongOnlyRecords() {
    var detector = MusicTrackChangeDetector()
    let r8 = detector.observe(player: "spotify", title: "One", artist: "A", playing: true)
    #expect(!r8)
    let r9 = detector.observe(player: "spotify", title: "One", artist: "A", playing: false)
    #expect(!r9)
    let r10 = detector.observe(player: "spotify", title: "One", artist: "", playing: true)
    #expect(!r10)
    let r11 = detector.observe(player: "spotify", title: "Two", artist: "A", playing: true)
    #expect(r11)
    let r12 = detector.observe(player: "spotify", title: "", artist: "A", playing: true)
    #expect(!r12)
}

@Test func theNextSongCountsOnceItPlaysEvenIfFirstReportedPaused() {
    var detector = MusicTrackChangeDetector()
    _ = detector.observe(player: "p", title: "One", artist: "A", playing: true)
    let r13 = detector.observe(player: "p", title: "Two", artist: "A", playing: false)
    #expect(!r13)
    let r14 = detector.observe(player: "p", title: "Two", artist: "A", playing: true)
    #expect(r14)
}

@Test func anotherPlayerInBetweenIsANewSongForNeither() {
    var detector = MusicTrackChangeDetector()
    _ = detector.observe(player: "spotify", title: "One", artist: "A", playing: true)
    let r15 = detector.observe(player: "chrome", title: "Clip", artist: "", playing: true)
    #expect(!r15)
    let r16 = detector.observe(player: "spotify", title: "One", artist: "A", playing: true)
    #expect(!r16)
    detector.reset()
    let r17 = detector.observe(player: "spotify", title: "Three", artist: "A", playing: true)
    #expect(!r17)
}

private let player = MusicSourceKey(pid: 1, bundleID: "p")

@Test func anUnchangedCoverOnANewSongDecodesToThePreviousCover() {
    var tracker = MusicArtworkTracker<String>()
    tracker.receive(.cover("red"), player: player, recording: "r1", now: 0)
    tracker.receive(.unchanged, player: player, recording: "r2", now: 1)
    #expect(tracker.shown == "red")
    tracker.expire(now: 2.6)
    #expect(tracker.shown == "red")
    #expect(tracker.deadline == nil)
}

@Test func aNewSongWithoutArtworkCannotKeepThePreviousCover() {
    var tracker = MusicArtworkTracker<String>()
    tracker.receive(.cover("red"), player: player, recording: "r1", now: 0)
    tracker.receive(.missing, player: player, recording: "r2", now: 1)
    #expect(tracker.shown == "red")
    // Repeated missing replies never move the deadline.
    tracker.receive(.missing, player: player, recording: "r2", now: 2)
    #expect(tracker.deadline == 2.5)
    tracker.expire(now: 2.5)
    #expect(tracker.shown == nil)
}

@Test func aRepeatedCoverFollowedByMissingArtworkIsNotAdopted() {
    var tracker = MusicArtworkTracker<String>()
    tracker.receive(.cover("red"), player: player, recording: "r1", now: 0)
    tracker.receive(.cover("red"), player: player, recording: "r2", now: 1)
    tracker.receive(.missing, player: player, recording: "r2", now: 1.2)
    tracker.expire(now: 2.5)
    #expect(tracker.shown == nil)
}

@Test func songsSharingACoverKeepItThroughMetadataOnlyReplies() {
    var tracker = MusicArtworkTracker<String>()
    tracker.receive(.cover("red"), player: player, recording: "r1", now: 0)
    tracker.receive(.missing, player: player, recording: "r1", now: 5)
    #expect(tracker.shown == "red")
    tracker.receive(.cover("blue"), player: player, recording: "r2", now: 6)
    #expect(tracker.shown == "blue")
    #expect(tracker.deadline == nil)
    // A different player starts clean.
    tracker.receive(.missing, player: MusicSourceKey(pid: 2, bundleID: "q"), recording: "r3", now: 7)
    #expect(tracker.shown == nil)
}

@Test func greyCoversGetNoTintAndColourfulOnesGlowEqually() {
    #expect(MusicTint.from(red: 0.5, green: 0.5, blue: 0.5) == nil)
    #expect(MusicTint.from(red: 0.02, green: 0.01, blue: 0.0) == nil)
    let tint = MusicTint.from(red: 0.2, green: 0.1, blue: 0.1)
    #expect(tint.map { abs($0.red - 0.92) < 1e-9 && abs($0.green - 0.06) < 1e-9 } == true)
}

// MARK: - Lyrics

@Test func lrcAcceptsDecimalsRepeatedTagsAndAnOffset() throws {
    let text = """
    [ar:Someone]
    [offset:500]
    [00:01.5][00:10.25]Chorus
    [00:05]Verse
    [1:00.123]Late
    """
    let lines = try #require(LyricsParser.parse(text))
    #expect(lines.map(\.time) == [1.0, 4.5, 9.75, 59.623])
    #expect(lines.map(\.text) == ["Chorus", "Verse", "Chorus", "Late"])
}

@Test func invalidTagsAreRejectedAndANegativeOffsetDelays() throws {
    let lines = try #require(LyricsParser.parse("[offset:-1000]\n[00:60]No\n[0a:01]No\n[-1:00]No\n[00:02]Yes"))
    #expect(lines == [LyricLine(time: 3, text: "Yes")])
    #expect(LyricsParser.parse("just words") == nil)
    #expect(!LyricsParser.hasTiming("just words\n[ar:x]"))
    #expect(LyricsParser.hasTiming("[00:01]x"))
}

@Test func simultaneousVoicesShareALineAndBlankLinesEndAVerse() throws {
    let lines = try #require(LyricsParser.parse("[00:03]Two\n[00:01]One\n[00:03]Also\n[00:05]\n", duration: 4))
    #expect(lines == [LyricLine(time: 1, text: "One"), LyricLine(time: 3, text: "Two\nAlso")])
    let gap = try #require(LyricsParser.parse("[00:01]One\n[00:02]"))
    #expect(gap.last == LyricLine(time: 2, text: ""))
}

@Test func strictByteEntryAndExpansionLimits() {
    #expect(LyricsParser.parse(String(repeating: "x", count: LyricsParser.maxBytes + 1)) == nil)
    let entries = (0..<2001).map { "[00:\(String(format: "%02d", $0 % 60))]a" }.joined(separator: "\n")
    #expect(LyricsParser.parse(entries) == nil)
    // Many tags on one long line cannot amplify a small file.
    let tags = String(repeating: "[00:01]", count: 200)
    #expect(LyricsParser.parse(tags + String(repeating: "y", count: 1000)) == nil)
}

@Test func lyricsWaitForTheFirstTimestampAndSwitchExactlyAtBoundaries() {
    let lines = [LyricLine(time: 2, text: "a"), LyricLine(time: 5, text: "b")]
    #expect(LyricsTimeline.index(lines, position: 1.99, offset: 0) == nil)
    #expect(LyricsTimeline.index(lines, position: 2, offset: 0) == 0)
    #expect(LyricsTimeline.index(lines, position: 5, offset: 0) == 1)
    // A positive adjustment delays, a negative one advances; an invalid one never highlights.
    #expect(LyricsTimeline.index(lines, position: 5, offset: 0.5) == 0)
    #expect(LyricsTimeline.index(lines, position: 4.5, offset: -0.5) == 1)
    #expect(LyricsTimeline.index(lines, position: 5, offset: .nan) == nil)
}

@Test func theScheduleRedrawsOnlyAtReachableFutureVerses() {
    let lines = [LyricLine(time: 2, text: "a"), LyricLine(time: 5, text: "b"), LyricLine(time: 9, text: "c")]
    let now = Date(timeIntervalSinceReferenceDate: 1000)
    let dates = LyricsTimeline.schedule(lines, position: 3, playing: true, rate: 2, offset: 0.5, duration: 8, now: now)
    // b at 5.5 is reachable (1.25 s at double speed); c at 9.5 is past the duration.
    #expect(dates.count == 2)
    #expect(abs(dates[0].timeIntervalSince(now) - 1.25) < 0.01)
    #expect(dates[0].timeIntervalSince(now) > 1.25)
    #expect(dates.last == .distantFuture)
    // At the scheduled moment the new verse is lit despite rounding.
    let position = 3 + dates[0].timeIntervalSince(now) * 2
    #expect(LyricsTimeline.index(lines, position: position, offset: 0.5) == 1)
    #expect(LyricsTimeline.schedule(lines, position: 3, playing: false, rate: 1, offset: 0, duration: 8, now: now).isEmpty)
    #expect(LyricsTimeline.schedule(lines, position: nil, playing: true, rate: 1, offset: 0, duration: 8, now: now).isEmpty)
    #expect(LyricsTimeline.schedule(lines, position: 3, playing: true, rate: 0, offset: 0, duration: 8, now: now).isEmpty)
    #expect(LyricsTimeline.schedule(lines, position: 3, playing: true, rate: 1, offset: 11, duration: 8, now: now).isEmpty)
}

@Test func timingStepsAreQuarterSecondsWithinTenSeconds() {
    #expect(LyricsTimeline.adjust(0, by: 0.25) == 0.25)
    #expect(LyricsTimeline.adjust(0.1, by: -0.25) == -0.25)
    #expect(LyricsTimeline.adjust(9.9, by: 0.25) == 10)
    #expect(LyricsTimeline.adjust(-10, by: -0.25) == -10)
}

@Test func lookupsNeedAFullRecordingAndStripSingleAndEPSuffixesOnly() throws {
    #expect(LyricsQuery(title: "T", artist: "", album: "A", duration: 200) == nil)
    #expect(LyricsQuery(title: "T", artist: "B", album: "A", duration: 4000) == nil)
    #expect(LyricsQuery(title: "T", artist: "B", album: "A", duration: nil) == nil)
    #expect(LyricsQuery.normalizedAlbum("Summer - single") == "Summer")
    #expect(LyricsQuery.normalizedAlbum("Summer - EP") == "Summer")
    #expect(LyricsQuery.normalizedAlbum("Summer - Remastered") == "Summer - Remastered")
    let query = try #require(LyricsQuery(title: "Song & Co", artist: "Band", album: "Summer - Single", duration: 200.4))
    let items = URLComponents(url: query.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.url.host == "lrclib.net")
    #expect(items.first { $0.name == "track_name" }?.value == "Song & Co")
    #expect(items.first { $0.name == "album_name" }?.value == "Summer")
    #expect(items.first { $0.name == "duration" }?.value == "200")
}

@Test func onlyTheExactRecordingIsAccepted() throws {
    let query = try #require(LyricsQuery(title: "Song", artist: "Band", album: "Summer - Single", duration: 200))
    let exact = LyricsResponse(trackName: "song", artistName: "BAND", albumName: "Summer", duration: 201.5,
                               syncedLyrics: "[00:01]Hi")
    #expect(query.content(of: exact) == .synced([LyricLine(time: 1, text: "Hi")]))
    #expect(query.content(of: LyricsResponse(trackName: "Song", artistName: "Band", albumName: "Summer", duration: 203)) == nil)
    #expect(query.content(of: LyricsResponse(trackName: "Song", artistName: "Band", albumName: "Live", duration: 200)) == nil)
    let instrumental = LyricsResponse(trackName: "Song", artistName: "Band", albumName: "Summer", duration: 200,
                                      instrumental: true, plainLyrics: "stray")
    #expect(query.content(of: instrumental) == .instrumental)
}

// MARK: - Compact strip and bars

@Test func musicWingsAreThirtyFourBesideAThirtyTwoPointNotch() {
    let geometry = MusicStripGeometry(stripHeight: 32, isPhysical: true)
    #expect(geometry.coverSide == 22)
    #expect(abs(geometry.coverRadius - 5.88) < 0.01)
    #expect(abs(geometry.coverInset - 11.08) < 0.01)
    #expect(abs(geometry.barsInset - 11.49) < 0.01)
    #expect(abs(geometry.barsWidth - 21.78) < 0.01)
    #expect(geometry.barsHeight == 16)
    #expect(geometry.wing == 34)
    #expect(MusicStripGeometry(stripHeight: 24, isPhysical: false).wing == 56)
}

@Test func everyStripElementClearsTheCurveByTheGap() {
    for height in stride(from: CGFloat(24), through: 64, by: 2) {
        let geometry = MusicStripGeometry(stripHeight: height, isPhysical: true)
        let shoulder = min(14, 0.19 * height)
        #expect(geometry.coverInset >= shoulder + 5 - 1e-9)
        #expect(geometry.barsInset >= shoulder + 5 - 1e-9)
        // The cover's lower corner stays at least the gap inside the strip's corner arc.
        let corner = min(28, 0.34 * height)
        let r = geometry.coverRadius
        let dx = (shoulder + corner) - (geometry.coverInset + r)
        let dy = ((height + geometry.coverSide) / 2 - r) - (height - corner)
        if dx > 0, dy > 0 { #expect((dx * dx + dy * dy).squareRoot() + r <= corner - 5 + 1e-6) }
    }
}

@Test func barsAreSymmetricWithTallerCentresAndRoundedDots() {
    let bars = (0..<7).map { MusicBars.bar($0, count: 7, barWidth: 1.8, height: 16) }
    #expect(bars[3].high > bars[0].high)
    #expect(abs(bars[1].high - bars[5].high) < 1e-9)
    #expect(bars.allSatisfy { $0.low >= 1.8 && $0.high <= 16 && $0.low <= $0.high })
    #expect(abs(bars[1].x - bars[0].x - 3.33) < 1e-9)
    #expect(abs(bars[0].duration - Double.pi / 5.2) < 1e-9)
    #expect(abs(bars[2].timeOffset - 0.34) < 1e-9)
    #expect(MusicBars.height(level: 0, barWidth: 1.8, height: 16) == 1.8)
    #expect(MusicBars.band(forBar: 0, bars: 3, bands: 7) == 1)
    #expect(MusicBars.band(forBar: 2, bars: 3, bands: 7) == 5)
}

@Test func lrclibAnswersDecodeWithTheirExtraFieldsAndPunctuationFailsClosed() throws {
    // The shape lrclib.net returns (checked 28 Sep 2026), including fields the island ignores.
    let body = Data("""
    {"id":1,"name":"Midnight City","trackName":"Midnight City","artistName":"M83.","albumName":"Hurry Up, We're Dreaming.",
     "duration":244.0,"instrumental":false,"hasWordSync":false,"plainLyrics":"Waiting in a car",
     "syncedLyrics":"[00:37.66]Waiting in a car","lyricsfile":"version: '1.0'"}
    """.utf8)
    let response = try JSONDecoder().decode(LyricsResponse.self, from: body)
    let exact = try #require(LyricsQuery(title: "Midnight City", artist: "M83.", album: "Hurry Up, We're Dreaming.", duration: 243.7))
    #expect(exact.content(of: response) == .synced([LyricLine(time: 37.66, text: "Waiting in a car")]))
    let unpunctuated = try #require(LyricsQuery(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming", duration: 244))
    #expect(unpunctuated.content(of: response) == nil)
}

@Test func targetsCarryAtMostFourExtraPlayers() throws {
    let extra = (1...6).map { MusicSourceKey(pid: Int32($0), bundleID: "b\($0)") }
    let data = try #require(MusicWire.encode(.target(sequence: 3, follow: extra[0], extra: extra)))
    let object = try #require(try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
    #expect((object["extra"] as? [Any])?.count == 4)
    #expect((object["follow"] as? [String: Any])?["bundle"] as? String == "b1")
}
