import CoreGraphics
import Foundation
import Testing
@testable import IslandKit

// Recent captures, the capture controls and the capture tools (tools spec §3, §7.2–7.3; shell spec §2, §6).

// MARK: Capture-controls strip (inert window, value clock)

@Test func controlsStayOpenForThreeSecondsThenCollapseWithTheCaptureStillRunning() {
    var strip = CaptureControlsStrip(session: 1, now: 0)
    let changed1 = strip.tick(now: 2.9, session: 1)
    #expect(!changed1)
    #expect(strip.phase == .expanded)
    strip.pointer(inside: false, now: 1)  // moving about outside
    let changed2 = strip.tick(now: 3, session: 1)
    #expect(changed2)
    #expect(strip.phase == .collapsed)
    let controls = CGRect(x: 0, y: 0, width: 560, height: 200)
    let target = CGRect(x: 240, y: 0, width: 80, height: 32)
    #expect(strip.takesMouse(at: CGPoint(x: 280, y: 16), controls: controls, target: target))
}

@Test func movingOutsideDoesNotPostponeTheCollapse() {
    var strip = CaptureControlsStrip(session: 1, now: 0)
    for t in stride(from: 0.2, to: 3.0, by: 0.4) { strip.pointer(inside: false, now: t) }
    let changed3 = strip.tick(now: 3, session: 1)
    #expect(changed3)
}

@Test func activatingTheTargetReopensTheControls() {
    var strip = CaptureControlsStrip(session: 1, now: 0)
    strip.tick(now: 3, session: 1)
    strip.activateTarget(now: 4)
    #expect(strip.phase == .expanded)
    #expect(strip.nextDeadline == 7)
}

@Test func pointerOverTheControlsTakesClicksAndKeepsThemOpenWhileInUse() {
    var strip = CaptureControlsStrip(session: 1, now: 0)
    let controls = CGRect(x: 0, y: 0, width: 560, height: 200)
    let target = CGRect(x: 240, y: 0, width: 80, height: 32)
    strip.pointer(inside: true, now: 0.5)
    #expect(strip.takesMouse(at: CGPoint(x: 20, y: 150), controls: controls, target: target))
    let changed4 = strip.tick(now: 3, session: 1)
    #expect(!changed4)
    let changed5 = strip.tick(now: 6, session: 1)
    #expect(!changed5)
    #expect(strip.phase == .expanded)
    strip.pointer(inside: false, now: 6.5)
    let changed6 = strip.tick(now: 9.4, session: 1)
    #expect(!changed6)
    let changed7 = strip.tick(now: 9.5, session: 1)
    #expect(changed7)
}

@Test func manualCollapseUnderAStationaryPointerDoesNotReopen() {
    var strip = CaptureControlsStrip(session: 1, now: 0)
    strip.pointer(inside: true, now: 0.5)
    strip.collapse()
    strip.pointer(inside: true, now: 0.6)  // the same resting pointer, now over the target
    let changed8 = strip.tick(now: 1.6, session: 1)
    #expect(!changed8)
    #expect(strip.phase == .collapsed)
    // Leaving and coming back is a real hover.
    strip.pointer(inside: false, now: 2)
    strip.pointer(inside: true, now: 2.1)
    let changed9 = strip.tick(now: 2.35, session: 1)
    #expect(changed9)
    #expect(strip.phase == .expanded)
}

@Test func duringTheCollapseOnlyTheTargetTakesClicks() {
    var strip = CaptureControlsStrip(session: 1, now: 0)
    strip.collapse()
    let controls = CGRect(x: 0, y: 0, width: 560, height: 200)
    let target = CGRect(x: 240, y: 0, width: 80, height: 32)
    #expect(!strip.takesMouse(at: CGPoint(x: 20, y: 150), controls: controls, target: target))
    #expect(strip.takesMouse(at: CGPoint(x: 250, y: 10), controls: controls, target: target))
    // Leaving the target returns clicks to the selection surface.
    #expect(!strip.takesMouse(at: CGPoint(x: 330, y: 10), controls: controls, target: target))
}

@Test func aQuickPassDoesNotReopenButAQuarterSecondDoes() {
    var strip = CaptureControlsStrip(session: 1, now: 0)
    strip.tick(now: 3, session: 1)
    strip.pointer(inside: true, now: 4)
    strip.pointer(inside: false, now: 4.2)
    let changed10 = strip.tick(now: 4.3, session: 1)
    #expect(!changed10)
    #expect(strip.phase == .collapsed)
    strip.pointer(inside: true, now: 5)
    let changed11 = strip.tick(now: 5.2, session: 1)
    #expect(!changed11)
    let changed12 = strip.tick(now: 5.25, session: 1)
    #expect(changed12)
    #expect(strip.phase == .expanded)
}

