import AppKit
import IslandKit
import SwiftUI
import UniformTypeIdentifiers

/// One history entry: a 104-pt card whose body pastes (or copies) it, over a row with its kind, when
/// it was copied, its ⌘-number while the surface has the keyboard, and Copy, Pin and Delete.
struct ClipboardCard: View {
    @ObservedObject var model: ClipboardHistoryModel
    let entry: ClipboardEntry
    let position: Int
    let showsBadge: Bool
    let highlighted: Bool
    let collapse: () -> Void

    /// Long texts are cut before layout; the card shows three lines at most.
    private static let previewCharacters = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.activate(entry, collapse: collapse) } label: {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(previewHelp)
            bottomRow
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(height: 104)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(entry.isPinned ? Color.white.opacity(0.14) : IslandStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(highlighted ? 0.34 : 0), lineWidth: 1))
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move up") { model.move(entry.id, up: true) }
        .accessibilityAction(named: "Move down") { model.move(entry.id, up: false) }
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        switch entry.kind {
        case .text:
            HStack(alignment: .top, spacing: 6) {
                if let color = ClipboardColor.parse(entry.text) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 12, height: 12)
                        .padding(.top, 2)
                }
                Text(String(entry.text.prefix(Self.previewCharacters)))
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        case .image:
            if let image = entry.image {
                ClipboardThumbnailView(key: image.file, url: model.store?.imageURL(image), thumbnails: model.thumbnails,
                                       fallback: "Image · \(image.dimensions)")
            }
        case .files:
            if entry.files.count == 1, let path = entry.files.first, Self.isImageFile(path) {
                ClipboardThumbnailView(key: path, url: URL(fileURLWithPath: path), thumbnails: model.thumbnails,
                                       fallback: (path as NSString).lastPathComponent)
            } else {
                Label {
                    Text(entry.files.count == 1 ? (entry.files[0] as NSString).lastPathComponent : "\(entry.files.count) files")
                        .lineLimit(2)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white)
            }
        }
    }

    private var previewHelp: String {
        if entry.kind == .files { return entry.files.joined(separator: "\n") }
        if model.accessibilityTrusted, let name = model.pasteTargetName { return "Paste into \(name)" }
        return "Copy"
    }

    static func isImageFile(_ path: String) -> Bool {
        UTType(filenameExtension: (path as NSString).pathExtension)?.conforms(to: .image) == true
    }

    // MARK: Bottom row

    private var bottomRow: some View {
        HStack(spacing: 2) {
            Image(systemName: kindSymbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IslandStyle.tertiaryText)
                .frame(width: 14)
            Text(Self.time(entry.lastUsed))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(IslandStyle.tertiaryText)
            if entry.rich != nil {
                Text("Formatted").font(.system(size: 9.5)).foregroundStyle(IslandStyle.tertiaryText)
            }
            Spacer(minLength: 4)
            if showsBadge {
                Text("⌘\(position + 1)")
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(IslandStyle.secondaryText)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .padding(.trailing, 2)
            }
            let copied = model.copiedID == entry.id
            cardButton(copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : "Copy") { model.copy(entry) }
            cardButton(entry.isPinned ? "pin.fill" : "pin", help: entry.isPinned ? "Unpin" : "Pin") { model.togglePin(entry.id) }
            cardButton("trash", help: "Delete item") { model.delete(entry.id) }
        }
        .frame(height: 28)
    }

    private var kindSymbol: String {
        switch entry.kind {
        case .text: "text.alignleft"
        case .image: "photo"
        case .files: "doc"
        }
    }

    private func cardButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.8))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 7))
        .help(help)
        .accessibilityLabel(help)
    }

    /// The time of day for today's copies; the date as well for older ones.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    // MARK: Menu

    @ViewBuilder private var menu: some View {
        if model.accessibilityTrusted {
            Button("Paste") { model.activate(entry, collapse: collapse) }
        }
        Button("Copy") { model.copy(entry) }
        Divider()
        Button(entry.isPinned ? "Unpin" : "Pin") { model.togglePin(entry.id) }
        Button("Move Up") { model.move(entry.id, up: true) }.disabled(!model.canMove(entry.id, up: true))
        Button("Move Down") { model.move(entry.id, up: false) }.disabled(!model.canMove(entry.id, up: false))
        Divider()
        Button("Delete Item", role: .destructive) { model.delete(entry.id) }
    }
}
