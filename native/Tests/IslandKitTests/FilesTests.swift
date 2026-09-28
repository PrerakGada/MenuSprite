import CoreGraphics
import Foundation
import Testing
@testable import IslandKit

// MARK: Shelf model

private func file(_ path: String, owned: Bool = false) -> ShelfContent { .file(ShelfFile(path: path, owned: owned)) }
private func files(_ count: Int) -> [ShelfContent] { (0..<count).map { file("/tmp/f\($0)") } }

@Test func shelfCapacityIsTwoHundredLeaves() {
    var shelf = Shelf()
    for index in 0..<199 { shelf.add([file("/tmp/\(index)")]) }
    #expect(shelf.leafCount == 199)
    var twoMore = shelf
    let result1 = twoMore.add(files(2))
    #expect(result1 == .full)
    #expect(twoMore.leafCount == 199)
    guard case .added = shelf.add([file("/tmp/last")]) else { Issue.record("199 + 1 must fit"); return }
    #expect(shelf.leafCount == 200)
    let result2 = shelf.add([file("/tmp/over")])
    #expect(result2 == .full)
    #expect(shelf.canAccept(1) == false)
}

@Test func aMultiItemDropBecomesOneOrderedPile() throws {
    var shelf = Shelf()
    let result = shelf.add([file("/a"), .text("hello"), .link(URL(string: "https://example.com/x")!)])
    guard case .added(let id) = result else { Issue.record("expected added"); return }
    let pile = try #require(shelf.item(id))
    #expect(pile.isPile)
    #expect(pile.leafCount == 3)
    #expect(pile.children.map(\.title) == ["a", "hello", "example.com"])
    let result3 = shelf.add([])
    #expect(result3 == .empty)
}

@Test func clearAllKeepsPinnedItemsAndPinnedLeavesInsidePiles() throws {
    var shelf = Shelf()
    guard case .added(let loose) = shelf.add([file("/loose")]),
          case .added(let kept) = shelf.add([file("/kept")]),
          case .added(let pileID) = shelf.add([file("/p1"), file("/p2"), file("/p3")]) else { Issue.record("adds"); return }
    let pinnedChild = try #require(shelf.item(pileID)?.children[1].id)
    shelf.setPinned([kept, pinnedChild], true)
    shelf.clearAll()
    #expect(shelf.item(loose) == nil)
    #expect(shelf.item(kept) != nil)
    // The pile kept only its pinned leaf, which now stands on its own.
    #expect(shelf.items.map(\.title) == ["kept", "p2"])
}

@Test func removeAfterDragKeepsPinnedItemsAndThePilesAroundThem() throws {
    var shelf = Shelf()
    guard case .added(let a) = shelf.add([file("/a")]),
          case .added(let b) = shelf.add([file("/b")]),
          case .added(let pile) = shelf.add([file("/c"), file("/d")]) else { Issue.record("adds"); return }
    shelf.setPinned([b], true)
    shelf.removeAfterDrag([a, b, pile])
    #expect(shelf.items.map(\.title) == ["b"])
    #expect(shelf.containsPinned([b]))
}

@Test func pinsAreSeenThroughThePileTheyAreIn() throws {
    var shelf = Shelf()
    guard case .added(let pile) = shelf.add([file("/c"), file("/d")]) else { Issue.record("add"); return }
    let child = try #require(shelf.item(pile)?.children[0].id)
    #expect(shelf.containsPinned([pile]) == false)
    shelf.setPinned([pile], true)
    #expect(shelf.containsPinned([child]))
    #expect(shelf.containsPinned([pile]))
}

@Test func leavesOfTilesAreInShelfOrderAndOnce() throws {
    var shelf = Shelf()
    guard case .added(let a) = shelf.add([file("/a")]),
          case .added(let pile) = shelf.add([file("/b"), file("/c")]) else { Issue.record("adds"); return }
    let child = try #require(shelf.item(pile)?.children[0].id)
    #expect(shelf.leaves(of: [pile, a, child]).map(\.title) == ["a", "b", "c"])
}

