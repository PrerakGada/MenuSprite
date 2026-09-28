import CoreGraphics
import Foundation
import Testing
@testable import IslandKit

// Calendar section rules (spec-sections-core §2.7, spec-activity §3.4), restated.

private func calendar(_ zone: String, firstWeekday: Int = 1) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.locale = Locale(identifier: "en_GB")
    calendar.firstWeekday = firstWeekday
    return calendar
}

private let london = calendar("Europe/London")
private let newYork = calendar("America/New_York")

private func date(_ text: String, _ calendar: Calendar = london) -> Date {
    let parts = text.split(whereSeparator: { "- :T".contains($0) }).compactMap { Int($0) }
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                    hour: parts.count > 3 ? parts[3] : 0, minute: parts.count > 4 ? parts[4] : 0,
                                    second: parts.count > 5 ? parts[5] : 0)
    return calendar.date(from: components)!
}

private let blue = IslandCalendarColor(red: 0, green: 0.4, blue: 1)
private let green = IslandCalendarColor(red: 0.2, green: 0.8, blue: 0.3)
private let orange = IslandCalendarColor(red: 1, green: 0.6, blue: 0)
private let purple = IslandCalendarColor(red: 0.6, green: 0.3, blue: 0.9)

private func event(_ name: String, _ start: String, _ end: String, allDay: Bool = false, color: IslandCalendarColor = blue,
                   calendar: Calendar = london) -> IslandCalendarEvent {
    let startDate = date(start, calendar)
    return IslandCalendarEvent(id: IslandCalendarEvent.identity(eventIdentifier: name, start: startDate), title: name,
                               calendarTitle: "Work", start: startDate, end: date(end, calendar), isAllDay: allDay,
                               color: color, itemIdentifier: name)
}

// MARK: Rule 2 — permission presentation

@Test func onlyFullAccessCountsAsGranted() {
    #expect(IslandCalendarAccess(.fullAccess) == .granted)
    #expect(IslandCalendarAccess(.writeOnly) == .askable)
    #expect(IslandCalendarAccess(.notDetermined) == .askable)
    #expect(IslandCalendarAccess(.denied) == .refused)
    #expect(IslandCalendarAccess(.restricted) == .refused)
}

@Test func aRequestThatDoesNotResolveReadAccessFailsButRefusalsKeepTheirOwnState() {
    #expect(IslandCalendarAccess.requestFailed(statusAfterRequest: .notDetermined))
    #expect(IslandCalendarAccess.requestFailed(statusAfterRequest: .writeOnly))
    #expect(!IslandCalendarAccess.requestFailed(statusAfterRequest: .fullAccess))
    #expect(!IslandCalendarAccess.requestFailed(statusAfterRequest: .denied))
    #expect(!IslandCalendarAccess.requestFailed(statusAfterRequest: .restricted))
    // A failed request stays askable, so the button stays there to try again.
    #expect(IslandCalendarAccess(.writeOnly) == .askable)
}

// MARK: Rule 5 — ordering, up next

@Test func orderingDropsCancelledDeclinedInvalidAndDuplicateOccurrences() {
    let a = event("A", "2026-09-28 10:00", "2026-09-28 11:00")
    let b = event("B", "2026-09-28 09:00", "2026-09-28 12:00")
    let tie = event("C", "2026-09-28 09:00", "2026-09-28 10:00")
    var zero = event("Zero", "2026-09-28 13:00", "2026-09-28 13:00")
    zero.id = "zero"
    let backwards = event("Back", "2026-09-28 15:00", "2026-09-28 14:00")
    let records: [IslandCalendarRecord] = [
        .init(event: a), .init(event: a), .init(event: b), .init(event: tie), .init(event: zero), .init(event: backwards),
        .init(event: event("Cancelled", "2026-09-28 08:00", "2026-09-28 09:00"), isCancelled: true),
        .init(event: event("Declined", "2026-09-28 08:00", "2026-09-28 09:00"), isDeclined: true),
    ]
    let result = IslandCalendarOrdering.normalize(records)
    #expect(result.map(\.title) == ["C", "B", "A"])
}

@Test func occurrencesOfOneSeriesAreDistinct() {
    let first = IslandCalendarEvent.identity(eventIdentifier: "series", start: date("2026-09-28 10:00"))
    let second = IslandCalendarEvent.identity(eventIdentifier: "series", start: date("2026-09-29 10:00"))
    #expect(first != second)
}

