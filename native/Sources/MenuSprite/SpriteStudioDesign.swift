import SwiftUI
import UniformTypeIdentifiers
import SystemMonitoring

/// The left half of the studio: the sprite as the menu bar draws it, enlarged and editable, the
/// pieces it is built from, and the selected piece's settings.
struct StudioDesignPane: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("Surface", selection: $model.showingBoard) {
                Label("Menu bar", systemImage: "menubar.rectangle").tag(false)
                Label("Board (opens on click)", systemImage: "rectangle.portrait.on.rectangle.portrait").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 360)
            .padding(.top, 12).padding(.bottom, 2)
            .accessibilityIdentifier("studio-surface")
            if model.showingBoard {
                StudioBoardPane(model: model, store: store)
            } else {
                menuBarDesign
            }
        }
    }

    private var menuBarDesign: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Menu bar").font(.headline)
                    Text("Click a piece to select it · drag it onto another to move it · drop new pieces from below")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Picker("Bar", selection: $model.darkBar) {
                        Image(systemName: "moon.fill").tag(true); Image(systemName: "sun.max.fill").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 74).help("Preview on a dark or a light menu bar")
                    Slider(value: $model.zoom, in: 3...8).frame(width: 80).help("Zoom")
                }
                ScrollView(.horizontal) {
                    StudioCanvas(model: model, store: store).padding(.vertical, 4)
                }
                .frame(height: NSStatusBar.system.thickness * model.zoom + 44)
                StudioPalette(model: model, store: store)
            }
            .padding(16)
            Divider()
            HSplitView {
                StudioOutline(model: model).frame(minWidth: 170, idealWidth: 210, maxWidth: 300)
                GeometryReader { proxy in
                    ScrollView { NodeInspector(model: model, store: store).padding(16).frame(width: proxy.size.width, alignment: .leading) }
                }
                .frame(minWidth: 260, maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Canvas

/// The design drawn at menu-bar size and enlarged, with every piece clickable and draggable.
struct StudioCanvas: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    @State private var hovered: String?
    @State private var dragging: String?
    @State private var drop: (target: String, edge: DropEdge)?
    @State private var paletteDrop: (target: String, edge: DropEdge)?

    private static let inset: CGFloat = 14

    var body: some View {
        let height = NSStatusBar.system.thickness
        let output = store.renderDesign(model.config, design: model.design, height: height)
        let zoom = model.zoom
        let size = CGSize(width: (output?.size.width ?? 20) * zoom + Self.inset * 2, height: height * zoom + Self.inset * 2)
        let placed = output?.placed ?? []
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(model.darkBar ? Color(white: 0.11) : Color(white: 0.92))
            if let output {
                Image(nsImage: Self.scaled(output.image, zoom: zoom, dark: model.darkBar))
                    .offset(x: Self.inset, y: Self.inset)
                    .accessibilityLabel(output.accessibilityText)
            }
            ForEach(placed.filter { $0.id != model.design.root.id }, id: \.id) { piece in
                let rect = frame(piece.frame, zoom: zoom, height: height)
                let selected = model.selection == piece.id
                let marked = selected || hovered == piece.id || model.highlighted == piece.id
                if marked {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(selected ? Color.accentColor : Color.accentColor.opacity(0.55),
                                style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: piece.kind.isContainer && !selected ? [4, 3] : []))
                        .frame(width: rect.width + 6, height: rect.height + 6)
                        .offset(x: rect.minX - 3, y: rect.minY - 3)
                        .allowsHitTesting(false)
                }
            }
            if let target = drop ?? paletteDrop, let piece = placed.first(where: { $0.id == target.target }) {
                indicator(frame(piece.frame, zoom: zoom, height: height), edge: target.edge)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let point) = phase { hovered = hit(point, placed: placed, zoom: zoom, height: height)?.id } else { hovered = nil }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = hit(value.startLocation, placed: placed, zoom: zoom, height: height)
                if dragging == nil, hypot(value.translation.width, value.translation.height) > 4,
                   let start, start.id != model.design.root.id { dragging = start.id }
                if let dragging { drop = target(at: value.location, excluding: dragging, placed: placed, zoom: zoom, height: height) }
            }
            .onEnded { value in
                if let dragging, let drop { model.edit { $0.move(dragging, to: drop.edge, of: drop.target) }; model.selection = dragging }
                else if dragging == nil { model.selection = hit(value.location, placed: placed, zoom: zoom, height: height)?.id }
                dragging = nil; drop = nil
            })
        .onDrop(of: [.plainText], delegate: PaletteDrop(model: model, store: store, placed: placed, zoom: zoom, height: height,
                                                        indicator: $paletteDrop, locate: target))
        .contextMenu { if model.selectedNode != nil { NodeActions(model: model) } }
    }

    /// A piece's frame in the canvas (y down), from its frame in the image (y up).
    private func frame(_ rect: CGRect, zoom: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: Self.inset + rect.minX * zoom, y: Self.inset + (height - rect.maxY) * zoom,
               width: rect.width * zoom, height: rect.height * zoom)
    }
    /// The innermost piece under a point; small pieces get a little slack so they are easy to hit.
    private func hit(_ point: CGPoint, placed: [DesignRenderer.Placed], zoom: CGFloat, height: CGFloat) -> DesignRenderer.Placed? {
        placed.last { frame($0.frame, zoom: zoom, height: height).insetBy(dx: -3, dy: -3).contains(point) }
    }
    /// The piece a drop at `point` lands on and which of its edges is nearest.
    fileprivate func target(at point: CGPoint, excluding moving: String?, placed: [DesignRenderer.Placed], zoom: CGFloat,
                            height: CGFloat) -> (target: String, edge: DropEdge)? {
        let excluded = moving.flatMap { model.design.node($0) }.map { Set($0.flattened.map(\.id)) } ?? []
        guard let piece = placed.last(where: { !excluded.contains($0.id) && frame($0.frame, zoom: zoom, height: height).insetBy(dx: -6, dy: -6).contains(point) })
            ?? placed.first(where: { $0.id == model.design.root.id }) else { return nil }
        let rect = frame(piece.frame, zoom: zoom, height: height)
        let distances: [(DropEdge, CGFloat)] = [
            (.left, (point.x - rect.minX) / max(1, rect.width)), (.right, (rect.maxX - point.x) / max(1, rect.width)),
            (.above, (point.y - rect.minY) / max(1, rect.height) * 1.6), (.below, (rect.maxY - point.y) / max(1, rect.height) * 1.6)
        ]
        return (piece.id, distances.min { $0.1 < $1.1 }!.0)
    }
    private func indicator(_ rect: CGRect, edge: DropEdge) -> some View {
        let line: CGRect = switch edge {
        case .left: CGRect(x: rect.minX - 5, y: rect.minY - 4, width: 3, height: rect.height + 8)
        case .right: CGRect(x: rect.maxX + 2, y: rect.minY - 4, width: 3, height: rect.height + 8)
        case .above: CGRect(x: rect.minX - 4, y: rect.minY - 5, width: rect.width + 8, height: 3)
        case .below: CGRect(x: rect.minX - 4, y: rect.maxY + 2, width: rect.width + 8, height: 3)
        }
        return Capsule().fill(Color.accentColor).frame(width: line.width, height: line.height)
            .offset(x: line.minX, y: line.minY).allowsHitTesting(false)
    }

    /// The menu-bar image enlarged as vectors (it is drawn again at the larger size, not stretched),
    /// tinted the way the menu bar tints a template image.
    static func scaled(_ image: NSImage, zoom: CGFloat, dark: Bool) -> NSImage {
        let size = NSSize(width: image.size.width * zoom, height: image.size.height * zoom)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        return NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                NSGraphicsContext.current?.cgContext.scaleBy(x: zoom, y: zoom)
                image.draw(in: NSRect(origin: .zero, size: image.size))
                if image.isTemplate {
                    NSGraphicsContext.current?.cgContext.scaleBy(x: 1 / zoom, y: 1 / zoom)
                    (dark ? NSColor.white : NSColor.black).set(); rect.fill(using: .sourceAtop)
                }
            }
            return true
        }
    }
}