@Test func expandedPilesShowTheirChildrenAfterThePileTile() throws {
    var shelf = Shelf()
    guard case .added(let pile) = shelf.add([file("/b"), file("/c")]) else { Issue.record("add"); return }
    shelf.add([file("/d")])
    #expect(shelf.tiles(expanded: []).map(\.item.title) == ["2 items", "d"])
    let open = shelf.tiles(expanded: [pile])
    #expect(open.map(\.item.title) == ["2 items", "b", "c", "d"])
    #expect(open[1].parent == pile)
    #expect(open[0].isExpanded)
}

@Test func textIsCappedAndTitledByItsFirstLine() {
    var shelf = Shelf()
    let long = String(repeating: "x", count: Shelf.textLimit + 10)
    guard case .added(let id) = shelf.add([.text(long)]) else { Issue.record("add"); return }
    if case .text(let stored) = shelf.item(id)?.content { #expect(stored.count == Shelf.textLimit) }
    #expect(ShelfTitles.text("\n\n  First line here  \nsecond") == "First line here")
    let title = ShelfTitles.text(String(repeating: "a", count: 80))
    #expect(title.count == ShelfTitles.textTitleLimit)
    #expect(title.hasSuffix("…"))
    #expect(ShelfTitles.link(URL(string: "https://www.apple.com/mac/")!) == "www.apple.com")
}

// MARK: Selection and layout

@Test func clickTogglesShiftSelectsARangeAllAndEscape() {
    let ids = (0..<6).map { _ in UUID() }
    var selection = ShelfSelection()
    selection.click(ids[1], extending: false, order: ids)
    #expect(selection.selected == [ids[1]])
    selection.click(ids[4], extending: true, order: ids)
    #expect(selection.selected == Set(ids[1...4]))
    selection.click(ids[2], extending: false, order: ids)
    #expect(!selection.contains(ids[2]))
    selection.selectAll(ids)
    #expect(selection.count == 6)
    selection.clear()
    #expect(selection.isEmpty)
    selection.click(ids[0], extending: false, order: ids)
    selection.prune(to: Array(ids.dropFirst()))
    #expect(selection.isEmpty && selection.anchor == nil)
}

@Test func sidewaysRowsAndColumnsFollowTheTileSize() {
    #expect(ShelfLayout.rows(height: 140) == 1)
    #expect(ShelfLayout.rows(height: 194) == 2)
    #expect(ShelfLayout.rows(height: 0) == 1)
    #expect(ShelfLayout.columns(width: 276) == 3)
    #expect(ShelfLayout.minimumPageHeight == CGFloat(88 + 8 + 28 + 10))
}

// MARK: Drop acceptance

@Test func acceptanceOrderPrefersFilesThenPromisesThenImagesThenLinksThenText() {
    let url = URL(string: "https://example.com/cat.png")!
    #expect(ShelfIntake.candidate(for: .init(fileURL: URL(fileURLWithPath: "/tmp/a"), hasImage: true, url: url)) == .file(URL(fileURLWithPath: "/tmp/a")))
    #expect(ShelfIntake.candidate(for: .init(isPromise: true, hasImage: true)) == .promise)
    #expect(ShelfIntake.candidate(for: .init(hasGIF: true, hasImage: true, url: url)) == .gif)
    // A browser image drag carries the image and its address: it stays an image.
    #expect(ShelfIntake.candidate(for: .init(hasImage: true, url: url, text: "cat")) == .image)
    #expect(ShelfIntake.candidate(for: .init(url: url, text: "cat")) == .link(url))
    #expect(ShelfIntake.candidate(for: .init(url: URL(string: "mailto:a@b.c")!, text: "a@b.c")) == .text("a@b.c"))
    #expect(ShelfIntake.candidate(for: .init(text: "  \n ")) == nil)
}

@Test func filesAreTakenOncePerDrop() {
    let a = URL(fileURLWithPath: "/tmp/a")
    let plan = ShelfIntake.plan([.init(fileURL: a), .init(text: "note"), .init(fileURL: URL(fileURLWithPath: "/tmp/./a")), .init(fileURL: URL(fileURLWithPath: "/tmp/b"))])
    #expect(plan == [.file(a), .text("note"), .file(URL(fileURLWithPath: "/tmp/b"))])
}

@Test func promisedFilesAreTakenOnlyFromInsideTheirFolder() {
    let folder = URL(fileURLWithPath: "/tmp/promises-1", isDirectory: true)
    #expect(ShelfPromiseRules.accepts(folder.appendingPathComponent("Invoice March.pdf"), folder: folder, isSymlink: false, failed: false))
    #expect(!ShelfPromiseRules.accepts(URL(fileURLWithPath: "/tmp/elsewhere/x.pdf"), folder: folder, isSymlink: false, failed: false))
    #expect(!ShelfPromiseRules.accepts(URL(fileURLWithPath: "/tmp/promises-1/../x.pdf"), folder: folder, isSymlink: false, failed: false))
    #expect(!ShelfPromiseRules.accepts(folder.appendingPathComponent("link"), folder: folder, isSymlink: true, failed: false))
    #expect(!ShelfPromiseRules.accepts(folder.appendingPathComponent("x.pdf"), folder: folder, isSymlink: false, failed: true))
    #expect(!ShelfPromiseRules.accepts(URL(string: "https://example.com/x")!, folder: folder, isSymlink: false, failed: false))
}

@Test func promisesKeepTheirDropOrderWhateverOrderTheyArriveIn() {
    var arrivals = ShelfArrivals<String>([.ready(["first"]), .waiting(expected: 2), .ready(["last"]), .waiting(expected: 1)])
    #expect(arrivals.plannedCount == 5)
    let result4 = arrivals.deliver("d", to: 3)
    #expect(result4)
    #expect(!arrivals.isComplete)
    let result5 = arrivals.deliver("b", to: 1)
    #expect(result5)
    let result6 = arrivals.deliver(nil, to: 1)
    #expect(result6)
    let result7 = arrivals.deliver("extra", to: 1)
    #expect(!result7)
    #expect(arrivals.isComplete)
    #expect(arrivals.values == ["first", "b", "last", "d"])
    #expect(arrivals.failures == 1)
}

@Test func cancellingWinsOverAQueuedDelivery() {
    var arrivals = ShelfArrivals<String>([.waiting(expected: 1)])
    arrivals.cancel()
    let result8 = arrivals.deliver("late", to: 0)
    #expect(!result8)
    #expect(arrivals.isComplete)
    #expect(arrivals.values.isEmpty)
    var stalled = ShelfArrivals<String>([.ready(["a"]), .waiting(expected: 2)])
    stalled.finishWaiting()
    #expect(stalled.isComplete && stalled.failures == 2 && stalled.values == ["a"])
}

// MARK: Drag out

@Test func dragOutCopiesUnlessItemsLeaveAndNothingIsPinned() {
    #expect(ShelfDragRules.operations(withinApp: true, removeAfterDrop: false, containsPinned: true) == .move)
    #expect(ShelfDragRules.operations(withinApp: false, removeAfterDrop: true, containsPinned: false) == [.copy, .move])
    #expect(ShelfDragRules.operations(withinApp: false, removeAfterDrop: true, containsPinned: true) == .copy)
    #expect(ShelfDragRules.operations(withinApp: false, removeAfterDrop: false, containsPinned: false) == .copy)
}

@Test func theIslandCollapsesOnlyForAnAcceptedUnmergedDropWithCloseOnAndUnpinned() {
    #expect(ShelfDragRules.collapsesAfterDrop(accepted: true, merged: false, closeAfterDrop: true, pinned: false, sameIsland: true))
    #expect(!ShelfDragRules.collapsesAfterDrop(accepted: false, merged: false, closeAfterDrop: true, pinned: false, sameIsland: true))
    #expect(!ShelfDragRules.collapsesAfterDrop(accepted: true, merged: true, closeAfterDrop: true, pinned: false, sameIsland: true))
    #expect(!ShelfDragRules.collapsesAfterDrop(accepted: true, merged: false, closeAfterDrop: false, pinned: false, sameIsland: true))
    #expect(!ShelfDragRules.collapsesAfterDrop(accepted: true, merged: false, closeAfterDrop: true, pinned: true, sameIsland: true))
    // A stale drag cannot close an island that was replaced meanwhile.
    #expect(!ShelfDragRules.collapsesAfterDrop(accepted: true, merged: false, closeAfterDrop: true, pinned: false, sameIsland: false))
    #expect(ShelfDragRules.removesAfterDrop(accepted: true, removeAfterDrop: true))
    #expect(!ShelfDragRules.removesAfterDrop(accepted: false, removeAfterDrop: true))
}

@Test func deadFilesHealMoveOrStayWhenTheirDiskIsAway() {
    let mounted: Set<String> = ["/Volumes/Work"]
    #expect(ShelfFileHealth.verdict(path: "/tmp/a", exists: true, resolved: nil, mounted: mounted) == .present)
    #expect(ShelfFileHealth.verdict(path: "/tmp/a", exists: false, resolved: "/tmp/b", mounted: mounted) == .moved("/tmp/b"))
    #expect(ShelfFileHealth.verdict(path: "/Volumes/Backup/x", exists: false, resolved: nil, mounted: mounted) == .offline)
    #expect(ShelfFileHealth.verdict(path: "/Volumes/Work/x", exists: false, resolved: nil, mounted: mounted) == .gone)
    #expect(ShelfFileHealth.verdict(path: "/tmp/a", exists: false, resolved: nil, mounted: mounted) == .gone)
}

@Test func aWindowMoveIsNeverAContentDrag() {
    var gesture = ShelfDragGesture()
    // Mouse-down unseen: the first dragged event takes the baseline.
    let result9 = gesture.dragged(changeCount: 7, hasDroppableType: { true })
    #expect(!result9)
    let result10 = gesture.dragged(changeCount: 7, hasDroppableType: { true })
    #expect(!result10)
    gesture.mouseUp()
    #expect(!gesture.isActive)
    // A real drag writes the drag pasteboard after mouse-down.
    gesture.mouseDown(changeCount: 7)
    let result11 = gesture.dragged(changeCount: 7, hasDroppableType: { true })
    #expect(!result11)
    let result12 = gesture.dragged(changeCount: 8, hasDroppableType: { true })
    #expect(result12)
    let result13 = gesture.dragged(changeCount: 9, hasDroppableType: { true })
    #expect(!result13)
    #expect(gesture.isContentDrag)
    // Content the shelf cannot take is checked once and never reveals.
    gesture.mouseDown(changeCount: 9)
    var checks = 0
    let result14 = gesture.dragged(changeCount: 10, hasDroppableType: { checks += 1; return false })
    #expect(!result14)
    let result15 = gesture.dragged(changeCount: 11, hasDroppableType: { checks += 1; return false })
    #expect(!result15)
    #expect(checks == 1)
}

@Test func threeQuickReversalsAreAShake() {
    var shake = ShelfShakeDetector()
    var time = 0.0
    var fired = false
    for x in [0.0, 40, 0, 40, 0] {
        fired = shake.move(x: x, at: time) || fired
        time += 0.1
    }
    #expect(fired)
    var slow = ShelfShakeDetector()
    fired = false
    time = 0
    for x in [0.0, 40, 0, 40, 0] {
        fired = slow.move(x: x, at: time) || fired
        time += 1
    }
    #expect(!fired)
    var small = ShelfShakeDetector()
    fired = false
    for (index, x) in [0.0, 5, 0, 5, 0, 5].enumerated() { fired = small.move(x: x, at: Double(index) * 0.05) || fired }
    #expect(!fired)
}

// MARK: Persistence

@Test func theStoreRoundTripsEveryKind() throws {
    var shelf = Shelf()
    shelf.add([.file(ShelfFile(path: "/tmp/a b.pdf", bookmark: Data([1, 2, 3]), owned: true))])
    guard case .added(let pile) = shelf.add([.text("note"), .link(URL(string: "https://example.com")!)]) else { Issue.record("add"); return }
    shelf.setPinned([pile], true)
    let decoded = ShelfCodec.decode(try ShelfCodec.encode(shelf))
    #expect(decoded.isComplete)
    #expect(decoded.items == shelf.items)
}

@Test func aPartlyReadableStoreLoadsWhatItCanAndSaysSo() throws {
    let json = """
    [{"id":"\(UUID().uuidString)","kind":"file","path":"/tmp/a"},
     {"id":"\(UUID().uuidString)","kind":"hologram"},
     {"id":"\(UUID().uuidString)","kind":"pile","children":[{"id":"\(UUID().uuidString)","kind":"text","text":"x"},{"kind":"file"}]}]
    """
    let decoded = ShelfCodec.decode(Data(json.utf8))
    #expect(!decoded.isComplete)
    #expect(decoded.items.count == 2)
    #expect(decoded.items[1].leafCount == 1)
    #expect(ShelfCodec.decode(Data("not json".utf8)).isComplete == false)
    #expect(ShelfCodec.decode(Data()).isComplete)
}

@Test func pilesDeeperThanFourLevelsAreFlattened() {
    var item = ShelfItem(content: .text("leaf"))
    for _ in 0..<6 { item = ShelfItem(content: .pile([item, ShelfItem(content: .text("more"))])) }
    let shelf = Shelf(items: [item])
    func depth(_ item: ShelfItem) -> Int { item.isPile ? 1 + (item.children.map(depth).max() ?? 0) : 0 }
    #expect(depth(shelf.items[0]) <= Shelf.maxDepth)
    #expect(shelf.leafCount == item.leafCount)
}

// MARK: ZIP

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func run(_ job: ShelfArchiveJob, timeout: TimeInterval = 20) -> ShelfArchiveJob.Outcome? {
    let done = DispatchSemaphore(value: 0)
    let box = OutcomeBox()
    job.start(progress: { _, _ in }) { outcome in box.set(outcome); done.signal() }
    return done.wait(timeout: .now() + timeout) == .success ? box.value : nil
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ShelfArchiveJob.Outcome?
    func set(_ outcome: ShelfArchiveJob.Outcome) { lock.withLock { stored = outcome } }
    var value: ShelfArchiveJob.Outcome? { lock.withLock { stored } }
}

@Test func zipNamesFollowFinderAndStayUnique() {
    #expect(ShelfArchiveNaming.name(for: URL(fileURLWithPath: "/tmp/Report.pdf")) == "Report.pdf.zip")
    #expect(ShelfArchiveNaming.name(for: URL(fileURLWithPath: "/tmp/Photos/")) == "Photos.zip")
    let taken: Set<String> = ["Report.pdf.zip", "Report.pdf 2.zip"]
    #expect(ShelfArchiveNaming.unique("Report.pdf.zip") { taken.contains($0) } == "Report.pdf 3.zip")
    let folder = URL(fileURLWithPath: "/tmp/out")
    let destinations = ShelfArchiveNaming.destinations(for: [URL(fileURLWithPath: "/a/x"), URL(fileURLWithPath: "/b/x")], in: folder) { _ in false }
    #expect(destinations.map(\.lastPathComponent) == ["x.zip", "x 2.zip"])
}

@Test func createZipProducesARealArchive() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appendingPathComponent("notes.txt")
    try Data("hello shelf".utf8).write(to: input)
    let output = folder.appendingPathComponent("notes.txt.zip")
    #expect(ShelfArchiveCheck.refusal(inputs: [input], destinations: [output]) == nil)
    let outcome = run(ShelfArchiveJob(inputs: [input], destinations: [output]))
    #expect(outcome == .finished([output]))
    let bytes = try Data(contentsOf: output)
    #expect(bytes.prefix(2) == Data("PK".utf8))
}

