import AppKit
import IslandKit
import SwiftUI

/// The shelf as a page: the dashed drop area when empty, otherwise a sideways strip of tiles over a
/// footer with the hint (or the status) on the left and Create ZIP, Share and Trash on the right.
/// Shared by the island's Files page and the separate shelf window.
struct ShelfPageView: View {
    @ObservedObject var controller: ShelfController
    @ObservedObject var store: ShelfStore
    let host: ShelfHost
    let width: CGFloat
    let height: CGFloat
    /// False in the settings preview: tiles draw but take no clicks or drags.
    var interactive = true

    init(controller: ShelfController, host: ShelfHost, width: CGFloat, height: CGFloat, interactive: Bool = true) {
        self.controller = controller
        self.store = controller.store
        self.host = host
        self.width = width
        self.height = height
        self.interactive = interactive
    }

    var body: some View {
        VStack(spacing: ShelfLayout.footerGap) {
            if store.shelf.isEmpty {
                ShelfEmptyView(status: controller.status)
            } else {
                ShelfStrip(controller: controller, host: host, height: ShelfLayout.stripHeight(pageHeight: height), interactive: interactive)
                ShelfFooter(controller: controller, host: host)
                    .frame(height: ShelfLayout.footerHeight)
            }
        }
        .padding(.bottom, ShelfLayout.bottomInset)
        .frame(width: width, height: height, alignment: .top)
    }
}

private struct ShelfEmptyView: View {
    let status: ShelfStatus?
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(IslandStyle.secondaryText)
            Text("Drop files here")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(IslandStyle.secondaryText)
            if case .message(let message) = status {
                Text(message).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center).lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 0.75, dash: [4, 5])))
    }
}

/// Tiles fill each column top to bottom, then flow sideways.
private struct ShelfStrip: View {
    @ObservedObject var controller: ShelfController
    let host: ShelfHost
    let height: CGFloat
    let interactive: Bool

    var body: some View {
        let rows = ShelfLayout.rows(height: height)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(ShelfLayout.tileHeight), spacing: ShelfLayout.spacing), count: rows),
                      alignment: .top, spacing: ShelfLayout.spacing) {
                ForEach(controller.tiles) { tile in
                    ShelfTileView(tile: tile, controller: controller, thumbnails: controller.thumbnails, host: host, interactive: interactive)
                }
            }
        }
        .frame(height: height, alignment: .top)
    }
}

/// One tile: a 64 × 50 picture well over a two-line name, with selection, pin and pile marks.
private struct ShelfTileView: View {
    let tile: ShelfTile
    @ObservedObject var controller: ShelfController
    @ObservedObject var thumbnails: ShelfThumbnails
    let host: ShelfHost
    let interactive: Bool
    @State private var hovering = false

    private var path: String? { (tile.item.isPile ? tile.item.leaves.first : tile.item)?.file?.path }