/// New pieces dragged from the palette onto the canvas.
private struct PaletteDrop: DropDelegate {
    let model: StudioModel
    let store: MonitoringStore
    let placed: [DesignRenderer.Placed]
    let zoom: CGFloat
    let height: CGFloat
    @Binding var indicator: (target: String, edge: DropEdge)?
    let locate: (CGPoint, String?, [DesignRenderer.Placed], CGFloat, CGFloat) -> (target: String, edge: DropEdge)?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        indicator = locate(info.location, nil, placed, zoom, height)
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { indicator = nil }
    func performDrop(info: DropInfo) -> Bool {
        let spot = locate(info.location, nil, placed, zoom, height)
        indicator = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let kind = object as? String else { return }
            Task { @MainActor in
                guard let node = StudioPalette.piece(kind, model: model) else { return }
                if let spot { model.selection = spot.target; model.add(node, edge: spot.edge) } else { model.add(node) }
            }
        }
        return true
    }
}

// MARK: - Palette

/// Pieces to add: click puts one beside the selection, dragging drops it exactly where you let go.
struct StudioPalette: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore

    /// A fresh piece for a palette entry ("text", "icon", "bar", "battery", "value:<variable>").
    @MainActor static func piece(_ kind: String, model: StudioModel) -> DesignNode? {
        switch kind {
        case "text":
            var node = DesignNode.text([.literal("Text")], size: 12, name: "Text"); node.style.tabular = false
            return node
        case "label":
            var node = DesignNode.text([.literal("LABEL")], size: 8.5, name: "Label")
            node.style.tabular = false; node.style.weight = .medium; node.style.shrinkToFit = true
            return node
        case "icon":
            var node = DesignNode(kind: .icon, name: "Icon", symbol: model.config.symbol); node.style.size = 14
            return node
        case "bar":
            var node = DesignNode(kind: .bar, name: "Bar", variable: model.design.variables.first { v in
                v.readingID.map { model.store.metric($0).unit == .percent } ?? false }?.id ?? model.design.variables.first?.id)
            node.style.size = 9
            return node
        case "battery":
            return DesignNode(kind: .battery, name: "Battery", variable: model.design.variables.first { $0.readingID == "battery.charge" }?.id)
        default:
            guard kind.hasPrefix("value:") else { return nil }
            var node = DesignNode.text([.value(String(kind.dropFirst(6)))], size: 12, name: "Value")
            node.style.align = .trailing
            return node
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Add").font(.caption).foregroundStyle(.secondary)
            tile("text", "Text", "textformat")
            tile("label", "Small label", "textformat.size.smaller")
            Menu {
                if model.design.variables.isEmpty { Text("Add a value on the right first") }
                ForEach(model.design.variables) { variable in
                    Button(variable.name) { if let node = Self.piece("value:\(variable.id)", model: model) { model.add(node) } }
                }
            } label: { Label("Value", systemImage: "number") }
                .menuStyle(.borderlessButton).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            tile("icon", "Icon", "star")
            tile("bar", "Level bar", "chart.bar.fill")
            tile("battery", "Battery", "battery.75percent")
            Spacer()
        }
        .controlSize(.small)
    }
    private func tile(_ kind: String, _ title: String, _ symbol: String) -> some View {
        Button { if let node = Self.piece(kind, model: model) { model.add(node) } } label: {
            Label(title, systemImage: symbol).padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(object: kind as NSString) }
        .help("Click to add beside the selection, or drag onto the sprite")
    }
}

