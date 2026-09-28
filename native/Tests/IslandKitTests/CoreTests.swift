import CoreGraphics
import Foundation
import Testing
@testable import IslandKit

// A 14-inch MacBook Pro's built-in display: 1512 × 982, a 185 × 32 notch.
let notched = IslandDisplayMetrics.make(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                       auxiliaryLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                       auxiliaryRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                       safeAreaTop: 32, barHeight: 33, scale: 2)
let external = IslandDisplayMetrics.make(frame: CGRect(x: 1512, y: -130, width: 1920, height: 1080),
                                         auxiliaryLeft: nil, auxiliaryRight: nil, safeAreaTop: 0, barHeight: 24, scale: 1)

@Test func notchedDisplayReportsItsPhysicalCamera() {
    #expect(notched.cutout == IslandCutout(width: 185, height: 32, isPhysical: true))
    #expect(notched.barHeight == 33)
}

@Test func displayWithoutANotchGetsANotebookProportionedCutout() {
    #expect(external.cutout.isPhysical == false)
    #expect(external.cutout.width == 135)
    #expect(external.cutout.height == 24)
}

@Test func barHeightFallsBackThroughRememberedThenSystemThenTwentyFour() {
    #expect(IslandBarHeight.resolve(measuredGap: 33, remembered: 24, systemThickness: 22) == 33)
    #expect(IslandBarHeight.resolve(measuredGap: 0, remembered: 28, systemThickness: 22) == 28)
    #expect(IslandBarHeight.resolve(measuredGap: 0, remembered: nil, systemThickness: 22) == 22)
    #expect(IslandBarHeight.resolve(measuredGap: 0, remembered: nil, systemThickness: 3) == 24)
}

@Test func closedStripHasCutoutLikeCorners() {
    let strip = IslandSilhouette(width: 273, height: 32)
    #expect(abs(strip.shoulder - 6.08) < 0.01)
    #expect(abs(strip.cornerRadius - 10.88) < 0.01)
    #expect(strip.cornerRadius >= 8 && strip.cornerRadius <= 12)
    let open = IslandSilhouette(width: 560, height: 286)
    #expect(open.cornerRadius == 28)
    #expect(open.shoulder == 14)
}

@Test func silhouetteTakesThePointsInsideItsBodyOnly() {
    let shape = IslandSilhouette(width: 200, height: 100)
    #expect(shape.contains(CGPoint(x: 100, y: 50)))
    #expect(shape.contains(CGPoint(x: 100, y: 1)))
    // Outside the shoulders at mid-height, and below the bottom.
    #expect(!shape.contains(CGPoint(x: 2, y: 50)))
    #expect(!shape.contains(CGPoint(x: 100, y: 101)))
}

@Test func restingWingsAreFortyFourOrNothing() {
    #expect(IslandGeometry.restingWing(room: 655) == 44)
    #expect(IslandGeometry.restingWing(room: 43.9) == 0)
    #expect(IslandGeometry.restingWing(room: nil) == 0)
    let strip = IslandGeometry.strip(notched, wing: 44)
    #expect(strip == CGSize(width: 273, height: 32))
}

@Test func coveringTheMenusUsesTheRoomOfAnEmptyBar() {
    #expect(abs(IslandGeometry.emptyBarRoom(notched) - 655.5) < 0.01)
}

@Test func presetOpenIslandsAreWiderThanTallAndSplitTheHeaderBesideTheCamera() {
    var settings = IslandSettings()
    settings.size = .compact
    let compact = IslandGeometry.openLayout(notched, settings: settings, page: .fill)
    #expect(compact.width == 480)
    #expect(compact.height == 244)
    #expect(compact.headerBesideCamera)
    #expect(compact.headerTop == 0)
    settings.size = .spacious
    let spacious = IslandGeometry.openLayout(notched, settings: settings, page: .fill)
    #expect(spacious.width == 560)
    #expect(spacious.width > spacious.height)
    #expect(spacious.contentWidth == 504)
}

