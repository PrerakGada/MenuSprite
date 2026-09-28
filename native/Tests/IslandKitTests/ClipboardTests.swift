import Foundation
import Testing
@testable import IslandKit

// Clipboard history rules (spec-sections-tools §2.4, §2.7, §2.9; spec-activity §4.8), restated.

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

private func image(_ hash: String, bytes: Int = 1_000) -> ClipboardImage {
    ClipboardImage(file: "\(hash).png", sha256: hash, width: 640, height: 480, bytes: bytes)
}

private func history(_ texts: [String]) -> ClipboardHistory {
    var history = ClipboardHistory()
    for (index, text) in texts.reversed().enumerated() {
        history.record(.text(text, at: at(Double(index))), limit: .unlimited)
    }
    return history
}

private func texts(_ entries: [ClipboardEntry]) -> [String] { entries.map(\.text) }

private func admit(_ gate: inout ClipboardCaptureGate, _ seconds: Double) -> ClipboardCaptureGate.Ticket? {
    gate.admit(now: at(seconds))
}

private func complete(_ gate: inout ClipboardCaptureGate, _ ticket: ClipboardCaptureGate.Ticket, _ count: Int,
                      _ seconds: Double) -> ClipboardCaptureGate.Outcome {
    gate.complete(ticket, count: count, now: at(seconds))
}

// MARK: Island keyboard

@Test func quickKeysMapPhysicalDigitsWithCommandAlone() {
    let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    for (index, code) in codes.enumerated() {
        #expect(ClipboardQuickKeys.index(keyCode: code, commandOnly: true) == index)
        #expect(ClipboardQuickKeys.index(keyCode: code, commandOnly: false) == nil)
    }
    #expect(ClipboardQuickKeys.index(keyCode: 29, commandOnly: true) == nil) // 0
    #expect(ClipboardQuickKeys.index(keyCode: 0, commandOnly: true) == nil)
}

@Test func typedSearchHighlightsTopResultAndEmptySearchWaits() {
    let ids = [UUID(), UUID(), UUID()]
    var highlight = ClipboardHighlight()
    highlight.restart(results: ids, hasQuery: true)
    #expect(highlight.id == ids[0])
    highlight.restart(results: ids, hasQuery: false)
    #expect(highlight.id == nil)
}

@Test func arrowsStartAtTopStopAtEndsAndRecover() {
    let ids = [UUID(), UUID(), UUID()]
    var highlight = ClipboardHighlight()
    highlight.move(down: true, results: ids)
    #expect(highlight.id == ids[0])
    highlight.move(down: false, results: ids)
    #expect(highlight.id == ids[0])
    highlight.move(down: true, results: ids)
    highlight.move(down: true, results: ids)
    highlight.move(down: true, results: ids)
    #expect(highlight.id == ids[2])
    // The highlighted row is filtered out: the next arrow lands on the top result again.
    highlight.move(down: true, results: [ids[0], ids[1]])
    #expect(highlight.id == ids[0])
    // A row that disappears hands the highlight on only while there is a query.
    var queried = ClipboardHighlight(id: ids[2])
    queried.reconcile(results: [ids[1]], hasQuery: true)
    #expect(queried.id == ids[1])
    var plain = ClipboardHighlight(id: ids[2])
    plain.reconcile(results: [ids[1]], hasQuery: false)
    #expect(plain.id == nil)
}

// MARK: Routing and the indicator

@Test func clipboardOpeningDefaultsToTheEnabledIsland() {
    var settings = IslandSettings()
    settings.enabled = true
    #expect(settings.clipboardInIsland)
    #expect(ClipboardRouting.route(settings) == .island)
    #expect(ClipboardRouting.shortcut(settings, islandAccepts: true, pageShowing: false) == .openPage)
    #expect(ClipboardRouting.shortcut(settings, islandAccepts: true, pageShowing: true) == .closeIsland)
}

