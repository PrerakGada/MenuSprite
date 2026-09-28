import IslandKit
import SwiftUI

enum CalendarStyle {
    /// Today's circle: a warm red.
    static let accent = Color(.sRGB, red: 1.0, green: 0.36, blue: 0.39, opacity: 1)
}

/// The short island's week: chevrons, seven days from the person's first weekday, then Month, Today,
/// Next 7 days and Open Calendar as the width allows.
struct CalendarWeekStrip: View {
    @ObservedObject var model: CalendarModel
    let now: Date
    let width: CGFloat

    var body: some View {
        let calendar = model.calendar
        let days = IslandCalendarDays.week(containing: model.focus, calendar: calendar)
        let dots = IslandCalendarAgenda.dots(for: days, events: model.events, calendar: calendar)
        let letters = model.text.weekdayLetters
        HStack(spacing: 2) {
            CalendarIconButton(symbol: "chevron.left", help: "Previous week", width: 20) { model.moveWeek(-1) }
            ForEach(Array(days.enumerated()), id: \.element) { index, day in
                CalendarDayButton(letter: letters[index], number: model.text.dayNumber(day),
                                  isToday: calendar.isDate(day, inSameDayAs: now), isSelected: model.selectedDay == day,
                                  dots: dots[day] ?? []) { model.tapStripDay(day) }
            }
            CalendarIconButton(symbol: "chevron.right", help: "Next week", width: 20) { model.moveWeek(1) }
            CalendarIconButton(symbol: "calendar", help: "Month") { model.showsMonth = true }
            if IslandCalendarLayout.showsTodayButtons(width: width) {
                CalendarIconButton(symbol: "smallcircle.filled.circle", help: "Today") { model.showToday() }
                CalendarIconButton(symbol: "list.bullet", help: "Next 7 days", isOn: model.selectedDay == nil) {
                    model.showNextSevenDays()
                }
            }
            if IslandCalendarLayout.showsOpenCalendar(width: width) {
                CalendarIconButton(symbol: "arrow.up.forward.app", help: "Open Calendar") { model.openCalendar() }
            }
        }
        .frame(height: IslandCalendarLayout.weekStripHeight)
    }
}

/// A day in the week strip: weekday letter, the date in a circle, and up to three calendar dots.
struct CalendarDayButton: View {
    let letter: String
    let number: String
    let isToday: Bool
    let isSelected: Bool
    let dots: [IslandCalendarColor]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(letter).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.white.opacity(0.45))
                CalendarDateCircle(number: number, diameter: 26, fontSize: 12, isToday: isToday, isSelected: isSelected,
                                   isOutside: false)
                CalendarDots(colors: dots)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 10))
    }
}

/// Today filled with the accent, a chosen day filled white; both at once adds a white ring.
struct CalendarDateCircle: View {
    let number: String
    let diameter: CGFloat
    let fontSize: CGFloat
    let isToday: Bool
    let isSelected: Bool
    let isOutside: Bool

    var body: some View {
        ZStack {
            if isToday {
                Circle().fill(CalendarStyle.accent)
                if isSelected { Circle().strokeBorder(Color.white, lineWidth: 1.5) }
            } else if isSelected {
                Circle().fill(Color.white)
            }
            Text(number)
                .font(.system(size: fontSize, weight: isToday || isSelected ? .bold : .regular).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isSelected && !isToday ? Color.black : Color.white.opacity(isOutside && !isToday ? 0.4 : 1))
        }
        .frame(width: diameter, height: diameter)
    }
}

struct CalendarDots: View {
    let colors: [IslandCalendarColor]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(colors, id: \.self) { Circle().fill(Color(calendar: $0)).frame(width: 3, height: 3) }
        }
        .frame(height: 3)
    }
}