@Test func upNextSkipsAllDayAndAdvancesExactlyAtTheEnd() {
    let allDay = event("Holiday", "2026-09-28", "2026-09-29", allDay: true)
    let meeting = event("Meeting", "2026-09-28 10:00", "2026-09-28 11:00")
    let lunch = event("Lunch", "2026-09-28 12:00", "2026-09-28 13:00")
    let events = [allDay, meeting, lunch]
    #expect(IslandCalendarAgenda.upNext(now: date("2026-09-28 09:00"), in: events)?.title == "Meeting")
    // The appointment in progress stays current; the all-day event never hides it.
    #expect(IslandCalendarAgenda.upNext(now: date("2026-09-28 10:59:59"), in: events)?.title == "Meeting")
    #expect(IslandCalendarAgenda.upNext(now: date("2026-09-28 11:00"), in: events)?.title == "Lunch")
    #expect(IslandCalendarAgenda.upNext(now: date("2026-09-28 13:00"), in: events) == nil)
    #expect(IslandCalendarAgenda.upNext(now: date("2026-09-28 09:00"), in: [allDay]) == nil)
}

// MARK: Rule 12 — agenda lists

@Test func aSelectedDayKeepsEndedEventsAndListsAllDayFirst() {
    let early = event("Early", "2026-09-28 08:00", "2026-09-28 09:00")
    let later = event("Later", "2026-09-28 15:00", "2026-09-28 16:00")
    let allDay = event("Offsite", "2026-09-28", "2026-09-29", allDay: true)
    let list = IslandCalendarAgenda.events(on: date("2026-09-28"), in: [early, later, allDay], calendar: london)
    #expect(list.map(\.title) == ["Offsite", "Early", "Later"])
}

@Test func multiDayAndOvernightEventsAppearOnEveryDayTheyTouch() {
    let trip = event("Trip", "2026-09-28", "2026-10-01", allDay: true)
    let overnight = event("Flight", "2026-09-28 22:00", "2026-09-29 06:00")
    let endsAtMidnight = event("Late", "2026-09-28 23:00", "2026-09-29 00:00")
    let events = [trip, overnight, endsAtMidnight]
    let days = (0..<4).map { IslandCalendarDays.day($0, from: date("2026-09-28"), calendar: london) }
    let titles = days.map { IslandCalendarAgenda.events(on: $0, in: events, calendar: london).map(\.title) }
    #expect(titles[0] == ["Trip", "Flight", "Late"])
    #expect(titles[1] == ["Trip", "Flight"])          // end dates are exclusive: "Late" stops at midnight
    #expect(titles[2] == ["Trip"])
    #expect(titles[3] == [])                           // the all-day end (1 Oct 00:00) is exclusive
}

@Test func sevenDayModeHidesEndedEventsEvenWithTheMonthLoaded() {
    let now = date("2026-09-28 12:00")
    let lastWeek = event("Old", "2026-09-20 10:00", "2026-09-20 11:00")
    let thisMorning = event("Morning", "2026-09-28 09:00", "2026-09-28 10:00")
    let ongoing = event("Now", "2026-09-28 11:30", "2026-09-28 12:30")
    let tomorrow = event("Tomorrow", "2026-09-29 09:00", "2026-09-29 10:00")
    let nextWeek = event("Far", "2026-10-05 09:00", "2026-10-05 10:00")
    let days = IslandCalendarAgenda.nextSevenDays(now: now, events: [lastWeek, thisMorning, ongoing, tomorrow, nextWeek],
                                                  calendar: london)
    #expect(days.map { $0.events.map(\.title) } == [["Now"], ["Tomorrow"]])
    #expect(days.first?.day == date("2026-09-28"))
}

@Test func dayDotsAreUpToThreeDistinctCalendarColours() {
    let events = [event("1", "2026-09-28 08:00", "2026-09-28 09:00", color: blue),
                  event("2", "2026-09-28 09:00", "2026-09-28 10:00", color: blue),
                  event("3", "2026-09-28 10:00", "2026-09-28 11:00", color: green),
                  event("4", "2026-09-28 11:00", "2026-09-28 12:00", color: orange),
                  event("5", "2026-09-28 12:00", "2026-09-28 13:00", color: purple)]
    let day = date("2026-09-28")
    let dots = IslandCalendarAgenda.dots(for: [day, date("2026-09-29")], events: events, calendar: london)
    #expect(dots[day] == [blue, green, orange])
    #expect(dots[date("2026-09-29")] == nil)
}