@Test func focusedControlPreventsCollapseAndLosingFocusRestoresThreeSeconds() {
    var strip = CaptureControlsStrip(session: 1, now: 0)
    strip.focus(true, now: 0.1)
    let changed13 = strip.tick(now: 3, session: 1)
    #expect(!changed13)
    let changed14 = strip.tick(now: 6, session: 1)
    #expect(!changed14)
    strip.focus(false, now: 6)
    #expect(strip.nextDeadline == 9)
    let changed15 = strip.tick(now: 9, session: 1)
    #expect(changed15)
}

@Test func anOpenMenuPreventsCollapse() {
    var strip = CaptureControlsStrip(session: 1, now: 0)
    strip.menu(true, now: 1)
    let changed16 = strip.tick(now: 3, session: 1)
    #expect(!changed16)
    strip.menu(false, now: 5)
    let changed17 = strip.tick(now: 8, session: 1)
    #expect(changed17)
}

@Test func startingASelectionHidesEverythingAndAnEmptyOneBringsBackOnlyTheTarget() {
    var strip = CaptureControlsStrip(session: 1, now: 0)
    let controls = CGRect(x: 0, y: 0, width: 560, height: 200)
    let target = CGRect(x: 240, y: 0, width: 80, height: 32)
    strip.dragBegan()
    #expect(strip.phase == .hidden)
    #expect(!strip.takesMouse(at: CGPoint(x: 250, y: 10), controls: controls, target: target))
    strip.pointer(inside: true, now: 1)
    strip.activateTarget(now: 1.2)
    let changed18 = strip.tick(now: 5, session: 1)
    #expect(!changed18)
    #expect(strip.phase == .hidden)
    strip.dragEnded()
    #expect(strip.phase == .collapsed)
    #expect(!strip.takesMouse(at: CGPoint(x: 20, y: 150), controls: controls, target: target))
}

@Test func endingTheCaptureLeavesNothingScheduled() {
    var strip = CaptureControlsStrip(session: 1, now: 0)
    strip.tick(now: 3, session: 1)
    strip.pointer(inside: true, now: 3.1)
    #expect(strip.nextDeadline != nil)
    strip.end()
    #expect(strip.nextDeadline == nil)
    let changed19 = strip.tick(now: 10, session: 1)
    #expect(!changed19)
}

@Test func aStaleDeadlineCannotCollapseAReplacementSession() {
    var replacement = CaptureControlsStrip(session: 2, now: 10)
    let changed20 = replacement.tick(now: 13, session: 1)
    #expect(!changed20)
    #expect(replacement.phase == .expanded)
    let changed21 = replacement.tick(now: 13, session: 2)
    #expect(changed21)
}

@Test func controlsGeometryFollowsTheIslandSizes() {
    // Camera 32 + gap 10 + header 28 + spacing 12 + tiles 74 + bottom 16, and 40 more for the audio switches.
    #expect(CaptureControlsGeometry.expandedHeight(cutoutHeight: 32, tool: .screenshot) == 172)
    #expect(CaptureControlsGeometry.expandedHeight(cutoutHeight: 32, tool: .recording) == 212)
    let collapsed = CaptureControlsGeometry.collapsedSize(cutout: IslandCutout(width: 185, height: 32, isPhysical: true))
    #expect(collapsed == CGSize(width: 241, height: 32))
}

// MARK: Hosted preview keyboard

@Test func hostedPreviewKeysNeedEveryCondition() {
    #expect(CapturePreviewKeys.Context().accepts)
    let breakers: [(inout CapturePreviewKeys.Context) -> Void] = [
        { $0.pageVisible = false }, { $0.islandExpanded = false }, { $0.exploreOrPanelShowing = true },
        { $0.chooserActive = true }, { $0.previewCurrent = false }, { $0.textFieldHasFocus = true },
        { $0.sheetAttached = true }, { $0.recordingShortcut = true },
    ]
    for breaker in breakers {
        var context = CapturePreviewKeys.Context()
        breaker(&context)
        #expect(!context.accepts)
    }
}

@Test func previewKeyTable() {
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.e, characters: "e")) == .edit)
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.returnKey, characters: "\r")) == .edit)
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.delete)) == .discard)
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.forwardDelete)) == .discard)
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.delete, command: true)) == .discard)
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.c, characters: "c", command: true)) == .copy)
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.s, characters: "s", command: true)) == .save)
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.w, characters: "w", command: true)) == .close)
}