@Test func anArchiveCannotLandInsideItsOwnSource() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("inner"), withIntermediateDirectories: true)
    let link = folder.appendingPathComponent("Shortcut")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(ShelfArchiveCheck.refusal(inputs: [source], destinations: [source.appendingPathComponent("Project.zip")]) == .insideSource("Project"))
    #expect(ShelfArchiveCheck.refusal(inputs: [source], destinations: [source.appendingPathComponent("inner/Project.zip")]) == .insideSource("Project"))
    #expect(ShelfArchiveCheck.refusal(inputs: [source], destinations: [link.appendingPathComponent("Project.zip")]) == .insideSource("Project"))
    let alias = folder.appendingPathComponent("PROJECT/Project.zip")
    #expect(ShelfArchiveCheck.refusal(inputs: [source], destinations: [alias]) == .insideSource("Project"))
    // Beside the selection is fine.
    #expect(ShelfArchiveCheck.refusal(inputs: [source], destinations: [folder.appendingPathComponent("Project.zip")]) == nil)
    let fileInput = folder.appendingPathComponent("a.txt")
    try Data("a".utf8).write(to: fileInput)
    #expect(ShelfArchiveCheck.refusal(inputs: [fileInput], destinations: [folder.appendingPathComponent("a.txt.zip")]) == nil)
    #expect(ShelfArchiveCheck.refusal(inputs: [URL(string: "https://example.com/a")!], destinations: [folder.appendingPathComponent("a.zip")]) == .remote)
    #expect(ShelfArchiveCheck.refusal(inputs: [URL(fileURLWithPath: "/")], destinations: [folder.appendingPathComponent("root.zip")]) == .root)
}

