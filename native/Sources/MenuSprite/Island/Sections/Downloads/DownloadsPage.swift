import AppKit
import IslandKit
import SwiftUI

/// The open island's Downloads page: the set-up controls until a folder is watched, then the folder's
/// newest entries with transfers in progress on top.
struct DownloadsPage: View {
    let section: DownloadsSection
    @ObservedObject var model: DownloadsModel
    @ObservedObject var preferences: DownloadsPreferences
    let context: IslandPageContext

    var body: some View {
        Group {
            if section.setup == .ready {
                DownloadsList(section: section, model: model, origin: context.isPreview ? .settings : .island)
            } else {
                DownloadsSetupView(section: section, setup: section.setup, style: .island) {
                    section.chooseFolder(from: context.isPreview ? .settings : .island)
                }
            }
        }
        .frame(width: context.width, alignment: .top)
    }
}

/// The Downloads switch, the hint, the folder (or why it is unavailable) and the folder buttons. The
/// island page and Settings share it; only the look differs.
struct DownloadsSetupView: View {
    enum Style { case island, settings }

    /// The hint takes one line on the Spacious page and wraps on the narrower Compact one.
    static func height(width: CGFloat) -> CGFloat { hintWidth <= width ? 116 : 132 }

    private static let hintWidth: CGFloat = ceil((DownloadFolderChooser.hint as NSString)
        .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)

    let section: DownloadsSection
    let setup: DownloadsSection.Setup
    let style: Style
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { section.isEnabled }, set: { section.setEnabled($0) })) {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text(DownloadFolderChooser.hint)
                .font(.system(size: 12))
                .foregroundStyle(secondary)
                .fixedSize(horizontal: false, vertical: true)
            DownloadsFolderLine(name: section.folderName, unavailable: setup == .unavailable, style: style)
            HStack(spacing: 8) {
                button("Choose Folder…", action: choose)
                if section.folderSource != nil || setup == .unavailable {
                    button("Forget Folder") { section.forgetFolder() }
                }
            }
        }
        .foregroundStyle(style == .island ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var secondary: Color { style == .island ? IslandStyle.secondaryText : .secondary }

    @ViewBuilder private func button(_ title: String, action: @escaping () -> Void) -> some View {
        if style == .island {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(IslandStyle.surface))
            }
            .buttonStyle(IslandButtonStyle(cornerRadius: 14))
        } else {
            Button(title, action: action)
        }
    }
}

/// The watched folder's name with a folder symbol, or the orange line when it was lost.
struct DownloadsFolderLine: View {
    let name: String?
    let unavailable: Bool
    let style: DownloadsSetupView.Style

    var body: some View {
        if unavailable {
            Label("This folder is unavailable. Choose it again to restore access.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
        } else {
            Label {
                Text(name ?? "No folder chosen").lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(name == nil ? tertiary : secondary)
        }
    }

    private var secondary: Color { style == .island ? IslandStyle.secondaryText : .secondary }
    private var tertiary: Color { style == .island ? IslandStyle.tertiaryText : Color.secondary.opacity(0.7) }
}

/// The watched folder's header and its entries, newest first.
private struct DownloadsList: View {
    let section: DownloadsSection
    @ObservedObject var model: DownloadsModel
    let origin: DownloadFolderChooser.Origin

    var body: some View {
        VStack(spacing: 8) {
            header
            if !model.isLoaded {
                // Until the first scan lands the list is unknown, not empty. Nothing is read while the
                // island is off, so a settings preview says so instead of showing an empty folder.
                if !model.isWatching {
                    IslandUnavailableView(symbol: "arrow.down.circle", message: "Files appear here while the Dynamic Island is on.")
                }
            } else if model.items.isEmpty {
                IslandUnavailableView(symbol: "arrow.down.circle", message: "No files in this folder")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(model.items) { item in
                            DownloadCard(item: item, reveal: { section.reveal(item.revealURL) }, open: { section.open(item.revealURL) })
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label {
                Text(section.folderName ?? "").lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
            }
            .font(.caption)
            .foregroundStyle(IslandStyle.secondaryText)
            Spacer(minLength: 8)
            Menu {
                Button("Choose Folder…") { section.chooseFolder(from: origin) }
                Button("Forget Folder") { section.forgetFolder() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(IslandStyle.secondaryText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Downloads folder")
        }
        .frame(height: 20)
    }
}

/// One entry: saved files open on click; in-progress ones show what is known about the transfer.
private struct DownloadCard: View {
    let item: DownloadItem
    let reveal: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if case .saved = item.status {
                Button(action: open) { summary }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(item.name)")
            } else {
                summary
            }
            Button(action: reveal) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(IslandButtonStyle(cornerRadius: 13))
            .help("Show in Finder")
            .accessibilityLabel("Show \(item.name) in Finder")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(symbolTint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    trailing
                }
                details
            }
        }
        .contentShape(Rectangle())
    }

    private var symbol: String {
        if case .saved = item.status { return "checkmark.circle.fill" }
        return "arrow.down.circle"
    }

    private var symbolTint: Color {
        if case .saved = item.status { return .green }
        return .white
    }

    @ViewBuilder private var trailing: some View {
        if case .inProgress(let fraction, _, let active) = item.status {
            if let fraction {
                Text(DownloadFormat.percent(fraction))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(IslandStyle.secondaryText)
            } else if active {
                ProgressView().controlSize(.mini)
            }
        }
    }

    @ViewBuilder private var details: some View {
        switch item.status {
        case .saved:
            Text("Saved").font(.caption).foregroundStyle(IslandStyle.secondaryText)
        case .inProgress(let fraction, let bytes, let active):
            if let fraction { IslandMeter(value: fraction, height: 4) }
            let parts = [active ? "Downloading" : nil,
                         bytes.map(DownloadFormat.bytes) ?? (fraction == nil ? "Total size unavailable" : nil)].compactMap { $0 }
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(IslandStyle.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}

/// How the page and strip write numbers.
enum DownloadFormat {
    /// Whole percent, rounded down so a transfer never reads 100% before it is done.
    static func percent(_ fraction: Double) -> String { "\(Int((min(1, max(0, fraction)) * 100).rounded(.down)))%" }
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