@Test func escapeClosesWithoutDestroyingAnything() {
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.escape, characters: "\u{1b}")) == .close)
}

@Test func commandWLayoutMatrix() {
    // Latin layout: the typed W, Caps Lock included.
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.w, characters: "W", command: true)) == .close)
    // Dvorak: W typed on another key still closes.
    #expect(CapturePreviewKeys.action(for: .init(keyCode: 43, characters: "w", command: true)) == .close)
    // Non-Latin layout: the physical W key.
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.w, characters: "ц", command: true)) == .close)
    // A Latin layout typing "z" at the W position does not close.
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.w, characters: "z", command: true)) == nil)
    // Never with a second modifier.
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.w, characters: "w", command: true, shift: true)) == nil)
    #expect(CapturePreviewKeys.action(for: .init(keyCode: CaptureKeyCode.w, characters: "w", command: true, option: true)) == nil)
}

// MARK: Chooser keyboard

@Test func navigationKeysPassThrough() {
    let context = CaptureChooserKeys.Context(controlHasFocus: true)
    for code in [CaptureKeyCode.tab, CaptureKeyCode.space, CaptureKeyCode.up, CaptureKeyCode.down] {
        #expect(CaptureChooserKeys.action(for: .init(keyCode: code), context: context) == .passThrough)
    }
}

@Test func returnActivatesTheFocusedControlElseCapturesTheDisplay() {
    let key = CaptureKeyPress(keyCode: CaptureKeyCode.returnKey, characters: "\r")
    #expect(CaptureChooserKeys.action(for: key, context: .init(controlHasFocus: true)) == .activateFocused)
    #expect(CaptureChooserKeys.action(for: key, context: .init()) == .captureDisplay)
    // A text editor keeps its Return.
    #expect(CaptureChooserKeys.action(for: key, context: .init(controlHasFocus: true, textFieldHasFocus: true)) == .passThrough)
}

@Test func spaceMovesTheSelectionDuringADragEvenWithAFocusedControl() {
    let key = CaptureKeyPress(keyCode: CaptureKeyCode.space, characters: " ")
    #expect(CaptureChooserKeys.action(for: key, context: .init(controlHasFocus: true, dragging: true)) == .moveSelection)
}

@Test func escapeCancelsEvenWithAFocusedControl() {
    let key = CaptureKeyPress(keyCode: CaptureKeyCode.escape)
    #expect(CaptureChooserKeys.action(for: key, context: .init(controlHasFocus: true)) == .cancel)
}

@Test func theRRule() {
    #expect(CaptureChooserKeys.action(for: .init(keyCode: CaptureKeyCode.r, characters: "r"), context: .init()) == .repeatRegion)
    #expect(CaptureChooserKeys.action(for: .init(keyCode: CaptureKeyCode.r, characters: "R", shift: true), context: .init()) == .repeatRegion)
    #expect(CaptureChooserKeys.action(for: .init(keyCode: CaptureKeyCode.r, characters: "к"), context: .init()) == .repeatRegion)
    #expect(CaptureChooserKeys.action(for: .init(keyCode: CaptureKeyCode.r, characters: "r", command: true), context: .init()) == .ignore)
    #expect(CaptureChooserKeys.action(for: .init(keyCode: CaptureKeyCode.r, characters: "r", control: true), context: .init()) == .ignore)
    #expect(CaptureChooserKeys.action(for: .init(keyCode: CaptureKeyCode.r, characters: "r", option: true), context: .init()) == .ignore)
}

@Test func numberKeysSwitchInstalledToolsOnly() {
    #expect(CaptureChooserKeys.action(for: .init(keyCode: 18, characters: "1"), context: .init()) == .selectTool(.screenshot))
    #expect(CaptureChooserKeys.action(for: .init(keyCode: 19, characters: "é"), context: .init()) == .selectTool(.recording))
    #expect(CaptureChooserKeys.action(for: .init(keyCode: 20, characters: "3"), context: .init()) == .ignore)
    #expect(CaptureChooserKeys.action(for: .init(keyCode: 19, characters: "2"), context: .init(tools: [.screenshot])) == .ignore)
}

// MARK: Dimming, tools

@Test func dimmingRules() {
    #expect(CaptureDim.amount(controlsInIsland: true, dragging: false) == 0)
    #expect(CaptureDim.amount(controlsInIsland: true, dragging: true) > 0)
    #expect(CaptureDim.amount(controlsInIsland: false, dragging: false) == 0.22)
}

