import IslandKit
import SwiftUI

/// The Now Playing page's arithmetic, shared by the page and its height.
struct MusicPageLayout: Equatable {
    static let spacing: CGFloat = 10
    static let controlsRowHeight: CGFloat = 32
    static let panelHeight: CGFloat = 216
    static let idleHeight: CGFloat = 84
    static let minimumRow: CGFloat = 88
    /// Below this the lyrics panel takes the player row's place instead of sharing the page.
    static let minimumPanel: CGFloat = 120

    var playerRow: CGFloat
    var panel: CGFloat
    var controlsRow: Bool
    var height: CGFloat

    init(size: IslandSize, budget: CGFloat, idle: Bool, controlsRow: Bool, panelOpen: Bool) {
        let controls = controlsRow ? Self.controlsRowHeight + Self.spacing : 0
        let available = max(0, budget - controls)
        let preset: CGFloat = size == .spacious ? 148 : 120
        if idle {
            playerRow = Self.idleHeight
            panel = 0
        } else if panelOpen {
            var row = min(preset, max(Self.minimumRow, available - Self.spacing - Self.panelHeight))
            var room = available - Self.spacing - row
            if room < Self.minimumPanel {
                row = 0
                room = min(Self.panelHeight, available)
            }
            playerRow = row
            panel = max(0, room)
        } else {
            playerRow = min(preset, max(Self.minimumRow, available))
            panel = 0
        }
        self.controlsRow = controlsRow
        let stacked = playerRow + (playerRow > 0 && panel > 0 ? Self.spacing : 0) + panel + controls
        height = min(budget, stacked)
    }
}

/// Which parts of the details column fit beside the cover: first try a two-line title (roomy rows
/// only), then one line, then without the artist, then without the timeline.
struct MusicDetailsFit: Equatable {
    var titleLines: Int
    var artist: Bool
    var timeline: Bool

    static func fit(height: CGFloat, roomy: Bool, hasTimeline: Bool) -> MusicDetailsFit {
        let titleLine: CGFloat = roomy ? 24 : 19
        let artistLine: CGFloat = roomy ? 16 : 15
        let gap: CGFloat = 4
        let transport: CGFloat = 44
        var options: [MusicDetailsFit] = []
        if roomy { options.append(MusicDetailsFit(titleLines: 2, artist: true, timeline: hasTimeline)) }
        options += [MusicDetailsFit(titleLines: 1, artist: true, timeline: hasTimeline),
                    MusicDetailsFit(titleLines: 1, artist: false, timeline: hasTimeline),
                    MusicDetailsFit(titleLines: 1, artist: true, timeline: false)]
        for option in options {
            let needed = titleLine * CGFloat(option.titleLines) + (option.artist ? artistLine + gap : 0)
                + (option.timeline ? 30 + gap : 0) + gap + transport
            if needed <= height { return option }
        }
        return MusicDetailsFit(titleLines: 1, artist: false, timeline: false)
    }
}

struct MusicPage: View {
    let section: MusicSection
    @ObservedObject var model: MusicModel
    @ObservedObject var lyrics: LyricsModel
    @ObservedObject var options: MusicOptions
    @ObservedObject var audio: IslandSystemAudio
    let context: IslandPageContext

    init(section: MusicSection, context: IslandPageContext) {
        self.section = section
        model = section.model
        lyrics = section.lyrics
        options = section.musicOptions
        audio = section.environment.systemAudio
        self.context = context
    }

    var body: some View {
        let layout = section.layout(for: context)
        VStack(alignment: .leading, spacing: MusicPageLayout.spacing) {
            switch model.phase {
            case .off, .idle:
                MusicIdleView(model: model)
            case .waiting:
                Color.clear.frame(height: layout.playerRow)
            case .ready:
                if layout.playerRow > 0 { MusicPlayerRow(model: model, height: layout.playerRow) }
            }
            if layout.panel > 0 {
                LyricsPanel(lyrics: lyrics, model: model, options: options) { section.chooseLyricsFile() }
                    .frame(height: layout.panel)
            }
            if layout.controlsRow {
                MusicControlsRow(section: section, model: model, lyrics: lyrics, options: options, audio: audio, preview: context.isPreview)
                    .frame(height: MusicPageLayout.controlsRowHeight)
            }
        }
        .frame(width: context.width, height: layout.height, alignment: .top)
    }
}

