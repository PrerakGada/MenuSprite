import AppKit
import Foundation
import Testing
@testable import IslandKit

// MARK: Catalogue and arrangement

@Test func everyToolHasAnActivationContractAndAnIconThatExists() {
    for tool in IslandBuiltInTool.allCases {
        #expect(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil) != nil, "\(tool.symbol)")
        #expect(!tool.title.isEmpty)
    }
    #expect(IslandBuiltInTool.keepAwake.activation == .toggle)
    #expect(IslandBuiltInTool.speedTest.activation == .host)
    #expect(IslandBuiltInTool.appPanel.activation == .islandPage)
    for tool in [IslandBuiltInTool.commandBar, .monitoring, .batteryPower, .aiAccounts, .permissions, .menuBarSpacing] {
        #expect(tool.activation == .dismissThenAct(delay: 0.15))
    }
    #expect(IslandTool.app("/Applications/Safari.app").activation == .dismissThenAct(delay: 0.15))
}

@Test func theStandardOrderIsMenuSpritesOwnToolsWithNothingHidden() {
    let arrangement = IslandToolArrangement.standard
    #expect(arrangement.visible == IslandBuiltInTool.allCases.map(IslandTool.builtIn))
    #expect(arrangement.hidden.isEmpty)
    #expect(arrangement.visible.first == .builtIn(.keepAwake))
}

@Test func savedOrderDropsUnknownIdsAndDuplicatesAndAppendsNewToolsAtTheEnd() {
    let arrangement = IslandToolArrangement(
        order: ["speedTest", "cleaner", "speedTest", "app:/Applications/Safari.app", "app:relative.app", "keepAwake"],
        hidden: ["permissions", "unknown"])
    let expected: [IslandTool] = [.builtIn(.speedTest), .app("/Applications/Safari.app"), .builtIn(.keepAwake)]
        + IslandBuiltInTool.allCases.filter { $0 != .speedTest && $0 != .keepAwake }.map(IslandTool.builtIn)
    #expect(arrangement.order == expected)
    #expect(arrangement.hidden == [.permissions])
    #expect(!arrangement.visible.contains(.builtIn(.permissions)))
    // Storage round-trips.
    let again = IslandToolArrangement(order: arrangement.storedOrder, hidden: arrangement.storedHidden)
    #expect(again == arrangement)
}

@Test func minusHidesABuiltInToolInPlaceAndUnpinsAnApp() {
    var arrangement = IslandToolArrangement.standard
    let step1 = arrangement.pin(app: "/Applications/Notes.app")
    #expect(step1)
    let step2 = arrangement.pin(app: "/Applications/Notes.app")
    #expect(!step2, "pinning twice is refused")
    let step3 = arrangement.pin(app: "/Applications/Notes")
    #expect(!step3, "only app bundles can be pinned")
    arrangement.remove(.builtIn(.speedTest))
    #expect(arrangement.hiddenTools == [.speedTest])
    #expect(!arrangement.visible.contains(.builtIn(.speedTest)))
    arrangement.addBack(.speedTest)
    #expect(arrangement.visible[1] == .builtIn(.speedTest), "added back where it was")
    arrangement.remove(.app("/Applications/Notes.app"))
    #expect(arrangement.pinnedApps.isEmpty)
}

@Test func dragMovesATileIntoItsTargetsPlace() {
    var arrangement = IslandToolArrangement.standard
    arrangement.move(.builtIn(.keepAwake), to: .builtIn(.commandBar))
    #expect(Array(arrangement.order.prefix(3)) == [.builtIn(.speedTest), .builtIn(.commandBar), .builtIn(.keepAwake)])
    arrangement.move(.builtIn(.keepAwake), to: .builtIn(.speedTest))
    #expect(arrangement.order == IslandToolArrangement.standard.order)
}

// MARK: Launcher rules

private let tiles: [IslandTool] = [.builtIn(.keepAwake), .builtIn(.speedTest), .builtIn(.commandBar), .builtIn(.appPanel),
                                   .app("/Applications/Safari.app")]

