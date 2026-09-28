import CoreGraphics
import Foundation
import Testing
@testable import IslandKit

// Settings › Dynamic Island: tab and row fitting, the Content tab's columns, and the Layout canvas.

private let spacious = CGSize(width: 560, height: 244)

private func canvas(width: CGFloat = 745, island: CGSize = spacious) -> IslandLayoutCanvas {
    IslandLayoutCanvas(canvasWidth: width, islandSize: island)
}

// MARK: Tab row and choice rows (§13.13)

@Test func tabRowStaysSegmentedWhereItFits() {
    let widths: [CGFloat] = [44, 52, 50, 60]
    let needed = IslandTabRowFit.segmentedWidth(titleWidths: widths) + IslandTabRowFit.spacing + IslandTabRowFit.openButtonWidth
    #expect(IslandTabRowFit.style(available: needed, titleWidths: widths) == .segmented)
    #expect(IslandTabRowFit.style(available: 764, titleWidths: widths) == .segmented)
}

@Test func tabRowBecomesAMenuRatherThanWideningThePage() {
    let widths: [CGFloat] = [44, 52, 50, 60]
    let needed = IslandTabRowFit.segmentedWidth(titleWidths: widths) + IslandTabRowFit.spacing + IslandTabRowFit.openButtonWidth
    #expect(IslandTabRowFit.style(available: needed - 1, titleWidths: widths) == .menu)
}

@Test func choiceRowSitsBesideTheTitleWhenTheRowFitsOnOneLine() {
    #expect(IslandChoiceRowFit.placement(available: 700, leading: 44, titleWidth: 110, controlWidth: 250, menuWidth: 150) == .beside)
}

@Test func choiceRowDropsUnderTheTitleTextRatherThanSqueezing() {
    // 44 + 110 + 16 + 250 = 420 > 400, but 250 fits the 356-pt text column.
    #expect(IslandChoiceRowFit.placement(available: 400, leading: 44, titleWidth: 110, controlWidth: 250, menuWidth: 150) == .underTitle)
}

@Test func choiceRowFallsBackToAMenuUnderTheTitleThenUnderTheIcon() {
    #expect(IslandChoiceRowFit.placement(available: 240, leading: 44, titleWidth: 110, controlWidth: 250, menuWidth: 150) == .menuUnderTitle)
    #expect(IslandChoiceRowFit.placement(available: 180, leading: 44, titleWidth: 110, controlWidth: 250, menuWidth: 150) == .menuUnderIcon)
}

// MARK: Content tab

@Test func wideContentPageGivesThePreviewAColumnOfAtMostHalfTheRest() {
    let layout = IslandContentEditorLayout(pageWidth: 984)
    #expect(layout.listWidth == 216)
    // 984 − 216 − 16 = 752; (752 − 16) / 2 = 368.
    #expect(layout.preview == .column(width: 368))
    #expect(layout.optionsWidth == 368)
    let huge = IslandContentEditorLayout(pageWidth: 2400)
    #expect(huge.preview == .column(width: 560))
}

@Test func narrowContentPageStacksThePreviewAboveTheOptions() {
    let layout = IslandContentEditorLayout(pageWidth: 764)
    #expect(layout.listWidth == 196)
    #expect(layout.preview == .above(maxHeight: 280))
    #expect(layout.optionsWidth == 552)
}

@Test func contentPreviewScaleComesFromTheTallestPageAndNeverEnlarges() {
    #expect(IslandContentEditorLayout.previewScale(islandWidth: 560, tallestHeight: 384, availableWidth: 280, maxHeight: nil) == 0.5)
    #expect(IslandContentEditorLayout.previewScale(islandWidth: 560, tallestHeight: 384, availableWidth: 900, maxHeight: nil) == 1)
    // Stacked: the 280-pt cap wins over the width.
    let stacked = IslandContentEditorLayout.previewScale(islandWidth: 560, tallestHeight: 400, availableWidth: 540, maxHeight: 280)
    #expect(abs(stacked - 0.7) < 0.0001)
}

// MARK: Reopening menu, hints, section order, search

@Test func reopenMenuListsFixedChoicesThenVisibleSections() {
    let options = IslandReopenMenu.options(visible: [.controls, .system], saved: .lastPage)
    #expect(options.map(\.title) == ["Last page", "Open app panel", "Explore", "Controls", "System"])
    #expect(options.allSatisfy { $0.enabled })
}

