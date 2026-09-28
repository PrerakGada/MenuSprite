import AppKit
import IslandKit
import SwiftUI

// Pieces shared by the Now Playing page and the Controls card.

extension MusicCover {
    var swiftUIImage: Image { Image(decorative: image, scale: 2) }
    var tintColor: Color? { tint.map(Color.init(nsColor:)) }
}

extension MusicModel {
    var title: String {
        switch phase {
        case .ready: playback?.title ?? ""
        case .idle: "Nothing playing"
        case .waiting, .off: "Now Playing"
        }
    }

    /// Artist, else album, else a plain label.
    var subtitle: String {
        guard let playback else { return "" }
        if !playback.artist.isEmpty { return playback.artist }
        if !playback.album.isEmpty { return playback.album }
        return "Now Playing"
    }

    var isPlaying: Bool { phase == .ready && playback?.isPlaying == true }

    static let idleHint = "Play something and its controls show up here."
    static let failure = "Could not change playback."
}

/// The cover square: rounded, a hairline edge, a placeholder note, a slight shrink while paused, and
/// a glow in the cover's colour.
struct MusicArtworkView: View {
    let cover: MusicCover?
    let side: CGFloat
    var playing = true
    var glow = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.19, style: .continuous)
        let tint = glow ? cover?.tintColor : nil
        ZStack {
            if let cover {
                cover.swiftUIImage.resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.black
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.3, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: (tint ?? .clear).opacity(0.42), radius: 20, y: 7)
        .shadow(color: (tint ?? .clear).opacity(0.2), radius: 42, y: 14)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: tint)
        .scaleEffect(playing ? 1 : 0.94)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: playing)
    }
}

/// Previous, play/pause, next. A skip the player said it cannot do is hidden; everything is disabled
/// while a command is pending or the player cannot be controlled from here.
struct MusicTransport: View {
    @ObservedObject var model: MusicModel
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 14 : 22) {
            if !model.hidesPrevious { skip(forward: false) }
            playButton
            if !model.hidesNext { skip(forward: true) }
        }
        .help(model.canControl || model.phase != .ready ? "" : "This player can't be controlled from the island.")
    }

    private var playButton: some View {
        let size: CGFloat = compact ? 36 : 44
        return Button { model.playPause() } label: {
            ZStack {
                Circle().fill(.white)
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 14 : 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.22), value: model.isPlaying)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(!model.canControl || model.isPending)
        .opacity(model.canControl ? 1 : 0.45)
        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
    }

    private func skip(forward: Bool) -> some View {
        let enabled = forward ? model.canSkipNext : model.canSkipPrevious
        return Button { model.skip(forward: forward) } label: {
            Image(systemName: forward ? "forward.end.fill" : "backward.end.fill")
                .font(.system(size: compact ? 15 : 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: compact ? 28 : 32, height: compact ? 28 : 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 10))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(forward ? "Next track" : "Previous track")
    }
}

/// The seek bar (or a read-only meter) with elapsed and remaining time. Ticks once a second while
/// playing and not at all while paused.
struct MusicTimeline: View {
    @ObservedObject var model: MusicModel
    var tint: Color

    var body: some View {
        if model.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { _ in content }
        } else {
            content
        }
    }

    private var content: some View {
        let now = ProcessInfo.processInfo.systemUptime
        let duration = max(0, model.playback?.duration ?? 0)
        let position = model.position(at: now) ?? 0
        return VStack(spacing: 4) {
            if model.canSeek {
                IslandLevelSlider(value: Binding(get: { position }, set: { model.scrubMoved(to: $0) }),
                                  range: 0...max(duration, 1), tint: tint,
                                  editingChanged: { began in model.scrubEditing(began, value: model.scrub?.value ?? position) },
                                  accessibilityLabel: "Position")
                    .frame(height: 10)
            } else {
                IslandMeter(value: duration > 0 ? position / duration : 0, tint: tint, height: 6)
                    .frame(height: 10)
            }
            HStack {
                Text(MusicTime.format(position))
                Spacer()
                Text("−" + MusicTime.format(max(0, duration - position)))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(IslandStyle.secondaryText)
        }
        .frame(height: 30)
    }
}

/// The playback-source chooser: Automatic, then one row per player.
struct MusicSourceMenu: View {
    @ObservedObject var model: MusicModel
    var prominent = false

    var body: some View {
        Menu {
            Button { model.choose(nil) } label: {
                if model.isAutomatic { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
            }
            Divider()
            ForEach(model.sources, id: \.pid) { source in
                Button { model.choose(source) } label: {
                    if model.chosenPID == source.pid { Label(model.name(of: source), systemImage: "checkmark") } else { Text(model.name(of: source)) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(model.currentSourceName ?? "Playback source")
                    .font(.system(size: prominent ? 17 : 10, weight: prominent ? .semibold : .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: prominent ? 10 : 7, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.white : IslandStyle.secondaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: prominent ? 220 : 110, alignment: .leading)
        .accessibilityLabel("Playback source")
    }
}
