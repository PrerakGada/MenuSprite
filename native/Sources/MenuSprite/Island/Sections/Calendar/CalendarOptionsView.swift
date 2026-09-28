import IslandKit
import SwiftUI

/// The Calendar section's own option, kept beside the island's settings under
/// `MenuSprite.Island.Calendar.countdown`. The countdown is off until the person turns it on,
/// because it puts event titles outside the open island.
@MainActor
final class CalendarPreferences: ObservableObject {
    static let countdownKey = "MenuSprite.Island.Calendar.countdown"
    private let defaults: UserDefaults?

    @Published var countdown: Bool {
        didSet { defaults?.set(countdown, forKey: Self.countdownKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        countdown = defaults.bool(forKey: Self.countdownKey)
    }

    /// Renders only: a fixed value that is never saved.
    init(fixed countdown: Bool) {
        defaults = nil
        self.countdown = countdown
    }
}

/// Settings › Content › Calendar: calendar access, and the countdown switch.
struct CalendarOptionsView: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var preferences: CalendarPreferences

    init(model: CalendarModel) {
        self.model = model
        self.preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            access
            Toggle(isOn: $preferences.countdown) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Event countdown")
                    Text("In the hour before your next timed event, the closed island counts down to it. The event's title can appear in screenshots and recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
        .onAppear { model.refreshAccess() }
    }

    @ViewBuilder private var access: some View {
        if model.access == .granted {
            Label {
                Text("Calendar access is on")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.access == .refused ? CalendarCopy.refused : CalendarCopy.ask)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if model.access == .askable {
                        Button("Allow Calendar Access") { model.requestAccess(fromIsland: false) }
                            .disabled(model.isRequesting)
                    }
                    Button("Open System Settings") { model.openPrivacySettings() }
                    if model.isRequesting { ProgressView().controlSize(.small) }
                }
                if model.requestFailed {
                    Text(CalendarCopy.failed).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

/// The section's permission wording, shared by the page and its settings.
enum CalendarCopy {
    static let ask = "MenuSprite reads your calendars to show what's coming up. Your events stay on this Mac."
    static let refused = "Calendar access is off. Turn it on for MenuSprite in System Settings to see your events here."
    static let failed = "Calendar access couldn't be requested. Try again."
}