// MARK: Rule 6, 7, 9 — refresh scheduling

@Test func nextRefreshIsTheNearestBoundaryBoundedByMidnightAndFifteenMinutes() {
    let now = date("2026-09-28 10:00")
    let soon = event("Soon", "2026-09-28 10:05", "2026-09-28 10:30")
    #expect(IslandCalendarSchedule.nextRefresh(after: now, events: [soon], countdown: false, calendar: london)
            == date("2026-09-28 10:05"))
    let ongoing = event("Ongoing", "2026-09-28 09:00", "2026-09-28 10:07")
    #expect(IslandCalendarSchedule.nextRefresh(after: now, events: [ongoing, soon], countdown: false, calendar: london)
            == date("2026-09-28 10:05"))
    #expect(IslandCalendarSchedule.nextRefresh(after: now, events: [ongoing], countdown: false, calendar: london)
            == date("2026-09-28 10:07"))
    let far = event("Far", "2026-09-28 14:00", "2026-09-28 15:00")
    #expect(IslandCalendarSchedule.nextRefresh(after: now, events: [far], countdown: false, calendar: london)
            == date("2026-09-28 10:15"))
    #expect(IslandCalendarSchedule.nextRefresh(after: date("2026-09-28 23:50"), events: [], countdown: false, calendar: london)
            == date("2026-09-29 00:00"))
}

@Test func withTheCountdownOnRefreshesOpenTheHourAndMarkTheStart() {
    let now = date("2026-09-28 10:00")
    let meeting = event("Meeting", "2026-09-28 11:10", "2026-09-28 12:00")
    #expect(IslandCalendarSchedule.nextRefresh(after: now, events: [meeting], countdown: false, calendar: london)
            == date("2026-09-28 10:15"))
    #expect(IslandCalendarSchedule.nextRefresh(after: now, events: [meeting], countdown: true, calendar: london)
            == date("2026-09-28 10:10"))
    #expect(IslandCalendarSchedule.nextRefresh(after: date("2026-09-28 10:59"), events: [meeting], countdown: true, calendar: london)
            == date("2026-09-28 11:10"))
    // An all-day event opens no countdown hour: 22:50 waits the full fifteen minutes, not until 23:00.
    let allDay = event("Holiday", "2026-09-29", "2026-09-30", allDay: true)
    #expect(IslandCalendarSchedule.nextRefresh(after: date("2026-09-28 22:50"), events: [allDay], countdown: true, calendar: london)
            == date("2026-09-28 23:05"))
}

@Test func refreshReachesTheNextLocalDayAcrossDaylightSaving() {
    // 8 March 2026 is 23 hours long in New York; 1 November is 25.
    let spring = IslandCalendarDays.nextMidnight(after: date("2026-03-08 12:00", newYork), calendar: newYork)
    #expect(spring == date("2026-03-09 00:00", newYork))
    #expect(newYork.component(.hour, from: spring) == 0)
    let autumn = IslandCalendarDays.nextMidnight(after: date("2026-11-01 23:30", newYork), calendar: newYork)
    #expect(autumn == date("2026-11-02 00:00", newYork))
    #expect(autumn.timeIntervalSince(date("2026-11-01 23:30", newYork)) == 30 * 60)
}

// MARK: Rule 7, 8 — countdown

@Test func countdownChoosesTheNextTimedStartIgnoringAllDayAndOngoing() {
    let now = date("2026-09-28 10:00")
    let allDay = event("Holiday", "2026-09-28", "2026-09-29", allDay: true)
    let ongoing = event("Ongoing", "2026-09-28 09:30", "2026-09-28 10:30")
    let next = event("Next", "2026-09-28 10:45", "2026-09-28 11:00")
    let later = event("Later", "2026-09-28 11:30", "2026-09-28 12:00")
    let chosen = IslandCalendarCountdown.nextEvent(after: now, in: [later, allDay, next, ongoing])
    #expect(chosen?.title == "Next")
    #expect(IslandCalendarCountdown.nextEvent(after: now, in: [allDay, ongoing]) == nil)
}

