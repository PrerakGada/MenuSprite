import SwiftUI
import SystemMonitoring

/// The sprite being edited in the studio. Changes apply to the menu bar as they are made (saved a
/// moment after the last one), with undo, redo and a revert to how the sprite was when opened.
@MainActor
final class StudioModel: ObservableObject {
    @Published private(set) var config: SpriteConfiguration
    @Published var selection: String?
    /// The block selected on the board.
    @Published var boardSelection: String?
    /// Which surface the design pane shows: the menu-bar face or the board a click opens.
    @Published var showingBoard = false
    @Published var darkBar = true
    @Published var zoom: CGFloat = 5
    /// The node a rule target picker is pointing at, outlined on the canvas.
    @Published var highlighted: String?
    let original: SpriteConfiguration
    unowned let store: MonitoringStore
    private var undoStack: [SpriteConfiguration] = []
    private var redoStack: [SpriteConfiguration] = []
    private var lastCoalesced = Date.distantPast
    private var saveTask: Task<Void, Never>?

    init(config: SpriteConfiguration, store: MonitoringStore) {
        var value = config
        if value.design == nil { value.design = SpriteDesign.migrated(from: config, metric: store.knownMetric) }
        Self.placeCommands(&value)
        self.config = value
        self.original = value
        self.store = store
        store.preview(design: value.design)
    }

    var id: UUID { config.id }
    var isSaved: Bool { store.sprites.contains { $0.id == config.id } }
    var design: SpriteDesign { config.design ?? SpriteDesign() }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasChanges: Bool { config != original }
    var selectedNode: DesignNode? { selection.flatMap(design.node) }