// MARK: - Structure actions

/// Split, merge, wrap and reorder for the selected piece; shared by the toolbar and context menus.
struct NodeActions: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        if let node = model.selectedNode {
            let isRoot = node.id == model.design.root.id
            Button("Split sideways (row)") {
                var fresh: String?; model.edit { fresh = $0.split(node.id, axis: .row) }; model.selection = fresh ?? node.id }
            Button("Split top and bottom (column)") {
                var fresh: String?; model.edit { fresh = $0.split(node.id, axis: .column) }; model.selection = fresh ?? node.id }
            if model.design.canMergeWithNext(node.id) {
                Button("Merge with the next text") { model.edit { $0.mergeWithNext(node.id) } }
            }
            if node.kind.isContainer {
                Button(node.kind == .row ? "Turn into a column" : "Turn into a row") { model.edit { $0.flip(node.id) } }
                if !isRoot { Button("Unwrap (keep what is inside)") { model.edit { $0.unwrap(node.id) }; model.selection = nil } }
            }
            if !isRoot {
                Divider()
                Button("Move earlier") { model.edit { $0.shift(node.id, by: -1) } }
                Button("Move later") { model.edit { $0.shift(node.id, by: 1) } }
                Button("Select the container") { model.selection = model.design.root.parent(of: node.id)?.0.id }
                Button("Duplicate") { var copy: String?; model.edit { copy = $0.duplicate(node.id) }; model.selection = copy }
                Divider()
                Button("Delete", role: .destructive) { model.deleteSelection() }
            }
        }
    }
}

