import Foundation

/// The calendar page's dates and times. Names follow the app's language; date order, the 12- or
/// 24-hour clock and the first weekday follow the system region, because every format comes from a
/// template resolved against the current locale. Build a new one when the locale or time zone changes.
public final class IslandCalendarText {
    public let calendar: Calendar
    private let time: DateFormatter
    private let dayMonth: DateFormatter
    private let weekdayDayMonth: DateFormatter
    private let monthYear: DateFormatter
    private let monthName: DateFormatter
    private let yearName: DateFormatter

    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        var calendar = calendar
        calendar.locale = locale
        self.calendar = calendar
        func formatter(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        time = formatter("jmm")
        dayMonth = formatter("dMMM")
        weekdayDayMonth = formatter("EEEdMMM")
        monthYear = formatter("MMMMyyyy")
        monthName = formatter("LLLL")
        yearName = formatter("y")
    }

    public func time(_ date: Date) -> String { time.string(from: date) }

    /// "All day", "10:00 · 11:00" within one day, or "8 Mar, 10:00 → 9 Mar, 11:00" across days. An
    /// event ending exactly at midnight still reads as one day.
    public func timeLine(_ event: IslandCalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        let lastMoment = event.end.addingTimeInterval(-1)
        if calendar.isDate(event.start, inSameDayAs: max(event.start, lastMoment)) {
            return "\(time(event.start)) · \(time(event.end))"
        }
        return "\(dayMonth.string(from: event.start)), \(time(event.start)) → \(dayMonth.string(from: event.end)), \(time(event.end))"
    }

    /// A day heading: ("Today", "28 Sep") for today, (nil, "Mon 29 Sep") otherwise.
    public func dayHeading(_ day: Date, now: Date) -> (today: String?, date: String) {
        calendar.isDate(day, inSameDayAs: now) ? ("Today", dayMonth.string(from: day)) : (nil, weekdayDayMonth.string(from: day))
    }

    /// "Mon 29 Sep".
    public func dayTitle(_ day: Date) -> String { weekdayDayMonth.string(from: day) }
    /// "September 2026".
    public func monthTitle(_ date: Date) -> String { monthYear.string(from: date) }
    /// "September" over "2026" in the side-by-side grid.
    public func monthName(_ date: Date) -> String { monthName.string(from: date) }
    public func year(_ date: Date) -> String { yearName.string(from: date) }

    /// One letter per weekday, starting at the person's first weekday.
    public var weekdayLetters: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }

    public func dayNumber(_ day: Date) -> String { String(calendar.component(.day, from: day)) }
}