@Test func countdownAppearsOnlyInTheHourBeforeAStart() {
    let meeting = event("Meeting", "2026-09-28 11:00", "2026-09-28 12:00")
    #expect(!IslandCalendarCountdown.isLive(meeting, at: date("2026-09-28 09:59:59")))
    #expect(IslandCalendarCountdown.isLive(meeting, at: date("2026-09-28 10:00")))
    #expect(IslandCalendarCountdown.isLive(meeting, at: date("2026-09-28 10:59:59")))
    #expect(!IslandCalendarCountdown.isLive(meeting, at: date("2026-09-28 11:00")))
    let allDay = event("Holiday", "2026-09-29", "2026-09-30", allDay: true)
    #expect(!IslandCalendarCountdown.isLive(allDay, at: date("2026-09-28 23:30")))
}

@Test func countdownClockRoundsUpAndReadsMinutesAndSeconds() {
    let start = date("2026-09-28 11:00")
    #expect(IslandCalendarCountdown.secondsLeft(until: start, now: date("2026-09-28 10:47:55")) == 725)
    #expect(IslandCalendarCountdown.secondsLeft(until: start, now: start.addingTimeInterval(-0.4)) == 1)
    #expect(IslandCalendarCountdown.secondsLeft(until: start, now: start) == 0)
    #expect(IslandCalendarCountdown.clock(725) == "12:05")
    #expect(IslandCalendarCountdown.clock(3600) == "60:00")
    #expect(IslandCalendarCountdown.clock(42) == "0:42")
    #expect(IslandCalendarCountdown.spoken(725) == "12 minutes, 5 seconds")
    #expect(IslandCalendarCountdown.spoken(60) == "1 minute")
    #expect(IslandCalendarCountdown.spoken(1) == "1 second")
    let anchor = IslandCalendarCountdown.tickAnchor(start: start, now: date("2026-09-28 10:47:55").addingTimeInterval(0.3))
    #expect(start.timeIntervalSince(anchor) == 725)
}

@Test func countdownWingsFitTheWiderOfTitleAndClockWithin72To120() {
    let inset = IslandCalendarCountdown.edgeInset(stripHeight: 32, contentHeight: 11 * 0.72)
    #expect(abs(inset - 11.08) < 0.01)
    // A short title: the clock side (00:00 + start time) decides, never below 72.
    #expect(IslandCalendarCountdown.wing(titleSide: IslandCalendarCountdown.titleSide(titleWidth: 20),
                                         clockSide: IslandCalendarCountdown.clockSide(widestClock: 36, startTime: 32),
                                         inset: inset) == 84)
    #expect(IslandCalendarCountdown.wing(titleSide: 30, clockSide: 30, inset: inset) == 72)
    #expect(IslandCalendarCountdown.wing(titleSide: 90.2, clockSide: 60, inset: inset) == 102)
    #expect(IslandCalendarCountdown.wing(titleSide: 400, clockSide: 60, inset: inset) == 120)
}

@Test func countdownUsesTheWingsOrOneRowBelowACrowdedPhysicalCamera() {
    #expect(IslandCalendarCountdown.placement(wing: 100, room: 600, physicalCamera: true) == .wings(100))
    #expect(IslandCalendarCountdown.placement(wing: 100, room: 80, physicalCamera: true) == .wings(80))
    #expect(IslandCalendarCountdown.placement(wing: 100, room: 71, physicalCamera: true) == .belowCamera)
    #expect(IslandCalendarCountdown.placement(wing: 100, room: nil, physicalCamera: true) == .belowCamera)
    #expect(IslandCalendarCountdown.placement(wing: 100, room: 40, physicalCamera: false) == .hidden)
}