@Test func separateWindowAndHiddenSectionKeepTheHistoryReachable() {
    var settings = IslandSettings()
    settings.enabled = true
    settings.clipboardInIsland = false
    #expect(ClipboardRouting.shortcut(settings, islandAccepts: true, pageShowing: false) == .toggleWindow)
    settings.clipboardInIsland = true
    settings.setVisible(.clipboard, false)
    #expect(ClipboardRouting.route(settings) == .window)
    settings.setVisible(.clipboard, true)
    #expect(ClipboardRouting.shortcut(settings, islandAccepts: false, pageShowing: false) == .toggleWindow)
    settings.enabled = false
    #expect(ClipboardRouting.route(settings) == .window)
}

@Test func indicatorNeedsHistoryReadingAndAVisibleSection() {
    #expect(ClipboardIndicatorBlocker.check(historyOn: false, readingAllowed: true, sectionVisible: true) == .historyOff)
    #expect(ClipboardIndicatorBlocker.check(historyOn: true, readingAllowed: false, sectionVisible: true) == .pasteboardAccess)
    #expect(ClipboardIndicatorBlocker.check(historyOn: true, readingAllowed: true, sectionVisible: false) == .sectionHidden)
    #expect(ClipboardIndicatorBlocker.check(historyOn: true, readingAllowed: true, sectionVisible: true) == nil)
}

@Test func aCopyNeverInterruptsAVolumeNotice() {
    #expect(!IslandNoticeKind.clipboard.replaces(.volume))
    #expect(IslandNoticeKind.clipboard.replaces(.clipboard))
    #expect(IslandNoticeKind.clipboard.duration == 2.5)
    #expect(IslandNoticeKind.clipboard.section == .clipboard)
}

// MARK: Change count and admission

@Test func changeCountTable() {
    let table: [(Int, Int, Int, Int?)] = [
        (101, 100, 100, 101), (100, 100, 100, nil), (2, 178, 178, 2), (3, 2, 2, 3),
        (0, 178, 178, 0), (101, 100, 102, nil), (103, 100, 102, 103),
    ]
    for (read, queued, latest, expected) in table {
        #expect(ClipboardChangeCount.adopt(read: read, queued: queued, latest: latest) == expected)
    }
}

@Test func firstReadAfterStartOnlyTakesABaseline() {
    var gate = ClipboardCaptureGate()
    let stopped = gate.admit(now: at(0))
    #expect(stopped == nil)
    gate.start()
    let first = try! #require(admit(&gate, 0))
    #expect(first.known == nil)
    #expect(!ClipboardCaptureGate.shouldRead(count: 40, ticket: first))
    #expect(complete(&gate, first, 40, 0.1) == .baseline)
    let second = try! #require(admit(&gate, 1))
    #expect(!ClipboardCaptureGate.shouldRead(count: 40, ticket: second))
    #expect(complete(&gate, second, 40, 1.1) == .unchanged)
    let third = try! #require(admit(&gate, 2))
    #expect(ClipboardCaptureGate.shouldRead(count: 41, ticket: third))
    #expect(complete(&gate, third, 41, 2.1) == .new)
    #expect(gate.latest == 41)
}

@Test func oneReadInFlightAndAnExpiredReadKeepsTheSlot() {
    var gate = ClipboardCaptureGate()
    gate.start()
    let baseline = try! #require(admit(&gate, 0))
    _ = complete(&gate, baseline, 10, 0)
    let slow = try! #require(admit(&gate, 1))
    // Ticks while the slow read is out are skipped, past its deadline too.
    #expect(admit(&gate, 2) == nil)
    #expect(admit(&gate, 9) == nil)
    #expect(complete(&gate, slow, 11, 7) == .stale)
    #expect(gate.latest == 10)
    #expect(admit(&gate, 8) != nil)
}

