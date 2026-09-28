import CoreGraphics
import Foundation
import Testing
@testable import IslandKit

// The Notifications section's rules, restated from the spec (core sections §3.7) against synthetic
// Accessibility trees. Numbers in the comments are the spec's rule numbers.

private func text(_ identifier: String?, _ value: String) -> NotificationAXNode {
    NotificationAXNode(role: NotificationAX.staticTextRole, identifier: identifier, text: value)
}
private func image(_ label: String) -> NotificationAXNode { NotificationAXNode(role: NotificationAX.imageRole, imageLabel: label) }
private func group(_ children: [NotificationAXNode], subrole: String? = nil, identifier: String? = nil, handle: Int = -1) -> NotificationAXNode {
    NotificationAXNode(role: "AXGroup", subrole: subrole, identifier: identifier, children: children, handle: handle)
}
private func banner(_ children: [NotificationAXNode], identifier: String? = nil, handle: Int = 1) -> NotificationAXNode {
    group(children, subrole: NotificationAX.bannerSubrole, identifier: identifier, handle: handle)
}
private func window(_ children: [NotificationAXNode]) -> NotificationAXNode { NotificationAXNode(role: "AXWindow", children: children) }
private func parse(_ nodes: NotificationAXNode...) -> NotificationParseReport { NotificationParser.parse(windows: [window(nodes)]) }
private func message(_ title: String, _ body: String) -> [NotificationAXNode] { [text("title", title), text("body", body)] }

private let uuidA = "8C1F2B7E-3D4A-4F9B-A1C2-0E5D6F7A8B9C"
private let uuidB = "1B2C3D4E-5F60-4718-92A3-B4C5D6E7F809"

private func item(_ title: String, body: String? = nil, native: String? = nil, element: UInt64, canPress: Bool = true,
                  close: String? = nil, persistent: Bool = false) -> NotificationSnapshotItem {
    NotificationSnapshotItem(fields: NotificationFields(title: title, body: body), nativeID: native, element: element,
                             canPress: canPress, closeAction: close, isPersistent: persistent)
}
private let now = Date(timeIntervalSince1970: 1_000_000)

// MARK: 1–3 Timing, replacement, the close action

@Test func mirroredBannersShowThreeSecondsAndTheNativeCloseWaitsLess() {
    #expect(IslandNoticeKind.notification.duration == 3)
    #expect(IslandNoticeKind.timerFinished.duration == 6)
    #expect(NotificationTiming.closeGrace >= 1.2)
    #expect(NotificationTiming.closeGrace < IslandNoticeKind.notification.duration)
}

@Test func heldPreviewYieldsToNotificationsVolumeAndTimersButNotBatteryOrClipboard() {
    #expect(NotificationPolicy.heldBannerYields(to: .notification))
    #expect(NotificationPolicy.heldBannerYields(to: .volume))
    #expect(NotificationPolicy.heldBannerYields(to: .timerFinished))
    #expect(!NotificationPolicy.heldBannerYields(to: .battery))
    #expect(!NotificationPolicy.heldBannerYields(to: .clipboard))
    // An unheld banner is an ordinary priority-1 notice: battery replaces it.
    #expect(IslandNoticeKind.battery.replaces(.notification))
}

@Test func closeUsesOnlyTheExactCloseAction() {
    let close = "Name:Close\nTarget:0x0\nSelector:(null)"
    let closeAll = "Name:Close All\nTarget:0x0\nSelector:(null)"
    #expect(NotificationValidation.closeAction(in: ["AXPress", closeAll, close], localizedClose: "Close") == close)
    #expect(NotificationValidation.closeAction(in: ["AXPress", closeAll], localizedClose: "Close") == nil)
    #expect(NotificationValidation.closeAction(in: [close, close], localizedClose: "Close") == nil)
    #expect(NotificationValidation.closeAction(in: ["AXPress", "Name:Show\nTarget:0x0"], localizedClose: "Close") == nil)
    let german = "Name:Schließen\nTarget:0x0\nSelector:(null)"
    #expect(NotificationValidation.closeAction(in: [german], localizedClose: "Schließen") == german)
}