@Test func countdownContentKeepsFivePointsFromTheCurveAtEveryBarHeight() {
    // Title text (11 pt), the clock (13 pt) and the round colour dot.
    let contents: [(height: CGFloat, radius: CGFloat)] = [(11 * 0.72, 0), (13 * 0.72, 0), (6, 3)]
    for height in stride(from: CGFloat(24), through: 64, by: 2) {
        let shape = IslandSilhouette(width: 400, height: height)
        for content in contents {
            let inset = IslandCalendarCountdown.edgeInset(stripHeight: height, contentHeight: content.height,
                                                          contentRadius: content.radius)
            let top = (height - content.height) / 2, bottom = top + content.height
            // Every point of the content's left edge and lower corner, grown by just under the gap,
            // stays inside the outline.
            let r = content.radius
            var probes: [CGPoint] = []
            for step in 0...8 {
                let y = top + r + (bottom - top - 2 * r) * CGFloat(step) / 8
                probes.append(CGPoint(x: inset, y: y))
            }
            let corner = CGPoint(x: inset + r, y: bottom - r)
            for step in 0...8 {
                let angle = CGFloat.pi / 2 + CGFloat.pi / 2 * CGFloat(step) / 8
                probes.append(CGPoint(x: corner.x + r * cos(angle), y: corner.y + r * sin(angle)))
            }
            for probe in probes {
                for step in 0..<16 {
                    let angle = 2 * CGFloat.pi * CGFloat(step) / 16
                    let point = CGPoint(x: probe.x + 4.9 * cos(angle), y: probe.y + 4.9 * sin(angle))
                    guard point.y >= 0 else { continue }
                    #expect(shape.contains(point), "height \(height) content \(content.height) at \(point)")
                }
            }
        }
    }
}

// MARK: Rule 10 — month grid and week strip

@Test func monthGridHasSixWholeWeeksFromTheFirstWeekday() {
    for firstWeekday in [1, 2, 7] {
        let cal = calendar("Europe/London", firstWeekday: firstWeekday)
        let grid = IslandCalendarDays.monthGrid(for: date("2026-09-15", cal), calendar: cal)
        #expect(grid.count == 42)
        #expect(Set(grid).count == 42)
        #expect(cal.component(.weekday, from: grid[0]) == firstWeekday)
        #expect(grid.contains(date("2026-09-01", cal)))
        #expect(grid.contains(date("2026-09-30", cal)))
        for (index, day) in grid.enumerated().dropFirst() {
            #expect(cal.dateComponents([.day], from: grid[index - 1], to: day).day == 1)
        }
    }
}

@Test func monthGridIncludesLeapDay() {
    let grid = IslandCalendarDays.monthGrid(for: date("2028-02-10"), calendar: london)
    #expect(grid.contains(date("2028-02-29")))
    #expect(grid.contains(date("2028-03-01")))
}

@Test func gridDatesStayOnTheStartOfTheLocalDayThroughDaylightSaving() {
    let grid = IslandCalendarDays.monthGrid(for: date("2026-03-15", newYork), calendar: newYork)
    for day in grid {
        #expect(newYork.dateComponents([.hour, .minute, .second], from: day) == DateComponents(hour: 0, minute: 0, second: 0))
    }
    // Chile moves its clocks at midnight (6 Sep 2026): that day starts at 01:00 and the grid follows.
    let santiago = calendar("America/Santiago")
    for day in IslandCalendarDays.monthGrid(for: date("2026-09-10", santiago), calendar: santiago) {
        #expect(santiago.startOfDay(for: day) == day)
    }
    #expect(Set(IslandCalendarDays.monthGrid(for: date("2026-09-10", santiago), calendar: santiago)
        .map { santiago.component(.day, from: $0) * 100 + santiago.component(.month, from: $0) }).count == 42)
}

@Test func weekStripStartsOnTheFirstWeekdayContainsItsDayAndFitsTheMonthRead() {
    for firstWeekday in [1, 2] {
        let cal = calendar("Europe/London", firstWeekday: firstWeekday)
        var day = date("2026-01-01", cal)
        for _ in 0..<400 {
            let week = IslandCalendarDays.week(containing: day, calendar: cal)
            #expect(week.count == 7)
            #expect(cal.component(.weekday, from: week[0]) == firstWeekday)
            #expect(week.contains(cal.startOfDay(for: day)))
            let read = IslandCalendarWindow.month(focus: day, now: date("2025-06-01", cal), calendar: cal)
            #expect(read.start <= week[0] && read.end >= IslandCalendarDays.day(1, from: week[6], calendar: cal))
            day = IslandCalendarDays.day(1, from: day, calendar: cal)
        }
    }
}