    /// Applies a change. `coalesce` folds a burst of changes (typing, dragging a slider) into one undo step.
    func change(coalesce: Bool = false, _ body: (inout SpriteConfiguration) -> Void) {
        var next = config
        body(&next)
        Self.placeCommands(&next)
        guard next != config else { return }
        let now = Date()
        if !coalesce || now.timeIntervalSince(lastCoalesced) > 0.8 {
            undoStack.append(config)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack = []
        }
        if coalesce { lastCoalesced = now } else { lastCoalesced = .distantPast }
        apply(next)
    }
    func edit(coalesce: Bool = false, _ body: (inout SpriteDesign) -> Void) {
        change(coalesce: coalesce) { config in
            var design = config.design ?? SpriteDesign()
            body(&design)
            config.design = design
        }
    }
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(config); apply(previous)
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(config); apply(next)
    }
    func revert() { change { $0 = original } }
    /// The gallery template this sprite came from, if it still exists.
    var template: SpriteTemplate? { SpriteTemplates.template(config.templateID) }
    /// Back to the template's design and settings, as one undoable step. Running, menu-bar visibility
    /// and which side of the bar it sits on are the sprite's own and stay.
    func resetToTemplate() {
        guard let template else { return }
        selection = nil; boardSelection = nil
        change { $0 = template.reset($0, metric: store.knownMetric) }
    }

    /// A sprite with a folder of files runs every command there, the ones added here included, as the
    /// compiler arranges for an agent's: otherwise a new script block's `python3 prs.py` would run in the home
    /// folder beside the sprite's own button that finds it. A sprite without a folder is left as it is.
    static func placeCommands(_ config: inout SpriteConfiguration) {
        guard config.design != nil,
              let folder = CommandVariableRunner.existingDirectory(SpriteFolders.directory(for: config.id).path) else { return }
        config.design?.setCommandDirectory(folder)
    }

    private func apply(_ next: SpriteConfiguration) {
        config = next
        if let selection, next.design?.node(selection) == nil { self.selection = nil }
        if let boardSelection, next.design?.board?.root.find(boardSelection) == nil { self.boardSelection = nil }
        store.preview(design: next.design)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            self.saveNow()
        }
    }
    func saveNow() {
        saveTask?.cancel(); saveTask = nil
        store.save(config)
    }
    /// Takes the copy an agent saved through the socket without saving over it. The studio's own copy becomes
    /// an undo step, so an edit made here a moment earlier is not lost either.
    func adopt(_ saved: SpriteConfiguration) {
        saveTask?.cancel(); saveTask = nil
        guard saved != config else { return }
        undoStack.append(config); redoStack = []
        config = saved
        if let selection, saved.design?.node(selection) == nil { self.selection = nil }
        if let boardSelection, saved.design?.board?.root.find(boardSelection) == nil { self.boardSelection = nil }
        store.preview(design: saved.design)
    }
    /// Closes without saving: the sprite was removed elsewhere.
    func discard() {
        saveTask?.cancel(); saveTask = nil
        store.preview(design: nil)
    }
    func close() {
        if saveTask != nil { saveNow() }
        store.preview(design: nil)
    }

    // MARK: Bindings

    func binding<Value>(_ path: WritableKeyPath<SpriteConfiguration, Value>, coalesce: Bool = false) -> Binding<Value> {
        Binding(get: { self.config[keyPath: path] }, set: { value in self.change(coalesce: coalesce) { $0[keyPath: path] = value } })
    }
    func node<Value>(_ id: String, _ path: WritableKeyPath<DesignNode, Value>, fallback: Value, coalesce: Bool = false) -> Binding<Value> {
        Binding(get: { self.design.node(id)?[keyPath: path] ?? fallback },
                set: { value in self.edit(coalesce: coalesce) { $0.root.update(id) { $0[keyPath: path] = value } } })
    }
    func variable<Value>(_ id: String, _ path: WritableKeyPath<SpriteVariable, Value>, fallback: Value, coalesce: Bool = false) -> Binding<Value> {
        Binding(get: { self.design.variable(id)?[keyPath: path] ?? fallback },
                set: { value in
                    self.edit(coalesce: coalesce) { design in
                        if let index = design.variables.firstIndex(where: { $0.id == id }) { design.variables[index][keyPath: path] = value }
                    }
                })
    }
    func rule<Value>(_ id: String, _ path: WritableKeyPath<SpriteRule, Value>, fallback: Value, coalesce: Bool = false) -> Binding<Value> {
        Binding(get: { self.design.rules.first { $0.id == id }?[keyPath: path] ?? fallback },
                set: { value in
                    self.edit(coalesce: coalesce) { design in
                        if let index = design.rules.firstIndex(where: { $0.id == id }) { design.rules[index][keyPath: path] = value }
                    }
                })
    }

    // MARK: Structure actions

    /// Adds `node` beside the selection (or at the end of the sprite) and selects it.
    func add(_ node: DesignNode, edge: DropEdge = .right) {
        let target = selection ?? design.root.id
        edit { design in
            if !design.insert(node, at: edge, of: target) { design.root.children.append(node) }
        }
        selection = node.id
    }
    func addValueText(_ variableID: String) {
        var text = DesignNode.text([.value(variableID)], size: 12, name: "Value")
        text.style.align = .trailing
        add(text)
    }
    /// Adds a value and, when a text is selected, puts it at the end of that text.
    func addVariable(_ variable: SpriteVariable, insertIntoSelection: Bool = true) {
        edit { design in
            var variable = variable
            variable.id = design.freshVariableID(variable.id)
            design.variables.append(variable)
        }
        guard let added = design.variables.last else { return }
        if insertIntoSelection, let node = selectedNode, node.kind == .text {
            edit { $0.root.update(node.id) { $0.segments.append(.value(added.id)) } }
        } else if insertIntoSelection, let node = selectedNode, node.kind == .bar || node.kind == .battery {
            edit { $0.root.update(node.id) { $0.variable = added.id } }
        } else if insertIntoSelection {
            addValueText(added.id)
        }
    }
    func addReading(_ metric: Metric, insertIntoSelection: Bool = true) {
        var format = ValueFormat()
        format.decimals = metric.unit == .watts || metric.unit == .celsius ? 1 : 0
        let key = metric.shortName.count > 1 && metric.shortName.allSatisfy(\.isLetter) ? metric.shortName : metric.name
        addVariable(SpriteVariable(id: key, name: metric.name, source: .reading(metric: metric.id), format: format),
                    insertIntoSelection: insertIntoSelection)
    }
    func deleteSelection() {
        guard let selection, selection != design.root.id else { return }
        edit { $0.delete(selection) }
        self.selection = nil
    }
}