// MARK: 4 Content

@Test func labelledFieldsStaySeparate() throws {
    let report = parse(banner([text("header", "Messages"), text("title", "Alex"), text("subtitle", "Team"), text("body", "Lunch?")]))
    let fields = try #require(report.candidates.first?.fields)
    #expect(fields == NotificationFields(header: "Messages", title: "Alex", subtitle: "Team", body: "Lunch?"))
}

@Test func twoTitlesTwoBodiesOrABodyWithoutATitleAreRejected() {
    #expect(parse(banner([text("title", "Alex"), text("title", "Sam"), text("body", "Hi")])).candidates.isEmpty)
    #expect(parse(banner([text("title", "Alex"), text("body", "Hi"), text("body", "Bye")])).candidates.isEmpty)
    let bodyOnly = parse(banner([text("body", "Hi")]))
    #expect(bodyOnly.candidates.isEmpty)
    #expect(bodyOnly.rejected == [.noTitle])
}

@Test func anOverlongFieldRejectsTheMessage() {
    let limit = String(repeating: "a", count: 16_384)
    #expect(parse(banner([text("title", limit), text("body", "x")])).candidates.count == 1)
    let over = parse(banner([text("title", limit + "a"), text("body", "x")]))
    #expect(over.candidates.isEmpty)
    #expect(over.rejected == [.fieldTooLong])
}

@Test func unlabelledTextsKeepSenderAndMessage() {
    #expect(parse(banner([text(nil, "Alex"), text(nil, "Hi")])).candidates.first?.fields == NotificationFields(title: "Alex", body: "Hi"))
    #expect(parse(banner([text(nil, "Alex"), text("", "Team"), text(nil, "Hi")])).candidates.first?.fields
        == NotificationFields(title: "Alex", subtitle: "Team", body: "Hi"))
    #expect(parse(banner([text(nil, "a"), text(nil, "b"), text(nil, "c"), text(nil, "d")])).candidates.isEmpty)
}

@Test func editableNativeContentIsNeverRead() throws {
    let reply = NotificationAXNode(role: "AXTextArea", identifier: "body", text: "draft reply", children: [text("body", "draft")])
    let report = parse(banner(message("Alex", "Hi") + [reply]))
    let fields = try #require(report.candidates.first?.fields)
    #expect(fields.body == "Hi")
}

@Test func buttonLabelsAreNotMessageText() throws {
    let button = NotificationAXNode(role: "AXButton", children: [text(nil, "Reply")])
    let report = parse(banner([text(nil, "Alex"), text(nil, "Hi"), button]))
    #expect(try #require(report.candidates.first).fields == NotificationFields(title: "Alex", body: "Hi"))
}

@Test func unknownTextIdentifiersAreReportedNotGuessed() {
    let report = parse(banner([text("notificationTitle", "Alex"), text("notificationBody", "Hi")]))
    #expect(report.candidates.isEmpty)
    #expect(report.unknownTextIdentifiers == ["notificationTitle", "notificationBody"])
    #expect(report.rejected == [.unrecognisedLayout])
}

// MARK: 5 Identity

@Test func structuralIdentifiersAreNotDurableIdentities() {
    #expect(NotificationParser.nativeIdentity("AXNotificationListItems") == nil)
    #expect(NotificationParser.nativeIdentity(nil) == nil)
    #expect(NotificationParser.nativeIdentity("request-\(uuidA)") == "request-\(uuidA)")
    #expect(NotificationParser.nativeIdentity(uuidA.lowercased()) != nil)
    #expect(NotificationParser.nativeIdentity("8C1F2B7E-3D4A-4F9B-A1C2-0E5D6F7A8B9") == nil)
    #expect(NotificationParser.nativeIdentity(String(repeating: "x", count: 2_048) + uuidA) == nil)
}

// MARK: 6–7 Where it came from