@Test func narrowCustomIslandPutsTheHeaderInItsOwnRowBelowTheCamera() {
    var settings = IslandSettings()
    settings.size = .custom
    settings.customWidth = 360
    let layout = IslandGeometry.openLayout(notched, settings: settings, page: .fixed(100))
    #expect(!layout.headerBesideCamera)
    #expect(layout.headerTop == 42)
    #expect(layout.height <= settings.customHeight)
}

@Test func simulatedCutoutNeverReservesAHeaderRow() {
    let layout = IslandGeometry.openLayout(external, settings: IslandSettings(), page: .fill)
    #expect(layout.headerTop == 0)
    #expect(!layout.headerBesideCamera)
}

@Test func customDimensionsClampAndRejectNonFiniteValues() {
    var settings = IslandSettings()
    settings.customWidth = 10_000
    #expect(settings.customWidth == 600)
    settings.customHeight = .nan
    #expect(settings.customHeight == 480)
    settings.hoverDelay = 5
    #expect(settings.hoverDelay == 1)
}

@Test func openingDropsAheadOfWideningAndOvershootsAtMostTwelvePoints() {
    let plan = IslandMotionPlan.plan(from: CGSize(width: 185, height: 32), to: CGSize(width: 560, height: 300))
    #expect(plan.sizes.first == CGSize(width: 185, height: 32))
    #expect(plan.sizes.last == CGSize(width: 560, height: 300))
    #expect(plan.duration >= 0.1 && plan.duration <= 0.6)
    #expect(plan.envelope.width <= 560 + 12 && plan.envelope.height <= 300 + 12)
    #expect(plan.envelope.width > 560)
    let early = plan.sizes[6]
    let heightProgress = (early.height - 32) / (300 - 32)
    let widthProgress = (early.width - 185) / (560 - 185)
    #expect(heightProgress > widthProgress)
    #expect(plan.arrival < plan.duration)
}

@Test func closingNeverUndershootsItsTarget() {
    let plan = IslandMotionPlan.plan(from: CGSize(width: 560, height: 300), to: CGSize(width: 185, height: 32))
    #expect(plan.sizes.allSatisfy { $0.width >= 185 && $0.height >= 32 })
    #expect(plan.envelope == CGSize(width: 560, height: 300))
}

@Test func unchangedSizeReservesNothing() {
    let plan = IslandMotionPlan.plan(from: CGSize(width: 10, height: 10), to: CGSize(width: 10, height: 10))
    #expect(plan.isEmpty)
}

