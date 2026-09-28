import CoreGraphics
import EventKit
import IslandKit

/// Reads events off the main actor. It owns the section's one EventKit store, creates it only once
/// full access is granted (creating or querying a store never asks for access), and drops it whenever
/// the section stops reading. `EKEvent` is not `Sendable`, so only plain values leave this actor.
actor CalendarEventSource {
    private var store: EKEventStore?

    static var status: IslandCalendarAccess.Status {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// Events from every calendar overlapping any of the windows, filtered, de-duplicated and sorted.
    func events(in windows: [DateInterval]) -> [IslandCalendarEvent] {
        guard Self.status == .fullAccess else { store = nil; return [] }
        let store = self.store ?? EKEventStore()
        self.store = store
        var records: [IslandCalendarRecord] = []
        for window in windows {
            let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
            records += store.events(matching: predicate).map(Self.record)
        }
        return IslandCalendarOrdering.normalize(records)
    }

    func release() { store = nil }

    private static func record(_ event: EKEvent) -> IslandCalendarRecord {
        let start: Date = event.startDate ?? .distantPast
        let end: Date = event.endDate ?? start
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = IslandCalendarEvent(
            id: IslandCalendarEvent.identity(eventIdentifier: identifier, start: start),
            title: event.title ?? "",
            calendarTitle: event.calendar?.title ?? "",
            start: start, end: end, isAllDay: event.isAllDay,
            location: location?.isEmpty == false ? location : nil,
            color: color(event.calendar?.cgColor),
            itemIdentifier: event.calendarItemIdentifier.isEmpty ? nil : event.calendarItemIdentifier,
            isRecurring: event.hasRecurrenceRules || event.isDetached)
        let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
        return IslandCalendarRecord(event: value, isCancelled: event.status == .canceled, isDeclined: declined)
    }

    private static func color(_ color: CGColor?) -> IslandCalendarColor {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 3 else { return .fallback }
        return IslandCalendarColor(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }
}
