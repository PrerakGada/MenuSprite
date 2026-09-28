import IslandKit
import SwiftUI

/// The Volume mixer page: the output menu and an options button on top, then either the desk (the
/// system output's fader beside a sideways rail of app faders) or the options view in its place.
struct MixerPage: View {
    @ObservedObject var controller: MixerController
    @ObservedObject var audio: IslandSystemAudio
    let context: IslandPageContext
    @State private var showsOptions: Bool
    @State private var editing: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(controller: MixerController, audio: IslandSystemAudio, context: IslandPageContext, showsOptions: Bool = false) {
        self.controller = controller
        self.audio = audio
        self.context = context
        _showsOptions = State(initialValue: showsOptions)
    }

    var body: some View {
        let layout = MixerDeskLayout(pageHeight: context.budget)
        VStack(spacing: MixerDeskLayout.headerGap) {
            header.frame(height: MixerDeskLayout.headerHeight)
            Group {
                if showsOptions {
                    MixerOptionsPanel(controller: controller, store: controller.store, audio: audio, editing: $editing)
                } else {
                    desk(layout)
                }
            }
            .frame(height: layout.deskHeight)
        }
        .frame(width: context.width, height: context.budget, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            MixerOutputMenu(controller: controller, audio: audio)
            Spacer(minLength: 0)
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    editing = nil
                    showsOptions.toggle()
                }
            } label: {
                Image(systemName: showsOptions ? "xmark" : "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(IslandButtonStyle(cornerRadius: 8))
            .help(showsOptions ? "Close" : "Options")
            .accessibilityLabel(showsOptions ? "Close" : "Options")
        }
    }

    private func desk(_ layout: MixerDeskLayout) -> some View {
        HStack(spacing: 0) {
            MixerMasterColumn(audio: audio, layout: layout, editing: $editing)
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1).padding(.vertical, 6)
            apps(layout).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func apps(_ layout: MixerDeskLayout) -> some View {
        switch controller.permission {
        case .denied, .notDetermined:
            MixerPermissionView(canAsk: controller.permission == .notDetermined && !controller.isPreview) { controller.requestPermission() }
        case .unknown where controller.consentSuspect:
            MixerPermissionView(canAsk: false) {}
        case nil:
            Color.clear
        default:
            if controller.hasScanned && controller.rows.isEmpty {
                IslandUnavailableView(symbol: "speaker.wave.2", message: "Apps that play sound appear here.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(controller.rows) { row in
                            MixerAppColumn(row: row, outputs: controller.outputs, layout: layout, editing: $editing, controller: controller)
                        }
                    }
                }
            }
        }
    }
}

/// The current output's name as a menu of every output. A failed switch shows its error in orange.
struct MixerOutputMenu: View {
    let controller: MixerController
    @ObservedObject var audio: IslandSystemAudio

    var body: some View {
        Menu {
            ForEach(audio.outputs) { device in
                Toggle(device.name, isOn: Binding(get: { device.id == audio.output?.id },
                                                  set: { if $0 { controller.selectSystemOutput(device) } }))
            }
        } label: {
            HStack(spacing: 4) {
                Text(audio.error.map { "Could not switch: \($0)" } ?? audio.output?.name ?? "No output")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(audio.error == nil ? Color.white.opacity(0.85) : Color.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(IslandStyle.secondaryText)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(audio.outputs.isEmpty)
        .accessibilityLabel("Output device")
    }
}

/// Shown in place of the app faders until System Audio Recording is allowed. The system output
/// beside it keeps working, since it needs no permission.
struct MixerPermissionView: View {
    let canAsk: Bool
    let ask: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(IslandStyle.tertiaryText)
            Text("Per-app volume needs “System Audio Recording Only” in System Settings. Sound passes through live and is never recorded.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IslandStyle.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if canAsk {
                    Button("Allow…", action: ask).buttonStyle(MixerPillStyle(prominent: true))
                }
                Button("Open System Settings…") { MixerPermission.openSettings() }.buttonStyle(MixerPillStyle(prominent: !canAsk))
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small capsule button for the island's black surface.
struct MixerPillStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(prominent ? Color.white.opacity(configuration.isPressed ? 0.7 : 0.9)
                                                 : Color.white.opacity(configuration.isPressed ? 0.2 : 0.12)))
    }
}
