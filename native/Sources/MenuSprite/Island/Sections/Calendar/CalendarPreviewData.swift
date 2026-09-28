import Foundation
import IslandKit

/// Harness-only sample data, so the page can be rendered without reading real calendars or asking
/// for access: `MenuSprite --island-render <dir> --section calendar --calendar-preview <state>`.
/// Honoured only while the environment is headless.
struct CalendarPreviewData {
    enum State: String {
        /// Not asked yet, refused in System Settings, or a request that did not resolve.
        case ask, refused, failed
        /// Granted with sample events: the seven-day agenda, the short month grid, one chosen day.
        case events, month, day
    }

    let state: State

    static func requested() -> CalendarPreviewData? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--calendar-preview"), arguments.indices.contains(index + 1),
              let state = State(rawValue: arguments[index + 1]) else { return nil }
        return CalendarPreviewData(state: state)
    }

    var status: IslandCalendarAccess.Status {
        switch state {
        case .ask, .failed: .notDetermined
        case .refused: .denied
        case .events, .month, .day: .fullAccess
        }
    }

    func selectedDay(calendar: Calendar) -> Date? {
        state == .day ? IslandCalendarDays.day(1, from: Date(), calendar: calendar) : nil
    }

    /// A believable week around now: something under way, a meeting twelve minutes out (the
    /// countdown), an overnight trip, a multi-day all-day event and a few dots across the month.
    func events(now: Date, calendar: Calendar) -> [IslandCalendarEvent] {
        let base = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 300).rounded(.down) * 300)
        let today = calendar.startOfDay(for: now)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let start = IslandCalendarDays.day(day, from: today, calendar: calendar)
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) ?? start
        }
        let blue = IslandCalendarColor(red: 0.04, green: 0.52, blue: 1)
        let purple = IslandCalendarColor(red: 0.69, green: 0.32, blue: 0.87)
        let green = IslandCalendarColor(red: 0.2, green: 0.78, blue: 0.35)
        let orange = IslandCalendarColor(red: 1, green: 0.62, blue: 0.04)
        let red = IslandCalendarColor(red: 1, green: 0.27, blue: 0.23)
        var index = 0
        func event(_ title: String, _ calendarTitle: String, _ start: Date, _ end: Date, _ color: IslandCalendarColor,
                   allDay: Bool = false, location: String? = nil, recurring: Bool = false) -> IslandCalendarEvent {
            index += 1
            return IslandCalendarEvent(id: IslandCalendarEvent.identity(eventIdentifier: "preview-\(index)", start: start),
                                       title: title, calendarTitle: calendarTitle, start: start, end: end, isAllDay: allDay,
                                       location: location, color: color, itemIdentifier: "preview-\(index)",
                                       isRecurring: recurring)
        }
        return IslandCalendarOrdering.normalize([
            event("Planning week", "Work", today, IslandCalendarDays.day(3, from: today, calendar: calendar), purple, allDay: true),
            event("Morning stand-up", "Work", base.addingTimeInterval(-3 * 3600), base.addingTimeInterval(-2.75 * 3600), blue,
                  recurring: true),
            event("Design review", "Work", base.addingTimeInterval(-20 * 60), base.addingTimeInterval(25 * 60), blue,
                  location: "Room 4"),
            event("Supplier call", "Work", base.addingTimeInterval(12 * 60), base.addingTimeInterval(42 * 60), orange),
            event("Gym", "Personal", base.addingTimeInterval(3 * 3600), base.addingTimeInterval(4 * 3600), green),
            event("Dentist", "Personal", at(1, 10), at(1, 10, 45), green, location: "Linking Road, Bandra"),
            event("Team lunch", "Work", at(1, 13), at(1, 14), blue),
            event("Night train", "Travel", at(2, 22), at(3, 6, 30), purple, location: "Mumbai Central"),
            event("Release review", "Work", at(5, 16), at(5, 17), red, recurring: true),
            event("Quarterly filing", "Company", at(9, 11), at(9, 12), orange),
            event("Workshop", "Work", at(12, 9), at(12, 17), blue),
            event("Birthday", "Personal", at(-4, 0), at(-3, 0), red, allDay: true),
            event("Offsite", "Work", at(-10, 9), at(-10, 18), purple),
        ].map { IslandCalendarRecord(event: $0) })
    }
}
