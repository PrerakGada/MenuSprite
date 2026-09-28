import IslandKit
import SwiftUI

/// The lyrics panel under the player: synced lines that follow playback, plain text, or a short
/// status, with the import button always within reach.
struct LyricsPanel: View {
    @ObservedObject var lyrics: LyricsModel
    @ObservedObject var model: MusicModel
    @ObservedObject var options: MusicOptions
    let importLyrics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch lyrics.state {
            case .content(.synced(let lines)):
                SyncedLyrics(lines: lines, lyrics: lyrics, model: model)
                timingRow
            case .content(.plain(let text)):
                if model.playback?.hasPosition != true {
                    caption("This player doesn't share its position, so the lyrics can't follow along.")
                }
                ScrollView {
                    Text(text)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                importRow
            case .content(.instrumental):
                message("Instrumental")
                importRow
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading lyrics…").font(.system(size: 12, weight: .medium)).foregroundStyle(IslandStyle.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notFound:
                message("No lyrics found for this song.")
                retryRow
            case .failed:
                message("Couldn't load the lyrics.")
                retryRow
            case .consent:
                consent
            case .idle:
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.045)))
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lyrics come from lrclib.net. While this panel is open, the song's title, artist, album and length are sent there. Lyrics you import stay on this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(IslandStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Find lyrics online", isOn: $options.findLyricsOnline)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
            importRow
        }
    }

    private var retryRow: some View {
        HStack(spacing: 8) {
            importButton
            Spacer()
            if options.findLyricsOnline {
                Button("Try again") { lyrics.retry() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandStyle.secondaryText)
            }
        }
    }

    private var importRow: some View { HStack { importButton; Spacer() } }

    private var importButton: some View {
        Button(action: importLyrics) {
            Image(systemName: "doc.badge.plus").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22)
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 8))
        .foregroundStyle(IslandStyle.secondaryText)
        .help("Import lyrics…")
        .accessibilityLabel("Import lyrics")
    }

    private var timingRow: some View {
        HStack(spacing: 6) {
            importButton
            Spacer()
            Text("Timing").font(.system(size: 11, weight: .medium)).foregroundStyle(IslandStyle.tertiaryText)
            step("minus", help: "Earlier", delta: -LyricsTimeline.offsetStep)
            Button { lyrics.resetOffset() } label: {
                Text(String(format: "%+.2f", lyrics.offset))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(minWidth: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
            .help("Reset")
            step("plus", help: "Later", delta: LyricsTimeline.offsetStep)
        }
    }

    private func step(_ symbol: String, help: String, delta: Double) -> some View {
        Button { lyrics.adjust(by: delta) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 8))
        .foregroundStyle(.white.opacity(0.85))
        .help(help)
        .accessibilityLabel(help)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(IslandStyle.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(IslandStyle.tertiaryText)
    }
}

/// Timed lines that redraw only at line boundaries: an explicit schedule of the moments the lit line
/// changes, rebuilt whenever playback or the timing changes. No polling.
private struct SyncedLyrics: View {
    let lines: [LyricLine]
    @ObservedObject var lyrics: LyricsModel
    @ObservedObject var model: MusicModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let playback = model.playback
        let schedule = LyricsTimeline.schedule(lines, position: model.position(at: ProcessInfo.processInfo.systemUptime),
                                               playing: playback?.isPlaying == true, rate: playback?.rate ?? 0,
                                               offset: lyrics.offset, duration: playback?.duration, now: .now)
        TimelineView(.explicit(schedule)) { _ in
            let position = model.position(at: ProcessInfo.processInfo.systemUptime) ?? 0
            let current = LyricsTimeline.index(lines, position: position, offset: lyrics.offset)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if current == nil {
                            Text("Waiting for the first verse")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(IslandStyle.tertiaryText)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: index == current ? 18 : 15, weight: .semibold))
                                .foregroundStyle(index == current ? Color.white : Color.white.opacity(0.4))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .onChange(of: current) { _, index in
                    guard let index else { return }
                    if reduceMotion { proxy.scrollTo(index, anchor: .center) } else {
                        withAnimation(.smooth(duration: 0.28)) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            }
        }
    }
}
