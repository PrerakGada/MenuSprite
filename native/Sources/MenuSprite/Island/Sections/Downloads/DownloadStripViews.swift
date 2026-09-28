import AppKit
import IslandKit
import SwiftUI

// The download's compact strip beside the camera. The shell places each wing's content at the
// island's end, already inset from the curved corner, and offers it the wing minus that inset. Each
// view reads its size, recovers the wing width, and shows what fits: the same views work at the short
// 56-pt wing, the name-fitted wing and a camera-wide row below the notch.

/// The wing a view is drawn in, from the width it was offered and the strip height.
private func wingWidth(offered width: CGFloat, height: CGFloat) -> CGFloat {
    width + DownloadStripFit.edgeInset(stripHeight: height, contentHeight: DownloadStripFit.arrowSize(stripHeight: height), round: true)
}

/// Left wing: the arrow at the island's end, then the file name toward the camera once the wing is
/// wide enough to hold it.
struct DownloadStripLeading: View {
    @ObservedObject var model: DownloadsModel

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let wing = wingWidth(offered: proxy.size.width, height: height)
            let arrow = DownloadStripFit.arrowSize(stripHeight: height)
            HStack(spacing: DownloadStripFit.arrowToName) {
                if DownloadStripFit.showsArrow(wing: wing) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: arrow, weight: .medium))
                }
                if DownloadStripFit.showsName(wing: wing), let name = model.active?.name {
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .foregroundStyle(.white)
            .padding(.trailing, DownloadStripFit.nameToCamera)
            .frame(width: proxy.size.width, height: height, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.active.map { "Downloading \($0.name)" } ?? "Downloading")
    }
}

/// Right wing: the percentage at the island's end (a mini spinner when the size is unknown), with a
/// thin progress bar filling the rest of the side when the name is shown on the left.
struct DownloadStripTrailing: View {
    @ObservedObject var model: DownloadsModel

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let wing = wingWidth(offered: proxy.size.width, height: height)
            let fraction = model.active?.fraction
            HStack(spacing: 6) {
                if DownloadStripFit.showsName(wing: wing), let fraction {
                    IslandMeter(value: fraction, height: 4)
                } else {
                    Spacer(minLength: 0)
                }
                if DownloadStripFit.showsPercent(wing: wing) {
                    if let fraction {
                        DownloadPercentText(fraction: fraction)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .padding(.leading, DownloadStripFit.nameToCamera)
            .frame(width: proxy.size.width, height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.active?.fraction.map(DownloadFormat.percent) ?? "Size unknown")
    }
}

/// What a running timer's left wing shows when combined with a download: the arrow, and the
/// percentage when the wing has room for it.
struct DownloadCompanionMark: View {
    @ObservedObject var model: DownloadsModel

    var body: some View {
        let arrow = Image(systemName: "arrow.down.circle.fill").font(.system(size: 13, weight: .medium))
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                arrow
                if let fraction = model.active?.fraction { DownloadPercentText(fraction: fraction) }
            }
            arrow
        }
        .foregroundStyle(.white)
    }
}

/// The strip's percentage: one line in any language, shrinking to 75% rather than losing a digit.
private struct DownloadPercentText: View {
    let fraction: Double
    var body: some View {
        Text(DownloadFormat.percent(fraction))
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .contentTransition(.numericText())
    }
}

/// Text and symbol widths for fitting the wing, measured as drawn. The arrow renders wider than its
/// point size, and a name is measured once while it is on show.
@MainActor
enum DownloadStripMetrics {
    private static var arrowWidths: [CGFloat: CGFloat] = [:]

    static func arrowWidth(stripHeight: CGFloat) -> CGFloat {
        let size = DownloadStripFit.arrowSize(stripHeight: stripHeight)
        if let cached = arrowWidths[size] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let width = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?.size.width ?? size
        arrowWidths[size] = width
        return width
    }

    static func nameWidth(_ name: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        return ceil((name as NSString).size(withAttributes: [.font: font]).width)
    }
}