/// The whole right side of the window while a sprite is open: identity and state across the top,
/// the design on the left, values and rules on the right.
struct SpriteStudio: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            StudioHeader(model: model, store: store, close: close)
            Divider()
            HSplitView {
                StudioDesignPane(model: model, store: store)
                    .frame(minWidth: 440, idealWidth: 600, maxWidth: .infinity)
                StudioLogicPane(model: model, store: store)
                    .frame(minWidth: 360, idealWidth: 420, maxWidth: 620)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("sprite-studio")
    }
}

private struct StudioHeader: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    let close: () -> Void
    @State private var choosingSymbol = false
    @ObservedObject private var placement = SpritePlacement.shared

    var body: some View {
        HStack(spacing: 12) {
            Button { choosingSymbol = true } label: {
                Image(systemName: model.config.symbol).font(.system(size: 17)).frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).help("The sprite's identity icon: shown in lists and when it is paused")
            .popover(isPresented: $choosingSymbol) {
                SymbolPicker(symbol: model.binding(\.symbol)).frame(width: 330, height: 300).padding(12)
            }
            VStack(alignment: .leading, spacing: 2) {
                TextField("Sprite name", text: model.binding(\.name, coalesce: true))
                    .textFieldStyle(.plain).font(.system(size: 19, weight: .semibold, design: .rounded))
                    .accessibilityIdentifier("sprite-name")
                Text(model.isSaved ? (model.hasChanges ? "Changes apply to the menu bar as you make them" : "Live in the menu bar") : "Not saved yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("Running", isOn: model.binding(\.enabled)).toggleStyle(.switch).controlSize(.small)
                .help("Off stops its readings and commands").accessibilityIdentifier("sprite-enabled")
            Toggle("In menu bar", isOn: model.binding(\.showInMenuBar)).toggleStyle(.switch).controlSize(.small)
                .accessibilityIdentifier("sprite-menu-visible")
            // Where it sits applies at once and is not part of undo: it is this Mac's layout, kept apart from the design.
            Picker("Side", selection: Binding(get: { placement.isLeft(model.id) }, set: { placement.setLeft(model.id, $0) })) {
                Text("Left").tag(true)
                Text("Right").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 92)
            .disabled(!model.config.showInMenuBar)
            .help("Left sits over the front app's menus (\(placement.reveal == .hover ? "rest the pointer on it for \(placement.hoverDelay.formatted()) s" : "point at it and hold ⌘") to see them); right sits with the other menu bar items")
            .accessibilityIdentifier("sprite-side")
            Picker("Refresh", selection: model.binding(\.interval)) {
                ForEach([1.0, 2, 5, 10, 30, 60], id: \.self) { Text("Every \(Int($0)) s").tag($0) }
            }
            .labelsHidden().frame(width: 104).help("How often the menu bar redraws this sprite's readings")
            .accessibilityIdentifier("sprite-interval")
            Divider().frame(height: 22)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command).disabled(!model.canUndo).help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo).help("Redo")
            Button("Revert") { model.revert() }.disabled(!model.hasChanges)
                .help("Back to how this sprite was when you opened it")
            if let template = model.template {
                Button("Reset to template") { model.resetToTemplate() }
                    .help("Back to the gallery's “\(template.name)”: its design, values, rules and refresh. Undo brings your version back.")
                    .accessibilityIdentifier("reset-to-template")
            }
            if !model.isSaved {
                Button("Add sprite") { model.saveNow() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("save-sprite")
            }
            Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction).help("Close the studio")
        }
        .controlSize(.small)
        .padding(.horizontal, 18).padding(.vertical, 11)
    }
}

