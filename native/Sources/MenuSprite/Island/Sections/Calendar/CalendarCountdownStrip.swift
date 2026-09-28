import AppKit
import IslandKit
import SwiftUI

/// The closed island's countdown to the next timed event: the calendar's dot and the title on the
/// left, a ticking "M:SS" and the start time on the right. Wings are measured once per event, with
/// the widest clock, so the island never resizes as the seconds tick. The once-a-second clock is a
/// timeline inside the strip, so it exists only while the strip is on screen.
@MainActor
enum CalendarCountdownStrip {
    static let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    static let startFont = NSFont.systemFont(ofSize: 11)

    static func make(_ event: IslandCalendarEvent, text: IslandCalendarText) -> IslandCompactStrip {
        let startTime = "· " + text.time(event.start)
        let inset = IslandCalendarCountdown.edgeInset(stripHeight: IslandCalendarCountdown.nominalStripHeight,
                                                      contentHeight: 13 * 0.72)
        let wing = IslandCalendarCountdown.wing(
            titleSide: IslandCalendarCountdown.titleSide(titleWidth: width(event.displayTitle, titleFont)),
            clockSide: IslandCalendarCountdown.clockSide(widestClock: width("00:00", clockFont), startTime: width(startTime, startFont)),
            inset: inset)
        return IslandCompactStrip(kind: .calendar, wing: wing, minimumRoom: IslandCalendarCountdown.minimumRoom,
                                  allowsFooter: true,
                                  left: AnyView(CountdownTitleWing(event: event)),
                                  right: AnyView(CountdownClockWing(event: event, startTime: startTime)))
    }

    private static func width(_ string: String, _ font: NSFont) -> CGFloat {
        NSAttributedString(string: string, attributes: [.font: font]).size().width
    }
}

private struct CountdownTitleWing: View {
    let event: IslandCalendarEvent

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: IslandCalendarCountdown.dotGap) {
                Circle()
                    .fill(Color(calendar: event.color))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
                    .frame(width: IslandCalendarCountdown.dotSize, height: IslandCalendarCountdown.dotSize)
                Text(event.displayTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, IslandCalendarCountdown.edgeInset(stripHeight: proxy.size.height, contentHeight: 11 * 0.72))
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Up next: \(event.displayTitle)")
    }
}

private struct CountdownClockWing: View {
    let event: IslandCalendarEvent
    let startTime: String

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: IslandCalendarCountdown.tickAnchor(start: event.start, now: Date()), by: 1)) { timeline in
                let seconds = IslandCalendarCountdown.secondsLeft(until: event.start, now: max(timeline.date, Date()))
                let clock = IslandCalendarCountdown.clock(seconds)
                // A wing narrowed by the menus keeps just the clock.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: IslandCalendarCountdown.clockGap) {
                        clockText(clock)
                        Text(startTime)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    clockText(clock)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Up next: \(event.displayTitle)")
                .accessibilityValue(IslandCalendarCountdown.spoken(seconds))
            }
            .padding(.trailing, IslandCalendarCountdown.edgeInset(stripHeight: proxy.size.height, contentHeight: 13 * 0.72))
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
    }

    private func clockText(_ clock: String) -> some View {
        Text(clock)
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

extension Color {
    init(calendar color: IslandCalendarColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
    }
}
