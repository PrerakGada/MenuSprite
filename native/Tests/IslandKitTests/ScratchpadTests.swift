import Foundation
import Testing
@testable import IslandKit

// Scratchpad rules (spec-sections-tools §5.2, §5.4, §5.7, §7.7; spec-shell §13.5), restated.

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let day: TimeInterval = 86_400

private func names(_ document: ScratchpadDocument) -> [String] { document.pads.map(\.name) }

private func makeDocument(_ texts: [String]) -> ScratchpadDocument {
    var document = ScratchpadDocument()
    for (index, text) in texts.enumerated() {
        if index > 0 { document.addPad() }
        document.setText(text, of: document.selectedID, at: t0)
    }
    return document
}

// MARK: Routing

private func islandOn() -> IslandSettings {
    var settings = IslandSettings()
    settings.enabled = true
    return settings
}

@Test func scratchpadDefaultsToTheIslandPage() {
    #expect(ScratchpadRouting.route(islandOn()) == .island)
    #expect(ScratchpadRouting.tile(islandOn()) == .showPage)
}

@Test func theShortcutOpensFocusesThenCloses() {
    let settings = islandOn()
    #expect(ScratchpadRouting.shortcut(settings, islandAccepts: true, pageShowing: false, islandIsKey: false) == .openPage)
    #expect(ScratchpadRouting.shortcut(settings, islandAccepts: true, pageShowing: true, islandIsKey: false) == .focusPage)
    #expect(ScratchpadRouting.shortcut(settings, islandAccepts: true, pageShowing: true, islandIsKey: true) == .closeIsland)
}

@Test func separateWindowHiddenPageAndUnavailableIslandUseTheFloatingPad() {
    var settings = islandOn()
    settings.scratchpadInIsland = false
    // Choosing the window leaves the page itself shown in the island.
    #expect(settings.isVisible(IslandSectionID.scratchpad))
    #expect(ScratchpadRouting.shortcut(settings, islandAccepts: true, pageShowing: false, islandIsKey: false) == .floatingPad)
    #expect(ScratchpadRouting.tile(settings) == .collapseThenFloatingPad)
    settings.scratchpadInIsland = true
    settings.setVisible(IslandSectionID.scratchpad, false)
    #expect(ScratchpadRouting.route(settings) == .window)
    settings.setVisible(IslandSectionID.scratchpad, true)
    #expect(ScratchpadRouting.shortcut(settings, islandAccepts: false, pageShowing: false, islandIsKey: false) == .floatingPad)
    settings.enabled = false
    #expect(ScratchpadRouting.route(settings) == .window)
}

// MARK: Document

@Test func newPadsAppendInOrderWithClearNamesAndBecomeSelected() {
    var document = ScratchpadDocument()
    #expect(names(document) == ["Scratchpad 1"])
    let second = document.addPad()
    let third = document.addPad()
    #expect(names(document) == ["Scratchpad 1", "Scratchpad 2", "Scratchpad 3"])
    #expect(document.selectedID == third?.id)
    document.close(second!.id)
    document.addPad()
    #expect(names(document) == ["Scratchpad 1", "Scratchpad 3", "Scratchpad 2"])
}

@Test func anUnnumberedScratchpadHoldsSlotOne() {
    #expect(ScratchpadDocument.nextName(existing: ["Scratchpad"]) == "Scratchpad 2")
    #expect(ScratchpadDocument.nextName(existing: ["Scratchpad", "Scratchpad 2", "Ideas"]) == "Scratchpad 3")
    #expect(ScratchpadDocument.nextName(existing: ["Ideas"]) == "Scratchpad 1")
}

@Test func namesStaySingleLineBoundedAndNeverEmpty() {
    var document = ScratchpadDocument()
    let id = document.selectedID
    document.rename(id, to: "  Work \n\t notes  ")
    #expect(document.selected.name == "Work notes")
    document.rename(id, to: "   ")
    #expect(document.selected.name == "Work notes")
    document.rename(id, to: String(repeating: "a", count: 60))
    #expect(document.selected.name.count == 40)
}