@Test func stopAndStartCannotQueueASecondRead() {
    var gate = ClipboardCaptureGate()
    gate.start()
    let baseline = try! #require(admit(&gate, 0))
    _ = complete(&gate, baseline, 10, 0)
    let pending = try! #require(admit(&gate, 1))
    gate.stop()
    gate.start()
    #expect(admit(&gate, 1.5) == nil)
    // The old read returns into a new start: dropped, and the next read takes a fresh baseline.
    #expect(complete(&gate, pending, 12, 1.6) == .stale)
    let fresh = try! #require(admit(&gate, 2))
    #expect(fresh.known == nil)
}

@Test func ownWritesAreNeverRecorded() {
    var gate = ClipboardCaptureGate()
    gate.start()
    let baseline = try! #require(admit(&gate, 0))
    _ = complete(&gate, baseline, 10, 0)
    let queued = try! #require(admit(&gate, 1))
    gate.noteOwnWrite(count: 11)
    #expect(complete(&gate, queued, 11, 1.1) == .unchanged)
    let next = try! #require(admit(&gate, 2))
    #expect(complete(&gate, next, 11, 2.1) == .unchanged)
}

// MARK: Dedup, groups, limit and budgets

@Test func recopyMovesToTopOfItsGroupKeepingIdAndPin() {
    var history = history(["c", "b", "a"])
    let a = history.entries.first { $0.text == "a" }!.id
    let result = history.record(.text("a", at: at(10)), limit: .count(50))
    #expect(result == .moved(a))
    #expect(texts(history.entries) == ["a", "c", "b"])
    #expect(history.entries[0].id == a)
    let pinnedA = history.pin(a, at: at(11))
    #expect(pinnedA)
    history.record(.text("b", at: at(12)), limit: .count(50))
    #expect(texts(history.entries) == ["a", "b", "c"])
    history.record(.text("a", at: at(13)), limit: .count(50))
    #expect(history.entries[0].id == a)
    #expect(history.entries[0].isPinned)
    #expect(history.entries[0].lastUsed == at(13))
}

@Test func dedupRulesPerKindAndKindsNeverCross() {
    var history = ClipboardHistory()
    history.record(.text("report.pdf", at: at(0)), limit: .unlimited)
    history.record(.files(["/tmp/report.pdf"], at: at(1)), limit: .unlimited)
    history.record(.files(["/tmp/a", "/tmp/b"], at: at(2)), limit: .unlimited)
    history.record(.files(["/tmp/b", "/tmp/a"], at: at(3)), limit: .unlimited)
    history.record(.files(["/tmp/a", "/tmp/b"], at: at(4)), limit: .unlimited)
    history.record(.image(image("aa"), at: at(5)), limit: .unlimited)
    var sameImage = ClipboardEntry.image(image("aa"), at: at(6))
    sameImage.image?.file = "other.png"
    history.record(sameImage, limit: .unlimited)
    #expect(history.entries.count == 5)
    #expect(history.entries[0].kind == .image)
    #expect(history.entries[0].image?.file == "aa.png")
    #expect(history.entries[1].files == ["/tmp/a", "/tmp/b"])
}

@Test func limitCountsOnlyUnpinnedEntries() {
    var history = history(["e", "d", "c", "b", "a"])
    let a = history.entries.first { $0.text == "a" }!.id
    let pinnedA = history.pin(a, at: at(20))
    #expect(pinnedA)
    let removed = history.trim(limit: .count(2))
    #expect(texts(history.entries) == ["a", "e", "d"])
    #expect(Set(texts(removed)) == ["c", "b"])
}

@Test func limitValuesAreExactlyTheListAndUnknownFallsBackTo50() {
    #expect(ClipboardLimit.storedChoices == [20, 50, 100, 250, 500, 1000, 10_000, 0])
    #expect(ClipboardLimit(stored: 250) == .count(250))
    #expect(ClipboardLimit(stored: 0) == .unlimited)
    #expect(ClipboardLimit(stored: 7) == .count(50))
    #expect(ClipboardLimit(stored: -1) == .standard)
}

