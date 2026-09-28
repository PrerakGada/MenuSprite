import AppKit
import Combine
import IslandKit
import SwiftUI

/// The floating tools panel, used when "Tools" opens in a separate window or the island cannot take
/// it. Built when shown and released when hidden: while hidden it holds no window, monitor or view.
@MainActor
final class ToolsQuickPanel: NSObject, NSWindowDelegate {
    private let model: ToolsModel
    private var panel: ToolsFloatingPanel?
    private let dismissal = FloatingPanelDismissal()
    private var observation: AnyCancellable?
    private var pending: Task<Void, Never>?

    static let width: CGFloat = 420

    init(model: ToolsModel) { self.model = model }

    var isVisible: Bool { panel != nil }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        pending?.cancel()
        guard panel == nil, let screen = ToolsFloatingPanel.pointerScreen else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        model.present()
        let size = CGSize(width: Self.width, height: QuickPanelMetrics.height(model.launcher))
        let panel = ToolsFloatingPanel(size: size, cornerRadius: 22, title: "Tools")
        panel.delegate = self
        panel.host(ToolsQuickPanelView(model: model, preferences: model.preferences,
                                       chooseApps: { [weak self] in self?.chooseApps() },
                                       close: { [weak self] in self?.hide() }))
        panel.keyHandler = { [weak self] event in self?.key(event) ?? false }
        self.panel = panel
        panel.present(at: IslandToolPlacement.toolsPanel(size: size, visible: screen.visibleFrame))
        dismissal.install(on: panel, suppressed: { [weak self] in self?.model.launcher.holdsSurface ?? false },
                          dismiss: { [weak self] in self?.hide() })
        // Edit mode and utilities change the panel's height; it re-fits keeping its top edge and centre.
        observation = model.$launcher.map { QuickPanelMetrics.height($0) }.removeDuplicates().dropFirst()
            .sink { [weak self] height in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refit(height) } }
            }
    }

    func hide() {
        guard let panel else { return }
        panel.close()
    }

    /// Hides the panel, then runs `action` once after `delay`, so a window it opens never lands under it.
    func dismiss(after delay: Double, then action: @escaping @MainActor () -> Void) {
        hide()
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? ToolsFloatingPanel, window === panel else { return }
        dismissal.remove()
        observation = nil
        window.keyHandler = nil
        window.delegate = nil
        window.contentView = nil
        panel = nil
        model.dismissed()
    }

    private func refit(_ height: CGFloat) {
        guard let panel, let screen = panel.screen ?? ToolsFloatingPanel.pointerScreen else { return }
        panel.setFrame(IslandToolPlacement.refit(panel.frame, to: CGSize(width: Self.width, height: height), visible: screen.visibleFrame),
                       display: true)
    }

    private func chooseApps() {
        model.chooseApps(above: panel?.level ?? .floating)
    }

    /// Arrows move through three columns, 1–9 pick by position, Return runs, Escape peels one layer.
    /// Anything with ⌘, ⌃ or ⌥ passes through, and nothing but Escape acts while editing.
    private func key(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 53 {
            if !model.escape() { hide() }
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty, !model.launcher.editing, model.launcher.hosted == nil else { return false }
        let count = model.tools.count
        let current = model.launcher.selection ?? 0
        switch event.keyCode {
        case 123: model.select(IslandToolGrid.move(current, .left, count: count), byKeyboard: true)
        case 124: model.select(IslandToolGrid.move(current, .right, count: count), byKeyboard: true)
        case 126: model.select(IslandToolGrid.move(current, .up, count: count), byKeyboard: true)
        case 125: model.select(IslandToolGrid.move(current, .down, count: count), byKeyboard: true)
        case 36, 76: model.activateSelection(from: .panel)
        default:
            guard let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
                  let index = IslandToolGrid.index(forDigit: digit, count: count) else { return false }
            model.select(index, byKeyboard: true)
            model.activate(model.tools[index], from: .panel)
        }
        return true
    }
}