@Test func reopenMenuKeepsAHiddenSavedSectionDisabled() {
    let options = IslandReopenMenu.options(visible: [.controls], saved: .section(.timer))
    #expect(options.last == IslandReopenOption(value: .section(.timer), title: "Timer", enabled: false))
    #expect(IslandReopenMenu.options(visible: [.controls, .timer], saved: .section(.timer)).filter { $0.value == .section(.timer) }.count == 1)
}

@Test func keyIndicatorsAskForAccessibilityOnlyWhenOnAvailableAndUntrusted() {
    var settings = IslandSettings()
    settings.enabled = true
    let all = Set(IslandIndicatorID.allCases)
    #expect(IslandSettingsHints.indicatorsNeedAccessibility(settings, available: all, trusted: false))
    #expect(!IslandSettingsHints.indicatorsNeedAccessibility(settings, available: all, trusted: true))
    // Switched on but not raisable on this Mac: nothing to ask for.
    #expect(!IslandSettingsHints.indicatorsNeedAccessibility(settings, available: [.battery], trusted: false))
    settings.indicators = [.battery, .newTrack]
    #expect(!IslandSettingsHints.indicatorsNeedAccessibility(settings, available: all, trusted: false))
    settings.indicators = [.keyboardLight]
    #expect(IslandSettingsHints.indicatorsNeedAccessibility(settings, available: all, trusted: false))
    settings.enabled = false
    #expect(!IslandSettingsHints.indicatorsNeedAccessibility(settings, available: all, trusted: false))
}

@Test func menuRoomHintOnlyWhereMeasuringIsNeeded() {
    var settings = IslandSettings()
    settings.enabled = true
    settings.coversMenus = false
    #expect(IslandSettingsHints.menuRoomNeedsAccessibility(settings, displayIsNotched: false, trusted: false))
    #expect(!IslandSettingsHints.menuRoomNeedsAccessibility(settings, displayIsNotched: true, trusted: false))
    #expect(!IslandSettingsHints.menuRoomNeedsAccessibility(settings, displayIsNotched: nil, trusted: false))
    #expect(!IslandSettingsHints.menuRoomNeedsAccessibility(settings, displayIsNotched: false, trusted: true))
    settings.opening = .hidden
    #expect(!IslandSettingsHints.menuRoomNeedsAccessibility(settings, displayIsNotched: false, trusted: false))
    settings.opening = .click
    // Covering the menus needs no measuring, so no hint (Vorssaint shows it anyway).
    settings.coversMenus = true
    #expect(!IslandSettingsHints.menuRoomNeedsAccessibility(settings, displayIsNotched: false, trusted: false))
}

@Test func draggingASectionOntoAnotherTakesItsPlace() {
    let order: [IslandSectionID] = [.controls, .mixer, .music, .system]
    #expect(IslandSectionOrder.move(.system, onto: .mixer, in: order) == [.controls, .system, .mixer, .music])
    #expect(IslandSectionOrder.move(.controls, onto: .music, in: order) == [.mixer, .music, .controls, .system])
    #expect(IslandSectionOrder.move(.music, onto: .music, in: order) == order)
}

@Test func sectionMoveUpAndDownStopAtTheEnds() {
    let order: [IslandSectionID] = [.controls, .mixer, .music]
    #expect(IslandSectionOrder.shift(.mixer, by: -1, in: order) == [.mixer, .controls, .music])
    #expect(IslandSectionOrder.shift(.mixer, by: 1, in: order) == [.controls, .music, .mixer])
    #expect(IslandSectionOrder.shift(.controls, by: -1, in: order) == order)
    #expect(IslandSectionOrder.shift(.music, by: 1, in: order) == order)
}

@Test func actionSearchMatchesEveryWordIgnoringCaseAndAccents() {
    let all = IslandFloatingAction.sectionGroup + IslandFloatingAction.quickGroup
    #expect(IslandActionSearch.filter("", all) == all)
    #expect(IslandActionSearch.filter("  ", all) == all)
    #expect(IslandActionSearch.filter("MIXER volume", all) == [.section(.mixer), .section(.mixer)])
    #expect(IslandActionSearch.filter("séttings", all) == [.settings])
    #expect(IslandActionSearch.filter("awake keep", all) == [.control(.keepAwake)])
    #expect(IslandActionSearch.filter("zzz", all).isEmpty)
}

// MARK: Layout canvas (§8)

