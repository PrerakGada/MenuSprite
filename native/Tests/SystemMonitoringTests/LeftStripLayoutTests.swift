import Testing
@testable import SystemMonitoring

@Suite struct LeftStripLayoutTests {
    @Test func coversTheAppsMenusWhenTheyAreWiderThanTheSprites() {
        let span = LeftStripLayout.span(start: 100, menusEnd: 600, limit: 900, content: 200)
        #expect(span?.x == 106)
        #expect(span?.width == 496)
    }

    @Test func growsPastTheMenusForSpritesThatNeedMore() {
        let span = LeftStripLayout.span(start: 100, menusEnd: 200, limit: 900, content: 400)
        #expect(span?.width == 400)
    }

    @Test func neverCrossesTheNotchOrFirstStatusItem() {
        let span = LeftStripLayout.span(start: 100, menusEnd: 1200, limit: 700, content: 900)
        #expect(span.map { $0.x + $0.width } == 694)
    }

    @Test func unreadMenusCoverUpToTheLimit() {
        let span = LeftStripLayout.span(start: 100, menusEnd: nil, limit: 700, content: 50)
        #expect(span?.width == 588)
    }

    @Test func noRoomMeansNoStrip() {
        #expect(LeftStripLayout.span(start: 680, menusEnd: 690, limit: 700, content: 50) == nil)
    }
}