@Test func onlyScreenRecordingShowsTheAudioSwitches() {
    #expect(CaptureTool.recording.showsAudioOptions)
    #expect(!CaptureTool.screenshot.showsAudioOptions)
    #expect(CaptureTool(number: 1) == .screenshot && CaptureTool(number: 2) == .recording && CaptureTool(number: 3) == nil)
}

// MARK: Selection

@Test func aShortPressIsAWindowClickAndTinySelectionsAreIgnored() {
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
    var selection = CaptureDragSelection(start: CGPoint(x: 100, y: 100), bounds: bounds)
    selection.drag(to: CGPoint(x: 102, y: 102))
    #expect(selection.isClick)
    #expect(selection.usableRect == nil)
    selection.drag(to: CGPoint(x: 101.5, y: 105))
    #expect(!selection.isClick)
    #expect(selection.usableRect == nil)  // 1.5 pt wide
    selection.drag(to: CGPoint(x: 300, y: 250))
    #expect(selection.usableRect == CGRect(x: 100, y: 100, width: 200, height: 150))
}

@Test func selectionsAreClampedToTheirDisplay() {
    var selection = CaptureDragSelection(start: CGPoint(x: 1400, y: 900), bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
    selection.drag(to: CGPoint(x: 1700, y: 1200))
    #expect(selection.rect == CGRect(x: 1400, y: 900, width: 112, height: 82))
}

@Test func shiftMakesASquareAndOptionGrowsFromTheCentre() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    var selection = CaptureDragSelection(start: CGPoint(x: 500, y: 500), bounds: bounds)
    selection.drag(to: CGPoint(x: 600, y: 540), square: true)
    #expect(selection.rect == CGRect(x: 500, y: 500, width: 100, height: 100))
    selection.drag(to: CGPoint(x: 600, y: 540), fromCenter: true)
    #expect(selection.rect == CGRect(x: 400, y: 460, width: 200, height: 80))
}

@Test func spaceDragMovesTheSelectionAndKeepsItOnTheDisplay() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    var selection = CaptureDragSelection(start: CGPoint(x: 100, y: 100), bounds: bounds)
    selection.drag(to: CGPoint(x: 300, y: 200))
    selection.drag(to: CGPoint(x: 350, y: 260), moving: true)
    #expect(selection.rect == CGRect(x: 150, y: 160, width: 200, height: 100))
    selection.drag(to: CGPoint(x: 2000, y: 260), moving: true)
    #expect(selection.rect == CGRect(x: 800, y: 160, width: 200, height: 100))
    // Releasing Space resumes resizing from where the pointer is.
    selection.drag(to: CGPoint(x: 2000, y: 400))
    #expect(selection.rect.minX == 800 && selection.rect.maxX == 1000)
}

@Test func windowPickingTakesTheFrontmostOrdinaryWindow() {
    let windows = [
        CaptureWindowInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 33), layer: 25),     // menu bar
        CaptureWindowInfo(id: 2, frame: CGRect(x: 100, y: 100, width: 30, height: 30)),              // too small
        CaptureWindowInfo(id: 3, frame: CGRect(x: 90, y: 90, width: 400, height: 300), alpha: 0),     // invisible
        CaptureWindowInfo(id: 9, frame: CGRect(x: 50, y: 50, width: 800, height: 600)),              // our own
        CaptureWindowInfo(id: 4, frame: CGRect(x: 80, y: 80, width: 500, height: 400)),
        CaptureWindowInfo(id: 5, frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
    ]
    #expect(CaptureWindowPicker.pick(at: CGPoint(x: 110, y: 110), in: windows, excluding: [9])?.id == 4)
    #expect(CaptureWindowPicker.pick(at: CGPoint(x: 10, y: 10), in: windows, excluding: [9])?.id == 5)
    #expect(CaptureWindowPicker.pick(at: CGPoint(x: 2000, y: 10), in: windows) == nil)
}

@Test func coordinatesFlipBetweenAppKitAndTheWindowServer() {
    let rect = CaptureCoordinates.quartz(CGRect(x: 10, y: 900, width: 100, height: 50), primaryHeight: 982)
    #expect(rect == CGRect(x: 10, y: 32, width: 100, height: 50))
    #expect(CaptureCoordinates.pixels(CGRect(x: 10.25, y: 5, width: 100, height: 50), scale: 2) == CGRect(x: 20, y: 10, width: 201, height: 100))
}