@Test func closingKeepsOrderSelectsTheNearestNeighbourAndNeverClosesTheLast() {
    var document = makeDocument(["a", "b", "c"])
    let ids = document.pads.map(\.id)
    document.select(ids[1])
    let closedMiddle = document.close(ids[1])
    #expect(closedMiddle)
    #expect(document.pads.map(\.id) == [ids[0], ids[2]])
    #expect(document.selectedID == ids[2])
    document.select(ids[2])
    let closedLast = document.close(ids[2])
    #expect(closedLast)
    #expect(document.selectedID == ids[0])
    #expect(!document.canClosePad)
    let closedOnly = document.close(ids[0])
    #expect(!closedOnly)
    #expect(document.pads.count == 1)
    // Closing a pad that is not selected keeps the selection.
    var other = makeDocument(["a", "b", "c"])
    let otherIDs = other.pads.map(\.id)
    other.select(otherIDs[0])
    other.close(otherIDs[2])
    #expect(other.selectedID == otherIDs[0])
}

@Test func onlyAPadWithTextNeedsConfirmation() {
    var document = makeDocument(["notes"])
    document.addPad()
    #expect(document.needsConfirmation(toClose: document.pads[0].id))
    #expect(!document.needsConfirmation(toClose: document.pads[1].id))
}

@Test func twelvePadsAtMost() {
    var document = ScratchpadDocument()
    for _ in 0..<20 { document.addPad() }
    #expect(document.pads.count == 12)
    #expect(!document.canAddPad)
    let beyond = document.addPad()
    #expect(beyond == nil)
}

@Test func editsTrackTheirTimeAndAnEmptyPadHasNone() {
    var document = ScratchpadDocument()
    let id = document.selectedID
    document.setText("hello", of: id, at: t0)
    #expect(document.selected.edited == t0)
    document.setText("", of: id, at: t0.addingTimeInterval(5))
    #expect(document.selected.edited == nil)
}

@Test func retentionClearsOnlyPadsWhoseOwnTextExpired() {
    var document = makeDocument(["old", "fresh", "future"])
    let ids = document.pads.map(\.id)
    document.setText("old!", of: ids[0], at: t0)
    document.setText("fresh!", of: ids[1], at: t0.addingTimeInterval(6 * day))
    document.setText("future!", of: ids[2], at: t0.addingTimeInterval(30 * day))
    let now = t0.addingTimeInterval(7 * day + 1)
    var week = document
    let cleared = week.applyRetention(.week, now: now)
    #expect(cleared == [ids[0]])
    #expect(week.pads.map(\.text) == ["", "fresh!", "future!"])
    #expect(week.pads[0].edited == nil)
    // Exactly the period is not "strictly older".
    var exact = document
    let exactlyAWeek = exact.applyRetention(.week, now: t0.addingTimeInterval(7 * day))
    #expect(exactlyAWeek.isEmpty)
    var never = document
    let neverCleared = never.applyRetention(.never, now: now.addingTimeInterval(365 * day))
    #expect(neverCleared.isEmpty)
}

@Test func retentionPeriodsAndUnknownValues() {
    #expect(ScratchpadRetention.day.period == day)
    #expect(ScratchpadRetention.week.period == 7 * day)
    #expect(ScratchpadRetention.month.period == 30 * day)
    #expect(ScratchpadRetention.never.period == nil)
    #expect(ScratchpadRetention(stored: "fortnight") == .never)
    #expect(ScratchpadRetention(stored: nil) == .never)
    #expect(ScratchpadRetention(stored: "month") == .month)
}

@Test func exportNamesUseTheLocalDateAndCannotBecomePaths() {
    let zone = TimeZone(identifier: "Asia/Kolkata")!
    let date = Date(timeIntervalSince1970: 1_790_593_200) // 28 Sep 2026, 16:30 in Mumbai
    #expect(ScratchpadDocument.exportName(for: "Work/Ideas: 1", on: date, timeZone: zone) == "Work-Ideas- 1 2026-09-28.txt")
    #expect(ScratchpadDocument.exportName(for: "Scratchpad 1", on: date, timeZone: zone) == "Scratchpad 1 2026-09-28.txt")
}

@Test func textNamesOrderAndSelectionRoundTrip() throws {
    var original = makeDocument(["one", "two\nlines", ""])
    original.rename(original.pads[1].id, to: "Ideas")
    original.select(original.pads[1].id)
    let data = try ScratchpadPersistence.encode(original)
    guard case .loaded(let decoded) = ScratchpadPersistence.outcome(of: .data(data)) else {
        Issue.record("did not load"); return
    }
    #expect(decoded == original)
    #expect(decoded.selected.name == "Ideas")
}