@Test func canvasPreviewIsHalfSizeUnlessTheCanvasIsNarrow() {
    #expect(canvas().scale == 0.5)
    // (392 − 112) / 560 = 0.5 exactly; narrower canvases shrink the preview.
    #expect(canvas(width: 392).scale == 0.5)
    #expect(abs(canvas(width: 336).scale - 0.4) < 0.0001)
    #expect(canvas(width: 150).scale == 0.2)
}

@Test func canvasCentresTheIslandTwentyPointsFromTheTop() {
    let c = canvas()
    #expect(c.island == CGRect(x: 232.5, y: 20, width: 280, height: 122))
}

@Test func sideButtonsStartThirtyBelowTheTopEveryFortyEighteenOutside() {
    let c = canvas()
    #expect(c.slot(.left, index: 0, count: 2) == CGPoint(x: c.island.minX - 18, y: 50))
    #expect(c.slot(.left, index: 1, count: 2) == CGPoint(x: c.island.minX - 18, y: 90))
    #expect(c.slot(.right, index: 2, count: 3) == CGPoint(x: c.island.maxX + 18, y: 130))
}

@Test func bottomButtonsAreCentredTwentyFourBelowFortyApart() {
    let c = canvas()
    let y = c.island.maxY + 24
    #expect(c.slot(.bottom, index: 0, count: 1) == CGPoint(x: c.island.midX, y: y))
    #expect(c.slot(.bottom, index: 0, count: 2) == CGPoint(x: c.island.midX - 20, y: y))
    #expect(c.slot(.bottom, index: 1, count: 2) == CGPoint(x: c.island.midX + 20, y: y))
}

@Test func standardLayoutMatchesThePlacementInTheScreenshot() {
    let c = canvas()
    let centers = c.centers(.standard)
    let buttons = IslandFloatingLayout.standard.buttons
    #expect(centers[buttons[0].id] == CGPoint(x: c.island.minX - 18, y: 50))   // Explore
    #expect(centers[buttons[1].id] == CGPoint(x: c.island.minX - 18, y: 90))   // Timer
    #expect(centers[buttons[2].id] == CGPoint(x: c.island.maxX + 18, y: 50))   // Settings
    #expect(centers[buttons[4].id] == CGPoint(x: c.island.midX, y: c.island.maxY + 24)) // Music
    #expect(c.addSlot(.left, in: .standard) == CGPoint(x: c.island.minX - 18, y: 130))
    #expect(c.addSlot(.bottom, in: .standard) == CGPoint(x: c.island.midX + 40, y: c.island.maxY + 24))
}

@Test func plusSlotIsCentredOnAnEmptySideAndGoneOnAFullOne() {
    let c = canvas()
    let empty = IslandFloatingLayout(buttons: [])
    #expect(c.addSlot(.bottom, in: empty) == CGPoint(x: c.island.midX, y: c.island.maxY + 24))
    #expect(c.addSlot(.right, in: empty) == CGPoint(x: c.island.maxX + 18, y: 50))
    let full = IslandFloatingLayout(buttons: [.init(action: .explore, side: .left), .init(action: .settings, side: .left),
                                              .init(action: .pin, side: .left)])
    #expect(c.addSlot(.left, in: full) == nil)
}