@Test func automaticPriorityIsTimerDownloadsAgentsCalendarMusic() {
    let kinds = IslandActivityKind.allCases
    for mask in 1..<(1 << kinds.count) {
        let live = Set(kinds.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
        let expected = kinds.first(where: live.contains)
        #expect(IslandActivityChoice().resolve(live: live, timerRunning: true)?.primary == expected)
    }
}

@Test func choiceLastsOnlyWhileItsActivityIsLive() {
    var choice = IslandActivityChoice()
    choice.choose(.music, live: [.timer, .music])
    #expect(choice.resolve(live: [.timer, .music], timerRunning: true)?.primary == .music)
    choice.reconcile(live: [.timer], timerRunning: true)
    #expect(choice.chosen == nil)
    // Coming back later does not revive the old choice.
    #expect(choice.resolve(live: [.timer, .music], timerRunning: true)?.primary == .timer)
    // A late click on a choice that is no longer live is ignored.
    choice.choose(.calendar, live: [.timer])
    #expect(choice.chosen == nil)
}

@Test func onlyTheTimerSharesAndOnlyWithEligibleCompanions() {
    let everything = Set(IslandActivityKind.allCases)
    #expect(IslandActivityChoice.companions(live: everything, timerRunning: true) == [.downloads, .agents, .music])
    #expect(IslandActivityChoice.companions(live: everything, timerRunning: false) == [.downloads])
    #expect(IslandActivityChoice.companions(live: [.music], timerRunning: true).isEmpty)
    var choice = IslandActivityChoice()
    choice.combine(.calendar, live: everything, timerRunning: true)
    #expect(choice.chosen == nil)
    choice.combine(.music, live: everything, timerRunning: true)
    #expect(choice.resolve(live: everything, timerRunning: true)! == (.timer, .music))
    // Pausing the timer drops the music companion but keeps the timer.
    #expect(choice.resolve(live: everything, timerRunning: false)! == (.timer, nil))
    choice.choose(.timer, live: everything)
    #expect(choice.companion == nil)
}

@Test func noticePriorityReplacesEqualOrHigherAndDropsLower() {
    #expect(IslandNoticeKind.brightness.replaces(.volume))
    #expect(!IslandNoticeKind.clipboard.replaces(.volume))
    #expect(IslandNoticeKind.capture.replaces(.battery))
    #expect(IslandNoticeKind.newTrack.replaces(nil))
}

@Test func settingsSurviveARoundTripAndIgnoreUnknownValues() throws {
    var settings = IslandSettings()
    settings.enabled = true
    settings.size = .custom
    settings.customWidth = 500
    settings.hiddenSections = [.camera, .files]
    settings.floating.remove(IslandFloatingLayout.standard.buttons[0].id)
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(IslandSettings.self, from: data) == settings)
    let messy = #"{"enabled":true,"size":"capsule","sectionOrder":["timer","nope","timer","music"],"hiddenSections":["zzz","camera"],"customWidth":9999}"#
    let decoded = try JSONDecoder().decode(IslandSettings.self, from: Data(messy.utf8))
    #expect(decoded.enabled)
    #expect(decoded.size == .spacious)
    #expect(decoded.customWidth == 600)
    #expect(decoded.hiddenSections == [.camera])
    #expect(decoded.orderedSections.prefix(2) == [.timer, .music])
    #expect(decoded.orderedSections.count == IslandSectionID.allCases.count)
}

@Test func floatingLayoutKeepsAtMostThreePerSideAndMovesKeepIdentity() {
    var layout = IslandFloatingLayout.standard
    #expect(layout.buttons(on: .left).map(\.action) == [.explore, .section(.timer)])
    let addedPin = layout.append(.init(action: .pin, side: .left))
    let addedFourth = layout.append(.init(action: .control(.keepAwake), side: .left))
    #expect(addedPin)
    #expect(!addedFourth)
    let explore = layout.buttons[0].id
    let moved = layout.move(explore, to: .bottom, at: 0)
    #expect(moved)
    #expect(layout.buttons(on: .bottom).first?.id == explore)
    #expect(IslandFloatingButton.clean("  a\nb  ") == "a b")
    #expect(IslandFloatingButton.clean(String(repeating: "x", count: 60)).count == 40)
}

@Test func unknownFloatingActionsAreDroppedNotFatal() throws {
    let json = #"{"buttons":[{"id":"00000000-0000-4000-8000-000000000009","action":"warp","side":"left"},{"id":"00000000-0000-4000-8000-000000000008","action":"control.timer","side":"left","label":"T"}]}"#
    let layout = try JSONDecoder().decode(IslandFloatingLayout.self, from: Data(json.utf8))
    #expect(layout.buttons.map(\.action) == [.control(.timer)])
}

@Test func automaticDisplayPrefersTheNotchedBuiltInScreen() {
    let screens = [IslandScreenInfo(id: 1, isBuiltIn: true, isNotched: true, isPrimary: false),
                   IslandScreenInfo(id: 2, isBuiltIn: false, isNotched: false, isPrimary: true)]
    #expect(IslandDisplaySelection.select(screens, choice: .automatic, hasLid: true) == 1)
    #expect(IslandDisplaySelection.select(screens, choice: .main, hasLid: true) == 2)
    #expect(IslandDisplaySelection.select([screens[1]], choice: .builtIn, hasLid: true) == nil)
    #expect(IslandDisplaySelection.select([screens[1]], choice: .builtIn, hasLid: false) == 2)
    #expect(IslandDisplaySelection.select([], choice: .automatic, hasLid: true) == nil)
}