/// The panel's height for each state: the grid sized to its rows, or a fixed area while editing or
/// hosting a utility.
enum QuickPanelMetrics {
    static let padding: CGFloat = 14
    static let header: CGFloat = 26
    static let tileHeight: CGFloat = 84
    static let spacing: CGFloat = 8

    /// Beyond this many rows the grid scrolls, so a long list of pinned apps never outgrows the screen.
    static let maximumRows = 5

    static func rows(_ launcher: IslandToolLauncher) -> Int {
        Int(ceil(Double(launcher.tools.count) / Double(IslandToolGrid.columns)))
    }

    static func height(_ launcher: IslandToolLauncher) -> CGFloat {
        let chrome = 2 * padding + header + 10
        if launcher.hosted != nil { return 2 * padding + 200 }
        if launcher.editing { return chrome + 400 }
        let rows = min(maximumRows, rows(launcher))
        guard rows > 0 else { return chrome + 110 }
        return chrome + CGFloat(rows) * tileHeight + CGFloat(rows - 1) * spacing
    }
}

private struct ToolsQuickPanelView: View {
    @ObservedObject var model: ToolsModel
    @ObservedObject var preferences: ToolsPreferences
    let chooseApps: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let utility = model.launcher.hosted {
                ToolsUtilityFrame(title: utility.title, back: model.closeUtility, close: close) {
                    ToolsUtilityContent(utility: utility, model: model)
                }
            } else {
                HStack {
                    Text("Tools").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    ToolsCustomizeButton(model: model)
                }
                .frame(height: QuickPanelMetrics.header)
                if model.launcher.editing {
                    ToolsEditView(model: model, preferences: preferences, columns: IslandToolGrid.columns, chooseApps: chooseApps)
                } else if model.tools.isEmpty {
                    IslandUnavailableView(symbol: IslandSectionID.tools.symbol, message: "No tools on show. Customize tools to add some back.")
                } else {
                    grid
                }
            }
        }
        .padding(QuickPanelMetrics.padding)
        .frame(width: ToolsQuickPanel.width, height: QuickPanelMetrics.height(model.launcher), alignment: .top)
        .foregroundStyle(.white)
    }

    private var grid: some View {
        let tools = model.tools
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: QuickPanelMetrics.spacing), count: IslandToolGrid.columns),
                          spacing: QuickPanelMetrics.spacing) {
                    ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                        QuickTile(model: model, tool: tool, number: index < 9 ? index + 1 : nil,
                                  selected: model.launcher.selection == index) {
                            model.select(index, byKeyboard: false)
                            model.activate(tool, from: .panel)
                        }
                        .id(index)
                    }
                }
            }
            .scrollDisabled(QuickPanelMetrics.rows(model.launcher) <= QuickPanelMetrics.maximumRows)
            .onChange(of: model.launcher.selection) { _, selection in
                if let selection { proxy.scrollTo(selection) }
            }
        }
    }
}

/// A floating-panel tile: a larger icon, a number badge for keys 1–9, and a filled selection.
private struct QuickTile: View {
    @ObservedObject var model: ToolsModel
    let tool: IslandTool
    let number: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let title = model.title(tool)
        Button(action: action) {
            VStack(spacing: 6) {
                ToolIcon(model: model, tool: tool, size: 38, glyph: 17)
                    .overlay(alignment: .topTrailing) {
                        if model.isActive(tool) {
                            Circle().fill(Color.green).frame(width: 8, height: 8).offset(x: 2, y: -1)
                        }
                    }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 28, alignment: .top)
            }
            .frame(maxWidth: .infinity, minHeight: QuickPanelMetrics.tileHeight, maxHeight: QuickPanelMetrics.tileHeight)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(selected ? 0.16 : 0.05)))
            .overlay(alignment: .topLeading) {
                if let number {
                    Text("\(number)").font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(IslandStyle.tertiaryText).padding(7)
                }
            }
        }
        .buttonStyle(IslandButtonStyle())
        .help(title)
        .accessibilityLabel(title)
    }
}