@Test func aCollidingNameFailsAndKeepsTheOriginal() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appendingPathComponent("a.txt")
    try Data("new".utf8).write(to: input)
    let output = folder.appendingPathComponent("a.txt.zip")
    try Data("original".utf8).write(to: output)
    let outcome = run(ShelfArchiveJob(inputs: [input], destinations: [output]))
    guard case .failed = outcome else { Issue.record("expected a failure, got \(String(describing: outcome))"); return }
    #expect(try Data(contentsOf: output) == Data("original".utf8))
}

/// A stand-in archiver that ignores SIGTERM and never finishes on its own.
private let stubborn = ShelfArchiveJob.Tool(executable: URL(fileURLWithPath: "/bin/sh")) { _, output, _ in
    ["-c", "trap '' TERM; : > \"$0\"; exec sleep 30", output.path]
}

@Test func stopNowKillsAChildThatIgnoresTerminate() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appendingPathComponent("a.txt")
    try Data("a".utf8).write(to: input)
    let output = folder.appendingPathComponent("a.txt.zip")
    try Data("previous".utf8).write(to: output)
    let job = ShelfArchiveJob(inputs: [input], destinations: [output], tool: stubborn)
    let done = DispatchSemaphore(value: 0)
    let box = OutcomeBox()
    job.start(progress: { _, _ in }) { outcome in box.set(outcome); done.signal() }
    Thread.sleep(forTimeInterval: 0.5)
    let started = Date()
    job.stopNow()
    #expect(done.wait(timeout: .now() + 5) == .success)
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(box.value == .cancelled([]))
    #expect(try Data(contentsOf: output) == Data("previous".utf8))
    // The staging folder went with it: no partial archive is left anywhere beside the destination.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(leftovers == ["a.txt", "a.txt.zip"])
}

