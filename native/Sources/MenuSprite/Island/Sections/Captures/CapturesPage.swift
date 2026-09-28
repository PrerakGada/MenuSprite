import AppKit
import IslandKit
import SwiftUI

/// The Recent captures page: the hosted quick preview when there is one, otherwise the sideways rail
/// of the last twelve captures, an empty state, or what to do about Screen Recording access.
struct CapturesPage: View {
    @ObservedObject var service: CaptureService
    @ObservedObject var library: CaptureLibrary
    @ObservedObject var preview: CapturePreviewController
    let context: IslandPageContext

    init(service: CaptureService, context: IslandPageContext) {
        self.service = service
        library = service.library
        preview = service.preview
        self.context = context
    }

    var body: some View {
        Group {
            if preview.isHosted, let item = preview.item {
                CapturePreviewPage(controller: preview, item: item, context: context)
            } else if !library.entries.isEmpty {
                rail
            } else if service.hasAccess || context.isPreview {
                empty
            } else {
                permission
            }
        }
        .frame(width: context.width, alignment: .top)
    }

    private var rail: some View {
        let layout = CaptureRailLayout(height: context.budget)
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(layout.cardHeight), spacing: CaptureRailLayout.spacing), count: layout.rows),
                      spacing: CaptureRailLayout.spacing) {
                ForEach(library.entries) { entry in
                    CaptureCard(entry: entry, thumbnail: library.thumbnail(for: entry), roomy: layout.isRoomy, service: service)
                        .frame(width: CaptureRailLayout.cardWidth, height: layout.cardHeight)
                }
            }
        }
        .frame(height: context.budget)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Text("Take a screenshot or save a recording to find it here.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(IslandStyle.tertiaryText)
                .multilineTextAlignment(.center)
            // The settings preview never starts a capture.
            if !context.isPreview {
                HStack(spacing: 8) {
                    capsule("camera.viewfinder", "Screenshot") { service.begin(.screenshot) }
                    capsule("record.circle", "Record screen") { service.begin(.recording) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permission: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(IslandStyle.tertiaryText)
            Text("MenuSprite needs Screen Recording access to take screenshots and recordings.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IslandStyle.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack(spacing: 8) {
                capsule("hand.raised", "Allow…") { service.requestAccess() }
                capsule("gearshape", "Open System Settings") { CapturePermission.openSettings() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func capsule(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(IslandStyle.surface))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

/// One capture in the rail: thumbnail, kind, name for recordings, when; then Restore (screenshot) or
/// Open (recording), Copy, Show in Finder and Remove from history. Drag the card to take the file out.
struct CaptureCard: View {
    let entry: RecentCapture
    let thumbnail: NSImage?
    let roomy: Bool
    let service: CaptureService

    var body: some View {
        Group {
            if roomy {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        thumbnailView
                        details
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Button(entry.kind == .screenshot ? "Restore" : "Open") { primary() }
                            .buttonStyle(CaptureCardButtonStyle(prominent: true))
                        Spacer(minLength: 4)
                        secondaryButtons
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    thumbnailView
                    VStack(alignment: .leading, spacing: 0) {
                        details
                        Spacer(minLength: 4)
                        HStack(spacing: 3) {
                            iconButton(entry.kind == .screenshot ? "arrow.up.left.and.arrow.down.right" : "play",
                                       entry.kind == .screenshot ? "Restore" : "Open", action: primary)
                            secondaryButtons
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IslandStyle.surface))
        .foregroundStyle(.white)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDrag { service.dragProvider(for: entry) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.kind.title), \(relativeTime)")
    }

    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.13))
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: entry.kind == .screenshot ? "photo" : "film")
                    .font(.system(size: 18))
                    .foregroundStyle(IslandStyle.tertiaryText)
            }
        }
        .frame(width: 104, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .onTapGesture(perform: primary)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.kind.title).font(.system(size: 11.5, weight: .semibold))
            if entry.kind == .recording, let name = entry.fileURL?.lastPathComponent {
                Text(name).font(.system(size: 9.5)).foregroundStyle(IslandStyle.secondaryText).lineLimit(1).truncationMode(.middle)
            }
            Text(relativeTime).font(.system(size: 9.5)).foregroundStyle(IslandStyle.tertiaryText)
        }
    }

    @ViewBuilder private var secondaryButtons: some View {
        iconButton("doc.on.doc", "Copy") { service.copy(entry) }
        if entry.fileURL != nil { iconButton("folder", "Show in Finder") { service.reveal(entry) } }
        iconButton("trash", "Remove from history") { service.library.remove(entry) }
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(CaptureCardButtonStyle())
            .help(label)
            .accessibilityLabel(label)
    }

    private func primary() {
        if entry.kind == .screenshot { service.restore(entry) } else { service.open(entry) }
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return Date().timeIntervalSince(entry.date) < 60 ? "Just now" : formatter.localizedString(for: entry.date, relativeTo: Date())
    }
}

/// The cards' buttons: a white capsule for Restore and Open (the island's selection colours), soft
/// squares for the rest. Drawn by hand so they look the same whether or not the island is key.
struct CaptureCardButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 10.5 : 11, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, prominent ? 10 : 0)
            .frame(minWidth: prominent ? nil : 26, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: prominent ? 11 : 6, style: .continuous)
                .fill(prominent ? Color.white.opacity(configuration.isPressed ? 0.7 : 0.92)
                                : Color.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
