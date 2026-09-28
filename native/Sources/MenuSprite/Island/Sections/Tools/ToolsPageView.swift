import AppKit
import IslandKit
import SwiftUI

/// The island's Tools page: the rail of tiles, the edit grid while customising, or a hosted utility
/// with its own Back and Close.
struct ToolsPage: View {
    @ObservedObject var model: ToolsModel
    let context: IslandPageContext
    let chooseApps: () -> Void
    let close: () -> Void

    var body: some View {
        Group {
            if let utility = model.launcher.hosted {
                ToolsUtilityFrame(title: utility.title, back: model.closeUtility, close: close) {
                    ToolsUtilityContent(utility: utility, model: model)
                }
            } else if model.launcher.editing {
                ToolsEditView(model: model, preferences: model.preferences, columns: 5, chooseApps: chooseApps)
            } else if model.tools.isEmpty {
                IslandUnavailableView(symbol: IslandSectionID.tools.symbol, message: "No tools on show. Customize tools to add some back.")
            } else {
                ToolsRail(model: model, rail: IslandToolRail(count: model.tools.count, width: context.width, budget: context.budget))
            }
        }
        .frame(width: context.width, alignment: .top)
        // The settings preview draws the live page; a click there must not run a tool or open an app.
        .allowsHitTesting(!context.isPreview)
    }
}

/// The rail: rows in reading order while every column fits, otherwise a sideways scroll filled
/// column by column.
private struct ToolsRail: View {
    @ObservedObject var model: ToolsModel
    let rail: IslandToolRail

    var body: some View {
        let tools = model.tools
        if rail.fits {
            VStack(spacing: IslandToolRail.spacing) {
                ForEach(rail.readingRows, id: \.lowerBound) { row in
                    HStack(spacing: IslandToolRail.spacing) {
                        ForEach(Array(row), id: \.self) { index in tile(tools[index], index) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: IslandToolRail.spacing) {
                        ForEach(0..<rail.scrollColumns, id: \.self) { column in
                            VStack(spacing: IslandToolRail.spacing) {
                                ForEach(column * rail.rows..<min(tools.count, (column + 1) * rail.rows), id: \.self) { index in
                                    tile(tools[index], index).id(index)
                                }
                            }
                        }
                    }
                }
                .onChange(of: model.launcher.selection) { _, selection in
                    guard model.showsSelection, let selection else { return }
                    withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(selection) }
                }
            }
        }
    }

    private func tile(_ tool: IslandTool, _ index: Int) -> some View {
        ToolRailTile(model: model, tool: tool, selected: model.showsSelection && model.launcher.selection == index) {
            model.select(index, byKeyboard: false)
            model.activate(tool, from: .island)
        }
    }
}

/// An island tile: a 32-pt icon well over a 10-pt label, a green dot while its feature is active.
/// No number badge and no selection fill; a keyboard selection is drawn as a thin ring.
private struct ToolRailTile: View {
    @ObservedObject var model: ToolsModel
    let tool: IslandTool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let title = model.title(tool)
        Button(action: action) {
            VStack(spacing: 5) {
                ToolIcon(model: model, tool: tool, size: 32, glyph: 16)
                    .overlay(alignment: .topTrailing) {
                        if model.isActive(tool) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                                .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                                .offset(x: 2, y: -1)
                        }
                    }
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(height: 26, alignment: .top)
            }
            .padding(.vertical, 4)
            .frame(width: IslandToolRail.tileWidth, height: IslandToolRail.tileHeight)
        }
        .buttonStyle(IslandButtonStyle())
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.45), lineWidth: 1)
            }
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(model.isActive(tool) ? .isSelected : [])
    }
}

/// A tool's icon: an SF Symbol in a round well, or a pinned app's own icon.
struct ToolIcon: View {
    @ObservedObject var model: ToolsModel
    let tool: IslandTool
    let size: CGFloat
    let glyph: CGFloat

    var body: some View {
        switch tool {
        case .app(let path):
            Image(nsImage: model.app(path).icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        case .builtIn:
            ZStack {
                Circle().fill(IslandStyle.surface)
                Image(systemName: model.symbol(tool))
                    .font(.system(size: glyph, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: size, height: size)
        }
    }
}

/// The header's "Customize tools" button, which turns into Done while editing. Hidden while a
/// utility is hosted.
struct ToolsCustomizeButton: View {
    @ObservedObject var model: ToolsModel

    var body: some View {
        if model.launcher.hosted == nil {
            let editing = model.launcher.editing
            Button { model.setEditing(!editing) } label: {
                Image(systemName: editing ? "checkmark" : "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(editing ? 0.95 : 0.7))
                    .frame(width: 26, height: 26)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IslandButtonStyle(cornerRadius: 8))
            .help(editing ? "Done" : "Customize tools")
            .accessibilityLabel(editing ? "Done customizing tools" : "Customize tools")
        }
    }
}

/// A hosted utility's frame: Back to the tiles, the utility's title, and Close.
struct ToolsUtilityFrame<Content: View>: View {
    let title: String
    let back: () -> Void
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(IslandButtonStyle(cornerRadius: 8))
                .help("Back to tools")
                .accessibilityLabel("Back")
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(IslandButtonStyle(cornerRadius: 8))
                .help("Close")
                .accessibilityLabel("Close")
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// What a hosted utility shows. The speed test is the only one MenuSprite has.
struct ToolsUtilityContent: View {
    let utility: IslandBuiltInTool
    @ObservedObject var model: ToolsModel

    var body: some View {
        switch utility {
        case .speedTest: SpeedTestPanel(model: model.speedTest)
        default: EmptyView()
        }
    }
}
