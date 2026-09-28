import IslandKit
import SwiftUI

/// The Layout tab's canvas: a live Controls page at half size with the floating buttons around it.
/// "+" adds a button, a click edits one, a drag moves it between sides, and the corner grip resizes the
/// island (switching Size to Custom). Every change is saved at once, so the live island follows.
struct IslandLayoutCanvasView: View {
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var settings: IslandSettingsStore
    let width: CGFloat
    /// A click on the preview: open the Content tab on Controls.
    let openContent: () -> Void

    @State private var editing: UUID?
    @State private var adding: IslandFloatingSide?
    @State private var drag: Drag?
    @State private var resize: Resize?

    private static let space = "island-layout-canvas"

    private struct Drag: Equatable {
        var id: UUID
        var point: CGPoint
    }

    private struct Resize: Equatable {
        var start: CGSize
        var scale: CGFloat
    }

    var body: some View {
        let layout = IslandSettingsPreview.layout(.controls, environment: environment).0
        let islandSize = CGSize(width: layout.width, height: layout.height)
        let canvas = IslandLayoutCanvas(canvasWidth: width, islandSize: islandSize)
        let floating = settings.value.floating
        let centers = canvas.centers(floating)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(IslandSettingsStyle.cardFill)
            if let drag { zones(canvas, floating: floating, drag: drag) }
            preview(canvas, size: islandSize)
            if drag == nil {
                ForEach(IslandFloatingSide.allCases, id: \.self) { side in
                    if let point = canvas.addSlot(side, in: floating) { addButton(side).position(point) }
                }
            }
            ForEach(floating.buttons) { button in
                circle(button, canvas: canvas)
                    .position(drag.flatMap { $0.id == button.id ? $0.point : nil } ?? centers[button.id] ?? .zero)
            }
            grip(canvas)
        }
        .frame(width: width, height: IslandLayoutCanvas.height)
        .coordinateSpace(name: Self.space)
        .animation(.easeInOut(duration: 0.2), value: floating)
        .animation(resize == nil ? .easeInOut(duration: 0.2) : nil, value: islandSize)
    }

    // MARK: Island

    private func preview(_ canvas: IslandLayoutCanvas, size: CGSize) -> some View {
        IslandScaled(size: size, scale: canvas.scale) {
            IslandPreviewIsland(section: .controls, environment: environment, outline: settings.value.outline)
        }
        .overlay {
            Rectangle().fill(Color.clear).contentShape(Rectangle()).onTapGesture(perform: openContent)
        }
        .accessibilityElement()
        .accessibilityLabel("Controls page preview")
        .accessibilityHint("Shows the Controls options on the Content tab")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openContent() }
        .help("Choose what the Controls page shows")
        .position(x: canvas.island.midX, y: canvas.island.midY)
    }

    // MARK: Buttons

    private func circle(_ button: IslandFloatingButton, canvas: IslandLayoutCanvas) -> some View {
        IslandEditorCircle(symbol: button.action.symbol, highlighted: editing == button.id || drag?.id == button.id,
                           dimmed: !IslandActionAvailability.of(button.action, in: environment).isAvailable)
            .help(button.displayTitle)
            .onTapGesture { editing = button.id }
            .gesture(DragGesture(minimumDistance: IslandLayoutCanvas.dragThreshold, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    editing = nil
                    drag = Drag(id: button.id, point: value.location)
                }
                .onEnded { value in
                    var layout = settings.value.floating
                    if canvas.drop(button.id, at: value.location, in: &layout) { settings.update { $0.floating = layout } }
                    drag = nil
                })
            .popover(isPresented: binding(for: button.id), arrowEdge: Self.edge(button.side)) {
                IslandEditButtonPopover(buttonID: button.id, environment: environment, settings: settings) { editing = nil }
            }
            .accessibilityElement()
            .accessibilityLabel(button.displayTitle)
            .accessibilityHint("Edits this floating button")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { editing = button.id }
    }

    private func addButton(_ side: IslandFloatingSide) -> some View {
        Button { adding = side } label: { IslandAddCircle() }
            .buttonStyle(.plain)
            .help("Add a button")
            .accessibilityLabel(side == .bottom ? "Add a button below the island" : "Add a button on the \(side.rawValue)")
            .popover(isPresented: Binding(get: { adding == side }, set: { if !$0 { adding = nil } }), arrowEdge: Self.edge(side)) {
                IslandAddButtonPopover(environment: environment) { action in
                    settings.update { _ = $0.floating.append(IslandFloatingButton(action: action, side: side)) }
                    adding = nil
                }
            }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { editing == id }, set: { if !$0, editing == id { editing = nil } })
    }

    private static func edge(_ side: IslandFloatingSide) -> Edge {
        switch side {
        case .left: .leading
        case .right: .trailing
        case .bottom: .bottom
        }
    }

    // MARK: Dragging

    private func zones(_ canvas: IslandLayoutCanvas, floating: IslandFloatingLayout, drag: Drag) -> some View {
        let hovered = canvas.zone(at: drag.point)
        return ForEach(IslandFloatingSide.allCases, id: \.self) { side in
            let rect = canvas.zone(side)
            let accepts = canvas.accepts(side, dragging: drag.id, in: floating)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(hovered == side && accepts ? 0.18 : 0.04))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(accepts ? 0.9 : 0.3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private func grip(_ canvas: IslandLayoutCanvas) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: IslandLayoutCanvas.gripDiameter, height: IslandLayoutCanvas.gripDiameter)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    let start = resize ?? Resize(start: CGSize(width: canvas.islandSize.width,
                                                               height: IslandSettingsPreview.maximumHeight(environment: environment)),
                                                 scale: canvas.scale)
                    resize = start
                    let size = IslandLayoutCanvas.resize(from: start.start, translation: value.translation, scale: start.scale)
                    settings.update {
                        $0.size = .custom
                        $0.customWidth = size.width
                        $0.customHeight = size.height
                    }
                }
                .onEnded { _ in resize = nil })
            .help("Drag to resize the island")
            .accessibilityLabel("Resize the island")
            .position(canvas.gripCenter)
    }
}

/// A floating button as the editor draws it: a small black circle with its symbol.
struct IslandEditorCircle: View {
    let symbol: String
    var highlighted = false
    var dimmed = false

    var body: some View {
        ZStack {
            Circle().fill(Color.black)
            Circle().strokeBorder(highlighted ? Color.accentColor : Color.white.opacity(0.22), lineWidth: 1.5)
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        }
        .frame(width: IslandLayoutCanvas.buttonDiameter, height: IslandLayoutCanvas.buttonDiameter)
        .opacity(dimmed ? 0.45 : 1)
        .contentShape(Circle())
    }
}

/// The dashed "+" in a side's next free slot.
struct IslandAddCircle: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
        }
        .frame(width: IslandLayoutCanvas.buttonDiameter, height: IslandLayoutCanvas.buttonDiameter)
        .contentShape(Circle())
    }
}
