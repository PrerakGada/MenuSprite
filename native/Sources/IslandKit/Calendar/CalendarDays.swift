import CoreGraphics
import Foundation

/// Day and month arithmetic. Every day is the start of a local day computed with calendar arithmetic
/// from a noon anchor, so dates stay on local midnight through daylight-saving changes (and on the
/// real start of the day where a change skips midnight).
public enum IslandCalendarDays {
    public static func day(_ offset: Int, from date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        let noon = calendar.date(byAdding: .hour, value: 12, to: start) ?? start
        let moved = calendar.date(byAdding: .day, value: offset, to: noon) ?? noon
        return calendar.startOfDay(for: moved)
    }

    public static func interval(of day: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        return DateInterval(start: start, end: Self.day(1, from: start, calendar: calendar))
    }

    public static func firstOfMonth(_ date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.startOfDay(for: calendar.date(from: parts) ?? date)
    }

    /// The first day of the month `offset` months from the one containing `date`.
    public static func month(_ offset: Int, from date: Date, calendar: Calendar) -> Date {
        let first = firstOfMonth(date, calendar: calendar)
        let noon = calendar.date(byAdding: .hour, value: 12, to: first) ?? first
        return firstOfMonth(calendar.date(byAdding: .month, value: offset, to: noon) ?? noon, calendar: calendar)
    }

    /// The first day of the week containing `date`, honouring the person's first weekday.
    public static func weekStart(containing date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        let back = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return day(-back, from: start, calendar: calendar)
    }

    public static func week(containing date: Date, calendar: Calendar) -> [Date] {
        let start = weekStart(containing: date, calendar: calendar)
        return (0..<7).map { day($0, from: start, calendar: calendar) }
    }

    /// A month's grid: six whole weeks from the first weekday on or before the 1st.
    public static func monthGrid(for date: Date, calendar: Calendar) -> [Date] {
        let start = weekStart(containing: firstOfMonth(date, calendar: calendar), calendar: calendar)
        return (0..<42).map { day($0, from: start, calendar: calendar) }
    }

    public static func monthGridInterval(for date: Date, calendar: Calendar) -> DateInterval {
        let start = weekStart(containing: firstOfMonth(date, calendar: calendar), calendar: calendar)
        return DateInterval(start: start, end: day(42, from: start, calendar: calendar))
    }

    /// The next local midnight after `now`.
    public static func nextMidnight(after now: Date, calendar: Calendar) -> Date {
        day(1, from: now, calendar: calendar)
    }
}

/// Which dates the reader asks EventKit for.
public enum IslandCalendarWindow {
    /// Local midnight today to seven days later: the agenda's "Next 7 days" and the countdown.
    public static func upcoming(now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        return DateInterval(start: today, end: IslandCalendarDays.day(7, from: today, calendar: calendar))
    }

    /// What a page focused on `focus` reads: that month's 42-day grid, stretched to cover the next
    /// seven days when it is the current month (the grid can end before today + 7).
    public static func month(focus: Date, now: Date, calendar: Calendar) -> DateInterval {
        let grid = IslandCalendarDays.monthGridInterval(for: focus, calendar: calendar)
        guard calendar.isDate(focus, equalTo: now, toGranularity: .month) else { return grid }
        let week = upcoming(now: now, calendar: calendar)
        return DateInterval(start: min(grid.start, week.start), end: max(grid.end, week.end))
    }

    /// The windows to read. With the page closed, the next seven days. With the page open, the
    /// focused month only — plus the next seven days separately when the countdown is on and the
    /// month does not cover them, so browsing never loses the countdown. A distant month never pulls
    /// in the months between.
    public static func plan(pageFocus: Date?, countdown: Bool, now: Date, calendar: Calendar) -> [DateInterval] {
        let week = upcoming(now: now, calendar: calendar)
        guard let pageFocus else { return [week] }
        let visible = month(focus: pageFocus, now: now, calendar: calendar)
        let covers = visible.start <= week.start && visible.end >= week.end
        return countdown && !covers ? [visible, week] : [visible]
    }
}

