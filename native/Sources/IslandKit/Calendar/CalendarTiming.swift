import CoreGraphics
import Foundation

/// When the reader looks again. There is no polling: one one-shot timer at the nearest moment
/// something on screen could change.
public enum IslandCalendarSchedule {
    public static let maximumWait: TimeInterval = 15 * 60

    /// The nearest future moment among: any event's next start or end, local midnight, and fifteen
    /// minutes from now. With the countdown on, also the moment each timed event's final hour opens.
    public static func nextRefresh(after now: Date, events: [IslandCalendarEvent], countdown: Bool,
                                   calendar: Calendar) -> Date {
        var next = min(now.addingTimeInterval(maximumWait), IslandCalendarDays.nextMidnight(after: now, calendar: calendar))
        for event in events where event.end > now {
            if event.start > now { next = min(next, event.start) }
            next = min(next, event.end)
            if countdown, !event.isAllDay {
                let opens = event.start.addingTimeInterval(-IslandCalendarCountdown.lead)
                if opens > now { next = min(next, opens) }
            }
        }
        return next
    }
}

/// The closed island's countdown to the next timed event.
public enum IslandCalendarCountdown {
    /// The countdown shows during the hour before a start.
    public static let lead: TimeInterval = 60 * 60
    public static let wingRange: ClosedRange<CGFloat> = 72...120
    public static let minimumRoom: CGFloat = 72
    /// The strip's gap between its content and its outline.
    public static let edgeGap: CGFloat = 5
    public static let dotSize: CGFloat = 6
    public static let dotGap: CGFloat = 5
    public static let clockGap: CGFloat = 4
    /// Wings are fitted for this strip height; the views inset themselves by their real height.
    public static let nominalStripHeight: CGFloat = 32

    /// The next timed start: never an all-day event, never one already under way.
    public static func nextEvent(after now: Date, in events: [IslandCalendarEvent]) -> IslandCalendarEvent? {
        events.sorted(by: IslandCalendarOrdering.chronological).first { !$0.isAllDay && $0.start > now }
    }

    public static func isLive(_ event: IslandCalendarEvent, at now: Date) -> Bool {
        let left = event.start.timeIntervalSince(now)
        return !event.isAllDay && left > 0 && left <= lead
    }

    /// Whole seconds left, rounded up so the clock never reads 0:00 before the start.
    public static func secondsLeft(until start: Date, now: Date) -> Int {
        max(0, Int((start.timeIntervalSince(now) - 0.001).rounded(.up)))
    }

    /// "M:SS": minutes unpadded, seconds padded.
    public static func clock(_ seconds: Int) -> String {
        let value = max(0, seconds)
        let tens = value % 60 < 10 ? "0" : ""
        return "\(value / 60):\(tens)\(value % 60)"
    }

    /// "12 minutes, 5 seconds", for VoiceOver.
    public static func spoken(_ seconds: Int) -> String {
        let value = max(0, seconds)
        let minutes = value / 60, rest = value % 60
        func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
        if minutes == 0 { return unit(rest, "second") }
        if rest == 0 { return unit(minutes, "minute") }
        return unit(minutes, "minute") + ", " + unit(rest, "second")
    }

    /// The anchor a once-a-second clock ticks from, so each tick lands exactly when the reading changes.
    public static func tickAnchor(start: Date, now: Date) -> Date {
        start.addingTimeInterval(-Double(secondsLeft(until: start, now: now)))
    }

    /// Dot, gap and title.
    public static func titleSide(titleWidth: CGFloat) -> CGFloat { dotSize + dotGap + titleWidth }

    /// Measured with the widest clock ("00:00") and the start time, so the island does not resize as
    /// the minutes tick.
    public static func clockSide(widestClock: CGFloat, startTime: CGFloat) -> CGFloat { widestClock + clockGap + startTime }

    /// Both wings take what the wider side needs, within 72…120.
    public static func wing(titleSide: CGFloat, clockSide: CGFloat, inset: CGFloat) -> CGFloat {
        min(wingRange.upperBound, max(wingRange.lowerBound, (max(titleSide, clockSide) + inset).rounded(.up)))
    }

    public enum Placement: Equatable, Sendable {
        case wings(CGFloat)
        /// One camera-wide row below a physical camera.
        case belowCamera
        case hidden
    }

    /// Wings when the menus leave at least 72 pt (narrowed to the room), else one row below a physical
    /// camera; a drawn camera has no row below.
    public static func placement(wing: CGFloat, room: CGFloat?, physicalCamera: Bool) -> Placement {
        if let room, room >= minimumRoom { return .wings(min(wing, room)) }
        return physicalCamera ? .belowCamera : .hidden
    }

    /// How far from the strip's end content must start to keep the edge gap from the outline: past
    /// the shoulder, and clear of the bottom corner's arc for a vertically centred box of this height
    /// and corner radius. Text uses 0.72 × its font size as its height.
    public static func edgeInset(stripHeight: CGFloat, contentHeight: CGFloat, contentRadius: CGFloat = 0) -> CGFloat {
        let shape = IslandSilhouette(width: 1000, height: stripHeight)
        let shoulder = shape.shoulder, radius = shape.bottomRadius
        let straight = shoulder + edgeGap
        let cornerCentre = (stripHeight + contentHeight) / 2 - contentRadius
        let arcTop = stripHeight - radius
        guard cornerCentre > arcTop else { return straight }
        let rise = cornerCentre - arcTop
        let reach = radius - edgeGap - contentRadius
        guard reach > rise else { return shoulder + radius }
        return max(straight, shoulder + radius - contentRadius - (reach * reach - rise * rise).squareRoot())
    }
}

/// Links that bring Calendar.app to one exact occurrence, in the form macOS's own event alerts use.
public enum IslandCalendarLink {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `ical://ekevent/<id>?method=show&options=more`. A repeating event's occurrences share one
    /// identifier, so the occurrence start goes before it: in UTC for a timed event, and as the local
    /// day at 00:00:00 (still marked Z) for an all-day one. Nil without an identifier: open Calendar.
    public static func url(itemIdentifier: String?, start: Date, isAllDay: Bool, isRecurring: Bool,
                           timeZone: TimeZone) -> URL? {
        guard let itemIdentifier, !itemIdentifier.isEmpty,
              let escaped = itemIdentifier.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        var path = escaped
        if isRecurring { path = occurrenceStamp(start: start, isAllDay: isAllDay, timeZone: timeZone) + "/" + escaped }
        return URL(string: "ical://ekevent/\(path)?method=show&options=more")
    }

    public static func url(for event: IslandCalendarEvent, timeZone: TimeZone = .current) -> URL? {
        url(itemIdentifier: event.itemIdentifier, start: event.start, isAllDay: event.isAllDay,
            isRecurring: event.isRecurring, timeZone: timeZone)
    }

    static func occurrenceStamp(start: Date, isAllDay: Bool, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = isAllDay ? timeZone : TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        let day = String(format: "%04d", parts.year ?? 0) + two(parts.month) + two(parts.day)
        let time = isAllDay ? "000000" : two(parts.hour) + two(parts.minute) + two(parts.second)
        return day + "T" + time + "Z"
    }
}