@Test func textBudgetIsMeasuredAsEscapedJSON() {
    #expect(ClipboardEntry.escapedBytes("abc") == 3)
    #expect(ClipboardEntry.escapedBytes("\"\\\n") == 6)
    #expect(ClipboardEntry.escapedBytes("\u{01}") == 6)
    #expect(ClipboardEntry.escapedBytes("a/b") == 3)
    #expect(ClipboardEntry.escapedBytes("é") == 2)
}

@Test func budgetsKeepPinnedFirstThenNewestAndRefuseAPinThatWouldNotFit() {
    let small = ClipboardHistory.Budgets(text: 2_000, assets: 2_500)
    let big = String(repeating: "x", count: 600)
    var history = ClipboardHistory()
    for index in 0..<4 { history.record(.text(big + "\(index)", at: at(Double(index))), limit: .unlimited, budgets: small) }
    // Each entry costs 921 bytes: only the two newest fit.
    #expect(texts(history.entries) == [big + "3", big + "2"])
    let older = history.entries[1].id
    let pinnedOlder = history.pin(older, at: at(10), budgets: small)
    #expect(pinnedOlder)
    history.record(.text(big + "4", at: at(11)), limit: .unlimited, budgets: small)
    #expect(texts(history.entries) == [big + "2", big + "4"])
    let second = history.entries[1].id
    let pinnedSecond = history.pin(second, at: at(12), budgets: small)
    #expect(pinnedSecond)
    // Nothing more fits beside the two pins: a new copy is not kept, and pins are never trimmed.
    let fifth = history.record(.text(big + "5", at: at(13)), limit: .unlimited, budgets: small)
    #expect(fifth == .dropped)
    #expect(history.pinnedCount == 2)
    // A pin that would not fit (a history saved under larger budgets) is refused.
    var loaded = ClipboardHistory(entries: history.entries + [.text(big + "6", at: at(14))])
    let third = loaded.entries[2].id
    let refused = loaded.pin(third, at: at(15), budgets: small)
    #expect(!refused)
    #expect(!loaded.entries[2].isPinned)
    // Images share their own budget.
    var images = ClipboardHistory()
    images.record(.image(image("1", bytes: 1_000), at: at(0)), limit: .unlimited, budgets: small)
    images.record(.image(image("2", bytes: 1_000), at: at(1)), limit: .unlimited, budgets: small)
    images.record(.image(image("3", bytes: 1_000), at: at(2)), limit: .unlimited, budgets: small)
    #expect(images.entries.map { $0.image!.sha256 } == ["3", "2"])
}

@Test func pinningMovingAndClearing() {
    var history = history(["d", "c", "b", "a"])
    let ids = Dictionary(uniqueKeysWithValues: history.entries.map { ($0.text, $0.id) })
    history.pin(ids["c"]!, at: at(10))
    history.pin(ids["a"]!, at: at(11))
    #expect(texts(history.entries) == ["a", "c", "d", "b"])
    // Moves stay inside their group.
    #expect(!history.canMove(ids["a"]!, up: true))
    #expect(history.canMove(ids["a"]!, up: false))
    #expect(!history.canMove(ids["c"]!, up: false))
    #expect(!history.canMove(ids["d"]!, up: true))
    history.move(ids["d"]!, up: false)
    #expect(texts(history.entries) == ["a", "c", "b", "d"])
    // Unpinning rejoins the recent group by when it was last used: "a" is the oldest copy.
    history.unpin(ids["a"]!)
    #expect(texts(history.entries) == ["c", "b", "d", "a"])
    history.clearRecent()
    #expect(texts(history.entries) == ["c"])
    history.clearAll()
    #expect(history.entries.isEmpty)
}

