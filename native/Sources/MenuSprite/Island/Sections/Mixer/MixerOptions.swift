import IslandKit
import SwiftUI

/// The mixer's options, shown in the page in place of the desk: output, microphone and its level,
/// then the list options.
struct MixerOptionsPanel: View {
    let controller: MixerController
    @ObservedObject var store: MixerStore
    @ObservedObject var audio: IslandSystemAudio
    @Binding var editing: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                labelled("Output") { MixerOutputMenu(controller: controller, audio: audio) }
                if audio.outputs.isEmpty { status("No outputs found") }
                labelled("Microphone") { inputMenu }
                if audio.inputs.isEmpty {
                    status("No microphones found")
                } else {
                    microphoneLevel
                }
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
                Toggle("Hide inactive apps", isOn: Binding(get: { store.preferences.hideInactive }, set: { controller.setHideInactive($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text("Apps in the list")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IslandStyle.secondaryText)
                MixerAppChecklist(controller: controller, store: store)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IslandStyle.secondaryText)
                .frame(width: 84, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(IslandStyle.tertiaryText).padding(.leading, 92)
    }

    private var inputMenu: some View {
        Menu {
            ForEach(audio.inputs) { device in
                Toggle(device.name, isOn: Binding(get: { device.id == audio.input?.id }, set: { if $0 { audio.selectInput(device) } }))
            }
        } label: {
            HStack(spacing: 4) {
                Text(audio.input?.name ?? "Microphone unavailable")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(IslandStyle.secondaryText)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(audio.inputs.isEmpty)
        .accessibilityLabel("Microphone")
    }

    @ViewBuilder private var microphoneLevel: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IslandStyle.secondaryText)
                .frame(width: 84, alignment: .trailing)
            if let level = audio.inputVolume {
                IslandLevelSlider(value: Binding(get: { level }, set: { audio.setInputVolume($0) }), range: 0...MixerLevel.systemMaximum,
                                  accessibilityLabel: "Microphone level")
                    .frame(height: 20)
                MixerPercentLabel(id: "input", gain: level, maximum: MixerLevel.systemMaximum, editing: $editing, commit: { audio.setInputVolume($0) })
            } else {
                Text("This microphone has no adjustable level.").font(.system(size: 11)).foregroundStyle(IslandStyle.tertiaryText)
                Spacer(minLength: 0)
            }
        }
    }
}

/// Bring hidden apps back: the Finder's row and every app hidden from the list.
struct MixerAppChecklist: View {
    let controller: MixerController
    @ObservedObject var store: MixerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Finder (Quick Look)", isOn: Binding(get: { store.preferences.showsFinder }, set: { controller.setShowsFinder($0) }))
            ForEach(store.preferences.hidden.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }, id: \.key) { key, name in
                Toggle(name, isOn: Binding(get: { false }, set: { if $0 { controller.unhide(key) } }))
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// Settings › Content › Volume mixer.
struct MixerSettingsOptions: View {
    let controller: MixerController
    @ObservedObject var store: MixerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Hide inactive apps", isOn: Binding(get: { store.preferences.hideInactive }, set: { controller.setHideInactive($0) }))
                Text("An app still shows while it plays, or when it has its own level or output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Apps in the list").font(.headline)
                MixerAppChecklist(controller: controller, store: store)
                Text("Hidden apps always play at their own volume. Hide an app from its menu in the mixer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Changing an app’s level or output needs System Audio Recording permission. Apps you have not changed are never touched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