@Test func reopeningPrefersAVisibleActivityThenTheSavedDestination() {
    var settings = IslandSettings()
    let visible: [IslandSectionID] = [.controls, .music, .timer]
    #expect(IslandNavigation.reopenDestination(settings: settings, visible: visible, lastPage: .music, activity: nil) == .section(.music))
    #expect(IslandNavigation.reopenDestination(settings: settings, visible: visible, lastPage: .music, activity: .timer) == .section(.timer))
    settings.reopen = .section(.calendar)
    #expect(IslandNavigation.reopenDestination(settings: settings, visible: visible, lastPage: nil, activity: nil) == .section(.controls))
    settings.reopen = .explore
    #expect(IslandNavigation.reopenDestination(settings: settings, visible: visible, lastPage: nil, activity: nil) == .explore)
    #expect(IslandReopen(storageValue: "garbage") == .section(.controls))
}

@Test func shortcutsAndCyclingIgnoreHiddenSectionsAndWrap() {
    let visible: [IslandSectionID] = [.controls, .music, .timer]
    #expect(IslandNavigation.section(forShortcut: "M", visible: visible) == .music)
    #expect(IslandNavigation.section(forShortcut: "a", visible: visible) == nil)
    #expect(IslandNavigation.cycle(from: .timer, visible: visible, forward: true) == .controls)
    #expect(IslandNavigation.cycle(from: .controls, visible: visible, forward: false) == .timer)
    #expect(Set(IslandSectionID.allCases.map(\.shortcut)).count == IslandSectionID.allCases.count)
}

@Test func searchMatchesEveryWordIgnoringCaseAndAccents() {
    let all = IslandSectionID.allCases
    #expect(IslandNavigation.search("MÚSIC", in: all) == [.music])
    #expect(IslandNavigation.search("volume mixer", in: all) == [.mixer])
    #expect(IslandNavigation.search("   ", in: all) == all)
    #expect(IslandNavigation.search("zzz", in: all).isEmpty)
}

@Test func exploreShowsFiveColumnsOnSpaciousAndStepsWholeRows() {
    let spacious = IslandExplorePaging(count: 15, contentWidth: 504, height: 320)
    #expect(spacious.columns == 5)
    #expect(spacious.positions == 1)
    let compact = IslandExplorePaging(count: 15, contentWidth: 424, height: 320)
    #expect(compact.columns == 4)
    #expect(compact.rows == 4)
    #expect(compact.positions == 2)
    #expect(compact.reveal(3, from: 0) == 1)
    #expect(compact.reveal(0, from: 1) == 0)
}

@Test func floatingButtonsSitBesideTheBodyAndTheGapTakesNoClicks() {
    let layout = IslandFloatingLayout.standard
    let placement = IslandFloatingPlacement.make(layout: layout, island: CGSize(width: 560, height: 300),
                                                 headerTop: 0, headerHeight: 36, barHeight: 32)
    #expect(placement.slots.count == 5)
    let left = placement.slots.filter { $0.center.x < 0 }
    #expect(left.count == 2)
    #expect(left[1].center.y - left[0].center.y == 54)
    let bottom = placement.slots.first { $0.center.y > 300 }!
    #expect(bottom.center == CGPoint(x: 280, y: 334))
    // The gap between the island and a button is not a button, but it is inside the hover corridor.
    let gap = CGPoint(x: 5, y: left[0].center.y)
    #expect(placement.slot(at: gap) == nil)
    #expect(placement.corridorContains(gap))
    #expect(placement.slot(at: left[0].center) != nil)
}

// MARK: Gestures