@Test func shortMonthGridKeepsSixReadableRowsInEveryPresetAndTheSmallestCustomHeight() {
    let notched = IslandDisplayMetrics.make(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                            auxiliaryLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                            auxiliaryRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                            safeAreaTop: 32, barHeight: 33, scale: 2)
    let plain = IslandDisplayMetrics.make(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), auxiliaryLeft: nil,
                                          auxiliaryRight: nil, safeAreaTop: 0, barHeight: 24, scale: 1)
    var heights: [CGFloat] = []
    for display in [notched, plain] {
        for size in IslandSize.allCases {
            for width in [360.0, 600.0] {
                var settings = IslandSettings()
                settings.size = size
                settings.customWidth = width
                settings.customHeight = IslandSettings.customHeightRange.lowerBound
                heights.append(IslandGeometry.openLayout(display, settings: settings, page: .fill).pageHeight)
            }
        }
    }
    for height in heights {
        let row = IslandCalendarLayout.shortGridRow(pageHeight: height)
        #expect(row >= 16)
        let used = IslandCalendarLayout.monthHeaderHeight + IslandCalendarLayout.weekdayRowHeight
            + 2 * IslandCalendarLayout.gridSpacing + 6 * row
        #expect(used <= height, "page \(height)")
    }
    #expect(IslandCalendarLayout.shortGridRow(pageHeight: 264) == 30)
}

@Test func bothPresetsUseTheWeekStripAndOnlyATallWidePageGoesSideBySide() {
    #expect(!IslandCalendarLayout.sideBySide(width: 424, height: 180))
    #expect(!IslandCalendarLayout.sideBySide(width: 504, height: 264))
    #expect(IslandCalendarLayout.sideBySide(width: 504, height: 300))
    #expect(!IslandCalendarLayout.sideBySide(width: 419, height: 400))
    #expect(IslandCalendarLayout.showsTodayButtons(width: 424) && !IslandCalendarLayout.showsTodayButtons(width: 399))
    #expect(IslandCalendarLayout.showsOpenCalendar(width: 340) && !IslandCalendarLayout.showsOpenCalendar(width: 339))
}

// MARK: Rule 11 — read windows

@Test func theDefaultReadIsTodayToSevenDaysLater() {
    let window = IslandCalendarWindow.upcoming(now: date("2026-09-28 15:20"), calendar: london)
    #expect(window.start == date("2026-09-28"))
    #expect(window.end == date("2026-10-05"))
}

@Test func theCurrentMonthsReadCoversTheNextSevenDaysAcrossAMonthBoundary() {
    // August 2026 starts on a Saturday: with Sunday first, its grid ends on 6 September.
    let now = date("2026-08-31 09:00")
    let grid = IslandCalendarDays.monthGridInterval(for: now, calendar: london)
    #expect(grid.end == date("2026-09-06"))
    let read = IslandCalendarWindow.month(focus: now, now: now, calendar: london)
    #expect(read.start == grid.start)
    #expect(read.end == date("2026-09-07"))
}

@Test func aDistantMonthReadsOnlyItsGrid() {
    let now = date("2026-09-28 09:00")
    let focus = date("2027-02-10")
    #expect(IslandCalendarWindow.plan(pageFocus: focus, countdown: false, now: now, calendar: london)
            == [IslandCalendarDays.monthGridInterval(for: focus, calendar: london)])
}

@Test func withTheCountdownOnBrowsingKeepsTodaysWeekWithoutAnExtraReadWhenOff() {
    let now = date("2026-09-28 09:00")
    let week = IslandCalendarWindow.upcoming(now: now, calendar: london)
    let focus = date("2026-12-10")
    let grid = IslandCalendarDays.monthGridInterval(for: focus, calendar: london)
    #expect(IslandCalendarWindow.plan(pageFocus: focus, countdown: true, now: now, calendar: london) == [grid, week])
    #expect(IslandCalendarWindow.plan(pageFocus: focus, countdown: false, now: now, calendar: london) == [grid])
    // The current month already covers the week, so no second read.
    #expect(IslandCalendarWindow.plan(pageFocus: now, countdown: true, now: now, calendar: london).count == 1)
    // October's grid starts on 27 September and covers the week too.
    #expect(IslandCalendarWindow.plan(pageFocus: date("2026-10-03"), countdown: true, now: now, calendar: london).count == 1)
}

@Test func closingThePageReturnsToTheSevenDayWindow() {
    let now = date("2026-09-28 09:00")
    #expect(IslandCalendarWindow.plan(pageFocus: nil, countdown: true, now: now, calendar: london)
            == [IslandCalendarWindow.upcoming(now: now, calendar: london)])
}

// MARK: Rule 13 — occurrence links