@Test func recordedAreasSnapToEvenPixelsWithA32PixelMinimum() {
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let snapped = CaptureRecordingArea.snap(CGRect(x: 10.3, y: 20.7, width: 100.2, height: 50.1), scale: 2, bounds: bounds)
    #expect(Int(snapped.minX * 2) % 2 == 0 && Int(snapped.minY * 2) % 2 == 0)
    #expect(Int(snapped.width * 2) % 2 == 0 && Int(snapped.height * 2) % 2 == 0)
    #expect(snapped.width * 2 >= 200.4)
    let tiny = CaptureRecordingArea.snap(CGRect(x: 1500, y: 970, width: 3, height: 3), scale: 1, bounds: bounds)
    #expect(tiny.width == 32 && tiny.height == 32)
    #expect(tiny.maxX <= 1512 && tiny.maxY <= 982)
}

// MARK: Naming and transfers

@Test func capturesAreNamedWithPosixDigits() {
    let date = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13:20 UTC
    let utc = TimeZone(identifier: "UTC")!
    #expect(CaptureNaming.fileName(.screenshot, date: date, timeZone: utc) == "Screenshot 2026-09-21 at 14.13.20.png")
    #expect(CaptureNaming.fileName(.recording, date: date, timeZone: utc) == "Recording 2026-09-21 at 14.13.20.mov")
}

@Test func collisionsCountUpToNineThousandNineHundredNinetyNine() {
    let taken: Set<String> = ["a.png", "a 2.png", "a 3.png"]
    #expect(CaptureNaming.unique(base: "a", fileExtension: "png") { taken.contains($0) } == "a 4.png")
    #expect(CaptureNaming.unique(base: "a", fileExtension: "png") { _ in false } == "a.png")
    #expect(CaptureNaming.unique(base: "a", fileExtension: "png") { _ in true } == nil)
}

@Test func transfersArePrunedToADayAHundredFilesAnd256MiB() {
    let now = Date()
    var files = (0..<105).map { CaptureTransferFile(name: "f\($0)", modified: now.addingTimeInterval(-Double($0)), bytes: 1) }
    files.append(CaptureTransferFile(name: "old", modified: now.addingTimeInterval(-90_000), bytes: 1))
    let doomed = CaptureTransfers.expired(files, now: now)
    #expect(doomed.contains("old"))
    #expect(doomed.count == 6)
    #expect(!doomed.contains("f0"))
    let big = [CaptureTransferFile(name: "new", modified: now, bytes: 200 << 20),
               CaptureTransferFile(name: "older", modified: now.addingTimeInterval(-5), bytes: 100 << 20)]
    #expect(CaptureTransfers.expired(big, now: now) == ["older"])
}

// MARK: Preview timing and geometry

@Test func previewDurations() {
    #expect(CapturePreviewCountdown.duration(automaticActionSucceeded: false) == 12)
    #expect(CapturePreviewCountdown.duration(automaticActionSucceeded: true) == 3)
    #expect(CapturePreviewCountdown.duration(automaticActionSucceeded: true, hasLink: true) == 30)
}

@Test func hoveringPausesThePreviewAndLeavingRestartsTheFullDelay() {
    var countdown = CapturePreviewCountdown(duration: 12, now: 0)
    #expect(!countdown.isExpired(now: 11.9))
    countdown.hover(true, now: 10)
    #expect(!countdown.isExpired(now: 100))
    countdown.hover(false, now: 100)
    #expect(!countdown.isExpired(now: 111.9))
    #expect(countdown.isExpired(now: 112))
}

@Test func aCaptureReservesItsMeasuredPreviewWithinTheBudget() {
    let budget: CGFloat = 264
    let height = CapturePreviewLayout.pageHeight(CGSize(width: 3024, height: 1964), width: 504, budget: budget)
    #expect(height <= budget)
    let wide = CapturePreviewLayout.pageHeight(CGSize(width: 2000, height: 200), width: 504, budget: budget)
    #expect(wide == 80)  // image 50 + spacing 6 + caption 20 + inset 4
    // The preview respects a small custom height limit too.
    #expect(CapturePreviewLayout.pageHeight(CGSize(width: 800, height: 800), width: 504, budget: 90) == 90)
    #expect(CapturePreviewLayout.downscaled(CGSize(width: 3024, height: 1964)).width == 1200)
    #expect(CapturePreviewLayout.downscaled(CGSize(width: 300, height: 200)) == CGSize(width: 300, height: 200))
}

@Test func floatingPreviewSitsInTheBottomRightCorner() {
    let origin = CapturePreviewLayout.floatingOrigin(visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))
    #expect(origin == CGPoint(x: 1512 - 350 - 10, y: 80))
}