private let chat = NotificationAppRecord(name: "Chat, Inc.", bundleID: "com.example.chat")
private let messages = NotificationAppRecord(name: "Messages", bundleID: "com.apple.MobileSMS")
private let slack = NotificationAppRecord(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")

@Test func formattedDescriptionsKeepCommasEverywhere() {
    let fields = NotificationFields(title: "Alex, Sam, Group", body: "Hello, everyone")
    let described = "Chat, Inc., Alex, Sam, Group, Hello, everyone"
    #expect(NotificationParser.appLabel(description: described, fields: fields) == "Chat, Inc.")
    let candidate = NotificationCandidate(handle: 1, identifier: nil, fields: fields, imageLabels: [], isPersistent: false)
    let source = NotificationSourceResolver.source(for: candidate, description: described, running: [chat, messages], installed: { [] })
    #expect(source?.bundleID == chat.bundleID)
    #expect(source?.name == "Chat, Inc.")
    // Message-only or unmatched descriptions name nothing.
    #expect(NotificationParser.appLabel(description: "Alex, Sam, Group, Hello, everyone", fields: fields) == nil)
    #expect(NotificationParser.appLabel(description: "Chat, Inc., Alex, Hello", fields: fields) == nil)
    let unknown = NotificationSourceResolver.source(for: candidate, description: "Nope, Alex, Sam, Group, Hello, everyone",
                                                    running: [chat], installed: { [] })
    #expect(unknown == nil)
}

@Test func sourceResolutionAcceptsOnlyAWholeUnambiguousName() {
    let none: () -> [NotificationAppRecord] = { [] }
    #expect(NotificationSourceResolver.resolve("messages", running: [messages], installed: none) == messages)
    #expect(NotificationSourceResolver.resolve("\u{200E}Messages\u{202C} ", running: [messages], installed: none) == messages)
    #expect(NotificationSourceResolver.resolve("", running: [messages], installed: none) == nil)
    #expect(NotificationSourceResolver.resolve("Mess", running: [messages], installed: none) == nil)
    #expect(NotificationSourceResolver.resolve("com.apple.MobileSMS", running: [messages], installed: none) == nil)
    let twin = NotificationAppRecord(name: "Messages", bundleID: "com.example.messages")
    #expect(NotificationSourceResolver.resolve("Messages", running: [messages, twin], installed: none) == nil)
    // Several processes of one app are one app.
    #expect(NotificationSourceResolver.resolve("Messages", running: [messages, messages], installed: none) == messages)
}

@Test func closedAppsResolveThroughInstalledAppsAndRunningWins() {
    #expect(NotificationSourceResolver.resolve("Slack", running: [messages], installed: { [slack] }) == slack)
    let other = NotificationAppRecord(name: "Slack", bundleID: "com.example.otherslack")
    #expect(NotificationSourceResolver.resolve("Slack", running: [slack], installed: { [other] }) == slack)
    #expect(NotificationSourceResolver.resolve("Slack", running: [], installed: { [slack, other] }) == nil)
    var walked = false
    _ = NotificationSourceResolver.resolve("Messages", running: [messages]) { walked = true; return [] }
    #expect(!walked)
}

@Test func imageLabelsIdentifyTheAppBesideAContactButNotWhenTheyConflict() {
    let none: () -> [NotificationAppRecord] = { [] }
    #expect(NotificationSourceResolver.resolve(imageLabels: ["Alex Doe", "Messages"], running: [messages], installed: none) == messages)
    #expect(NotificationSourceResolver.resolve(imageLabels: ["Slack", "Messages"], running: [messages, slack], installed: none) == nil)
    #expect(NotificationSourceResolver.resolve(imageLabels: ["icon", "AXImage"], running: [messages], installed: none) == nil)
}

// MARK: 8 Compact text

@Test func compactTextKeepsSenderAndMessageApart() {
    let fields = NotificationFields(header: "Messages", title: "Alex", subtitle: "Team", body: "Lunch at one?")
    #expect(NotificationText.compactTitle(fields, appName: "Messages") == "Alex")
    #expect(NotificationText.compactDetail(fields) == "Team · Lunch at one?")
    #expect(NotificationText.spoken(fields, appName: "Messages") == "Messages, Alex, Team, Lunch at one?")
    let noTitle = NotificationFields(title: "  ", body: "Backup finished")
    #expect(NotificationText.compactTitle(noTitle, appName: "Time Machine") == "Time Machine")
    #expect(NotificationText.compactDetail(NotificationFields(title: "Alex", body: "Hi")) == "Hi")
    #expect(NotificationText.spoken(NotificationFields(title: "Alex", body: "Hi"), appName: nil) == "Alex, Hi")
    // Truncation is the view's business: the stored text is untouched.
    let long = String(repeating: "word ", count: 400)
    #expect(NotificationText.compactDetail(NotificationFields(title: "A", body: long)) == long.trimmingCharacters(in: .whitespaces))
}

// MARK: 9 Inbox

@Test func enablingDoesNotReplayBannersAlreadyOnScreen() {
    var inbox = NotificationInbox()
    #expect(inbox.apply([item("Alex", element: 1)], at: now).isEmpty)
    #expect(inbox.mirrors.isEmpty)
    #expect(inbox.apply([item("Alex", element: 1), item("Sam", element: 2)], at: now).map(\.fields.title) == ["Sam"])
}

@Test func repeatedCallbacksDeliverOnce() {
    var inbox = NotificationInbox()
    inbox.apply([], at: now)
    #expect(inbox.apply([item("Alex", element: 1)], at: now).count == 1)
    #expect(inbox.apply([item("Alex", element: 1)], at: now).isEmpty)
    #expect(inbox.apply([item("Alex", element: 1)], at: now).isEmpty)
    #expect(inbox.mirrors.count == 1)
}

@Test func identicalTextFromDifferentNotificationsStaysDistinct() {
    var inbox = NotificationInbox()
    inbox.apply([], at: now)
    #expect(inbox.apply([item("Alex", body: "Hi", element: 1), item("Alex", body: "Hi", element: 2)], at: now).count == 2)
    #expect(inbox.apply([item("Alex", body: "Hi", native: uuidA, element: 3), item("Alex", body: "Hi", native: uuidB, element: 3)], at: now).count == 2)
    #expect(inbox.mirrors.count == 4)
}

@Test func aDismissedMirrorDoesNotReturn() throws {
    var inbox = NotificationInbox()
    inbox.apply([], at: now)
    let first = try #require(inbox.apply([item("Alex", native: uuidA, element: 1)], at: now).first)
    inbox.dismiss(first.id)
    // The native banner changes layout: rebuilt element, same identity.
    #expect(inbox.apply([item("Alex", native: uuidA, element: 9)], at: now).isEmpty)
    #expect(inbox.mirrors.isEmpty)
    inbox.removeAll()
    #expect(inbox.apply([item("Alex", native: uuidA, element: 9)], at: now).isEmpty)
}

@Test func expiredBannersLoseActionsButKeepText() throws {
    var inbox = NotificationInbox()
    inbox.apply([], at: now)
    let arrived = try #require(inbox.apply([item("Alex", body: "Hi", element: 1)], at: now).first)
    #expect(arrived.canOpenNatively)
    inbox.apply([], at: now)
    let expired = try #require(inbox.mirror(arrived.id))
    #expect(expired.live == nil)
    #expect(!expired.canOpenNatively)
    #expect(expired.fields.body == "Hi")
}

@Test func burstsStayBoundedAtFifty() {
    var inbox = NotificationInbox()
    inbox.apply([], at: now)
    let burst = (1...80).map { item("Sender \($0)", element: UInt64($0)) }
    let arrivals = inbox.apply(burst, at: now)
    #expect(inbox.mirrors.count == NotificationInbox.capacity)
    #expect(arrivals.count == NotificationInbox.capacity)
    #expect(inbox.mirrors.first?.fields.title == "Sender 80")
    for round in 0..<5 {
        inbox.apply((1...60).map { item("R\(round)-\($0)", element: UInt64(1000 * (round + 1) + $0)) }, at: now)
    }
    #expect(inbox.mirrors.count == 50)
    #expect(inbox.seen.count <= NotificationInbox.seenLimit + 60)
}

@Test func lockOrDisableClearsEverything() {
    var inbox = NotificationInbox()
    inbox.apply([], at: now)
    inbox.apply([item("Alex", element: 1)], at: now)
    inbox.reset()
    #expect(inbox.mirrors.isEmpty)
    #expect(!inbox.hasBaseline)
    // After re-enabling, what is on screen is a fresh baseline again.
    #expect(inbox.apply([item("Alex", element: 1)], at: now).isEmpty)
}

@Test func aRestartedNotificationCenterTakesANewBaselineAndKeepsMessages() {
    var inbox = NotificationInbox()
    inbox.apply([], at: now)
    inbox.apply([item("Alex", element: 1)], at: now)
    inbox.rebaseline()
    #expect(inbox.mirrors.first?.live == nil)
    #expect(inbox.apply([item("Old", element: 5)], at: now).isEmpty)
    #expect(inbox.mirrors.map(\.fields.title) == ["Alex"])
}

// MARK: 10 Switches

@Test func switchesGateReaderBannersAndClosingTogether() {
    #expect(NotificationPreferences.closeOriginalsDefault == false)
    #expect(NotificationPreferences.showBannersDefault == true)
    #expect(NotificationPolicy.readerRuns(islandRunning: true, sectionVisible: true, trusted: true))
    #expect(!NotificationPolicy.readerRuns(islandRunning: false, sectionVisible: true, trusted: true))
    #expect(!NotificationPolicy.readerRuns(islandRunning: true, sectionVisible: false, trusted: true))
    #expect(!NotificationPolicy.readerRuns(islandRunning: true, sectionVisible: true, trusted: false))
    #expect(!NotificationPolicy.postsBanner(readerRuns: false, showBanners: true))
    #expect(NotificationPolicy.closesOriginal(readerRuns: true, closeOriginals: true, noticeShown: true, islandOpen: false, isPersistent: false))
    #expect(!NotificationPolicy.closesOriginal(readerRuns: false, closeOriginals: true, noticeShown: true, islandOpen: false, isPersistent: false))
    #expect(!NotificationPolicy.closesOriginal(readerRuns: true, closeOriginals: false, noticeShown: true, islandOpen: false, isPersistent: false))
    #expect(!NotificationPolicy.closesOriginal(readerRuns: true, closeOriginals: true, noticeShown: false, islandOpen: false, isPersistent: false))
    #expect(!NotificationPolicy.closesOriginal(readerRuns: true, closeOriginals: true, noticeShown: true, islandOpen: true, isPersistent: false))
    #expect(!NotificationPolicy.closesOriginal(readerRuns: true, closeOriginals: true, noticeShown: true, islandOpen: false, isPersistent: true))
}

// MARK: 11 Message card

/// Seven points per character, 16-pt lines: wrapping depends on the width it is given.
private func measure(_ text: String, _ style: NotificationTextStyle, _ width: CGFloat) -> (lineHeight: CGFloat, lines: Int) {
    let perLine = max(1, Int(width / 7))
    return (style == .title ? 17 : 16, Int(ceil(Double(text.count) / Double(perLine))))
}

@Test func previewGrowsWithItsMessageAndStopsAtTheLineLimits() {
    let width = NotificationPreviewLayout.textWidth(cardWidth: 400)
    #expect(width == 400 - 2 * NotificationPreviewLayout.horizontalInset)
    let short = NotificationPreviewLayout.contentHeight(NotificationFields(title: "Alex"), hasActionRow: false, textWidth: width, measure: measure)
    let withBody = NotificationPreviewLayout.contentHeight(NotificationFields(title: "Alex", body: "Hi"), hasActionRow: false, textWidth: width, measure: measure)
    let withBoth = NotificationPreviewLayout.contentHeight(NotificationFields(title: "Alex", subtitle: "Team", body: "Hi"), hasActionRow: false, textWidth: width, measure: measure)
    #expect(short < withBody && withBody < withBoth)
    let empty = NotificationPreviewLayout.contentHeight(NotificationFields(title: "Alex", subtitle: "", body: " "), hasActionRow: false, textWidth: width, measure: measure)
    #expect(empty == short)
    let long = String(repeating: "x", count: 5_000)
    let capped = NotificationPreviewLayout.contentHeight(NotificationFields(title: long, subtitle: long, body: long), hasActionRow: true, textWidth: width, measure: measure)
    let expected = 28 + 6 + 2 * 17 + 3 + 16 + 3 + 6 * 16 + 10 + 28
    #expect(capped == CGFloat(expected))
    // Wrapping is measured at the width given: narrower text needs more lines.
    let body = String(repeating: "y", count: 120)
    let wide = NotificationPreviewLayout.contentHeight(NotificationFields(title: "A", body: body), hasActionRow: false, textWidth: 500, measure: measure)
    let narrow = NotificationPreviewLayout.contentHeight(NotificationFields(title: "A", body: body), hasActionRow: false, textWidth: 200, measure: measure)
    #expect(narrow > wide)
}

@Test func previewIsBannerWideButNeverWiderThanTheIsland() {
    #expect(NotificationPreviewLayout.width(camera: 185, openWidth: 560) == 400)
    #expect(NotificationPreviewLayout.width(camera: 260, openWidth: 560) == 460)
    #expect(NotificationPreviewLayout.width(camera: 185, openWidth: 380) == 380)
    // An overlong message cannot exceed the display.
    #expect(NotificationPreviewLayout.maximumContentHeight(displayHeight: 982, cutoutHeight: 32) == CGFloat(982 - 48 - 32 - 10 - 16))
}

// MARK: 12 Reader

@Test func readBudgetsDiscardOversizedTrees() {
    var budget = NotificationReadBudget(clock: { 0 })
    for _ in 0..<384 { #expect(throws: Never.self) { try budget.visit(depth: 1) } }
    #expect(throws: NotificationReadFailure.tooManyNodes) { try budget.visit(depth: 1) }
    // Each read has its own budget: validation after a heavy refresh still has room.
    var validation = NotificationReadBudget(clock: { 0 })
    #expect(throws: Never.self) { try validation.visit(depth: 1) }
    #expect(validation.nodes == 1)
    #expect(throws: NotificationReadFailure.tooManyChildren) { try validation.check(children: 65, depth: 1) }
    #expect(throws: Never.self) { try validation.check(children: 64, depth: 1) }
    #expect(throws: NotificationReadFailure.tooDeep) { try validation.check(children: 1, depth: 10) }
    #expect(throws: NotificationReadFailure.tooDeep) { try validation.visit(depth: 11) }
    #expect(throws: NotificationReadFailure.tooManyWindows) { try validation.check(windows: 33) }
}

@Test func aReadThatRunsOutOfTimeFails() {
    let clock = TestClock()
    var budget = NotificationReadBudget(clock: { clock.now })
    #expect(throws: Never.self) { try budget.visit(depth: 0) }
    clock.now = 0.81
    #expect(throws: NotificationReadFailure.deadline) { try budget.visit(depth: 0) }
}

private final class TestClock: @unchecked Sendable { var now: TimeInterval = 0 }

@Test func anOpenNotificationCenterIsNotImportedAndAnUnreadableFocusFails() {
    #expect(NotificationFocus.none.stop == nil)
    #expect(NotificationFocus.focused.stop == .skipped)
    #expect(NotificationFocus.unreadable.stop == .failed(.focusUnreadable))
}

@Test func persistentAlertsStayMirroredButAreNeverClosed() throws {
    let close = "Name:Close\nTarget:0x0"
    let alert = group(message("Alarm", "07:00"), subrole: NotificationAX.alertSubrole, handle: 3)
    let report = parse(alert)
    let candidate = try #require(report.candidates.first)
    #expect(candidate.isPersistent)
    #expect(NotificationValidation.closable(item("Alarm", element: 3, close: close, persistent: true)) == nil)
    #expect(NotificationValidation.closable(item("Alex", element: 4, close: close)) == close)
    // A banner inside an alert stack is persistent too.
    let stacked = parse(group([banner(message("Alarm", "07:00"))], subrole: NotificationAX.alertStackSubrole))
    #expect(stacked.candidates.first?.isPersistent == true)
}

@Test func completeMessagesInsideAModernStackAreSeparatedAndStayClosable() {
    let card1 = group(message("Alex", "Hi"), handle: 11)
    let card2 = group(message("Sam", "Bye"), handle: 12)
    let report = parse(group([group([card1, card2], handle: 10)], subrole: NotificationAX.bannerStackSubrole))
    #expect(report.candidates.map(\.handle) == [11, 12])
    #expect(report.candidates.allSatisfy { !$0.isPersistent })
}

@Test func aWrapperAroundOneCompleteCardKeepsItsMessageAndItsAppIcon() throws {
    let card = group([text(nil, "Alex"), text(nil, "Hi")], handle: 21)
    let wrapper = group([image("Messages"), card], handle: 20)
    let report = parse(group([wrapper], subrole: NotificationAX.bannerStackSubrole))
    let candidate = try #require(report.candidates.first)
    #expect(report.candidates.count == 1)
    #expect(candidate.handle == 21)
    #expect(candidate.fields == NotificationFields(title: "Alex", body: "Hi"))
    #expect(candidate.imageLabels == ["Messages"])
}

@Test func partialSubgroupsAreNeverTakenAsCards() throws {
    // The sender and the message sit in separate groups: the card is their parent, not a half.
    let sender = group([text("title", "Alex")], handle: 31)
    let body = group([text("body", "Hi")], handle: 32)
    let report = parse(group([group([sender, body], handle: 30)], subrole: NotificationAX.bannerStackSubrole))
    #expect(report.candidates.map(\.handle) == [30])
    #expect(try #require(report.candidates.first).fields == NotificationFields(title: "Alex", body: "Hi"))
}

@Test func theAppIsRecoveredFromImageLabelsWithoutTouchingSenderOrMessage() throws {
    let candidate = try #require(parse(banner([image("Slack"), image("Messages")] + message("Slack", "Hi"))).candidates.first)
    #expect(candidate.fields == NotificationFields(title: "Slack", body: "Hi"))
    // The sender's own name on a contact photo cannot pass for the source.
    let source = NotificationSourceResolver.source(for: candidate, description: nil, running: [messages, slack], installed: { [] })
    #expect(source?.bundleID == messages.bundleID)
    let unknownImage = try #require(parse(banner([image("person.crop.circle")] + message("Alex", "Hi"))).candidates.first)
    #expect(NotificationSourceResolver.source(for: unknownImage, description: nil, running: [messages], installed: { [] }) == nil)
}

@Test func theFormattedDescriptionIdentifiesABannerWithNoHeaderOrImage() throws {
    let candidate = try #require(parse(banner(message("Alex", "Hi"))).candidates.first)
    let source = NotificationSourceResolver.source(for: candidate, description: "Messages, Alex, Hi", running: [messages], installed: { [] })
    #expect(source?.name == "Messages")
}

@Test func unrelatedWidgetsAreNotNotifications() {
    let widget = group([text("title", "Weather"), text("body", "Sunny")], subrole: "AXWidget")
    let report = parse(widget, group([text(nil, "Calendar"), text(nil, "No events")]))
    #expect(report.candidates.isEmpty)
    let changed = parse(group(message("Alex", "Hi"), subrole: "AXNotificationCenterBannerV2"))
    #expect(changed.candidates.isEmpty)
    #expect(changed.unknownSubroles == ["AXNotificationCenterBannerV2"])
}

@Test func twoSendersInOneBannerAreNotCombined() {
    let report = parse(banner(message("Alex", "Hi") + message("Sam", "Bye")))
    #expect(report.candidates.isEmpty)
    #expect(report.rejected == [.multipleTitles])
}

// MARK: 13 Opening

@Test func openNeedsAFreshPressableMatch() {
    let key = NotificationKey(nativeID: uuidA, fields: NotificationFields(title: "Alex", body: "Hi"), element: 1)
    #expect(NotificationValidation.pressable(key, in: [item("Alex", body: "Hi", native: uuidA, element: 1)])?.element == 1)
    // The press capability comes from the fresh read, never from memory.
    #expect(NotificationValidation.pressable(key, in: [item("Alex", body: "Hi", native: uuidA, element: 1, canPress: false)]) == nil)
    // Absent from the latest complete read.
    #expect(NotificationValidation.pressable(key, in: []) == nil)
    // A changed sender cannot inherit Open.
    #expect(NotificationValidation.pressable(key, in: [item("Sam", body: "Hi", native: uuidA, element: 1)]) == nil)
    // The element now belongs to another identity.
    #expect(NotificationValidation.pressable(key, in: [item("Alex", body: "Hi", native: uuidB, element: 1)]) == nil)
    // A rebuilt view is followed to its new element.
    #expect(NotificationValidation.pressable(key, in: [item("Alex", body: "Hi", native: uuidA, element: 7)])?.element == 7)
    // Two roots claiming one identity: nothing may be pressed.
    #expect(NotificationValidation.pressable(key, in: [item("Alex", body: "Hi", native: uuidA, element: 1),
                                                         item("Other", native: uuidA, element: 2)]) == nil)
}