@Test func loadingSanitisesTheDocument() throws {
    let id = UUID()
    let pads = [ScratchpadPad(id: id, name: "", text: "", edited: t0), ScratchpadPad(id: id, name: "Dup"),
                ScratchpadPad(name: "Kept", text: "x", edited: t0)]
        + (0..<15).map { ScratchpadPad(name: "Extra \($0)") }
    let document = ScratchpadDocument(pads: pads, selectedID: UUID())
    #expect(document.pads.count == 12)
    #expect(document.pads[0].name == "Scratchpad 1")
    #expect(document.pads[0].edited == nil)
    #expect(document.pads[1].name == "Kept")
    #expect(document.selectedID == id)
    #expect(ScratchpadDocument(pads: [], selectedID: nil).pads.map(\.name) == ["Scratchpad 1"])
}

// MARK: Shortcuts

@Test func commandTAndCommandWMatchTheTypedCharacter() {
    #expect(ScratchpadKeyCommand(characters: "t", commandOnly: true) == .newPad)
    #expect(ScratchpadKeyCommand(characters: "w", commandOnly: true) == .closePad)
    // Caps Lock still closes: the character arrives upper-case.
    #expect(ScratchpadKeyCommand(characters: "W", commandOnly: true) == .closePad)
    // AZERTY puts "z" where US has W: no close.
    #expect(ScratchpadKeyCommand(characters: "z", commandOnly: true) == nil)
    #expect(ScratchpadKeyCommand(characters: nil, commandOnly: true) == nil)
    #expect(ScratchpadKeyCommand(characters: "", commandOnly: true) == nil)
    #expect(ScratchpadKeyCommand(characters: "w", commandOnly: false) == nil)
}

@Test func commandTIsIdleAtTheLimitAndCommandWOnTheLastTabHides() {
    var full = ScratchpadDocument()
    for _ in 0..<11 { full.addPad() }
    let thirteenth = full.addPad()
    #expect(thirteenth == nil)
    let single = ScratchpadDocument()
    #expect(!single.canClosePad)
}

@Test func padBackgroundDefaultsTranslucentAndBrokenValuesBecomeOpaque() {
    #expect(ScratchpadBackground.standard == 0)
    #expect(ScratchpadBackground.resolve(0.4) == 0.4)
    #expect(ScratchpadBackground.resolve(-1) == 0)
    #expect(ScratchpadBackground.resolve(3) == 1)
    #expect(ScratchpadBackground.resolve(.nan) == 1)
    #expect(ScratchpadBackground.resolve(.infinity) == 1)
}

// MARK: Storage

/// A private folder inside the test's temporary directory, removed afterwards.
private final class Sandbox {
    let folder: URL
    var file: URL { folder.appendingPathComponent("Scratchpad/scratchpad.json") }

    init() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("scratchpad-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        lock(false)
        chmodTree(0o700)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Makes the private folder immutable, so nothing can be written in it (not even by its owner).
    func lock(_ locked: Bool) {
        chflags(folder.appendingPathComponent("Scratchpad").path, locked ? UInt32(UF_IMMUTABLE) : 0)
    }

    func chmodTree(_ mode: mode_t) {
        chmod(folder.appendingPathComponent("Scratchpad").path, mode)
        chmod(file.path, mode == 0o700 ? 0o600 : mode)
    }

    func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
    }

    func load(_ persistence: inout ScratchpadPersistence) -> ScratchpadDocument? {
        persistence.loaded(ScratchpadPersistence.outcome(of: IslandPrivateFile.read(file)))
    }

    /// Saves the way the app does: only when the rules allow, recording the result.
    @discardableResult
    func save(_ document: ScratchpadDocument, _ persistence: inout ScratchpadPersistence) -> Bool {
        guard persistence.shouldWrite(document) else { return false }
        let success = (try? IslandPrivateFile.write(ScratchpadPersistence.encode(document), to: file)) != nil
        persistence.wrote(document, success: success)
        return success
    }
}

@Test func savingIsImpossibleUntilALoadSucceeded() {
    let sandbox = Sandbox()
    var persistence = ScratchpadPersistence()
    #expect(!sandbox.save(ScratchpadDocument(), &persistence))
    #expect(!FileManager.default.fileExists(atPath: sandbox.file.path))
    let fresh = sandbox.load(&persistence)
    #expect(fresh.map(names) == ["Scratchpad 1"])
    #expect(persistence.canSave)
    #expect(sandbox.save(fresh!, &persistence))
}

