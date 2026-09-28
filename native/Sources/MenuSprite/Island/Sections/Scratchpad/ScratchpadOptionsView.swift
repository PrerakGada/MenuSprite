import IslandKit
import SwiftUI

/// Settings › Content › Scratchpad: where it opens, its shortcut, "Clear on its own", and the
/// floating pad's click-outside and background choices.
struct ScratchpadOptionsView: View {
    @ObservedObject var preferences: ScratchpadPreferences
    @ObservedObject var settings: IslandSettingsStore
    @ObservedObject var shortcut: IslandToolShortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Where Scratchpad opens", selection: Binding(
                get: { settings.value.scratchpadInIsland },
                set: { value in settings.update { $0.scratchpadInIsland = value } })) {
                Text("Dynamic Island").tag(true)
                Text("Separate window").tag(false)
            }
            .pickerStyle(.segmented)
            IslandToolShortcutRow(title: "Open scratchpad", shortcut: $preferences.shortcut, registration: shortcut)
            Picker("Clear on its own", selection: $preferences.retention) {
                ForEach(ScratchpadRetention.allCases) { Text($0.title).tag($0) }
            }
            Toggle(isOn: $preferences.closeOnClickOutside) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Close when I click outside")
                    Text("For the floating pad. Turn off to keep it open while you work elsewhere.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pad background")
                HStack {
                    Text("Translucent").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $preferences.background, in: 0...1)
                    Text("Opaque").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Notes stay on this Mac in a private file and are never part of settings backups. A pad left unedited clears only when the scratchpad next opens.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