@Test func toggleToolsChangeInPlaceWithoutDismissingOrHosting() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    let step4 = launcher.activate(.builtIn(.keepAwake))
    #expect(step4 == .toggle(.keepAwake))
    #expect(launcher.hosted == nil)
}

@Test func dismissThenActToolsDismissFirstAndActOnceAfterTheirDelay() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    let step5 = launcher.activate(.builtIn(.commandBar))
    #expect(step5 == .dismissThenAct(.builtIn(.commandBar), delay: 0.15))
    let step6 = launcher.activate(.app("/Applications/Safari.app"))
    #expect(step6 == .dismissThenAct(.app("/Applications/Safari.app"), delay: 0.15))
    #expect(launcher.hosted == nil)
}

@Test func utilityToolsOnlyOpenTheirUtility() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    let step7 = launcher.activate(.builtIn(.speedTest))
    #expect(step7 == .host(.speedTest))
    #expect(launcher.hosted == .speedTest)
    #expect(launcher.holdsSurface)
}

@Test func theAppPanelSwitchesTheIslandPageWithNoCloseAndReopen() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    let step8 = launcher.activate(.builtIn(.appPanel))
    #expect(step8 == .islandPage(.appPanel))
}

@Test func inEditModeNoTileActivates() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    launcher.setEditing(true)
    #expect(launcher.holdsSurface)
    for tool in tiles { let step9 = launcher.activate(tool); #expect(step9 == nil) }
    let step10 = launcher.activateSelection()
    #expect(step10 == nil)
    #expect(launcher.hosted == nil)
}

@Test func aNewPresentationResetsEditControlsAndSelectsTheFirstTile() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    launcher.select(3)
    launcher.setEditing(true)
    launcher.present()
    #expect(!launcher.editing)
    #expect(launcher.selection == 0)
    #expect(launcher.presentation == 1)
}

@Test func returnRightAfterPresentationActivatesTheFirstTile() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    launcher.present()
    let step11 = launcher.activateSelection()
    #expect(step11 == .toggle(.keepAwake))
}

@Test func reopeningPreservesAWorkingUtilityWhileItsFeatureIsAvailable() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    _ = launcher.activate(.builtIn(.speedTest))
    launcher.present()
    #expect(launcher.hosted == .speedTest)
    // Hiding the tile is not removing the feature.
    launcher.update(tools: tiles.filter { $0 != .builtIn(.speedTest) }, hostable: [.speedTest])
    #expect(launcher.hosted == .speedTest)
}

@Test func removingAFeatureClearsItsUtilityEvenWhileNothingIsOnScreen() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    _ = launcher.activate(.builtIn(.speedTest))
    // Removed while closed: no presentation in between.
    launcher.update(tools: tiles, hostable: [])
    #expect(launcher.hosted == nil)
    launcher.present()
    #expect(launcher.hosted == nil, "a utility removed while closed does not return")
    let step12 = launcher.host(.speedTest)
    #expect(!step12)
    let step13 = launcher.activate(.builtIn(.speedTest))
    #expect(step13 == nil)
}

@Test func aStaleTileCannotActivateARemovedTool() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    launcher.update(tools: tiles.filter { $0 != .builtIn(.commandBar) }, hostable: [.speedTest])
    let step14 = launcher.activate(.builtIn(.commandBar))
    #expect(step14 == nil)
}

@Test func anEmptyLauncherHasNoSelectionAndReturnDoesNothing() {
    var launcher = IslandToolLauncher(tools: [], hostable: [.speedTest])
    launcher.present()
    #expect(launcher.selection == nil)
    let step15 = launcher.activateSelection()
    #expect(step15 == nil)
    launcher.update(tools: tiles, hostable: [.speedTest])
    launcher.update(tools: [], hostable: [.speedTest])
    #expect(launcher.selection == nil)
}

@Test func escapePeelsUtilityThenEditModeThenHides() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    _ = launcher.activate(.builtIn(.speedTest))
    let step16 = launcher.escape()
    #expect(step16)
    #expect(launcher.hosted == nil)
    launcher.setEditing(true)
    let step17 = launcher.escape()
    #expect(step17)
    #expect(!launcher.editing)
    let step18 = launcher.escape()
    #expect(!step18, "nothing left: the launcher hides")
}

