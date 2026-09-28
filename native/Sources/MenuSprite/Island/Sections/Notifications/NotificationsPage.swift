import IslandKit
import SwiftUI

enum NotificationsCopy {
    static let privacy = "Only banners that appear from now on. They stay in memory and are cleared when this Mac locks or this section is turned off."
    static let failed = "This notification can't be opened any more."
    static let accessReason = "MenuSprite sees new banners through Accessibility."
}

/// The Notifications page: this session's mirrored messages, the empty state, or what is missing.
struct NotificationsPage: View {
    @ObservedObject var store: NotificationMirrorStore
    let context: IslandPageContext
    let requestAccess: () -> Void
    let openAccessSettings: () -> Void
    let open: (Int) -> Void

    var body: some View {
        Group {
            if !store.trusted {
                NotificationsAccessView(requestAccess: requestAccess, openAccessSettings: openAccessSettings)
            } else if store.mirrors.isEmpty {
                NotificationsEmptyView(waiting: store.status == .waiting)
            } else {
                GeometryReader { proxy in
                    NotificationsRail(store: store, height: proxy.size.height, open: open)
                }
            }
        }
        .frame(width: context.width)
        .frame(maxHeight: .infinity)
        .onAppear { store.refreshTrust() }
    }
}

private struct NotificationsAccessView: View {
    let requestAccess: () -> Void
    let openAccessSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .overlay(Image(systemName: "accessibility").font(.system(size: 18, weight: .medium)).foregroundStyle(.white))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("Not allowed yet. " + NotificationsCopy.accessReason)
                        .font(.system(size: 11))
                        .foregroundStyle(IslandStyle.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Allow…", action: requestAccess)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Settings", action: openAccessSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: IslandStyle.cardRadius, style: .continuous).fill(IslandStyle.surface))
            Text(NotificationsCopy.privacy)
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer(minLength: 0)
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct NotificationsEmptyView: View {
    let waiting: Bool
    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(Image(systemName: "bell").font(.system(size: 24, weight: .medium)).foregroundStyle(.white.opacity(0.8)))
                .frame(width: 56, height: 56)
            Text(waiting ? "Waiting for macOS's notification service" : "New notifications show up here")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(NotificationsCopy.privacy)
                .font(.system(size: 11))
                .foregroundStyle(IslandStyle.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Newest first, top to bottom then left to right, scrolling sideways.
private struct NotificationsRail: View {
    @ObservedObject var store: NotificationMirrorStore
    let height: CGFloat
    let open: (Int) -> Void

    var body: some View {
        let rows = NotificationRail.rows(height: height)
        let cardHeight = NotificationRail.cardHeight(height: height)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(cardHeight), spacing: NotificationRail.spacing), count: rows),
                      spacing: NotificationRail.spacing) {
                ForEach(store.mirrors) { mirror in
                    NotificationInboxCard(store: store, mirror: mirror, height: cardHeight, open: { open(mirror.id) })
                }
            }
        }
        .frame(height: height)
    }
}

private struct NotificationInboxCard: View {
    @ObservedObject var store: NotificationMirrorStore
    let mirror: NotificationMirror
    let height: CGFloat
    let open: () -> Void

    var body: some View {
        let fields = mirror.fields
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                NotificationAppIcon(image: store.icon(for: mirror), size: 18)
                Text(mirror.appName ?? "Notifications").lineLimit(1)
                Spacer(minLength: 4)
                Text(mirror.receivedAt, format: .dateTime.hour().minute()).monospacedDigit()
                if store.opening == mirror.id {
                    ProgressView().controlSize(.mini).frame(width: 20, height: 20)
                } else if mirror.canOpen {
                    iconButton("arrow.up.forward.app", label: "Open", action: open)
                        .disabled(store.opening != nil)
                }
                iconButton("xmark", label: "Dismiss") { store.dismiss(mirror.id) }
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.6))
            .frame(height: 22)
            Text(NotificationText.compactTitle(fields, appName: mirror.appName))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            if let subtitle = fields.subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.white).lineLimit(1)
            }
            if let body = fields.body {
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Spacer(minLength: 0)
            }
            if store.failed.contains(mirror.id) {
                Text(NotificationsCopy.failed).font(.system(size: 10, weight: .medium)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(12)
        .frame(width: NotificationRail.cardWidth, height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NotificationText.spoken(fields, appName: mirror.appName))
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20)
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 10))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// "Clear" beside the page title while the inbox has messages.
struct NotificationsClearButton: View {
    @ObservedObject var store: NotificationMirrorStore
    var body: some View {
        if !store.mirrors.isEmpty {
            Button("Clear") { store.removeAll() }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .buttonStyle(IslandButtonStyle(cornerRadius: 12))
                .help("Remove every message from the island (Notification Center keeps them)")
        }
    }
}