@Test func repeatedReadsKeepIdentityAndReceiptTime() throws {
    var inbox = NotificationInbox()
    inbox.apply([], at: now)
    let first = try #require(inbox.apply([item("Alex", native: uuidA, element: 1)], at: now).first)
    inbox.apply([item("Alex", native: uuidA, element: 2)], at: now.addingTimeInterval(30))
    let again = try #require(inbox.mirrors.first)
    #expect(again.id == first.id)
    #expect(again.receivedAt == now)
    #expect(again.key.element == 2)
    #expect(again.live?.element == 2)
}

@Test func duplicateNativeIdentitiesBlockOpenUntilUnambiguous() throws {
    var inbox = NotificationInbox()
    inbox.apply([], at: now)
    inbox.apply([item("Alex", native: uuidA, element: 1)], at: now)
    inbox.apply([item("Alex", native: uuidA, element: 1), item("Alex", native: uuidA, element: 2)], at: now)
    #expect(inbox.mirrors.count == 1)
    #expect(try #require(inbox.mirrors.first).canOpenNatively == false)
    inbox.apply([item("Alex", native: uuidA, element: 1)], at: now)
    #expect(try #require(inbox.mirrors.first).canOpenNatively)
}

@Test func withoutANativeIdentityTheSameElementStillDeduplicates() {
    var inbox = NotificationInbox()
    inbox.apply([], at: now)
    #expect(inbox.apply([item("Alex", element: 1)], at: now).count == 1)
    #expect(inbox.apply([item("Alex", element: 1)], at: now).isEmpty)
    // A different element with the same text is a different notification.
    #expect(inbox.apply([item("Alex", element: 2)], at: now).count == 1)
}

@Test func mirroringExposesOpenWithoutPerformingIt() throws {
    var inbox = NotificationInbox()
    inbox.apply([], at: now)
    let mirror = try #require(inbox.apply([item("Alex", element: 1)], at: now).first)
    #expect(mirror.canOpen)
    #expect(mirror.canOpenNatively)
    let sourceOnly = NotificationMirror(id: 9, key: NotificationKey(nativeID: nil, fields: NotificationFields(title: "A"), element: 3),
                                        source: NotificationSource(name: "Slack", bundleID: slack.bundleID), receivedAt: now, live: nil)
    #expect(sourceOnly.canOpen && !sourceOnly.canOpenNatively)
}

// MARK: Page

@Test func theInboxRailShowsTwoRowsOnSpaciousAndOneOnCompact() {
    #expect(NotificationRail.rows(height: 264) == 2)
    #expect(NotificationRail.rows(height: 180) == 1)
    #expect(NotificationRail.rows(height: 60) == 1)
    #expect(NotificationRail.cardHeight(height: 264) == 128)
    #expect(NotificationRail.cardHeight(height: 180) == 180)
}