@Test func editModeCannotStartOverAHostedUtilityAndHostingEndsEditing() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    _ = launcher.activate(.builtIn(.speedTest))
    launcher.setEditing(true)
    #expect(!launcher.editing)
    launcher.closeUtility()
    launcher.setEditing(true)
    let step19 = launcher.host(.speedTest)
    #expect(step19)
    #expect(!launcher.editing)
}

@Test func selectionFollowsItsTileWhenTheListChanges() {
    var launcher = IslandToolLauncher(tools: tiles, hostable: [.speedTest])
    launcher.select(2)
    launcher.update(tools: Array(tiles.dropFirst()), hostable: [.speedTest])
    #expect(launcher.selectedTool == .builtIn(.commandBar))
    launcher.update(tools: [.builtIn(.keepAwake)], hostable: [.speedTest])
    #expect(launcher.selection == 0)
}

// MARK: Rail geometry and arrows

@Test func railTilesAreSeventySixByseventyTwoAndRowsFitTheBudget() {
    // Spacious (504 pt): six across; nine tools make two rows.
    let spacious = IslandToolRail(count: 9, width: 504, budget: 264)
    #expect(spacious.columns == 6)
    #expect(spacious.rows == 2)
    #expect(spacious.fits)
    #expect(spacious.height == 150)
    // Compact (424 pt, 180 budget): five across, two rows at most.
    let compact = IslandToolRail(count: 9, width: 424, budget: 180)
    #expect(compact.columns == 5)
    #expect(compact.rows == 2)
    #expect(compact.fits)
    let crowded = IslandToolRail(count: 12, width: 424, budget: 180)
    #expect(crowded.rows == 2)
    #expect(!crowded.fits, "extra tiles continue sideways")
    #expect(crowded.scrollColumns == 6)
    #expect(IslandToolRail(count: 0, width: 504, budget: 264).height == 140)
    #expect(IslandToolRail(count: 0, width: 504, budget: 120).height == 120)
}

@Test func aFittingRailReadsInRowsAndAScrollingRailFillsColumnByColumn() {
    let fitting = IslandToolRail(count: 9, width: 424, budget: 180)
    #expect(fitting.readingRows == [0..<5, 5..<9])
    let scrolling = IslandToolRail(count: 7, width: 170, budget: 180)
    #expect(scrolling.columns == 2)
    #expect(!scrolling.fits)
    #expect(scrolling.scrollingRows == [[0, 2, 4, 6], [1, 3, 5]])
}

@Test func arrowsFollowRowsWhileEveryColumnFitsAndStopAtTheEnds() {
    let rail = IslandToolRail(count: 9, width: 424, budget: 180)  // rows of 5 and a centred 4
    #expect(rail.move(0, .left) == 0)
    #expect(rail.move(4, .right) == 5, "right continues into the next row")
    #expect(rail.move(8, .right) == 8)
    #expect(rail.move(2, .up) == 2)
    // Column 2 of 5 sits over the centred row's third tile (index 7); column 0 over its first.
    #expect(rail.move(2, .down) == 7)
    #expect(rail.move(0, .down) == 5)
    #expect(rail.move(4, .down) == 8)
    #expect(rail.move(5, .up) == 1)
    #expect(rail.move(8, .down) == 8)
}

@Test func arrowsFollowColumnsOnceTheRailScrolls() {
    let rail = IslandToolRail(count: 7, width: 170, budget: 180)  // two rows, filled by column
    #expect(rail.move(0, .down) == 1)
    #expect(rail.move(1, .down) == 2, "down continues into the next column")
    #expect(rail.move(0, .right) == 2)
    #expect(rail.move(5, .right) == 6, "the short last column takes the last tile")
    #expect(rail.move(6, .right) == 6)
    #expect(rail.move(2, .left) == 0)
    #expect(rail.move(0, .left) == 0)
    #expect(rail.move(0, .up) == 0)
    #expect(rail.move(6, .down) == 6)
}