private func run(_ deltas: [(Double, Double)], origin: IslandGestureOrigin = .init(vertical: true, horizontal: true, islandOpen: false),
                 precise: Bool = true, phased: Bool = true) -> [IslandGestureAction] {
    var recognizer = IslandGestureRecognizer()
    var actions: [IslandGestureAction] = []
    var time = 0.0
    if phased { _ = recognizer.handle(.init(deltaX: 0, deltaY: 0, phase: .began, timestamp: time), originIfStarting: { origin }) }
    for (dx, dy) in deltas {
        time += 0.01
        // Natural scrolling: deltas arrive in the direction of finger travel.
        if let action = recognizer.handle(.init(deltaX: dx, deltaY: dy, precise: precise, inverted: true,
                                                phase: phased ? .changed : .none, timestamp: time), originIfStarting: { origin }) {
            actions.append(action)
        }
    }
    return actions
}

@Test func smallDownwardMovementAccumulatesToOneOpening() {
    #expect(run([(0, 5), (0, 10), (0, 10)]) == [.open])
    #expect(run([(0, 0.1)] + Array(repeating: (0, 0.5), count: 7) + [(0, 21)]) == [.open])
    // Holding on after firing never fires a second action in the same sequence.
    #expect(run([(0, 30), (0, -60)]) == [.open])
}

@Test func upwardSwipeClosesOnlyAnOpenIsland() {
    #expect(run([(0, -30)]).isEmpty)
    #expect(run([(0, -30)], origin: .init(vertical: true, horizontal: false, islandOpen: true)) == [.close])
}

@Test func horizontalSwipesChangeOneTrackAndTheLockingDeltaCountsOnce() {
    #expect(run([(-10, 0), (-15, 0), (-20, 0)]) == [.nextTrack])
    #expect(run([(-20, 0), (-19, 0), (-1, 0)]) == [.nextTrack])
    #expect(run([(45, 0)]) == [.previousTrack])
    #expect(run([(30, 30), (30, 30)]).isEmpty)
    #expect(run([(-45, 0)], origin: .init(vertical: true, horizontal: false, islandOpen: false)).isEmpty)
}

@Test func oneWheelStepCanOpenAndWheelTiltIsNotASwipe() {
    // A wheel reports line steps, classic direction: rolling toward you is negative.
    var recognizer = IslandGestureRecognizer()
    let origin = IslandGestureOrigin(vertical: true, horizontal: true, islandOpen: false)
    #expect(recognizer.handle(.init(deltaX: 0, deltaY: -1, precise: false, phase: .none, timestamp: 1), originIfStarting: { origin }) == .open)
    recognizer.reset()
    #expect(recognizer.handle(.init(deltaX: -3, deltaY: 0, precise: false, phase: .none, timestamp: 1), originIfStarting: { origin }) == nil)
}

@Test func momentumModifiersAndOrphansNeverAct() {
    var recognizer = IslandGestureRecognizer()
    let origin = IslandGestureOrigin(vertical: true, horizontal: true, islandOpen: false)
    #expect(recognizer.handle(.init(deltaX: 0, deltaY: 50, inverted: true, phase: .none, momentum: true, timestamp: 1), originIfStarting: { origin }) == nil)
    #expect(recognizer.handle(.init(deltaX: 0, deltaY: 50, inverted: true, phase: .changed, timestamp: 2), originIfStarting: { origin }) == nil)
    _ = recognizer.handle(.init(deltaX: 0, deltaY: 0, phase: .began, timestamp: 3), originIfStarting: { origin })
    #expect(recognizer.handle(.init(deltaX: 0, deltaY: 50, inverted: true, phase: .changed, timestamp: 4, modifiers: true), originIfStarting: { origin }) == nil)
    #expect(recognizer.handle(.init(deltaX: 0, deltaY: .nan, phase: .changed, timestamp: 5), originIfStarting: { origin }) == nil)
}