@Test func aHistoryFileWithPinsOutOfPlaceIsRepaired() {
    var pinned = ClipboardEntry.text("pinned", at: at(0))
    pinned.pinnedAt = at(1)
    let history = ClipboardHistory(entries: [.text("recent", at: at(2)), pinned])
    #expect(texts(history.entries) == ["pinned", "recent"])
}

// MARK: Search

@Test func searchFoldsCaseDiacriticsWidthAndWhitespace() {
    let history = history(["Café Crème\tbrûlée", "ｆｕｌｌ width", "line one\nline two", "unrelated"])
    let index = ClipboardSearchIndex(entries: history.entries)
    #expect(texts(index.results("cafe creme", pinnedOnly: false)) == ["Café Crème\tbrûlée"])
    #expect(texts(index.results("FULL", pinnedOnly: false)) == ["ｆｕｌｌ width"])
    #expect(texts(index.results("one line", pinnedOnly: false)) == ["line one\nline two"])
    #expect(index.results("cafe missing", pinnedOnly: false).isEmpty)
    #expect(index.results("  ", pinnedOnly: false).count == 4)
}

@Test func searchScoresEqualPrefixContainsAndWords() {
    #expect(ClipboardSearchIndex.score("git", pinned: false, query: "git", tokens: ["git"]) == 1200 + 140)
    #expect(ClipboardSearchIndex.score("git status", pinned: false, query: "git", tokens: ["git"]) == 900 + 140)
    #expect(ClipboardSearchIndex.score("run git", pinned: true, query: "git", tokens: ["git"]) == 30 + 700 + 140)
    #expect(ClipboardSearchIndex.score("github", pinned: false, query: "git", tokens: ["git"]) == 900 + 80)
    #expect(ClipboardSearchIndex.score("digit", pinned: false, query: "git", tokens: ["git"]) == 700 + 40)
    #expect(ClipboardSearchIndex.score("nothing", pinned: false, query: "git", tokens: ["git"]) == nil)
    let history = history(["digit", "github", "git"])
    let order = texts(ClipboardSearchIndex(entries: history.entries).results("git", pinnedOnly: false))
    #expect(order == ["git", "github", "digit"])
}

@Test func imagesAndFilesAreSearchableAndPinnedFilterApplies() {
    var history = ClipboardHistory()
    history.record(.image(image("aa"), at: at(0)), limit: .unlimited)
    history.record(.files(["/Users/example/Budget 2026.xlsx"], at: at(1)), limit: .unlimited)
    history.record(.text("note", at: at(2)), limit: .unlimited)
    let index = ClipboardSearchIndex(entries: history.entries)
    #expect(index.results("image", pinnedOnly: false).first?.kind == .image)
    #expect(index.results("640x480", pinnedOnly: false).first?.kind == .image)
    #expect(index.results("png", pinnedOnly: false).first?.kind == .image)
    #expect(index.results("budget", pinnedOnly: false).first?.kind == .files)
    #expect(index.results("", pinnedOnly: true).isEmpty)
}

// MARK: Privacy

@Test func sensitiveTextIsSkipped() {
    #expect(ClipboardPrivacy.looksSensitive("my password is hunter2"))
    #expect(ClipboardPrivacy.looksSensitive("Authorization: Bearer abc"))
    #expect(ClipboardPrivacy.looksSensitive("sk-ant-api03-Abc123XYZ_def456"))
    #expect(!ClipboardPrivacy.looksSensitive("just a normal sentence to keep"))
    #expect(!ClipboardPrivacy.looksSensitive("short-1a"))
    // UUIDs are kept in either case and in braces; near-UUIDs are not.
    #expect(!ClipboardPrivacy.looksSensitive("123e4567-e89b-12d3-a456-426614174000"))
    #expect(!ClipboardPrivacy.looksSensitive("123E4567-E89B-12D3-A456-426614174000"))
    #expect(!ClipboardPrivacy.looksSensitive("{123e4567-e89b-12d3-a456-426614174000}"))
    #expect(ClipboardPrivacy.looksSensitive("123e4567-e89b-12d3-a456-42661417400"))
    #expect(ClipboardPrivacy.looksSensitive("123e4567-e89b-12d3-a456_426614174000"))
    // Web addresses are kept unless they carry a credential.
    #expect(!ClipboardPrivacy.looksSensitive("https://example.com/path/to/page?id=42"))
    #expect(ClipboardPrivacy.looksSensitive("https://example.com/reset?token=abc123"))
}