@Test func cancelEscalatesToKillAfterTheGracePeriod() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appendingPathComponent("a.txt")
    try Data("a".utf8).write(to: input)
    let job = ShelfArchiveJob(inputs: [input], destinations: [folder.appendingPathComponent("a.txt.zip")], tool: stubborn)
    let done = DispatchSemaphore(value: 0)
    let box = OutcomeBox()
    job.start(progress: { _, _ in }) { outcome in box.set(outcome); done.signal() }
    Thread.sleep(forTimeInterval: 0.5)
    job.cancel()
    #expect(done.wait(timeout: .now() + 5) == .success)
    #expect(box.value == .cancelled([]))
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.txt.zip").path))
}

@Test func aStoppedJobCannotRestartAndAQueuedOneNeverStartsItsChild() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let marker = folder.appendingPathComponent("ran")
    let tool = ShelfArchiveJob.Tool(executable: URL(fileURLWithPath: "/usr/bin/touch")) { _, _, _ in [marker.path] }
    let input = folder.appendingPathComponent("a.txt")
    try Data("a".utf8).write(to: input)
    let job = ShelfArchiveJob(inputs: [input], destinations: [folder.appendingPathComponent("a.zip")], tool: tool)
    job.stopNow()
    #expect(run(job) == .cancelled([]))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(run(job) == .cancelled([]))
}