struct CalendarIconButton: View {
    let symbol: String
    let help: String
    var width: CGFloat = 26
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Color.black : Color.white.opacity(0.8))
                .frame(width: width, height: 26)
                .background(Circle().fill(isOn ? Color.white : Color.clear))
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 13))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Six weeks of a month. Days outside the month are dimmed; a tap chooses the day.
struct CalendarMonthGrid: View {
    @ObservedObject var model: CalendarModel
    let now: Date
    let rowHeight: CGFloat

    var body: some View {
        let calendar = model.calendar
        let days = IslandCalendarDays.monthGrid(for: model.focus, calendar: calendar)
        let dots = IslandCalendarAgenda.dots(for: days, events: model.events, calendar: calendar)
        let circle = min(24, max(16, rowHeight - 5))
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(days[row * 7..<row * 7 + 7], id: \.self) { day in
                        Button { model.select(day) } label: {
                            CalendarDateCircle(number: model.text.dayNumber(day), diameter: circle,
                                               fontSize: circle >= 20 ? 12 : 11,
                                               isToday: calendar.isDate(day, inSameDayAs: now),
                                               isSelected: model.selectedDay == day,
                                               isOutside: !calendar.isDate(day, equalTo: model.focus, toGranularity: .month))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .overlay(alignment: .bottom) { CalendarDots(colors: dots[day] ?? []) }
                        }
                        .buttonStyle(IslandButtonStyle(cornerRadius: 8))
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: rowHeight)
            }
        }
    }
}

struct CalendarWeekdayRow: View {
    let letters: [String]
    let height: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
                Text(letter).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
    }
}

/// The short island's month: it replaces the week strip and agenda until a day (or Today) is chosen.
struct CalendarShortMonth: View {
    @ObservedObject var model: CalendarModel
    let now: Date
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(spacing: IslandCalendarLayout.gridSpacing) {
            HStack(spacing: 2) {
                CalendarIconButton(symbol: "chevron.left", help: "Previous month", width: 22) { model.moveMonth(-1) }
                Text(model.text.monthTitle(model.focus))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                CalendarIconButton(symbol: "chevron.right", help: "Next month", width: 22) { model.moveMonth(1) }
                Spacer(minLength: 4)
                CalendarPillButton(title: "Today") { model.showToday() }
                if IslandCalendarLayout.showsOpenCalendar(width: width) {
                    CalendarIconButton(symbol: "arrow.up.forward.app", help: "Open Calendar") { model.openCalendar() }
                }
                CalendarIconButton(symbol: "calendar", help: "Back to the week", isOn: true) { model.showsMonth = false }
            }
            .frame(height: IslandCalendarLayout.monthHeaderHeight)
            CalendarWeekdayRow(letters: model.text.weekdayLetters, height: IslandCalendarLayout.weekdayRowHeight)
            CalendarMonthGrid(model: model, now: now, rowHeight: IslandCalendarLayout.shortGridRow(pageHeight: height))
            Spacer(minLength: 0)
        }
    }
}

struct CalendarPillButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 11))
    }
}

/// The tall island's month column: name over year, chevrons, the grid, then Today and Open Calendar.
struct CalendarSideMonth: View {
    @ObservedObject var model: CalendarModel
    let now: Date

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 2) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.text.monthName(model.focus)).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        Text(model.text.year(model.focus)).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.45))
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    CalendarIconButton(symbol: "chevron.left", help: "Previous month", width: 22) { model.moveMonth(-1) }
                    CalendarIconButton(symbol: "chevron.right", help: "Next month", width: 22) { model.moveMonth(1) }
                }
                CalendarWeekdayRow(letters: model.text.weekdayLetters, height: 18)
                CalendarMonthGrid(model: model, now: now, rowHeight: IslandCalendarLayout.sideDayCell)
                HStack {
                    CalendarPillButton(title: "Today") { model.showToday() }
                    Spacer()
                    CalendarIconButton(symbol: "arrow.up.forward.app", help: "Open Calendar") { model.openCalendar() }
                }
            }
        }
        .frame(width: IslandCalendarLayout.sideMonthWidth)
    }
}