// MARK: - Outline

/// Every piece as an indented list: the easy way to reach small or nested pieces.
struct StudioOutline: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pieces").font(.system(size: 12, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                Spacer()
                if let node = model.selectedNode, node.id != model.design.root.id {
                    Button { model.deleteSelection() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete the selected piece").keyboardShortcut(.delete, modifiers: [])
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    rows(model.design.root, depth: 0)
                }.padding(.horizontal, 6).padding(.bottom, 10)
            }
        }
    }
    private func rows(_ node: DesignNode, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 1) {
            OutlineRow(model: model, node: node, depth: depth)
            ForEach(node.children) { child in rows(child, depth: depth + 1) }
        })
    }
}

private struct OutlineRow: View {
    @ObservedObject var model: StudioModel
    let node: DesignNode
    let depth: Int
    var body: some View {
        let selected = model.selection == node.id
        Button { model.selection = node.id } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).frame(width: 14).foregroundStyle(.secondary)
                Text(node.id == model.design.root.id ? "Sprite" : model.design.title(of: node))
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if node.style.hidden { Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            .padding(.leading, CGFloat(depth) * 12 + 6).padding(.vertical, 4).padding(.trailing, 6)
            .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(node.style.hidden ? 0.55 : 1)
        .onHover { model.highlighted = $0 ? node.id : (model.highlighted == node.id ? nil : model.highlighted) }
        .contextMenu { NodeActions(model: model).onAppear { model.selection = node.id } }
    }
    private var icon: String {
        switch node.kind {
        case .row: "rectangle.split.3x1"; case .column: "rectangle.split.1x2"; case .text: node.referencedVariables.isEmpty ? "textformat" : "number"
        case .icon: "star"; case .bar: "chart.bar.fill"; case .battery: "battery.75percent"
        }
    }
}

/// A setting's name above its control, so the inspector fits a narrow pane.
struct InspectorField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Inspector