// MARK: Rail layout

@Test func theRailFillsThePageWithRowsOfAtLeast88Points() {
    let spacious = CaptureRailLayout(height: 264)
    #expect(spacious.rows == 2)
    #expect(spacious.cardHeight == 128)
    let compact = CaptureRailLayout(height: 180)
    #expect(compact.rows == 1)
    #expect(compact.cardHeight == 180)
    let tall = CaptureRailLayout(height: 400)
    #expect(tall.rows == 4)
    #expect(tall.cardHeight == 94)
    #expect(spacious.columns(for: 5) == 3)
    #expect(spacious.contentWidth(for: 5) == 724)
    #expect(spacious.columns(for: 0) == 0)
}

// MARK: Recorder rules

@Test func recorderDefaultsAndDiskGuards() {
    #expect(CaptureRecordingRules.framesPerSecond == 60)
    #expect(CaptureRecordingRules.defaultCountdown == 3)
    #expect(CaptureRecordingRules.recordsSystemAudioByDefault)
    #expect(!CaptureRecordingRules.recordsMicrophoneByDefault)
    #expect(!CaptureRecordingRules.canStart(freeBytes: 1_999_999_999))
    #expect(CaptureRecordingRules.canStart(freeBytes: 2_000_000_000))
    #expect(CaptureRecordingRules.mustStop(freeBytes: 499_999_999))
    #expect(!CaptureRecordingRules.mustStop(freeBytes: 500_000_000))
    #expect(CaptureRecordingRules.elapsed(0) == "0:00")
    #expect(CaptureRecordingRules.elapsed(65.9) == "1:05")
    #expect(CaptureRecordingRules.elapsed(3600) == "60:00")
}

@Test func afterActions() {
    #expect(!CaptureAfterAction.ask.isAutomatic && !CaptureAfterAction.ask.saves && !CaptureAfterAction.ask.copies)
    #expect(CaptureAfterAction.saveAndCopy.saves && CaptureAfterAction.saveAndCopy.copies)
    #expect(CaptureAfterAction.copy.copies && !CaptureAfterAction.copy.saves)
}

// MARK: Recent-captures list

private func shot(_ minutesAgo: Double, bytes: Int64 = 1_000, file: String? = nil, kind: CaptureKind = .screenshot) -> RecentCapture {
    let id = UUID()
    return RecentCapture(id: id, kind: kind, date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                         fileURL: file.map { URL(fileURLWithPath: $0) },
                         imageName: kind == .screenshot ? RecentCapturesStore.imageName(for: id) : nil,
                         thumbnailName: RecentCapturesStore.thumbnailName(for: id), imageBytes: kind == .screenshot ? bytes : 0)
}

@Test func theHistoryKeepsTwelveNewestFirst() {
    var entries: [RecentCapture] = []
    for minute in (0..<15).reversed() { entries = RecentCapturesList.inserting(shot(Double(minute)), into: entries) }
    #expect(entries.count == 12)
    #expect(entries.first?.date == Date(timeIntervalSince1970: 1_000_000))
    #expect(zip(entries, entries.dropFirst()).allSatisfy { $0.date > $1.date })
}

@Test func readdingTheSameFileReplacesItsEntry() {
    let first = shot(5, file: "/tmp/Recording.mov", kind: .recording)
    let again = shot(1, file: "/tmp/Recording.mov", kind: .recording)
    let entries = RecentCapturesList.inserting(again, into: [first, shot(3)])
    #expect(entries.count == 2)
    #expect(entries.first?.id == again.id)
}

@Test func theNewestScreenshotIsKeptOverTheBudgetAndOlderOnesAreSkipped() {
    let huge = shot(0, bytes: 300 << 20)
    let older = shot(1, bytes: 10 << 20)
    let recording = shot(2, file: "/tmp/r.mov", kind: .recording)
    let entries = RecentCapturesList.limited([older, huge, recording])
    #expect(entries.map(\.id) == [huge.id, recording.id])
    let fits = RecentCapturesList.limited([shot(0, bytes: 200 << 20), shot(1, bytes: 50 << 20), shot(2, bytes: 10 << 20)])
    #expect(fits.count == 2)
}

@Test func entriesWhoseFileIsGoneAreDropped() {
    let kept = shot(0)
    let gone = shot(1)
    #expect(RecentCapturesList.present([kept, gone]) { $0.id == kept.id }.map(\.id) == [kept.id])
}

// MARK: Recent-captures store (the thirteen rules)