@Test func theFloatingGridIsThreeColumnsClampedWithDigitsByPosition() {
    #expect(IslandToolGrid.move(0, .left, count: 7) == 0)
    #expect(IslandToolGrid.move(2, .right, count: 7) == 2)
    #expect(IslandToolGrid.move(1, .down, count: 7) == 4)
    #expect(IslandToolGrid.move(4, .down, count: 7) == 6, "below the short row lands on its last tile")
    #expect(IslandToolGrid.move(6, .down, count: 7) == 6)
    #expect(IslandToolGrid.move(1, .up, count: 7) == 1)
    #expect(IslandToolGrid.index(forDigit: 1, count: 7) == 0)
    #expect(IslandToolGrid.index(forDigit: 7, count: 7) == 6)
    #expect(IslandToolGrid.index(forDigit: 8, count: 7) == nil)
    #expect(IslandToolGrid.index(forDigit: 0, count: 7) == nil)
}

@Test func theToolsPanelSitsWithThirtyEightPercentOfTheFreeSpaceAboveIt() {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    let frame = IslandToolPlacement.toolsPanel(size: CGSize(width: 420, height: 350), visible: visible)
    #expect(frame.midX == visible.midX)
    #expect(abs((visible.maxY - frame.maxY) - 600 * 0.38) < 0.001)
    #expect(abs((frame.minY - visible.minY) - 600 * 0.62) < 0.001)
    // Re-fitting keeps the top edge and the centre.
    let taller = IslandToolPlacement.refit(frame, to: CGSize(width: 420, height: 500), visible: visible)
    #expect(taller.maxY == frame.maxY)
    #expect(taller.midX == frame.midX)
}

@Test func theCommandBarTopSitsTwentyEightPercentDownAndAlwaysStaysOnScreen() {
    let visible = CGRect(x: 100, y: 0, width: 1400, height: 1000)
    let frame = IslandToolPlacement.commandBar(height: 300, visible: visible)
    #expect(frame.width == 560)
    #expect(frame.midX == visible.midX)
    #expect(frame.maxY == visible.maxY - 280)
    for screen in [CGRect(x: 0, y: 0, width: 500, height: 300), CGRect(x: -800, y: 200, width: 640, height: 480),
                   CGRect(x: 0, y: 0, width: 1400, height: 400)] {
        let placed = IslandToolPlacement.commandBar(height: 52 + 452, visible: screen)
        #expect(screen.insetBy(dx: 16, dy: 16).contains(placed), "\(screen) → \(placed)")
    }
}

// MARK: Command Bar ranking and keys

@Test func searchFoldsCaseAccentsWidthInvisibleCharactersAndSpaces() {
    #expect(CommandMatcher.fold("  Café\u{200B}  Crème ") == "cafe creme")
    #expect(CommandMatcher.fold("ＳＡＦＡＲＩ") == "safari")
    let cafe = CommandCandidate(title: "Café Crème")
    #expect(CommandMatcher.score(cafe, query: "CAFE   creme") != nil)
    #expect(CommandMatcher.score(cafe, query: "cr\u{200D}eme cafe") != nil, "tokens match in any order")
}

@Test func everyTypedWordMustLand() {
    let code = CommandCandidate(title: "Visual Studio Code")
    #expect(CommandMatcher.score(code, query: "studio code") != nil)
    #expect(CommandMatcher.score(code, query: "studio xcode") == nil)
    #expect(CommandMatcher.score(code, query: "   ") == nil)
}

@Test func wordScoresAndTitleBonusesFollowTheSpec() {
    let notes = CommandCandidate(title: "Notes")
    #expect(CommandMatcher.score(notes, query: "notes") == 140 + 1200)
    #expect(CommandMatcher.score(notes, query: "no") == 80 + 900)
    #expect(CommandMatcher.score(notes, query: "ote") == 44 + 700)
    let spacing = CommandCandidate(title: "Menu bar spacing", keywords: ["padding"])
    #expect(CommandMatcher.score(spacing, query: "padding") == 140, "keywords match without a title bonus")
    #expect(CommandMatcher.score(spacing, query: "bar spa") == 140 + 80 + 700)
}

