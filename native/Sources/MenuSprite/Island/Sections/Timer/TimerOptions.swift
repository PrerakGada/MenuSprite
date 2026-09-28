import IslandKit
import SwiftUI

/// Settings › Content › Timer: the alarm sound and the Pomodoro cycle. The same Pomodoro values can be
/// changed on the page; a cycle already under way keeps the lengths it started with.
struct TimerOptions: View {
    @ObservedObject var engine: TimerEngine
    @ObservedObject var preferences: TimerPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Play a sound when time is up", isOn: Binding(get: { preferences.value.sound }, set: { engine.setSound($0) }))
                Text("A chime every two seconds until you dismiss the timer, for five minutes at most.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Pomodoro").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                row("Focus", \.focusMinutes, PomodoroPlan.focusChoices, minutes: true)
                row("Short break", \.shortBreakMinutes, PomodoroPlan.breakChoices, minutes: true)
                row("Long break", \.longBreakMinutes, PomodoroPlan.breakChoices, minutes: true)
                row("Long break every", \.sessionsBeforeLongBreak, PomodoroPlan.sessionChoices, minutes: false)
                row("Sessions in a cycle", \.totalSessions, PomodoroPlan.sessionChoices, minutes: false)
            }
            Text("Changes apply to the next cycle.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ path: WritableKeyPath<PomodoroPlan, Int>, _ choices: [Int], minutes: Bool) -> some View {
        GridRow {
            Text(title)
            Picker(title, selection: Binding(get: { preferences.value.plan[keyPath: path] },
                                             set: { value in engine.setPlan { $0[keyPath: path] = value } })) {
                ForEach(choices, id: \.self) { value in
                    Text(minutes ? TimerFormat.minutes(value) : (value == 1 ? "1 session" : "\(value) sessions")).tag(value)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}
