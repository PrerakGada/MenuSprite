import AppKit
import IslandKit
import SwiftUI
import UniformTypeIdentifiers

/// Customising the launcher, in the island (five columns) or the floating panel (three): a minus badge
/// hides a tool or unpins an app, tiles drag to reorder, hidden tools wait in an "Add back" tray, and
/// the two global shortcuts are recorded here.
struct ToolsEditView: View {
    @ObservedObject var model: ToolsModel
    @ObservedObject var preferences: ToolsPreferences
    let columns: Int
    let chooseApps: () -> Void
    @State private var dragging: IslandTool?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Remove tools with the minus button, drag to reorder, and add them back or pin apps below.")
                    .font(.system(size: 11))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                    ForEach(preferences.arrangement.visible) { tool in
                        EditTile(model: model, tool: tool) { model.remove(tool) }
                            .opacity(dragging == tool ? 0.4 : 1)
                            .onDrag {
                                dragging = tool
                                return NSItemProvider(object: tool.storageValue as NSString)
                            }
                            .onDrop(of: [.text], delegate: ToolReorder(target: tool, dragging: $dragging, model: model))
                    }
                }
                tray
                shortcuts
            }
            .padding(.bottom, 4)
        }
    }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add back").font(.system(size: 10, weight: .semibold)).foregroundStyle(IslandStyle.tertiaryText)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(preferences.arrangement.hiddenTools) { tool in
                    TrayChip(title: tool.title, symbol: tool.symbol) { model.addBack(tool) }
                }
                TrayChip(title: "Add app…", symbol: "plus.app", action: chooseApps)
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shortcuts").font(.system(size: 10, weight: .semibold)).foregroundStyle(IslandStyle.tertiaryText)
            ShortcutRow(title: "Open Tools", shortcut: $preferences.toolsShortcut, rejected: model.toolsShortcutRejected)
            ShortcutRow(title: "Command Bar", shortcut: $preferences.commandBarShortcut, rejected: model.commandBarShortcutRejected)
        }
    }
}

private struct EditTile: View {
    @ObservedObject var model: ToolsModel
    let tool: IslandTool
    let remove: () -> Void

    var body: some View {
        let title = model.title(tool)
        VStack(spacing: 5) {
            ToolIcon(model: model, tool: tool, size: 30, glyph: 15)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(height: 26, alignment: .top)
        }
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(alignment: .topLeading) {
            Button(action: remove) {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(Color.red))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: 4)
            .help(tool.isApp ? "Unpin \(title)" : "Remove \(title)")
            .accessibilityLabel(tool.isApp ? "Unpin \(title)" : "Remove \(title)")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TrayChip: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle.fill").font(.system(size: 11)).foregroundStyle(Color.green)
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Capsule().fill(IslandStyle.surface))
        }
        .buttonStyle(IslandButtonStyle(cornerRadius: 13))
        .help(title)
    }
}

private struct ShortcutRow: View {
    let title: String
    @Binding var shortcut: IslandShortcut?
    let rejected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                Spacer()
                IslandShortcutRecorder(shortcut: $shortcut).controlSize(.small)
            }
            if rejected {
                Text("macOS would not take this shortcut. Try another.").font(.system(size: 10)).foregroundStyle(Color.orange)
            }
        }
    }
}

private struct ToolReorder: DropDelegate {
    let target: IslandTool
    @Binding var dragging: IslandTool?
    let model: ToolsModel

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        MainActor.assumeIsolated { model.move(dragging, to: target) }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

extension IslandTool {
    var isApp: Bool {
        if case .app = self { return true }
        return false
    }
}