@Test func rankingPrefersTheBestMatchKeepsTiesInOrderAndReturnsAtMostTwelve() {
    let candidates = ["Mail", "Maps", "Messages", "Music", "Mission Control"].map { CommandCandidate(title: $0) }
    #expect(CommandMatcher.rank(candidates, query: "m") == [0, 1, 2, 3, 4])
    #expect(CommandMatcher.rank(candidates, query: "mail").first == 0)
    #expect(CommandMatcher.rank(candidates, query: "control") == [4])
    let many = (0..<30).map { CommandCandidate(title: "App \($0)") }
    #expect(CommandMatcher.rank(many, query: "app").count == 12)
    #expect(CommandMatcher.rank(candidates, query: "").isEmpty, "an empty field shows the action list instead")
}

@Test func commandBarKeysMoveRunSwallowAndPassThroughWhileComposing() {
    #expect(CommandBarKeys.action(.up) == .moveUp)
    #expect(CommandBarKeys.action(.down) == .moveDown)
    #expect(CommandBarKeys.action(.character("p"), control: true) == .moveUp)
    #expect(CommandBarKeys.action(.character("n"), control: true) == .moveDown)
    #expect(CommandBarKeys.action(.returnKey) == .run)
    #expect(CommandBarKeys.action(.escape) == .escape)
    #expect(CommandBarKeys.action(.character("1"), command: true) == .runRow(0))
    #expect(CommandBarKeys.action(.character("9"), command: true) == .runRow(8))
    #expect(CommandBarKeys.action(.character("0"), command: true) == .passThrough)
    for letter in ["q", "w", "m", "h", "Q"] {
        #expect(CommandBarKeys.action(.character(letter), command: true) == .swallow)
        #expect(CommandBarKeys.action(.character(letter), command: true, option: true) == .swallow)
    }
    #expect(CommandBarKeys.action(.character("v"), command: true) == .passThrough, "paste still works")
    #expect(CommandBarKeys.action(.character("a")) == .passThrough)
    for key in [CommandBarKey.up, .down, .returnKey, .escape, .character("q")] {
        #expect(CommandBarKeys.action(key, command: true, composing: true) == .passThrough)
    }
}

@Test func commandBarSelectionWrapsAtBothEnds() {
    #expect(CommandBarKeys.move(0, by: -1, count: 5) == 4)
    #expect(CommandBarKeys.move(4, by: 1, count: 5) == 0)
    #expect(CommandBarKeys.move(nil, by: 1, count: 5) == 0)
    #expect(CommandBarKeys.move(nil, by: -1, count: 5) == 4)
    #expect(CommandBarKeys.move(2, by: 1, count: 0) == nil)
}

@Test func onlyTheLatestVisiblePresentationReceivesBackgroundResults() {
    var presentations = CommandBarPresentations()
    let first = presentations.begin()
    #expect(presentations.accepts(first))
    presentations.end()
    #expect(!presentations.accepts(first), "closing cancels deferred work")
    let second = presentations.begin()
    #expect(!presentations.accepts(first))
    #expect(presentations.accepts(second))
}

@Test func appScanKeepsOneEntryPerBundleNeverItselfAndSkipsHelpersInsidePackages() {
    let entries = [CommandAppList.Entry(path: "/Applications/Safari.app", name: "Safari"),
                   .init(path: "/Applications/MenuSprite.app", name: "MenuSprite"),
                   .init(path: "/System/Applications/Notes.app", name: "Notes"),
                   .init(path: "/applications/safari.app", name: "Safari")]
    let apps = CommandAppList.unique(entries, excluding: "/Applications/MenuSprite.app")
    #expect(apps.map(\.name) == ["Notes", "Safari"])
    #expect(CommandAppList.isInsidePackage("/Applications/Xcode.app/Contents/Applications/Instruments.app"))
    #expect(!CommandAppList.isInsidePackage("/Applications/Utilities/Terminal.app"))
}

// MARK: Speed test

