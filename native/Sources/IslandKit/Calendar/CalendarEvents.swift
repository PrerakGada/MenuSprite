import Foundation

/// A calendar's colour in sRGB. Colours cross from the EventKit reader to the views as plain numbers,
/// so nothing that is not `Sendable` leaves the reader.
public struct IslandCalendarColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    /// Used when a calendar reports no colour.
    public static let fallback = IslandCalendarColor(red: 0.56, green: 0.56, blue: 0.6)
}

/// One occurrence of an event, reduced to the values the island draws. Occurrences of a repeating
/// series share an event identifier, so the identity adds the start time.
public struct IslandCalendarEvent: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var calendarTitle: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var color: IslandCalendarColor
    /// The calendar item identifier Calendar.app shows an event by; nil opens Calendar itself.
    public var itemIdentifier: String?
    /// A repeating event, or a detached occurrence of one: its link must carry the occurrence date.
    public var isRecurring: Bool

    public init(id: String, title: String, calendarTitle: String, start: Date, end: Date, isAllDay: Bool,
                location: String? = nil, color: IslandCalendarColor = .fallback, itemIdentifier: String? = nil,
                isRecurring: Bool = false) {
        self.id = id; self.title = title; self.calendarTitle = calendarTitle; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.location = location; self.color = color; self.itemIdentifier = itemIdentifier
        self.isRecurring = isRecurring
    }

    /// Event identifier plus start time.
    public static func identity(eventIdentifier: String, start: Date) -> String {
        "\(eventIdentifier)@\(Int64(start.timeIntervalSinceReferenceDate.rounded()))"
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled event" : trimmed
    }

    /// A timed event that has begun and not ended.
    public func isHappening(at now: Date) -> Bool { !isAllDay && start <= now && end > now }
    public func hasEnded(at now: Date) -> Bool { end <= now }
    /// End dates are exclusive, so an event ending at midnight does not touch the next day.
    public func overlaps(_ interval: DateInterval) -> Bool { start < interval.end && end > interval.start }
}

/// What the reader hands over before filtering: an event plus the facts that exclude it.
public struct IslandCalendarRecord: Sendable {
    public var event: IslandCalendarEvent
    public var isCancelled: Bool
    /// The person is an attendee and declined.
    public var isDeclined: Bool

    public init(event: IslandCalendarEvent, isCancelled: Bool = false, isDeclined: Bool = false) {
        self.event = event; self.isCancelled = isCancelled; self.isDeclined = isDeclined
    }
}

public enum IslandCalendarOrdering {
    /// Drops cancelled and declined events, invalid dates and zero or negative durations, keeps one
    /// copy of each occurrence, and sorts by start, then end, then identity.
    public static func normalize(_ records: [IslandCalendarRecord]) -> [IslandCalendarEvent] {
        var seen = Set<String>()
        var events: [IslandCalendarEvent] = []
        for record in records where !record.isCancelled && !record.isDeclined {
            let event = record.event
            let start = event.start.timeIntervalSinceReferenceDate, end = event.end.timeIntervalSinceReferenceDate
            guard start.isFinite, end.isFinite, end > start, seen.insert(event.id).inserted else { continue }
            events.append(event)
        }
        return events.sorted(by: chronological)
    }

    public static func chronological(_ a: IslandCalendarEvent, _ b: IslandCalendarEvent) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end < b.end }
        return a.id < b.id
    }

    /// A day's list: all-day events first, then by start.
    public static func dayOrder(_ a: IslandCalendarEvent, _ b: IslandCalendarEvent) -> Bool {
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        return chronological(a, b)
    }
}

/// The calendar permission as the page presents it. Only full access counts as granted.
public enum IslandCalendarAccess: Equatable, Sendable {
    /// Not asked yet, or only write access: the page offers the request.
    case askable
    /// Denied or restricted: only System Settings can change it.
    case refused
    case granted

    /// EventKit's authorisation states, mirrored so this library needs no EventKit.
    public enum Status: Sendable {
        case notDetermined, restricted, denied, fullAccess, writeOnly
    }

    public init(_ status: Status) {
        switch status {
        case .fullAccess: self = .granted
        case .denied, .restricted: self = .refused
        case .notDetermined, .writeOnly: self = .askable
        }
    }

    /// A request that ends without a real answer (still undetermined, or write-only) failed; granted and
    /// explicit refusals keep their own presentation.
    public static func requestFailed(statusAfterRequest status: Status) -> Bool {
        status == .notDetermined || status == .writeOnly
    }
}