/// Which events a day shows, and the agenda's two lists.
public enum IslandCalendarAgenda {
    public struct Day: Identifiable, Hashable, Sendable {
        public var day: Date
        public var events: [IslandCalendarEvent]
        public var id: Date { day }
    }

    /// Everything overlapping the day, ended or not: all-day first, then by start. Overnight and
    /// multi-day events appear on every day they touch.
    public static func events(on day: Date, in events: [IslandCalendarEvent], calendar: Calendar) -> [IslandCalendarEvent] {
        let interval = IslandCalendarDays.interval(of: day, calendar: calendar)
        return events.filter { $0.overlaps(interval) }.sorted(by: IslandCalendarOrdering.dayOrder)
    }

    /// Today and the six days after it, keeping only events that have not ended; empty days are left out.
    public static func nextSevenDays(now: Date, events: [IslandCalendarEvent], calendar: Calendar) -> [Day] {
        let pending = events.filter { !$0.hasEnded(at: now) }
        return (0..<7).compactMap { offset in
            let day = IslandCalendarDays.day(offset, from: now, calendar: calendar)
            let list = Self.events(on: day, in: pending, calendar: calendar)
            return list.isEmpty ? nil : Day(day: day, events: list)
        }
    }

    /// The first timed event that has not ended. It advances exactly when the previous one ends, and
    /// an all-day event never hides the current appointment.
    public static func upNext(now: Date, in events: [IslandCalendarEvent]) -> IslandCalendarEvent? {
        events.sorted(by: IslandCalendarOrdering.chronological).first { !$0.isAllDay && $0.end > now }
    }

    /// Up to three distinct calendar colours per day, in event order, for the dots under each date.
    public static func dots(for days: [Date], events: [IslandCalendarEvent], calendar: Calendar,
                            limit: Int = 3) -> [Date: [IslandCalendarColor]] {
        var result: [Date: [IslandCalendarColor]] = [:]
        for day in days {
            let interval = IslandCalendarDays.interval(of: day, calendar: calendar)
            var colors: [IslandCalendarColor] = []
            for event in events where event.overlaps(interval) && !colors.contains(event.color) {
                colors.append(event.color)
                if colors.count == limit { break }
            }
            if !colors.isEmpty { result[day] = colors }
        }
        return result
    }
}

/// The page's measurements, shared by the page and its tests.
public enum IslandCalendarLayout {
    public static let weekStripHeight: CGFloat = 52
    public static let monthHeaderHeight: CGFloat = 28
    public static let weekdayRowHeight: CGFloat = 14
    public static let gridSpacing: CGFloat = 2
    public static let sideMonthWidth: CGFloat = 196
    public static let sideDayCell: CGFloat = 30
    public static let rowRange: ClosedRange<CGFloat> = 16...30

    /// Month grid beside the agenda only when the page is at least 300 tall and 420 wide; both presets
    /// get the week strip over the agenda.
    public static func sideBySide(width: CGFloat, height: CGFloat) -> Bool { width >= 420 && height >= 300 }

    /// Today and Next 7 days fit beside the week from 400 pt; Open Calendar from 340 pt.
    public static func showsTodayButtons(width: CGFloat) -> Bool { width >= 400 }
    public static func showsOpenCalendar(width: CGFloat) -> Bool { width >= 340 }

    /// Row height for the short island's month grid: six rows share what is left under the header
    /// and weekday row, 16…30 pt each.
    public static func shortGridRow(pageHeight: CGFloat) -> CGFloat {
        let available = pageHeight - monthHeaderHeight - weekdayRowHeight - 2 * gridSpacing
        return min(rowRange.upperBound, max(rowRange.lowerBound, (available / 6).rounded(.down)))
    }
}