@Test func throughputIsBytesTimesEightOverSecondsInMegabits() {
    #expect(SpeedTestMath.megabitsPerSecond(bytes: 62_500_000, seconds: 5) == 100)
    #expect(SpeedTestMath.megabitsPerSecond(bytes: 1_000_000, seconds: 0.5) == 16)
    #expect(SpeedTestMath.megabitsPerSecond(bytes: 0, seconds: 5) == nil)
    #expect(SpeedTestMath.megabitsPerSecond(bytes: 100, seconds: 0) == nil)
    #expect(SpeedTestMath.format(482.6) == "483")
    #expect(SpeedTestMath.format(100) == "100")
    #expect(SpeedTestMath.format(99.94) == "99.9")
    #expect(SpeedTestMath.format(7.25) == "7.2" || SpeedTestMath.format(7.25) == "7.3")
}

@Test func latencyIsTheMedianAndJitterTheMeanChangeBetweenRoundTrips() {
    let odd = SpeedTestMath.latency([20, 12, 14, 30, 13])
    #expect(odd?.median == 14)
    #expect(odd?.jitter == 10.75)
    let even = SpeedTestMath.latency([10, 20, 30, 40])
    #expect(even?.median == 25)
    #expect(even?.jitter == 10)
    #expect(SpeedTestMath.latency([9])?.jitter == 0)
    #expect(SpeedTestMath.latency([]) == nil)
}

/// Drives a machine and keeps every command it issued, so a test can check what was requested.
private struct SpeedDriver {
    var machine = SpeedTestMachine()
    var commands: [SpeedTestMachine.Command] = []
    var fired: Set<Int> = []

    mutating func send(_ event: SpeedTestMachine.Event) {
        if case .timeBoxFired(let id, _, _) = event, scheduled.contains(id) { fired.insert(id) }
        commands += machine.handle(event)
    }

    var lastRequest: Int {
        for command in commands.reversed() {
            switch command {
            case .requestLatency(let id), .requestDownload(let id), .startUpload(let id): return id
            default: continue
            }
        }
        return -1
    }

    var lastBox: Int {
        for case .scheduleTimeBox(let id, _) in commands.reversed() { return id }
        return -1
    }

    var scheduled: Set<Int> { Set(commands.compactMap { if case .scheduleTimeBox(let id, _) = $0 { id } else { nil } }) }
    var cancelledBoxes: Set<Int> { Set(commands.compactMap { if case .cancelTimeBox(let id) = $0 { id } else { nil } }) }
    var everyBoxClosed: Bool { scheduled.subtracting(fired).subtracting(cancelledBoxes).isEmpty }
    var requestedDownload: Bool { commands.contains { if case .requestDownload = $0 { true } else { false } } }
    var requestedUpload: Bool { commands.contains { if case .startUpload = $0 { true } else { false } } }

    mutating func passLatency(_ roundTrips: [Double] = [0.020, 0.012, 0.014, 0.030, 0.013]) {
        send(.start)
        for roundTrip in roundTrips { send(.latency(lastRequest, status: 200, roundTrip: roundTrip)) }
    }

    /// One accepted chunk of 25 MB that completes, then five seconds pass with 12.5 MB of the next in flight.
    mutating func passDownload() {
        send(.response(lastRequest, status: 200, at: 10))
        send(.completed(lastRequest, failed: false, bytes: 25_000_000, at: 12))
        send(.response(lastRequest, status: 200, at: 12.1))
        send(.timeBoxFired(lastBox, inFlight: 12_500_000, at: 15))
    }
}

@Test func successCompletesEveryPhaseAndPublishesAllThreeReadings() {
    var driver = SpeedDriver()
    driver.passLatency()
    #expect(driver.machine.status == .running(.download))
    driver.passDownload()
    #expect(driver.machine.status == .running(.upload))
    driver.send(.sending(driver.lastRequest, bytes: 65_536, at: 15.2))
    driver.send(.timeBoxFired(driver.lastBox, inFlight: 65_536 + 12_500_000, at: 20.2))
    guard case .finished(let result) = driver.machine.status else { Issue.record("not finished"); return }
    #expect(result.download == 60, "37.5 MB in 5 s")
    #expect(result.upload == 20, "12.5 MB in 5 s, counted from the first bytes sent")
    #expect(result.latency == SpeedTestLatency(median: 14, jitter: 10.75))
    #expect(driver.everyBoxClosed)
}