@Test func writesAreOwnerOnlyVerifiedAndSkippedWhenUnchanged() throws {
    let sandbox = Sandbox()
    try FileManager.default.createDirectory(at: sandbox.file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
    var persistence = ScratchpadPersistence()
    var document = try #require(sandbox.load(&persistence))
    document.setText("hello", of: document.selectedID, at: t0)
    #expect(sandbox.save(document, &persistence))
    #expect(sandbox.mode(sandbox.file) == 0o600)
    #expect(sandbox.mode(sandbox.file.deletingLastPathComponent()) == 0o700)
    // An unchanged document is not rewritten.
    #expect(!persistence.shouldWrite(document))
    var reloaded = ScratchpadPersistence()
    #expect(sandbox.load(&reloaded) == document)
}

@Test func aDamagedFileIsLeftUntouchedAndBlocksEverySaveUntilItReads() throws {
    let sandbox = Sandbox()
    try FileManager.default.createDirectory(at: sandbox.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let damaged = Data("{ not a scratchpad".utf8)
    try damaged.write(to: sandbox.file)
    var persistence = ScratchpadPersistence()
    #expect(sandbox.load(&persistence) == nil)
    #expect(persistence.loadFailed)
    #expect(!sandbox.save(ScratchpadDocument(), &persistence))
    #expect(try Data(contentsOf: sandbox.file) == damaged)
    // Once the file reads again, loading works and saving is allowed.
    try ScratchpadPersistence.encode(makeDocument(["recovered"])).write(to: sandbox.file)
    let recovered = sandbox.load(&persistence)
    #expect(recovered?.selected.text == "recovered")
    #expect(persistence.canSave)
}

@Test func aNewerFileIsNotOverwritten() throws {
    let sandbox = Sandbox()
    try FileManager.default.createDirectory(at: sandbox.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let newer = Data("{\"version\":2,\"pads\":[],\"selectedID\":\"\(UUID().uuidString)\"}".utf8)
    try newer.write(to: sandbox.file)
    var persistence = ScratchpadPersistence()
    #expect(sandbox.load(&persistence) == nil)
    #expect(!sandbox.save(ScratchpadDocument(), &persistence))
    #expect(try Data(contentsOf: sandbox.file) == newer)
}

@Test func aReadPermissionFailureIsNotAMissingFile() throws {
    let sandbox = Sandbox()
    var persistence = ScratchpadPersistence()
    var document = try #require(sandbox.load(&persistence))
    document.setText("keep me", of: document.selectedID, at: t0)
    #expect(sandbox.save(document, &persistence))
    let before = try Data(contentsOf: sandbox.file)
    chmod(sandbox.file.path, 0o000)
    guard case .unreadable = IslandPrivateFile.read(sandbox.file) else {
        Issue.record("an unreadable file was reported as missing or readable"); return
    }
    // A failed reload revokes saving, even for the document that was saved before.
    #expect(sandbox.load(&persistence) == nil)
    #expect(!persistence.canSave)
    #expect(!sandbox.save(ScratchpadDocument(), &persistence))
    chmod(sandbox.file.path, 0o600)
    #expect(try Data(contentsOf: sandbox.file) == before)
}

@Test func aFailedWriteKeepsTheEditsWarnsAndRetriesOnTheNextChange() throws {
    let sandbox = Sandbox()
    var persistence = ScratchpadPersistence()
    var document = try #require(sandbox.load(&persistence))
    document.setText("first", of: document.selectedID, at: t0)
    #expect(sandbox.save(document, &persistence))
    // The private folder becomes unavailable: the write fails, the notes stay in memory.
    sandbox.lock(true)
    document.setText("second", of: document.selectedID, at: t0)
    #expect(!sandbox.save(document, &persistence))
    #expect(persistence.saveFailed)
    #expect(document.selected.text == "second")
    #expect(persistence.shouldWrite(document))
    // The next change retries; a successful write clears the warning.
    sandbox.lock(false)
    document.setText("third", of: document.selectedID, at: t0)
    #expect(sandbox.save(document, &persistence))
    #expect(!persistence.saveFailed)
    var reloaded = ScratchpadPersistence()
    #expect(sandbox.load(&reloaded)?.selected.text == "third")
}

@Test func aFolderThatCannotBeCreatedNeverDiscardsNotes() throws {
    let sandbox = Sandbox()
    // A plain file where the private folder should be.
    try Data("x".utf8).write(to: sandbox.folder.appendingPathComponent("Scratchpad"))
    var persistence = ScratchpadPersistence()
    let loaded = sandbox.load(&persistence)
    var document = loaded ?? ScratchpadDocument()
    document.setText("important", of: document.selectedID, at: t0)
    #expect(!sandbox.save(document, &persistence))
    #expect(document.selected.text == "important")
    #expect(try Data(contentsOf: sandbox.folder.appendingPathComponent("Scratchpad")) == Data("x".utf8))
}