// MARK: Camera mirror

@Test func thePreviewKeepsFourByThreeAndLeavesRoomForTheStopButton() {
    for (width, height) in [(424.0, 180.0), (504.0, 264.0), (304.0, 120.0), (600.0, 600.0)] {
        let size = CameraMirrorLayout.previewSize(pageWidth: width, pageHeight: height)
        #expect(abs(size.width / size.height - 4.0 / 3.0) < 0.001)
        #expect(size.height + CameraMirrorLayout.controlsGap + CameraMirrorLayout.controlsHeight <= height + 0.001)
        #expect(size.width <= width + 0.001)
    }
    #expect(CameraMirrorLayout.previewSize(pageWidth: 400, pageHeight: 20) == .zero)
}

@Test func openingAsksOnlyWhenUndecidedAndAnOldAnswerDoesNothing() {
    var machine = CameraMirrorMachine()
    let asked = machine.open(authorization: .notDetermined, devices: ["a"], preferred: nil)
    #expect(asked == [.requestAccess(generation: 1)])
    #expect(machine.status == .waitingForPermission)
    _ = machine.stop()
    _ = machine.open(authorization: .notDetermined, devices: ["a"], preferred: nil)
    let result16 = machine.accessAnswered(true, generation: 1, devices: ["a"], preferred: nil)
    #expect(result16.isEmpty)
    #expect(machine.status == .waitingForPermission)
    let result17 = machine.accessAnswered(true, generation: machine.generation, devices: ["a"], preferred: nil)
    #expect(result17 == [.configure(device: "a", generation: machine.generation)])
    var denied = CameraMirrorMachine()
    let result18 = denied.open(authorization: .denied, devices: ["a"], preferred: nil)
    #expect(result18.isEmpty)
    #expect(denied.status == .denied)
}