@Test func anUploadThatFinishesBeforeItsTimeBoxCancelsTheBox() {
    var driver = SpeedDriver()
    driver.passLatency()
    driver.passDownload()
    let upload = driver.lastRequest
    driver.send(.sending(upload, bytes: 0, at: 15))
    driver.send(.response(upload, status: 200, at: 18))
    driver.send(.completed(upload, failed: false, bytes: 100_000_000, at: 19))
    guard case .finished(let result) = driver.machine.status else { Issue.record("not finished"); return }
    #expect(result.upload == 200)
    #expect(driver.everyBoxClosed)
}

@Test func eachPhaseCanFailAndReportsWhich() {
    var latency = SpeedDriver()
    latency.send(.start)
    latency.send(.latency(latency.lastRequest, status: nil, roundTrip: nil))
    #expect(latency.machine.status == .failed(.latency))

    var download = SpeedDriver()
    download.passLatency()
    download.send(.completed(download.lastRequest, failed: true, bytes: 0, at: 10))
    #expect(download.machine.status == .failed(.download))

    var upload = SpeedDriver()
    upload.passLatency()
    upload.passDownload()
    upload.send(.completed(upload.lastRequest, failed: true, bytes: 0, at: 16))
    #expect(upload.machine.status == .failed(.upload))
    for driver in [latency, download, upload] { #expect(driver.machine.status.isTerminal) }
}

@Test func anInvalidLatencyResponseIsNeverMeasured() {
    var driver = SpeedDriver()
    driver.send(.start)
    driver.send(.latency(driver.lastRequest, status: 200, roundTrip: 0.01))
    driver.send(.latency(driver.lastRequest, status: 404, roundTrip: 0.011))
    #expect(driver.machine.status == .failed(.latency))
    #expect(!driver.requestedDownload, "it stops at the failed phase")
    #expect(driver.scheduled.isEmpty, "the failure comes before any time box")
}

@Test func aFailedDownloadResponseSchedulesNoTimeBoxAndRequestsNothingMore() {
    var driver = SpeedDriver()
    driver.passLatency()
    driver.send(.response(driver.lastRequest, status: 503, at: 10))
    #expect(driver.machine.status == .failed(.download))
    #expect(driver.scheduled.isEmpty)
    #expect(!driver.requestedUpload)
    #expect(driver.commands.last == .cancelTransfer)
}

@Test func anErrorBodyIsNeverCountedAsDownloadTraffic() {
    var driver = SpeedDriver()
    driver.passLatency()
    driver.send(.response(driver.lastRequest, status: 200, at: 10))
    driver.send(.completed(driver.lastRequest, failed: false, bytes: 25_000_000, at: 12))
    // The next chunk has no accepted response yet when the box closes: its bytes are not traffic.
    driver.send(.timeBoxFired(driver.lastBox, inFlight: 9_999_999, at: 15))
    driver.send(.sending(driver.lastRequest, bytes: 0, at: 15))
    driver.send(.timeBoxFired(driver.lastBox, inFlight: 12_500_000, at: 20))
    guard case .finished(let result) = driver.machine.status else { Issue.record("not finished"); return }
    #expect(result.download == 40, "only the 25 MB accepted chunk counts")
}

@Test func noUploadResultIsPublishedAfterARejection() {
    var driver = SpeedDriver()
    driver.passLatency()
    driver.passDownload()
    let upload = driver.lastRequest
    driver.send(.sending(upload, bytes: 0, at: 15))
    let box = driver.lastBox
    driver.send(.response(upload, status: 413, at: 15.5))
    #expect(driver.machine.status == .failed(.upload))
    driver.send(.completed(upload, failed: false, bytes: 1_000_000, at: 16))
    driver.send(.timeBoxFired(box, inFlight: 1_000_000, at: 20))
    #expect(driver.machine.status == .failed(.upload))
    #expect(driver.everyBoxClosed)
}

@Test func cancellingStopsTheTransferCancelsTheBoxAndStaleCallbacksChangeNothing() {
    var driver = SpeedDriver()
    driver.passLatency()
    driver.send(.response(driver.lastRequest, status: 200, at: 10))
    let box = driver.lastBox
    let request = driver.lastRequest
    driver.send(.cancel)
    #expect(driver.machine.status == .cancelled)
    #expect(driver.commands.suffix(2) == [.cancelTransfer, .cancelTimeBox(box)])
    let issued = driver.commands.count
    driver.send(.timeBoxFired(box, inFlight: 5_000_000, at: 15))
    driver.send(.completed(request, failed: false, bytes: 90_000_000, at: 14))
    driver.send(.start)
    #expect(driver.machine.status == .cancelled)
    #expect(driver.commands.count == issued, "a terminal test issues nothing")
    #expect(driver.everyBoxClosed)
}

@Test func callbacksFromAnEarlierRequestAreIgnored() {
    var driver = SpeedDriver()
    driver.send(.start)
    let first = driver.lastRequest
    driver.send(.latency(first, status: 200, roundTrip: 0.01))
    driver.send(.latency(first, status: 500, roundTrip: 0.01))
    #expect(driver.machine.status == .running(.latency))
}

@Test func aDownloadThatMovesNothingFails() {
    var driver = SpeedDriver()
    driver.passLatency()
    driver.send(.response(driver.lastRequest, status: 200, at: 10))
    driver.send(.timeBoxFired(driver.lastBox, inFlight: 0, at: 15))
    #expect(driver.machine.status == .failed(.download))
    #expect(!driver.requestedUpload)
}

@Test func everyScriptedCaseReachesATerminalState() {
    let scripts: [(inout SpeedDriver) -> Void] = [
        { $0.passLatency(); $0.passDownload(); $0.send(.sending($0.lastRequest, bytes: 0, at: 15)); $0.send(.timeBoxFired($0.lastBox, inFlight: 1_000_000, at: 20)) },
        { $0.send(.start); $0.send(.latency($0.lastRequest, status: 301, roundTrip: 0.01)) },
        { $0.passLatency(); $0.send(.response($0.lastRequest, status: 403, at: 1)) },
        { $0.passLatency(); $0.passDownload(); $0.send(.response($0.lastRequest, status: 500, at: 16)) },
        { $0.passLatency(); $0.passDownload(); $0.send(.cancel) },
        { $0.send(.start); $0.send(.cancel) },
    ]
    for script in scripts {
        var driver = SpeedDriver()
        script(&driver)
        #expect(driver.machine.status.isTerminal, "\(driver.machine.status)")
        #expect(driver.everyBoxClosed)
    }
}

// MARK: Streamed upload body

/// Reads a stream the way URLSession does: scheduled on a run loop, reading when bytes arrive.
private final class ScheduledReader: NSObject, StreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = [UInt8](repeating: 0xFF, count: 32 * 1024)
    private var count: Int64 = 0
    private var sawNonZero = false
    private var ended = false

    var result: (total: Int64, nonZero: Bool, ended: Bool) { lock.withLock { (count, sawNonZero, ended) } }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        guard let input = stream as? InputStream else { return }
        if event.contains(.hasBytesAvailable) {
            while input.hasBytesAvailable {
                let read = input.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                let nonZero = buffer[0..<read].contains { $0 != 0 }
                lock.withLock { count += Int64(read); sawNonZero = sawNonZero || nonZero }
            }
        }
        if event.contains(.endEncountered) || event.contains(.errorOccurred) { lock.withLock { ended = true } }
    }
}

@Test func theUploadBodyStreamsExactlyItsLengthOfZerosThroughASmallBuffer() {
    let length: Int64 = 3_000_000 + 17
    let body = ZeroBodyStream(length: length, bufferSize: 64 * 1024)
    let reader = ScheduledReader()
    let input = body.input
    let thread = Thread {
        input.delegate = reader
        input.schedule(in: .current, forMode: .default)
        input.open()
        let deadline = Date().addingTimeInterval(10)
        while !reader.result.ended, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        input.close()
    }
    thread.start()
    let deadline = Date().addingTimeInterval(10)
    while !reader.result.ended, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    let result = reader.result
    #expect(result.ended)
    #expect(result.total == length)
    #expect(!result.nonZero)
    body.close()
}