@Test func concealedTransientAndAutoGeneratedMarkersAreDetected() {
    #expect(ClipboardPrivacy.skips(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
    #expect(ClipboardPrivacy.skips(types: ["org.nspasteboard.TransientType"]))
    #expect(ClipboardPrivacy.skips(types: ["org.nspasteboard.AutoGeneratedType"]))
    #expect(!ClipboardPrivacy.skips(types: ["public.utf8-plain-text", "public.rtf"]))
}

@Test func appsToSkipDropAChangeWhenAnyWasFrontSinceTheLastRead() {
    let ignored: Set<String> = ["com.1password.1password"]
    #expect(ClipboardPrivacy.skips(frontmost: ["com.apple.Safari", "com.1password.1password"], ignored: ignored))
    #expect(!ClipboardPrivacy.skips(frontmost: ["com.apple.Safari"], ignored: ignored))
    #expect(!ClipboardPrivacy.skips(frontmost: ["com.apple.Safari"], ignored: []))
}

@Test func copiedTextIsKeptAsCopiedAndWebAddressesAreRestored() {
    #expect(ClipboardText.normalize("  \n ", webURL: nil) == nil)
    #expect(ClipboardText.normalize("    indented code\n", webURL: nil) == "    indented code\n")
    #expect(ClipboardText.normalize("https://example.com/a b", webURL: nil) == "https://example.com/a b")
    #expect(ClipboardText.normalize("https://example.com/path", webURL: nil) == "https://example.com/path")
    #expect(ClipboardText.normalize("example.com/path", webURL: "https://example.com/path") == "https://example.com/path")
    #expect(ClipboardText.normalize("//example.com/path", webURL: "https://example.com/path") == "https://example.com/path")
    #expect(ClipboardText.normalize("Example", webURL: "https://example.com/path") == "Example")
    #expect(ClipboardText.normalize(String(repeating: "a", count: 1_000_001), webURL: nil) == nil)
}

@Test func colourValuesGetASwatch() {
    #expect(ClipboardColor.parse("#fff") == ClipboardColor(red: 1, green: 1, blue: 1))
    #expect(ClipboardColor.parse(" #FF000080 ")?.alpha == Double(0x80) / 255)
    #expect(ClipboardColor.parse("rgb(0, 128, 255)") == ClipboardColor(red: 0, green: 128 / 255, blue: 1))
    #expect(ClipboardColor.parse("rgba(0,0,0,0.5)")?.alpha == 0.5)
    #expect(ClipboardColor.parse("#ggg") == nil)
    #expect(ClipboardColor.parse("the colour #fff") == nil)
    #expect(ClipboardColor.parse("rgb(300,0,0)") == nil)
}

// MARK: Paste and write back

@Test func activationPastesOnlyWithAccessibilityAndALiveTarget() {
    #expect(ClipboardActivation.decide(trusted: true, target: .running) == .paste)
    #expect(ClipboardActivation.decide(trusted: false, target: .running) == .copyNeedsAccessibility)
    #expect(ClipboardActivation.decide(trusted: true, target: .terminated) == .copyTargetGone)
    #expect(ClipboardActivation.decide(trusted: true, target: .none) == .copy)
    #expect(ClipboardActivation.decide(trusted: false, target: .none) == .copy)
}

// The paste handoff: ⌘V only once the target is really in front.

private let targetPID: Int32 = 500
private let ownPID: Int32 = 100
private let otherPID: Int32 = 700

