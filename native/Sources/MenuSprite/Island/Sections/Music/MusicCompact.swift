import AppKit
import IslandKit
import SwiftUI

// The closed island's music: the compact strip (cover left, bars right), the cover a running timer
// can carry as its companion, and the new-track notice. Also the Controls page's playback card.

/// What the compact strip draws. Updated only while the strip is live, so a strip that is leaving
/// keeps showing the last track (cover, colour, motion) while the island retracts.
@MainActor
final class MusicStripState: ObservableObject {
    @Published var cover: MusicCover?
    @Published var playing = true
}

/// A cover in a closed strip: circular corners concentric with the strip's own, a faint hairline.
struct MusicStripCoverMark: View {
    let cover: MusicCover?
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        ZStack {
            if let cover {
                cover.swiftUIImage.resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.black
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.45, weight: .medium))
                    .foregroundStyle(IslandStyle.secondaryText)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }
}

/// Left wing: the cover at the strip's end, inset so it clears the curve.
struct MusicStripLeft: View {
    @ObservedObject var state: MusicStripState
    var body: some View {
        GeometryReader { proxy in
            let geometry = MusicStripGeometry(stripHeight: proxy.size.height, isPhysical: true)
            MusicStripCoverMark(cover: state.cover, side: geometry.coverSide, radius: geometry.coverRadius)
                .position(x: geometry.coverInset + geometry.coverSide / 2, y: proxy.size.height / 2)
        }
        .accessibilityHidden(true)
    }
}

/// Right wing: seven bars tinted with the cover's colour, at the strip's end.
struct MusicStripRight: View {
    @ObservedObject var state: MusicStripState
    var body: some View {
        GeometryReader { proxy in
            let geometry = MusicStripGeometry(stripHeight: proxy.size.height, isPhysical: true)
            MusicBarsView(count: MusicStripGeometry.barCount, barWidth: MusicStripGeometry.barWidth, playing: state.playing,
                          tint: state.cover?.tint ?? .white)
                .frame(width: geometry.barsWidth, height: geometry.barsHeight)
                .position(x: proxy.size.width - geometry.barsInset - geometry.barsWidth / 2, y: proxy.size.height / 2)
        }
        .accessibilityHidden(true)
    }
}

/// The cover a running timer shows in its left wing when combined with music; centred in the frame
/// the timer gives it.
struct MusicCompanionMark: View {
    @ObservedObject var state: MusicStripState
    var body: some View {
        GeometryReader { proxy in
            let geometry = MusicStripGeometry(stripHeight: proxy.size.height, isPhysical: true)
            MusicStripCoverMark(cover: state.cover, side: geometry.coverSide, radius: geometry.coverRadius)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

/// The new-track notice: cover and title reading from the left end, the artist from the right end.
/// The cover updates live, because players often publish it after the title.
@MainActor
enum MusicTrackNotice {
    static var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium) }

    static func make(title: String, artist: String, model: MusicModel) -> IslandNotice {
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let wing = IslandNoticeWings.text(titleWidth: width(title), detailWidth: width(artist), cameraGap: 6)
        return IslandNotice(kind: .newTrack,
                            style: .custom(wing: wing, left: AnyView(Left(model: model, title: title)),
                                           right: AnyView(Right(artist: artist))),
                            label: artist.isEmpty ? title : "\(title), \(artist)")
    }

    private struct Left: View {
        @ObservedObject var model: MusicModel
        let title: String
        var body: some View {
            GeometryReader { proxy in
                let side = min(18, proxy.size.height - 6)
                let inset = IslandEdgeInset.inset(stripHeight: proxy.size.height, boxHeight: side, boxRadius: side * 0.22)
                HStack(spacing: 8) {
                    MusicStripCoverMark(cover: model.cover, side: side, radius: side * 0.22)
                    Text(title).font(Font(MusicTrackNotice.font)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                }
                .padding(.leading, inset)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private struct Right: View {
        let artist: String
        var body: some View {
            GeometryReader { proxy in
                let inset = IslandEdgeInset.inset(stripHeight: proxy.size.height, boxHeight: 11 * 0.72, boxRadius: 0)
                HStack {
                    Spacer(minLength: 6)
                    Text(artist).font(Font(MusicTrackNotice.font)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).truncationMode(.tail)
                }
                .padding(.trailing, inset)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

/// The Controls page's playback card: the cover, title and subtitle (both open Now Playing), and the
/// compact transport while there is playback.
struct MusicCard: View {
    @ObservedObject var model: MusicModel
    let height: CGFloat
    let open: () -> Void

    var body: some View {
        let side = max(40, height - 24)
        HStack(spacing: 12) {
            Button(action: open) { MusicArtworkView(cover: model.cover, side: side, playing: model.isPlaying, glow: false) }
                .buttonStyle(.plain)
                .help("Now Playing")
            VStack(alignment: .leading, spacing: 2) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if height >= 84, let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(model.commandFailed ? Color.orange : IslandStyle.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if model.phase == .ready {
                    Spacer(minLength: 0)
                    MusicTransport(model: model, compact: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var subtitle: String? {
        switch model.phase {
        case .ready: model.commandFailed ? MusicModel.failure : model.subtitle
        case .idle: MusicModel.idleHint
        case .waiting, .off: nil
        }
    }
}