private final class Sandbox {
    let root: URL
    let folder: URL
    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("captures-tests-\(UUID().uuidString)")
        folder = root.appendingPathComponent("History")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit {
        _ = chmod(folder.path, 0o700)
        _ = chmod(folder.appendingPathComponent("index.json").path, 0o600)
        try? FileManager.default.removeItem(at: root)
    }
    var store: RecentCapturesStore { RecentCapturesStore(folder: folder) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
    func permissions(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
    func imageFiles(for entry: RecentCapture) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: entry.ownedNames.map { ($0, Data("png".utf8)) })
    }
    /// Files present on disk count as present entries.
    func present(_ entry: RecentCapture) -> Bool {
        entry.kind == .screenshot ? entry.imageName.map(exists) ?? false : entry.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
}

@Test func storeCreatesItsFirstIndexOwnerOnly() {
    let box = Sandbox()
    var history = RecentCapturesHistory(store: box.store)
    history.reload(exists: box.present)
    #expect(history.isLoaded && history.entries.isEmpty)
    let entry = shot(0)
    let changed22 = history.add(entry, files: box.imageFiles(for: entry), exists: box.present)
    #expect(changed22)
    #expect(box.permissions(box.folder) == 0o700)
    #expect(box.permissions(box.store.indexURL) == 0o600)
    #expect(box.permissions(box.store.url(for: entry.imageName!)) == 0o600)
}

@Test func storeCommitsTheEntryBeforeCleanupAndAReloadIsUnchanged() {
    let box = Sandbox()
    var history = RecentCapturesHistory(store: box.store)
    var added: [RecentCapture] = []
    for minute in (0..<13).reversed() {
        let entry = shot(Double(minute))
        added.append(entry)
        history.add(entry, files: box.imageFiles(for: entry), exists: box.present)
    }
    // The oldest fell out: its files went only after the index naming the newest was written.
    #expect(!box.exists(added[0].imageName!))
    #expect(box.exists(added[12].imageName!))
    var again = RecentCapturesHistory(store: box.store)
    again.reload(exists: box.present)
    #expect(again.entries == history.entries)
}

@Test func aCorruptIndexBlocksCleanupAndEmptyReplacementThenRecovers() throws {
    let box = Sandbox()
    var history = RecentCapturesHistory(store: box.store)
    let entry = shot(0)
    history.add(entry, files: box.imageFiles(for: entry), exists: box.present)
    let good = try Data(contentsOf: box.store.indexURL)
    try Data("{ not json".utf8).write(to: box.store.indexURL)
    var fresh = RecentCapturesHistory(store: box.store)
    fresh.reload(exists: box.present)
    #expect(fresh.failure == .corruptIndex)
    let next = shot(-1)
    let changed23 = fresh.add(next, files: box.imageFiles(for: next), exists: box.present)
    #expect(!changed23)
    #expect(box.exists(entry.imageName!))
    #expect(try Data(contentsOf: box.store.indexURL) == Data("{ not json".utf8))
    try good.write(to: box.store.indexURL)
    fresh.reload(exists: box.present)
    #expect(fresh.failure == nil && fresh.entries.map(\.id) == [entry.id])
}

@Test func aDeniedReadPreservesTheIndexAndRetries() throws {
    let box = Sandbox()
    var history = RecentCapturesHistory(store: box.store)
    let entry = shot(0)
    history.add(entry, files: box.imageFiles(for: entry), exists: box.present)
    #expect(chmod(box.store.indexURL.path, 0) == 0)
    history.reload(exists: box.present)
    // A read error is not "no history": what was known stays, and nothing is written.
    #expect(history.failure == .unreadableIndex)
    #expect(history.entries.map(\.id) == [entry.id])
    let next = shot(-1)
    let changed24 = history.add(next, files: box.imageFiles(for: next), exists: box.present)
    #expect(!changed24)
    #expect(chmod(box.store.indexURL.path, 0o600) == 0)
    history.reload(exists: box.present)
    #expect(history.failure == nil && history.entries.map(\.id) == [entry.id])
}

@Test func aMissingIndexWithOwnedFilesNeverBecomesEmptyHistory() throws {
    let box = Sandbox()
    var history = RecentCapturesHistory(store: box.store)
    let entry = shot(0)
    history.add(entry, files: box.imageFiles(for: entry), exists: box.present)
    try FileManager.default.removeItem(at: box.store.indexURL)
    var fresh = RecentCapturesHistory(store: box.store)
    fresh.reload(exists: box.present)
    #expect(fresh.failure == .missingIndex)
    let next = shot(-1)
    let changed25 = fresh.add(next, files: box.imageFiles(for: next), exists: box.present)
    #expect(!changed25)
    #expect(!FileManager.default.fileExists(atPath: box.store.indexURL.path))
    #expect(box.exists(entry.imageName!))
}

@Test func aFailedSaveDeletesNothing() throws {
    let box = Sandbox()
    var history = RecentCapturesHistory(store: box.store)
    let first = shot(1)
    history.add(first, files: box.imageFiles(for: first), exists: box.present)
    // The index path becomes a directory, so the next write fails.
    try FileManager.default.removeItem(at: box.store.indexURL)
    try FileManager.default.createDirectory(at: box.store.indexURL, withIntermediateDirectories: false)
    let changed26 = history.remove(first.id, exists: box.present)
    #expect(!changed26)
    #expect(box.exists(first.imageName!) && box.exists(first.thumbnailName!))
}

@Test func aRetriedRemovalDeletesOnlyOwnedImages() throws {
    let box = Sandbox()
    var history = RecentCapturesHistory(store: box.store)
    let entry = shot(0)
    history.add(entry, files: box.imageFiles(for: entry), exists: box.present)
    try Data("mine".utf8).write(to: box.folder.appendingPathComponent("notes.txt"))
    try Data("user".utf8).write(to: box.folder.appendingPathComponent("Screenshot.png"))
    let changed27 = history.remove(entry.id, exists: box.present)
    #expect(changed27)
    let changed28 = history.remove(entry.id, exists: box.present)
    #expect(changed28)
    #expect(!box.exists(entry.imageName!) && !box.exists(entry.thumbnailName!))
    #expect(box.exists("notes.txt") && box.exists("Screenshot.png"))
}

@Test func clearingARecordingKeepsTheVideo() throws {
    let box = Sandbox()
    let video = box.root.appendingPathComponent("Recording.mov")
    try Data("mov".utf8).write(to: video)
    var history = RecentCapturesHistory(store: box.store)
    let entry = shot(0, file: video.path, kind: .recording)
    history.add(entry, files: box.imageFiles(for: entry), exists: box.present)
    #expect(history.entries.count == 1)
    let changed29 = history.remove(entry.id, exists: box.present)
    #expect(changed29)
    #expect(FileManager.default.fileExists(atPath: video.path))
    #expect(!box.exists(entry.thumbnailName!))
}

@Test func cleanupNeverFollowsSymlinks() throws {
    let box = Sandbox()
    var history = RecentCapturesHistory(store: box.store)
    history.reload(exists: box.present)
    let outside = box.root.appendingPathComponent("precious.png")
    try Data("keep".utf8).write(to: outside)
    let linkName = RecentCapturesStore.imageName(for: UUID())
    try FileManager.default.createSymbolicLink(at: box.folder.appendingPathComponent(linkName), withDestinationURL: outside)
    let entry = shot(0)
    history.add(entry, files: box.imageFiles(for: entry), exists: box.present)
    #expect(FileManager.default.fileExists(atPath: outside.path))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: box.folder.appendingPathComponent(linkName).path)) != nil)
}

@Test func aSymlinkedIndexIsNeverOverwritten() throws {
    let box = Sandbox()
    var history = RecentCapturesHistory(store: box.store)
    history.reload(exists: box.present)
    let target = box.root.appendingPathComponent("elsewhere.json")
    try Data("theirs".utf8).write(to: target)
    try FileManager.default.removeItem(at: box.store.indexURL)
    try FileManager.default.createSymbolicLink(at: box.store.indexURL, withDestinationURL: target)
    let entry = shot(0)
    let changed30 = history.add(entry, files: box.imageFiles(for: entry), exists: box.present)
    #expect(!changed30)
    #expect(try Data(contentsOf: target) == Data("theirs".utf8))
    var fresh = RecentCapturesHistory(store: box.store)
    fresh.reload(exists: box.present)
    #expect(fresh.failure == .symlinkedIndex)
}

@Test func ownedNamesAreOnlyTheStoresOwn() {
    let id = UUID()
    #expect(RecentCapturesStore.isOwnedName(RecentCapturesStore.imageName(for: id)))
    #expect(RecentCapturesStore.isOwnedName(RecentCapturesStore.thumbnailName(for: id)))
    #expect(!RecentCapturesStore.isOwnedName("Screenshot.png"))
    #expect(!RecentCapturesStore.isOwnedName("index.json"))
    #expect(!RecentCapturesStore.isOwnedName("\(id.uuidString).mov"))
}