private func seen(_ frontmost: Int32?, ownKey: Bool = false, gone: Bool = false, trusted: Bool = true) -> ClipboardPasteHandoff.Observation {
    ClipboardPasteHandoff.Observation(frontmost: frontmost, ownWindowHasKeyboard: ownKey, targetTerminated: gone, trusted: trusted)
}

/// Runs a handoff over timed observations and returns every step it took.
private func run(_ timeline: [(Double, ClipboardPasteHandoff.Observation)]) -> [ClipboardPasteHandoff.Step] {
    var handoff = ClipboardPasteHandoff(target: targetPID, own: ownPID, started: t0)
    return timeline.map { handoff.check($0.1, now: at($0.0)) }
}

@Test func pastesOnceTheTargetHasSettledInFrontAndOnlyOnce() {
    let steps = run([(0, seen(targetPID)), (0.04, seen(targetPID)), (0.1, seen(targetPID)), (0.2, seen(targetPID)), (0.5, seen(targetPID))])
    #expect(steps == [.wait, .wait, .post, .done, .done])
}

@Test func slowActivationWaitsForTheTarget() {
    let steps = run([(0, seen(otherPID)), (0.3, seen(otherPID)), (0.6, seen(targetPID)), (0.7, seen(targetPID))])
    #expect(steps == [.wait, .wait, .wait, .post])
}

@Test func aTargetThatNeverComesForwardGetsNoKeystroke() {
    let steps = run([(0, seen(otherPID)), (0.5, seen(nil)), (0.99, seen(otherPID)), (1.0, seen(otherPID)), (1.2, seen(targetPID))])
    #expect(steps == [.wait, .wait, .wait, .giveUp(.targetNotFront), .done])
    #expect(!steps.contains(.post))
}

@Test func focusMovingAwayRestartsTheSettle() {
    let steps = run([(0, seen(targetPID)), (0.05, seen(otherPID)), (0.1, seen(targetPID)), (0.15, seen(targetPID)), (0.2, seen(targetPID))])
    #expect(steps == [.wait, .wait, .wait, .wait, .post])
}

@Test func neverPostsWhileMenuSpriteIsFrontOrHoldsTheKeyboard() {
    // MenuSprite itself in front: never ready.
    let own = run([(0, seen(ownPID)), (0.5, seen(ownPID)), (1.0, seen(ownPID))])
    #expect(own == [.wait, .wait, .giveUp(.targetNotFront)])
    // The target is in front but the island (a non-activating panel) still has the keyboard.
    let keyed = run([(0, seen(targetPID, ownKey: true)), (0.2, seen(targetPID, ownKey: true)), (0.3, seen(targetPID)), (0.4, seen(targetPID))])
    #expect(keyed == [.wait, .wait, .wait, .post])
    // A target that is MenuSprite never pastes.
    var selfTarget = ClipboardPasteHandoff(target: ownPID, own: ownPID, started: t0)
    #expect(selfTarget.check(seen(ownPID), now: at(0.5)) == .wait)
    #expect(selfTarget.check(seen(ownPID), now: at(1.0)) == .giveUp(.targetNotFront))
}

@Test func theHandoffIsBoundedEvenWhenTheTargetArrivesLate() {
    let steps = run([(0, seen(otherPID)), (0.97, seen(targetPID)), (1.0, seen(targetPID))])
    #expect(steps == [.wait, .wait, .giveUp(.targetNotFront)])
}

@Test func aQuitTargetOrWithdrawnAccessibilityGivesUpAtOnce() {
    #expect(run([(0, seen(otherPID)), (0.2, seen(nil, gone: true))]) == [.wait, .giveUp(.targetGone)])
    #expect(run([(0, seen(targetPID)), (0.1, seen(targetPID, trusted: false))]) == [.wait, .giveUp(.notTrusted)])
}

private final class FakePasteboard: ClipboardWritable {
    var changeCount = 5
    var contents: [ClipboardRepresentation] = [.string("before")]
    var failing: Set<String> = []