@Test func theCameraStopsAndStartsAgainOnTheSamePage() {
    var machine = CameraMirrorMachine()
    _ = machine.open(authorization: .authorized, devices: ["a", "b"], preferred: "b")
    #expect(machine.device == "b")
    let result19 = machine.configured(success: true, generation: machine.generation)
    #expect(result19.isEmpty)
    #expect(machine.status == .running)
    let result20 = machine.stop()
    #expect(result20 == [.stopSession])
    #expect(machine.status == .off)
    // A slow start from before the stop cannot bring it back.
    let result21 = machine.configured(success: true, generation: 1)
    #expect(result21.isEmpty)
    #expect(machine.status == .off)
    _ = machine.open(authorization: .authorized, devices: ["a", "b"], preferred: "b")
    _ = machine.configured(success: true, generation: machine.generation)
    #expect(machine.status == .running)
}

@Test func onlyAnExplicitPickSetsThePreferredCamera() {
    var machine = CameraMirrorMachine()
    _ = machine.open(authorization: .authorized, devices: ["a", "b"], preferred: nil)
    _ = machine.configured(success: true, generation: machine.generation)
    let picked = machine.pick("b", devices: ["a", "b"])
    #expect(picked.contains(.setPreferred("b")))
    #expect(picked.contains(.configure(device: "b", generation: machine.generation)))
    _ = machine.configured(success: true, generation: machine.generation)
    let fallback = machine.devicesChanged(["a"], preferred: "b")
    #expect(!fallback.contains { if case .setPreferred = $0 { return true }; return false })
    #expect(fallback.contains(.configure(device: "a", generation: machine.generation)))
}

@Test func unpluggingTheLastCameraSaysSoAndPluggingOneInStarts() {
    var machine = CameraMirrorMachine()
    _ = machine.open(authorization: .authorized, devices: ["a"], preferred: nil)
    _ = machine.configured(success: true, generation: machine.generation)
    let result22 = machine.devicesChanged([], preferred: nil)
    #expect(result22 == [.stopSession])
    #expect(machine.status == .noCamera)
    let result23 = machine.devicesChanged(["c"], preferred: nil)
    #expect(result23 == [.configure(device: "c", generation: machine.generation)])
    #expect(machine.status == .starting)
    var none = CameraMirrorMachine()
    _ = none.open(authorization: .authorized, devices: [], preferred: nil)
    #expect(none.status == .noCamera)
}

@Test func aFailedOrInterruptedSessionIsUnavailableAndStops() {
    var machine = CameraMirrorMachine()
    _ = machine.open(authorization: .authorized, devices: ["a"], preferred: nil)
    let result24 = machine.configured(success: false, generation: machine.generation)
    #expect(result24 == [.stopSession])
    #expect(machine.status == .unavailable)
    _ = machine.open(authorization: .authorized, devices: ["a"], preferred: nil)
    _ = machine.configured(success: true, generation: machine.generation)
    let result25 = machine.failed(generation: machine.generation - 1)
    #expect(result25.isEmpty)
    let result26 = machine.failed(generation: machine.generation)
    #expect(result26 == [.stopSession])
    #expect(machine.status == .unavailable)
}