/// Settings for the selected piece: its content first, then how it looks, then how it sits.
struct NodeInspector: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore

    var body: some View {
        if let node = model.selectedNode {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    TextField("Name", text: model.node(node.id, \.name, fallback: "", coalesce: true))
                        .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold))
                        .help("Rules pick their targets by this name")
                    Spacer()
                    Menu { NodeActions(model: model) } label: { Label("Arrange", systemImage: "square.split.2x1") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                content(node)
                appearance(node)
                if node.kind.isContainer { layout(node) }
                affectingRules(node)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .controlSize(.small)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing selected").font(.headline)
                Text("Click any part of the sprite above, or a piece in the list, to change it. Right-click a piece to split it into a row or a column, merge texts, wrap or unwrap.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Select the whole sprite") { model.selection = model.design.root.id }
            }
        }
    }

    @ViewBuilder private func content(_ node: DesignNode) -> some View {
        switch node.kind {
        case .text:
            StudioSection(title: "Text") { SegmentEditor(model: model, store: store, nodeID: node.id) }
        case .icon:
            StudioSection(title: "Symbol") {
                SymbolPicker(symbol: model.node(node.id, \.symbol, fallback: "star")).frame(height: 190)
            }
            StudioSection(title: "Fills with") {
                // A percentage fills the symbol's variable layers: wifi's bars, speaker.wave.3's waves.
                Picker("Value", selection: model.node(node.id, \.variable, fallback: nil)) {
                    Text("Nothing (drawn whole)").tag(String?.none)
                    ForEach(model.design.variables) { Text($0.name).tag(String?.some($0.id)) }
                }.labelsHidden()
                if node.variable != nil {
                    InspectorField("Full at") {
                        TextField("100", value: model.node(node.id, \.style.maximum, fallback: 100, coalesce: true), format: .number)
                            .frame(width: 70)
                    }
                    Text("Symbols with layers (wifi, speaker.wave.3, cellularbars) fill as many as the value earns.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .bar, .battery:
            StudioSection(title: node.kind == .bar ? "Fills with" : "Charge from") {
                Picker("Value", selection: model.node(node.id, \.variable, fallback: nil)) {
                    Text("Nothing").tag(String?.none)
                    ForEach(model.design.variables) { Text($0.name).tag(String?.some($0.id)) }
                }.labelsHidden()
                if node.kind == .bar {
                    InspectorField("Full at") {
                        TextField("100", value: model.node(node.id, \.style.maximum, fallback: 100, coalesce: true), format: .number)
                            .frame(width: 70)
                    }
                } else {
                    Toggle("Charge drawn inside the battery", isOn: model.node(node.id, \.style.chargeInside, fallback: true))
                }
            }
        case .row, .column:
            EmptyView()
        }
    }

    @ViewBuilder private func appearance(_ node: DesignNode) -> some View {
        StudioSection(title: "Look") {
            VStack(alignment: .leading, spacing: 10) {
                InspectorField("Colour") {
                    ColorChoice(value: model.node(node.id, \.style.color, fallback: "inherit"), allowInherit: node.id != model.design.root.id)
                }
                if node.kind == .text || node.kind == .icon || node.kind == .bar {
                    InspectorField(node.kind == .text ? "Size" : (node.kind == .bar ? "Width" : "Size")) {
                        HStack {
                            Slider(value: sizeBinding(node), in: node.kind == .bar ? 3...20 : 6...22, step: 0.5).frame(width: 150)
                            Text(String(format: "%.1f pt", node.style.size ?? 12)).monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                    }
                }
                if node.kind == .text {
                    InspectorField("Weight") {
                        Picker("Weight", selection: model.node(node.id, \.style.weight, fallback: .regular)) {
                            ForEach(DesignWeight.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 150)
                    }
                    Toggle("Fixed-width digits", isOn: model.node(node.id, \.style.tabular, fallback: true))
                    Toggle("Shrink to fit (small labels)", isOn: model.node(node.id, \.style.shrinkToFit, fallback: false))
                }
                if node.kind != .row && node.kind != .column || model.design.root.parent(of: node.id) != nil {
                    InspectorField("Align") {
                        Picker("Align", selection: model.node(node.id, \.style.align, fallback: .center)) {
                            Image(systemName: "text.alignleft").tag(DesignAlign.leading)
                            Image(systemName: "text.aligncenter").tag(DesignAlign.center)
                            Image(systemName: "text.alignright").tag(DesignAlign.trailing)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 120)
                    }
                }
                InspectorField("Opacity") {
                    Slider(value: model.node(node.id, \.style.opacity, fallback: 1, coalesce: true), in: 0.1...1).frame(width: 150)
                }
                if node.id != model.design.root.id {
                    Toggle("Hidden (rules can show it)", isOn: model.node(node.id, \.style.hidden, fallback: false))
                }
            }
        }
    }
    private func sizeBinding(_ node: DesignNode) -> Binding<Double> {
        let fallback: Double = node.kind == .icon ? 14 : (node.kind == .bar ? 9 : 12)
        return Binding(get: { model.design.node(node.id)?.style.size ?? fallback },
                       set: { value in model.edit(coalesce: true) { $0.root.update(node.id) { $0.style.size = value } } })
    }

    @ViewBuilder private func layout(_ node: DesignNode) -> some View {
        StudioSection(title: node.kind == .row ? "Row" : "Column") {
            VStack(alignment: .leading, spacing: 10) {
                InspectorField("Direction") {
                    Picker("Direction", selection: Binding(get: { node.kind }, set: { kind in if kind != node.kind { model.edit { $0.flip(node.id) } } })) {
                        Text("Side by side").tag(DesignNodeKind.row)
                        Text("Stacked").tag(DesignNodeKind.column)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
                InspectorField("Gap") {
                    HStack {
                        Slider(value: model.node(node.id, \.style.gap, fallback: 4, coalesce: true), in: 0...16, step: 0.5).frame(width: 150)
                        Text(String(format: "%.1f pt", node.style.gap)).monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                }
                InspectorField("Spread") {
                    Picker("Spread", selection: model.node(node.id, \.style.justify, fallback: .center)) {
                        ForEach(DesignJustify.allCases.filter { node.kind == .column || $0 != .even }, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 150)
                }
                InspectorField("Side padding") {
                    Slider(value: model.node(node.id, \.style.padding, fallback: 0, coalesce: true), in: 0...12, step: 0.5).frame(width: 150)
                }
            }
        }
    }

    @ViewBuilder private func affectingRules(_ node: DesignNode) -> some View {
        let rules = model.design.rules.filter { rule in (rule.branches.flatMap(\.actions) + rule.otherwise).contains { $0.target == node.id } }
        if !rules.isEmpty {
            StudioSection(title: "Changed by rules") {
                ForEach(rules) { rule in
                    Label(rule.name.isEmpty ? "Untitled rule" : rule.name, systemImage: rule.enabled ? "wand.and.stars" : "pause.circle")
                        .font(.callout).foregroundStyle(rule.enabled ? .primary : .secondary)
                }
            }
        }
    }
}

// MARK: - Text content

/// A text's content as chips: typed text and values, in order. Values show their live reading.
struct SegmentEditor: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: MonitoringStore
    let nodeID: String
    @State private var editingTemplate = false

    private var segments: [TextSegment] { model.design.node(nodeID)?.segments ?? [] }
    private func setSegments(_ value: [TextSegment], coalesce: Bool = false) {
        model.edit(coalesce: coalesce) { $0.root.update(nodeID) { $0.segments = value } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in chip(index, segment) }
                Menu {
                    Button("Typed text") { setSegments(segments + [.literal(" ")]) }
                    if !model.design.variables.isEmpty {
                        Section("Values") {
                            ForEach(model.design.variables) { variable in
                                Button(variable.name) { setSegments(segments + [.value(variable.id)]) }
                            }
                        }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Add typed text or a value")
            }
            DisclosureGroup("Edit as one line", isExpanded: $editingTemplate) {
                TextField("{value}%", text: Binding(get: { TextTemplate.string(segments) },
                                                     set: { setSegments(TextTemplate.parse($0), coalesce: true) }))
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Text("Values are written in braces by their key: " + model.design.variables.map { "{\($0.id)}" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
        }
    }

    @ViewBuilder private func chip(_ index: Int, _ segment: TextSegment) -> some View {
        switch segment {
        case .literal(let text):
            HStack(spacing: 2) {
                TextField("text", text: Binding(get: { text }, set: { value in
                    var next = segments; guard next.indices.contains(index) else { return }
                    next[index] = .literal(value); setSegments(next, coalesce: true)
                }))
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                .frame(minWidth: 18, idealWidth: CGFloat(max(2, text.count)) * 8.5 + 6).fixedSize()
                remove(index)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        case .value(let id):
            let variable = model.design.variable(id)
            let live = variable.map { store.designValues(model.design).formatted($0) } ?? "missing"
            Menu {
                ForEach(model.design.variables) { other in
                    Button(other.name) { var next = segments; next[index] = .value(other.id); setSegments(next) }
                }
                Divider()
                Button("Move left") { var next = segments; if index > 0 { next.swapAt(index, index - 1); setSegments(next) } }
                Button("Move right") { var next = segments; if index < next.count - 1 { next.swapAt(index, index + 1); setSegments(next) } }
                Button("Remove", role: .destructive) { var next = segments; next.remove(at: index); setSegments(next) }
            } label: {
                HStack(spacing: 5) {
                    Text(variable?.name ?? id).font(.system(size: 12, weight: .semibold))
                    Text(live).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.2), in: Capsule())
            .help("A live value · click to swap, move or remove it")
        }
    }
    private func remove(_ index: Int) -> some View {
        Button { var next = segments; if next.indices.contains(index) { next.remove(at: index); setSegments(next) } } label: {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
        }.buttonStyle(.plain)
    }
}
