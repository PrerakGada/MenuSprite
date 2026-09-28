import IslandKit
import SwiftUI

/// The Controls page's volume level, as a card of its own or as a row in the shared levels card.
/// While it is on screen it holds interest in the system audio, which keeps the output observed.
struct VolumeLevelView: View {
    @ObservedObject var audio: IslandSystemAudio
    @ObservedObject var controller: SystemAudioController
    let environment: IslandEnvironment
    let style: IslandCardStyle

    var body: some View {
        Group {
            switch style {
            case .card(let height): card(tall: height >= 88)
            case .row: row
            }
        }
        .onAppear { audio.retain() }
        .onDisappear { audio.release() }
    }

    private func card(tall: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                muteButton
                Text("Volume")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // A short card has no room for the device line, so its readout becomes the device menu.
                if tall { IslandPercentText(value: audio.volume) } else { readoutMenu }
            }
            .frame(height: 16)
            level.frame(height: 28)
            if tall {
                IslandMenuButton(environment: environment, entries: entries) {
                    IslandDeviceLabel(symbol: audio.output?.symbol ?? "speaker.wave.2",
                                      title: audio.error ?? audio.output?.name ?? "No output",
                                      warning: audio.error != nil)
                }
                .frame(maxWidth: 154, alignment: .leading)
                .frame(height: 14)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, tall ? 10 : 5)
        // Tall cards start at the top so side-by-side headers line up whether or not a device line shows.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tall ? .top : .center)
    }

    private var row: some View {
        HStack(spacing: 6) {
            muteButton
            level.frame(height: 24)
            readoutMenu
        }
        .frame(height: 24)
    }

    private var muteButton: some View {
        let muted = audio.isMuted
        return Button { audio.setMuted(!muted) } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(muted ? Color.red : .white)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!audio.hasMute)
        .opacity(audio.hasMute ? 1 : 0.45)
        .accessibilityLabel(muted ? "Unmute" : "Mute")
    }

    @ViewBuilder private var level: some View {
        if let volume = audio.volume {
            IslandLevelSlider(value: Binding(get: { volume }, set: { controller.setVolume($0, own: true) }),
                              accessibilityLabel: "Volume")
        } else if controller.hasReading {
            Text("Output unavailable")
                .font(.system(size: 10))
                .foregroundStyle(IslandStyle.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear
        }
    }

    private var readoutMenu: some View {
        IslandMenuButton(environment: environment, entries: entries) { IslandReadoutLabel(value: audio.volume) }
    }

    /// Every output that can be the default, the current one checked; then the mixer when it is shown.
    private func entries() -> [IslandMenuEntry] {
        var entries: [IslandMenuEntry] = audio.outputs.map { device in
            .item(device.name, checked: device.id == audio.output?.id) { [audio] in audio.selectOutput(device) }
        }
        if entries.isEmpty { entries = [.item("No outputs found", enabled: false) {}] }
        if environment.visibleSections.contains(.mixer) {
            entries += [.separator, .item("Volume mixer") { [environment] in environment.open(.mixer) }]
        }
        return entries
    }
}
