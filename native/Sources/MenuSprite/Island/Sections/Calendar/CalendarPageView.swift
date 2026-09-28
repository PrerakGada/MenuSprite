import IslandKit
import SwiftUI

/// The Calendar page. Without full access it asks (only on a button press). With it, a tall and wide
/// page puts the month beside the agenda; everything else, both presets included, stacks the week
/// strip over the agenda with the month one tap away. It redraws once a minute and no more.
struct CalendarPageView: View {
    @ObservedObject var model: CalendarModel
    let context: IslandPageContext

    var body: some View {
        let height = context.budget
        Group {
            if model.access == .granted {
                TimelineView(.everyMinute) { _ in
                    content(now: Date(), height: height)
                }
            } else {
                CalendarAccessView(model: model, fromIsland: !context.isPreview)
            }
        }
        .frame(width: context.width, height: height, alignment: .top)
        .onAppear {
            if context.isPreview { model.previewAppeared() } else { model.refreshAccess() }
        }
        .onDisappear { if context.isPreview { model.previewDisappeared() } }
    }

    @ViewBuilder private func content(now: Date, height: CGFloat) -> some View {
        if IslandCalendarLayout.sideBySide(width: context.width, height: height) {
            HStack(spacing: 0) {
                CalendarSideMonth(model: model, now: now)
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1).padding(.horizontal, 12)
                CalendarAgendaView(model: model, now: now, showsWeekTitle: true)
            }
        } else if model.showsMonth {
            CalendarShortMonth(model: model, now: now, width: context.width, height: height)
        } else {
            VStack(spacing: 4) {
                CalendarWeekStrip(model: model, now: now, width: context.width)
                CalendarAgendaView(model: model, now: now)
            }
        }
    }
}

/// Shown until full access is granted: what the page needs and the one way to give it.
struct CalendarAccessView: View {
    @ObservedObject var model: CalendarModel
    /// From the island the request keeps the island open on this page; from Settings it does not.
    let fromIsland: Bool

    var body: some View {
        let refused = model.access == .refused
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.85))
            Text(refused ? CalendarCopy.refused : CalendarCopy.ask)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IslandStyle.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if refused {
                    Button("Open System Settings") { model.openPrivacySettings() }
                } else {
                    Button("Allow Calendar Access") { model.requestAccess(fromIsland: fromIsland) }
                        .disabled(model.isRequesting)
                }
                if model.isRequesting { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if model.requestFailed {
                Text(CalendarCopy.failed).font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: 340)
        .background(RoundedRectangle(cornerRadius: IslandStyle.cardRadius, style: .continuous).fill(IslandStyle.surface))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