@Test func singleEventLinksEscapeTheIdentifier() {
    let url = IslandCalendarLink.url(itemIdentifier: "9F2A 1C", start: date("2026-03-08 13:00"), isAllDay: false,
                                     isRecurring: false, timeZone: london.timeZone)
    #expect(url?.absoluteString == "ical://ekevent/9F2A%201C?method=show&options=more")
    let slash = IslandCalendarLink.url(itemIdentifier: "a/b:c", start: .now, isAllDay: false, isRecurring: false,
                                       timeZone: london.timeZone)
    #expect(slash?.absoluteString == "ical://ekevent/a%2Fb%3Ac?method=show&options=more")
}

@Test func repeatingTimedOccurrencesCarryTheirStartInUTC() {
    let kolkata = calendar("Asia/Kolkata")
    let start = date("2026-03-08 18:30", kolkata)          // 13:00 UTC
    let url = IslandCalendarLink.url(itemIdentifier: "9F2A", start: start, isAllDay: false, isRecurring: true,
                                     timeZone: kolkata.timeZone)
    #expect(url?.absoluteString == "ical://ekevent/20260308T130000Z/9F2A?method=show&options=more")
}

@Test func repeatingAllDayOccurrencesCarryTheLocalDay() {
    let kolkata = calendar("Asia/Kolkata")
    let start = date("2026-03-08", kolkata)                 // 7 March 18:30 UTC
    let url = IslandCalendarLink.url(itemIdentifier: "9F2A", start: start, isAllDay: true, isRecurring: true,
                                     timeZone: kolkata.timeZone)
    #expect(url?.absoluteString == "ical://ekevent/20260308T000000Z/9F2A?method=show&options=more")
}

@Test func withoutAnIdentifierThereIsNoLinkAndCalendarOpensItself() {
    #expect(IslandCalendarLink.url(itemIdentifier: nil, start: .now, isAllDay: false, isRecurring: true, timeZone: .current) == nil)
    #expect(IslandCalendarLink.url(itemIdentifier: "", start: .now, isAllDay: false, isRecurring: false, timeZone: .current) == nil)
}

// MARK: Text

@Test func timeLinesReadAllDaySameDayOrAcrossDays() {
    let text = IslandCalendarText(calendar: london, locale: Locale(identifier: "en_GB"))
    #expect(text.timeLine(event("A", "2026-09-28", "2026-09-29", allDay: true)) == "All day")
    #expect(text.timeLine(event("B", "2026-09-28 10:00", "2026-09-28 11:00")) == "10:00 · 11:00")
    #expect(text.timeLine(event("C", "2026-09-28 23:00", "2026-09-29 00:00")) == "23:00 · 00:00")
    #expect(text.timeLine(event("D", "2026-03-08 10:00", "2026-03-09 11:00")) == "8 Mar, 10:00 → 9 Mar, 11:00")
}

@Test func dayHeadingsNameTodayAndOtherDays() {
    let text = IslandCalendarText(calendar: london, locale: Locale(identifier: "en_GB"))
    let now = date("2026-09-28 10:00")
    #expect(text.dayHeading(date("2026-09-28"), now: now) == ("Today", "28 Sep"))
    #expect(text.dayHeading(date("2026-09-29"), now: now) == (nil, "Tue 29 Sep"))
    #expect(text.monthTitle(now) == "September 2026")
}

@Test func timesFollowTheRegionsClock() {
    let us = IslandCalendarText(calendar: london, locale: Locale(identifier: "en_US"))
    #expect(us.time(date("2026-09-28 15:00")).contains("PM"))
    let uk = IslandCalendarText(calendar: london, locale: Locale(identifier: "en_GB"))
    #expect(uk.time(date("2026-09-28 15:00")) == "15:00")
}

@Test func weekdayLettersStartOnTheFirstWeekday() {
    #expect(IslandCalendarText(calendar: calendar("Europe/London", firstWeekday: 2), locale: Locale(identifier: "en_GB"))
        .weekdayLetters == ["M", "T", "W", "T", "F", "S", "S"])
    #expect(IslandCalendarText(calendar: calendar("Europe/London", firstWeekday: 1), locale: Locale(identifier: "en_GB"))
        .weekdayLetters.first == "S")
}

@Test func blankTitlesReadAsUntitled() {
    var blank = event("x", "2026-09-28 10:00", "2026-09-28 11:00")
    blank.title = "  "
    #expect(blank.displayTitle == "Untitled event")
}
