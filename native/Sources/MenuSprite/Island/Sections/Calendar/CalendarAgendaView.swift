import IslandKit
import SwiftUI

/// The agenda: the next seven days grouped by day (only events that have not ended), or one chosen
/// day with everything on it, ended events included and all-day events first.
struct CalendarAgendaView: View {
    @ObservedObject var model: CalendarModel
    let now: Date
    /// The side-by-side layout titles the seven-day list; the short island has no room for it.
    var showsWeekTitle = false

    var body: some View {
        let upNext = IslandCalendarAgenda.upNext(now: now, in: model.events)?.id
        VStack(alignment: .leading, spacing: 6) {
            if let day = model.selectedDay {
                dayHeader(day)
                let events = IslandCalendarAgenda.events(on: day, in: model.events, calendar: model.calendar)
                list(isEmpty: events.isEmpty, empty: "Nothing on this day") {
                    ForEach(events) { card($0, upNext: upNext) }
                }
            } else {
                if showsWeekTitle {
                    Text("Next 7 days").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .frame(height: 22)
                }
                let days = IslandCalendarAgenda.nextSevenDays(now: now, events: model.events, calendar: model.calendar)
                list(isEmpty: days.isEmpty, empty: "Nothing coming up") {
                    ForEach(days) { group in
                        dayLabel(group.day)
                        ForEach(group.events) { card($0, upNext: upNext) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func list<Rows: View>(isEmpty: Bool, empty: String, @ViewBuilder rows: () -> Rows) -> some View {
        if !model.hasLoaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "calendar.badge.checkmark").font(.system(size: 20)).foregroundStyle(IslandStyle.tertiaryText)
                Text(empty).font(.system(size: 12, weight: .medium)).foregroundStyle(IslandStyle.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) { rows() }
                    .padding(.bottom, 2)
            }
        }
    }

    private func dayHeader(_ day: Date) -> some View {
        HStack(spacing: 6) {
            Text(model.text.dayTitle(day)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            Spacer(minLength: 4)
            Button { model.showNextSevenDays() } label: {
                Label("Next 7 days", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
            }
            .buttonStyle(IslandButtonStyle(cornerRadius: 11))
        }
        .frame(height: 22)
    }

    private func dayLabel(_ day: Date) -> some View {
        let heading = model.text.dayHeading(day, now: now)
        return HStack(spacing: 4) {
            if let today = heading.today { Text(today).foregroundStyle(.white) }
            Text(heading.date).foregroundStyle(Color.white.opacity(0.5))
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.top, 2)
    }

    private func card(_ event: IslandCalendarEvent, upNext: String?) -> some View {
        CalendarEventCard(event: event, now: now, isUpNext: event.id == upNext, timeLine: model.text.timeLine(event)) {
            model.open(event)
        }
    }
}

/// One event as a button that brings Calendar to that exact occurrence.
struct CalendarEventCard: View {
    let event: IslandCalendarEvent
    let now: Date
    let isUpNext: Bool
    let timeLine: String
    let open: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let happening = event.isHappening(at: now)
        let ended = event.hasEnded(at: now)
        let tint = Color(calendar: event.color)
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Button(action: open) {
            HStack(spacing: 0) {
                Rectangle().fill(tint).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    if happening {
                        Text("Happening now").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.mint)
                    } else if isUpNext {
                        Text("Up next").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.white.opacity(0.7))
                    }
                    Text(event.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(ended ? 0.65 : 1))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(timeLine)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(ended ? 0.5 : 0.8))
                        .lineLimit(1)
                    if !event.calendarTitle.isEmpty {
                        Text(event.calendarTitle).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.5)).lineLimit(1)
                    }
                    if let location = event.location {
                        Label(location, systemImage: "mappin")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(tint.opacity(happening ? 0.2 : 0.1))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(contrast == .increased ? 0.5 : (happening ? 0.16 : 0.05)), lineWidth: 0.5))
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 11))
        .help("Open Calendar")
        .accessibilityHint("Open Calendar")
    }
}