private struct MusicIdleView: View {
    @ObservedObject var model: MusicModel
    var body: some View {
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.06))
                .frame(width: 76, height: 76)
                .overlay(Image(systemName: "music.note").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.75)))
            VStack(alignment: .leading, spacing: 4) {
                if model.showsChooser {
                    MusicSourceMenu(model: model, prominent: true)
                } else {
                    Text("Nothing playing").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
                Text(MusicModel.idleHint).font(.system(size: 12)).foregroundStyle(IslandStyle.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .frame(height: MusicPageLayout.idleHeight)
    }
}

/// Cover on the left; title, artist, timeline and transport beside it.
private struct MusicPlayerRow: View {
    @ObservedObject var model: MusicModel
    let height: CGFloat

    var body: some View {
        let roomy = height >= 140
        let hasTimeline = (model.playback?.duration ?? 0) > 0
        let fit = MusicDetailsFit.fit(height: height, roomy: roomy, hasTimeline: hasTimeline)
        let tint = model.cover?.tintColor ?? .white
        HStack(alignment: .top, spacing: roomy ? 20 : 16) {
            Button { model.openPlayer() } label: {
                MusicArtworkView(cover: model.cover, side: height, playing: model.isPlaying)
            }
            .buttonStyle(.plain)
            .help("Now Playing")
            .accessibilityLabel("Open the player")
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.title)
                        .font(.system(size: roomy ? 20 : 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(fit.titleLines)
                        .layoutPriority(1)
                        .help(model.title)
                    Spacer(minLength: 4)
                    if model.showsChooser { MusicSourceMenu(model: model) }
                    if model.isPlaying {
                        MusicBarsView(count: 3, barWidth: 2.5, playing: true, tint: model.cover?.tint ?? .white)
                            .frame(width: MusicBars.width(count: 3, barWidth: 2.5), height: 12)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    }
                }
                if fit.artist {
                    Text(model.commandFailed ? MusicModel.failure : model.subtitle)
                        .font(.system(size: roomy ? 13 : 12))
                        .foregroundStyle(model.commandFailed ? Color.orange : IslandStyle.secondaryText)
                        .lineLimit(1)
                }
                if fit.timeline { MusicTimeline(model: model, tint: tint) }
                Spacer(minLength: 0)
                MusicTransport(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: height)
    }
}

/// The row under the player: inline volume, then the Lyrics toggle.
private struct MusicControlsRow: View {
    let section: MusicSection
    @ObservedObject var model: MusicModel
    @ObservedObject var lyrics: LyricsModel
    @ObservedObject var options: MusicOptions
    @ObservedObject var audio: IslandSystemAudio
    let preview: Bool

    var body: some View {
        HStack(spacing: 10) {
            if section.hasVolume { MusicInlineVolume(audio: audio, environment: section.environment) }
            Spacer(minLength: 0)
            if section.lyricsAvailable {
                Button { if !preview { lyrics.setPanelOpen(!lyrics.isPanelOpen) } } label: {
                    Label("Lyrics", systemImage: "quote.bubble")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.white.opacity(lyrics.isPanelOpen ? 0.14 : 0.05)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
    }
}

/// Mute, a level bar and the output menu, reading the island's shared system audio state.
struct MusicInlineVolume: View {
    @ObservedObject var audio: IslandSystemAudio
    let environment: IslandEnvironment

    var body: some View {
        HStack(spacing: 8) {
            Button { audio.setMuted(!audio.isMuted) } label: {
                Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(audio.isMuted ? Color.red : .white.opacity(0.85))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .disabled(!audio.hasMute)
            .accessibilityLabel(audio.isMuted ? "Unmute" : "Mute")
            if let volume = audio.volume {
                IslandLevelSlider(value: Binding(get: { audio.isMuted ? 0 : volume }, set: { audio.setVolume($0) }),
                                  accessibilityLabel: "Volume")
                    .frame(width: 150, height: 24)
            } else {
                Text("Output unavailable").font(.system(size: 10)).foregroundStyle(IslandStyle.secondaryText)
            }
            Menu {
                ForEach(audio.outputs) { device in
                    Button { audio.selectOutput(device) } label: {
                        if device.id == audio.output?.id { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                    }
                }
                if environment.visibleSections.contains(.mixer) {
                    Divider()
                    Button("Volume mixer") { environment.open(.mixer) }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "airplay.audio")
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(audio.error == nil ? Color.white.opacity(0.85) : .orange)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(audio.error ?? audio.output?.name ?? "Output")
            .accessibilityLabel("Output device")
        }
    }
}
