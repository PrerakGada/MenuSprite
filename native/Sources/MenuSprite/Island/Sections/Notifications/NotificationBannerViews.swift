import AppKit
import IslandKit
import SwiftUI

/// A source app's icon, or a neutral bell when the source is unknown.
struct NotificationAppIcon: View {
    let image: NSImage?
    let size: CGFloat
    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .overlay(Image(systemName: "bell.fill").font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.white.opacity(0.8)))
                .frame(width: size, height: size)
        }
    }
}

/// The closed island's left wing for a new message: the app's icon and the sender.
struct NotificationNoticeLeading: View {
    let icon: NSImage?
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            NotificationAppIcon(image: icon, size: 20)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The right wing: conversation and message, two lines when the strip is tall enough.
struct NotificationNoticeTrailing: View {
    let detail: String
    var body: some View {
        GeometryReader { proxy in
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(proxy.size.height >= 30 ? 2 : 1)
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
    }
}

/// The whole message, opened in place when the pointer rests on a banner: app, time, sender,
/// conversation and message, with Open and a way to the inbox. Its height is measured before it is
/// shown (`NotificationCardMetrics`), so it fits the message instead of scrolling.
struct NotificationMessageCard: View {
    @ObservedObject var store: NotificationMirrorStore
    let mirror: NotificationMirror
    let showsActionRow: Bool
    let open: () -> Void
    let dismiss: () -> Void
    let showInbox: () -> Void

    var body: some View {
        let current = store.inbox.mirror(mirror.id) ?? mirror
        let fields = current.fields
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                NotificationAppIcon(image: store.icon(for: current), size: 26)
                Text(current.appName ?? "Notifications")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(current.receivedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 4)
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                }
                .buttonStyle(IslandButtonStyle(cornerRadius: 11))
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityLabel("Dismiss")
            }
            .frame(height: NotificationPreviewLayout.headerHeight)
            VStack(alignment: .leading, spacing: NotificationPreviewLayout.textSpacing) {
                Text(NotificationText.compactTitle(fields, appName: current.appName))
                    .font(.system(size: NotificationTextStyle.title.pointSize, weight: .semibold))
                    .lineLimit(NotificationTextStyle.title.lineLimit)
                if let subtitle = fields.subtitle {
                    Text(subtitle)
                        .font(.system(size: NotificationTextStyle.subtitle.pointSize, weight: .medium))
                        .lineLimit(NotificationTextStyle.subtitle.lineLimit)
                }
                if let body = fields.body {
                    Text(body)
                        .font(.system(size: NotificationTextStyle.body.pointSize))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(NotificationTextStyle.body.lineLimit)
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, NotificationPreviewLayout.headerSpacing)
            if showsActionRow {
                HStack(spacing: 8) {
                    if store.opening == current.id {
                        ProgressView().controlSize(.small)
                    } else if current.canOpen {
                        Button("Open", action: open).buttonStyle(.bordered).controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    if store.mirrors.count > 1 {
                        Button(action: showInbox) {
                            Label("\(store.mirrors.count)", systemImage: "tray.full")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                        }
                        .buttonStyle(IslandButtonStyle(cornerRadius: 12))
                        .foregroundStyle(.white.opacity(0.8))
                        .accessibilityLabel("Show all \(store.mirrors.count) notifications")
                    }
                }
                .frame(height: NotificationPreviewLayout.actionRowHeight)
                .padding(.top, NotificationPreviewLayout.actionSpacing)
            }
        }
        .padding(.horizontal, NotificationPreviewLayout.horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }
}

/// Sizes the held-banner card the way the shell will: banner-wide on the island's display, as tall
/// as the message measures, never taller than the display allows.
enum NotificationCardMetrics {
    @MainActor static func preview(settings: IslandSettings) -> (width: CGFloat, maximumHeight: CGFloat) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return (400, 600) }
        let display = IslandDisplayMetrics.make(frame: screen.frame, auxiliaryLeft: screen.auxiliaryTopLeftArea,
                                                auxiliaryRight: screen.auxiliaryTopRightArea, safeAreaTop: screen.safeAreaInsets.top,
                                                barHeight: max(24, screen.frame.maxY - screen.visibleFrame.maxY),
                                                scale: screen.backingScaleFactor)
        let width = NotificationPreviewLayout.width(camera: display.cutout.width, openWidth: IslandGeometry.openWidth(display, settings: settings))
        return (width, NotificationPreviewLayout.maximumContentHeight(displayHeight: display.frame.height, cutoutHeight: display.cutout.height))
    }

    @MainActor static func height(for mirror: NotificationMirror, showsActionRow: Bool, settings: IslandSettings) -> CGFloat {
        let preview = preview(settings: settings)
        let measured = NotificationPreviewLayout.contentHeight(mirror.fields, hasActionRow: showsActionRow,
                                                               textWidth: NotificationPreviewLayout.textWidth(cardWidth: preview.width),
                                                               measure: measure)
        return min(measured, preview.maximumHeight)
    }

    static func font(_ style: NotificationTextStyle) -> NSFont {
        switch style {
        case .title: .systemFont(ofSize: style.pointSize, weight: .semibold)
        case .subtitle: .systemFont(ofSize: style.pointSize, weight: .medium)
        case .body: .systemFont(ofSize: style.pointSize)
        }
    }

    /// Wraps the text at `width` with AppKit's layout and reports its lines.
    static func measure(_ text: String, _ style: NotificationTextStyle, _ width: CGFloat) -> (lineHeight: CGFloat, lines: Int) {
        let font = font(style)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let bounds = (text as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return (lineHeight, max(1, Int(ceil(bounds.height / lineHeight - 0.01))))
    }
}