@Test func dropZonesMatchTheSpecifiedGeometry() {
    let c = canvas()
    let left = c.zone(.left), right = c.zone(.right), bottom = c.zone(.bottom)
    #expect(left.minX == c.island.minX - 48 && left.width == 62)
    #expect(right.minX == c.island.maxX - 14 && right.width == 62)
    #expect(bottom.width == c.island.width && bottom.height == 58)
    #expect(bottom.midY == c.island.maxY + 24)
    // Every side zone holds all three slots.
    for index in 0..<3 { #expect(left.contains(c.slot(.left, index: index, count: 3))) }
}

@Test func dropZoneHitTestingPicksTheZoneUnderThePoint() {
    let c = canvas()
    #expect(c.zone(at: c.slot(.left, index: 1, count: 2)) == .left)
    #expect(c.zone(at: c.slot(.right, index: 0, count: 2)) == .right)
    #expect(c.zone(at: CGPoint(x: c.island.midX, y: c.island.maxY + 20)) == .bottom)
    #expect(c.zone(at: CGPoint(x: c.island.midX, y: c.island.midY - 20)) == nil)
    #expect(c.zone(at: CGPoint(x: 5, y: 390)) == nil)
}

@Test func droppingInsertsBeforeTheFirstButtonWhoseSlotLiesAfterThePoint() {
    let c = canvas()
    var layout = IslandFloatingLayout.standard
    let music = layout.buttons[4].id, explore = layout.buttons[0].id
    // Music dropped between Explore (y 50) and Timer (y 90) on the left.
    #expect(c.insertionIndex(of: music, at: CGPoint(x: c.island.minX - 18, y: 70), on: .left, in: layout) == 1)
    #expect(c.drop(music, at: CGPoint(x: c.island.minX - 18, y: 70), in: &layout))
    #expect(layout.buttons(on: .left).map(\.action) == [.explore, .section(.music), .section(.timer)])
    #expect(layout.buttons(on: .bottom).isEmpty)
    #expect(layout.buttons.first { $0.id == music }?.side == .left)
    // Just above Timer's centre lands before it; below it, last.
    #expect(c.insertionIndex(of: explore, at: CGPoint(x: c.island.minX - 18, y: 125), on: .left, in: layout) == 1)
    #expect(c.drop(explore, at: CGPoint(x: c.island.minX - 18, y: 145), in: &layout))
    #expect(layout.buttons(on: .left).map(\.action) == [.section(.music), .section(.timer), .explore])
}

@Test func droppingUnderneathOrdersByX() {
    let c = canvas()
    var layout = IslandFloatingLayout.standard
    let settingsButton = layout.buttons[2].id
    #expect(c.drop(settingsButton, at: CGPoint(x: c.island.midX - 30, y: c.island.maxY + 24), in: &layout))
    #expect(layout.buttons(on: .bottom).map(\.action) == [.settings, .section(.music)])
}

@Test func droppingOutsideEveryZoneOrOnAFullSideChangesNothing() {
    let c = canvas()
    var layout = IslandFloatingLayout(buttons: [
        .init(action: .explore, side: .left), .init(action: .settings, side: .left), .init(action: .pin, side: .left),
        .init(action: .section(.music), side: .right),
    ])
    let before = layout
    let music = layout.buttons[3].id
    #expect(!c.drop(music, at: CGPoint(x: c.island.midX, y: c.island.midY), in: &layout))
    #expect(!c.accepts(.left, dragging: music, in: layout))
    #expect(!c.drop(music, at: c.slot(.left, index: 1, count: 3), in: &layout))
    #expect(layout == before)
    // A full side still takes its own buttons back.
    let pin = layout.buttons[2].id
    #expect(c.accepts(.left, dragging: pin, in: layout))
    #expect(c.drop(pin, at: CGPoint(x: c.island.minX - 18, y: 40), in: &layout))
    #expect(layout.buttons(on: .left).map(\.action) == [.pin, .explore, .settings])
}

@Test func gripSitsOnTheCornerOfTallIslandsAndSlidesDownOnShortOnes() {
    let short = canvas()
    #expect(short.gripCenter == CGPoint(x: short.island.maxX - 3, y: short.island.minY + 139))
    let tall = canvas(island: CGSize(width: 560, height: 480))
    #expect(tall.gripCenter == CGPoint(x: tall.island.maxX - 3, y: tall.island.maxY + 3))
    // Clear of the third right slot.
    let third = short.slot(.right, index: 2, count: 3)
    let gap = hypot(third.x - short.gripCenter.x, third.y - short.gripCenter.y)
    #expect(gap >= (IslandLayoutCanvas.buttonDiameter + IslandLayoutCanvas.gripDiameter) / 2)
}

@Test func resizeGripMapsTravelThroughThePreviewScaleAndClamps() {
    let start = CGSize(width: 560, height: 328)
    // 20 canvas points right at half size widens a centred island by 80.
    let wider = IslandLayoutCanvas.resize(from: start, translation: CGSize(width: 20, height: 30), scale: 0.5)
    #expect(wider.width == 600 && wider.height == 390)
    let narrower = IslandLayoutCanvas.resize(from: start, translation: CGSize(width: -26, height: -3), scale: 0.5)
    #expect(narrower.width == 460 && narrower.height == 320)
    let clamped = IslandLayoutCanvas.resize(from: start, translation: CGSize(width: -400, height: 900), scale: 0.5)
    #expect(clamped.width == 360 && clamped.height == 640)
    let broken = IslandLayoutCanvas.resize(from: CGSize(width: CGFloat.nan, height: 300), translation: .zero, scale: 0.5)
    #expect(broken.width == 360 && broken.height == 300)
}