    var body: some View {
        let selected = controller.selection.contains(tile.id)
        VStack(spacing: 4) {
            well.frame(width: 64, height: 50)
            // A name without spaces would break mid-word over two lines; it stays on one, truncated in the middle.
            let oneWord = !tile.item.title.contains(where: \.isWhitespace)
            Text(tile.item.title)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(oneWord ? 1 : 2)
                .minimumScaleFactor(oneWord ? 0.85 : 1)
                .truncationMode(.middle)
                .frame(width: 72, height: 26, alignment: .top)
        }
        .padding(.top, 6)
        .frame(width: ShelfLayout.tileWidth, height: ShelfLayout.tileHeight, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background(selected)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .overlay {
            if interactive {
                ShelfTileInteraction(tile: tile, controller: controller, host: host, image: path.flatMap(thumbnails.image(for:)),
                                     hovering: $hovering)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) { pinBadge }
        .task(id: path) { if let path { await thumbnails.load(path) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.item.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func background(_ selected: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.16) }
        if tile.parent != nil { return Color.white.opacity(0.05) }
        return hovering ? Color.white.opacity(0.06) : .clear
    }

    @ViewBuilder private var pinBadge: some View {
        if tile.item.pinned {
            Button {
                controller.setPinned([tile.id], false)
            } label: {
                Image(systemName: hovering ? "xmark.circle.fill" : "pin.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.white.opacity(0.28))
            }
            .buttonStyle(.plain)
            .disabled(!interactive)
            .help("Unpin")
            .padding(4)
        }
    }

    @ViewBuilder private var well: some View {
        ZStack {
            if tile.item.isPile {
                ForEach([2, 1], id: \.self) { depth in
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.08 + 0.04 * Double(2 - depth)))
                        .frame(width: 52, height: 40)
                        .offset(x: CGFloat(depth) * 4, y: CGFloat(depth) * -4)
                }
            }
            picture(for: tile.item.isPile ? (tile.item.leaves.first ?? tile.item) : tile.item)
                .frame(width: 52, height: 40)
            if tile.item.isPile {
                Text("\(tile.item.leafCount)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 16)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 26, y: 18)
            }
        }
    }

    @ViewBuilder private func picture(for item: ShelfItem) -> some View {
        switch item.content {
        case .file(let file):
            if let image = thumbnails.image(for: file.path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                symbol("doc")
            }
        case .text: symbol("text.alignleft")
        case .link: symbol("link")
        case .pile: symbol("square.stack")
        }
    }

    private func symbol(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(0.1))
            .overlay(Image(systemName: name).font(.system(size: 18, weight: .regular)).foregroundStyle(Color.white.opacity(0.8)))
    }
}

/// Hint or status on the left; Create ZIP, Share and Trash on the right.
private struct ShelfFooter: View {
    @ObservedObject var controller: ShelfController
    let host: ShelfHost
    @State private var zipAnchor = ShelfAnchor()
    @State private var shareAnchor = ShelfAnchor()

    var body: some View {
        let targets = controller.actionTargets
        let hasFiles = controller.hasFiles(targets)
        HStack(spacing: 6) {
            ShelfStatusLine(controller: controller)
                .frame(maxWidth: .infinity, alignment: .leading)
            footerButton("doc.zipper", help: "Create ZIP: each item is saved as a separate ZIP. Originals stay unchanged.",
                         anchor: zipAnchor, enabled: hasFiles && !controller.isZipping) {
                controller.createZip(targets, from: zipAnchor.view, host: host)
            }
            footerButton("square.and.arrow.up", help: "Share", anchor: shareAnchor, enabled: hasFiles) {
                if let view = shareAnchor.view { controller.share(targets, from: view, host: host) }
            }
            trash
        }
    }

    @ViewBuilder private var trash: some View {
        if controller.selection.isEmpty {
            Menu {
                Button("Clear All", role: .destructive) { controller.clearAll() }
                Button("Cancel") {}
            } label: {
                Image(systemName: "trash").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(IslandButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(controller.isZipping)
            .opacity(controller.isZipping ? 0.45 : 1)
            .help("Clear all (pinned items stay)")
        } else {
            footerButton("trash.fill", help: "Remove selected", anchor: nil, enabled: !controller.isZipping) {
                controller.removeSelected()
            }
        }
    }

    private func footerButton(_ symbol: String, help: String, anchor: ShelfAnchor?, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background { if let anchor { ShelfAnchorView(anchor: anchor) } }
        }
        .buttonStyle(IslandButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The footer's left side: a ZIP's progress or result, a refusal, or the hint.
private struct ShelfStatusLine: View {
    @ObservedObject var controller: ShelfController

    var body: some View {
        switch controller.status {
        case .zipping(let completed, let total, let cancelling):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Create ZIP · \(completed)/\(total)").font(.system(size: 10).monospacedDigit()).foregroundStyle(IslandStyle.secondaryText)
                Button("Cancel") { controller.cancelZip() }
                    .controlSize(.mini)
                    .disabled(cancelling)
            }
        case .saved:
            HStack(spacing: 6) {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
                Button("Show") { controller.showSaved() }.controlSize(.mini)
            }
        case .cancelled:
            Text("Cancelled.").font(.system(size: 10)).foregroundStyle(IslandStyle.secondaryText)
        case .message(let message):
            Text(message).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(3)
        case nil:
            let count = controller.selection.count
            Text(count > 0 ? "\(count) selected" : "Click to select. Drag out to use or right-click for more actions.")
                .font(.system(size: 10))
                .foregroundStyle(IslandStyle.secondaryText)
                .lineLimit(2)
        }
    }
}
