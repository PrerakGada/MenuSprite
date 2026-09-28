import AppKit
import Combine
import IslandKit
import SwiftUI

/// A MenuSprite action the Command Bar can run.
struct CommandBarAction: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    var keywords: [String] = []
    let run: @MainActor () -> Void
}

/// One row of the bar: an action or an installed app.
enum CommandBarItem: Identifiable {
    case action(CommandBarAction)
    case app(CommandAppList.Entry)

    var id: String {
        switch self {
        case .action(let action): "action." + action.id
        case .app(let app): "app." + app.path
        }
    }
}

/// A minimal launcher: one field that finds installed apps and MenuSprite's own actions, driven from
/// the keyboard. Built when it opens and released when it closes; the app list is re-read off the
/// main thread on every opening, and a scan that finishes after its opening ended is dropped.
@MainActor
final class CommandBar: NSObject, NSWindowDelegate {
    private let actions: () -> [CommandBarAction]
    private var panel: ToolsFloatingPanel?
    private var model: CommandBarModel?
    private var presentations = CommandBarPresentations()
    private let dismissal = FloatingPanelDismissal()
    private var observation: AnyCancellable?
    private var pending: Task<Void, Never>?

    init(actions: @escaping () -> [CommandBarAction]) { self.actions = actions }

    var isVisible: Bool { panel != nil }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        pending?.cancel()
        guard panel == nil, let screen = ToolsFloatingPanel.pointerScreen else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        let presentation = presentations.begin()
        let model = CommandBarModel(actions: actions(), run: { [weak self] item in self?.run(item) },
                                    close: { [weak self] in self?.hide() })
        let height = CommandBarModel.height(model)
        let panel = ToolsFloatingPanel(size: CGSize(width: IslandToolPlacement.commandBarWidth, height: height),
                                       cornerRadius: 16, title: "Command Bar")
        panel.delegate = self
        panel.host(CommandBarView(model: model))
        panel.keyHandler = { [weak self] event in self?.key(event) ?? false }
        self.model = model
        self.panel = panel
        panel.present(at: IslandToolPlacement.commandBar(height: height, visible: screen.visibleFrame))
        dismissal.install(on: panel, suppressed: { false }, dismiss: { [weak self] in self?.hide() })
        observation = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refit() } }
        }
        let own = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        Task { [weak self] in
            let apps = await Task.detached(priority: .userInitiated) { InstalledApps.scan(excluding: own) }.value
            guard let self, presentations.accepts(presentation) else { return }
            self.model?.setApps(apps)
        }
    }

    func hide() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? ToolsFloatingPanel, window === panel else { return }
        presentations.end()
        dismissal.remove()
        observation = nil
        window.keyHandler = nil
        window.delegate = nil
        window.contentView = nil
        panel = nil
        model = nil
    }

    /// The bar goes away first; the choice runs 0.15 s later, so a capture or window never shows it.
    private func run(_ item: CommandBarItem) {
        hide()
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(IslandToolActivation.dismissDelay))
            guard !Task.isCancelled else { return }
            switch item {
            case .action(let action): action.run()
            case .app(let app):
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        }
    }

    private func refit() {
        guard let panel, let model, let screen = panel.screen ?? ToolsFloatingPanel.pointerScreen else { return }
        let frame = IslandToolPlacement.commandBar(height: CommandBarModel.height(model), visible: screen.visibleFrame)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    private func key(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let model else { return false }
        let key: CommandBarKey
        switch event.keyCode {
        case 126: key = .up
        case 125: key = .down
        case 36, 76: key = .returnKey
        case 53: key = .escape
        default: key = .character(event.charactersIgnoringModifiers ?? "")
        }
        let flags = event.modifierFlags
        let composing = (panel?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
        let action = CommandBarKeys.action(key, command: flags.contains(.command), control: flags.contains(.control),
                                           option: flags.contains(.option), composing: composing)
        guard action != .passThrough else { return false }
        model.handle(action)
        return true
    }
}

/// The bar's query, rows and selection. With an empty field it lists MenuSprite's actions; otherwise
/// the twelve best matches among actions and apps.
@MainActor
final class CommandBarModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published private(set) var rows: [CommandBarItem] = []
    @Published private(set) var selection: Int?
    @Published private(set) var scanned = false

    private let actions: [CommandBarAction]
    private var apps: [CommandAppList.Entry] = []
    private var candidates: [CommandCandidate] = []
    private var icons: [String: NSImage] = [:]
    /// Hover selects only after the pointer really moves, not when rows slide under a still pointer.
    private var pointer = NSEvent.mouseLocation
    let run: (CommandBarItem) -> Void
    let close: () -> Void

    static let fieldHeight: CGFloat = 52
    static let rowHeight: CGFloat = 30

    init(actions: [CommandBarAction], run: @escaping (CommandBarItem) -> Void, close: @escaping () -> Void) {
        self.actions = actions
        self.run = run
        self.close = close
        rebuild()
    }

    static func height(_ model: CommandBarModel) -> CGFloat {
        guard !model.rows.isEmpty else { return fieldHeight + (model.isSearching ? 44 : 0) }
        let list = CGFloat(model.rows.count) * (rowHeight + 2) + 10
        return fieldHeight + 1 + min(IslandToolPlacement.commandBarListLimit, list)
    }

    var isSearching: Bool { !CommandMatcher.fold(query).isEmpty }

    func setApps(_ apps: [CommandAppList.Entry]) {
        self.apps = apps
        scanned = true
        rebuild()
    }

    func handle(_ action: CommandBarKeyAction) {
        switch action {
        case .moveUp: selection = CommandBarKeys.move(selection, by: -1, count: rows.count)
        case .moveDown: selection = CommandBarKeys.move(selection, by: 1, count: rows.count)
        case .run: if let selection, rows.indices.contains(selection) { run(rows[selection]) }
        case .runRow(let index): if rows.indices.contains(index) { run(rows[index]) }
        case .escape: if query.isEmpty { close() } else { query = "" }
        case .swallow, .passThrough: break
        }
    }

    func hover(_ index: Int) {
        let location = NSEvent.mouseLocation
        guard location != pointer else { return }
        pointer = location
        selection = index
    }

    func icon(_ app: CommandAppList.Entry) -> NSImage {
        if let icon = icons[app.path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icons[app.path] = icon
        return icon
    }

    private func rebuild() {
        candidates = actions.map { CommandCandidate(title: $0.title, keywords: $0.keywords) }
            + apps.map { CommandCandidate(title: $0.name) }
        refresh()
    }

    private func refresh() {
        if isSearching {
            rows = CommandMatcher.rank(candidates, query: query).map { index in
                index < actions.count ? .action(actions[index]) : .app(apps[index - actions.count])
            }
        } else {
            rows = actions.map(CommandBarItem.action)
        }
        selection = rows.isEmpty ? nil : 0
    }
}

/// Installed apps in /Applications, ~/Applications and /System/Applications (plus the Finder), found
/// by walking the folders without entering app bundles. Runs off the main thread.
enum InstalledApps {
    static func scan(excluding own: String?) -> [CommandAppList.Entry] {
        let manager = FileManager.default
        var entries: [CommandAppList.Entry] = []
        func add(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath().path
            guard !CommandAppList.isInsidePackage(resolved) else { return }
            var name = manager.displayName(atPath: resolved)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            entries.append(CommandAppList.Entry(path: resolved, name: name))
        }
        for root in ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"] {
            guard let walker = manager.enumerator(at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = walker.nextObject() as? URL {
                if url.pathExtension == "app" { add(url) }
                else if walker.level >= 4 { walker.skipDescendants() }
            }
        }
        let finder = "/System/Library/CoreServices/Finder.app"
        if manager.fileExists(atPath: finder) { add(URL(fileURLWithPath: finder)) }
        return CommandAppList.unique(entries, excluding: own)
    }
}

private struct CommandBarView: View {
    @ObservedObject var model: CommandBarModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                CommandBarField(text: $model.query)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: CommandBarModel.fieldHeight)
            if !model.rows.isEmpty {
                Divider().overlay(Color.white.opacity(0.08))
                list
            } else if model.isSearching {
                Text(model.scanned ? "Nothing matches." : "Looking through your apps…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, item in
                        CommandBarRow(model: model, item: item, index: index, selected: model.selection == index)
                            .id(index)
                    }
                }
                .padding(5)
            }
            .onChange(of: model.selection) { _, selection in
                if let selection { proxy.scrollTo(selection) }
            }
        }
    }
}

private struct CommandBarRow: View {
    @ObservedObject var model: CommandBarModel
    let item: CommandBarItem
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            Text(title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.35))
                    .frame(width: 26, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CommandBarModel.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(selected ? 0.14 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { model.run(item) }
        .onContinuousHover { phase in
            if case .active = phase { model.hover(index) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var title: String {
        switch item {
        case .action(let action): action.title
        case .app(let app): app.name
        }
    }

    private var detail: String {
        switch item {
        case .action(let action): action.detail
        case .app: "App"
        }
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .action(let action):
            Image(systemName: action.symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.12)))
        case .app(let app):
            Image(nsImage: model.icon(app)).resizable().interpolation(.high)
        }
    }
}

/// The bar's text field. It takes the keyboard as soon as it is on screen; keys the bar handles
/// (arrows, Return, Escape, ⌘-digits) are caught by the panel before they reach it.
private struct CommandBarField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = .systemFont(ofSize: 18)
        field.textColor = .white
        field.placeholderString = "Search apps and MenuSprite actions"
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Command Bar")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            text.wrappedValue = (notification.object as? NSTextField)?.stringValue ?? ""
        }
    }

    private final class FocusingField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
    }
}