    func clear() -> Int { contents = []; changeCount += 1; return changeCount }

    func write(_ representation: ClipboardRepresentation) -> Bool {
        let name: String = switch representation {
        case .string: "string"
        case .data(_, let type): type
        case .fileURLs: "files"
        }
        guard !failing.contains(name) else { return false }
        contents.append(representation)
        changeCount += 1
        return true
    }
}

@Test func writeReportsRequiredFailuresAndToleratesOptionalOnes() {
    let png = ClipboardRepresentation.data(Data([1]), type: "public.png")
    let tiff = ClipboardRepresentation.data(Data([2]), type: "public.tiff")

    let ok = FakePasteboard()
    ok.failing = ["public.tiff"]
    #expect(ClipboardWriteSequence.perform(required: [png], optional: [tiff], on: ok, expired: { false }) == .written(changeCount: 7))
    #expect(ok.contents == [png])

    let broken = FakePasteboard()
    broken.failing = ["public.png"]
    #expect(ClipboardWriteSequence.perform(required: [png], optional: [tiff], on: broken, expired: { false }) == .failed)
    #expect(broken.contents.isEmpty)

    let late = FakePasteboard()
    #expect(ClipboardWriteSequence.perform(required: [.string("x")], optional: [], on: late, expired: { true }) == .expired)
    #expect(late.contents == [.string("before")])
    #expect(late.changeCount == 5)
}

// MARK: Persistence format

@Test func archiveRoundTripsWithAVersion() throws {
    var history = history(["b", "a"])
    history.pin(history.entries[1].id, at: at(5))
    var rich = ClipboardEntry.text("styled", rich: ClipboardRichText(file: "r.rtf", bytes: 10), at: at(6))
    rich.lastUsed = at(6)
    history.record(rich, limit: .unlimited)
    let (data, kept) = try ClipboardArchive.encode(history.entries)
    #expect(kept == history.entries)
    #expect(String(decoding: data.prefix(24), as: UTF8.self).hasPrefix("{\"version\":1,\"entries\":["))
    #expect(try ClipboardArchive.decode(data) == history.entries)
}

@Test func archiveRefusesNewerAndDamagedFiles() {
    #expect(throws: ClipboardArchive.Failure.newerVersion(2)) {
        try ClipboardArchive.decode(Data("{\"version\":2,\"entries\":[]}".utf8))
    }
    #expect(throws: ClipboardArchive.Failure.damaged) { try ClipboardArchive.decode(Data("not json".utf8)) }
    #expect(throws: ClipboardArchive.Failure.damaged) { try ClipboardArchive.decode(Data("{\"version\":1,\"entries\":7}".utf8)) }
}

@Test func archiveDropsOldestUnpinnedToFitItsRealSize() throws {
    var history = history(["ccc", "bbb", "aaa"])
    history.pin(history.entries[2].id, at: at(9))
    let full = try ClipboardArchive.encode(history.entries).data.count
    let (data, kept) = try ClipboardArchive.encode(history.entries, maximumBytes: full - 1)
    #expect(data.count <= full - 1)
    #expect(texts(kept) == ["aaa", "ccc"])
    #expect(try ClipboardArchive.decode(data) == kept)
    #expect(throws: ClipboardArchive.Failure.tooLarge) { try ClipboardArchive.encode(history.entries, maximumBytes: 10) }
}

@Test func orphanAssetsAreThoseNoEntryRefersTo() {
    let entries = [ClipboardEntry.image(image("aa"), at: at(0)),
                   ClipboardEntry.text("x", rich: ClipboardRichText(file: "r1.rtf", bytes: 1), at: at(1))]
    #expect(ClipboardArchive.orphans(files: ["aa.png", "bb.png", "r1.rtf", "r2.rtf"], entries: entries) == ["bb.png", "r2.rtf"])
}