/// SF Symbols by name, with a few common ones to tap.
struct SymbolPicker: View {
    @Binding var symbol: String
    @State private var search = ""
    static let common = ["cpu", "memorychip", "bolt", "bolt.fill", "network", "wifi", "internaldrive", "externaldrive",
                         "display", "battery.100percent", "fan.fill", "thermometer.medium", "gauge.with.dots.needle.50percent",
                         "chart.xyaxis.line", "chart.bar.fill", "waveform.path.ecg", "sparkles", "terminal", "brain",
                         "clock", "timer", "calendar", "envelope", "bell", "star.fill", "heart.fill", "flame", "leaf",
                         "cloud", "sun.max", "moon", "drop", "house", "cart", "creditcard", "dollarsign.circle",
                         "server.rack", "shippingbox", "cube", "hammer", "wrench.and.screwdriver", "gearshape",
                         "arrow.up", "arrow.down", "arrow.up.arrow.down", "checkmark.circle", "xmark.octagon",
                         "exclamationmark.triangle", "circle.fill", "square.fill", "triangle.fill", "person", "music.note", "gamecontroller"]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Any SF Symbol name, e.g. cup.and.saucer", text: $search)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if NSImage(systemSymbolName: search, accessibilityDescription: nil) != nil { symbol = search } }
            if !search.isEmpty {
                let valid = NSImage(systemSymbolName: search, accessibilityDescription: nil) != nil
                Button { symbol = search } label: {
                    Label(valid ? "Use “\(search)”" : "No symbol called “\(search)”", systemImage: valid ? search : "questionmark")
                }.disabled(!valid)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 8), spacing: 6) {
                    ForEach(Self.common.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { name in
                        Button { symbol = name } label: { Image(systemName: name).frame(width: 30, height: 28) }
                            .buttonStyle(.borderless)
                            .background(symbol == name ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .help(name)
                    }
                }
            }
        }
    }
}

/// Swatches for a colour value: the parent's colour, the menu bar's own, presets, or any colour.
struct ColorChoice: View {
    @Binding var value: String
    var allowInherit = true
    static let presets = ["FFFFFF", "30D158", "34C759", "FFD60A", "FF9F0A", "FF453A", "79BFFA", "0A84FF", "B8A1F3", "78DFBD", "A0A0A0", "000000"]

    var body: some View {
        FlowLayout(spacing: 5) {
            if allowInherit {
                swatch("inherit", help: "Same as the container") {
                    Image(systemName: "arrow.turn.left.up").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            swatch("auto", help: "Follows the menu bar: white on dark, black on light") {
                Circle().fill(LinearGradient(colors: [.white, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 14, height: 14)
            }
            ForEach(Self.presets, id: \.self) { hex in
                swatch(hex, help: "#\(hex)") { Circle().fill(spriteColor(hex)).frame(width: 14, height: 14) }
            }
            // A system colour by name (an agent's "teal") adapts to light and dark; shown so it is not invisible here.
            if SpriteColors.system(value) != nil {
                swatch(value, help: "\(value) (Apple's system colour, adapts to light and dark)") {
                    Circle().fill(spriteColor(value)).frame(width: 14, height: 14)
                }
            }
            ColorPicker("", selection: Binding(
                get: { SpriteColors.color(value).map { Color(nsColor: $0) } ?? .white },
                set: { value = Self.hex($0) ?? value }), supportsOpacity: false)
                .labelsHidden().frame(width: 26).help("Any colour")
        }
    }
    private func swatch<Content: View>(_ hex: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        Button { value = hex } label: {
            content().frame(width: 20, height: 20)
                .overlay(Circle().stroke(value == hex ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: value == hex ? 2 : 1))
        }.buttonStyle(.plain).help(help)
    }
    static func hex(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
    }
}

/// Lays children left to right and wraps them onto new lines, like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

/// A titled block in the studio's panes.
struct StudioSection<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary) }
                Spacer()
                accessory()
            }
            content()
        }
    }
}
extension StudioSection where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.accessory = { EmptyView() }; self.content = content
    }
}
