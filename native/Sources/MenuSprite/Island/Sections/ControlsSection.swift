import IslandKit
import SwiftUI

/// Home page: the playback card, volume and brightness levels, and a rail of shortcut tiles. It owns
/// no data of its own; every card and tile comes from the feature that provides it.
@MainActor
final class ControlsSection: IslandSection {
    let id = IslandSectionID.controls
    private unowned let environment: IslandEnvironment

    init(environment: IslandEnvironment) { self.environment = environment }

    var availability: IslandAvailability { .available }

    func pageHeight(_ context: IslandPageContext) -> IslandPageHeight {
        .fixed(ControlsLayout(environment: environment, width: context.width, budget: context.budget).height)
    }

    func page(_ context: IslandPageContext) -> AnyView {
        AnyView(ControlsPage(environment: environment, context: context))
    }

    func options() -> AnyView? { AnyView(ControlsOptions(environment: environment)) }
}

/// The Controls page's arithmetic, shared by the page, its height and the settings preview.
@MainActor
struct ControlsLayout {
    static let tileStride: CGFloat = IslandStyle.tileMinWidth + IslandStyle.tileSpacing

    var cards: [IslandCardID]
    var levels: [IslandCardID]
    var showsPlayback: Bool
    var tiles: [IslandControlID]
    var columns: Int
    var rows: Int
    var cardHeight: CGFloat
    var height: CGFloat

    init(environment: IslandEnvironment, width: CGFloat, budget: CGFloat) {
        let settings = environment.settings
        cards = IslandCardID.allCases.filter { card in
            !settings.hiddenCards.contains(card) && (environment.cards[card]?.availability().isAvailable ?? false)
        }
        showsPlayback = cards.contains(.nowPlaying)
        levels = cards.filter { $0 != .nowPlaying }
        tiles = settings.orderedControls.filter { !settings.hiddenControls.contains($0) && environment.availability(of: $0).isAvailable }
        columns = max(1, Int((width + IslandStyle.tileSpacing) / Self.tileStride))
        let rowHeight = IslandStyle.tileHeight + IslandStyle.tileSpacing
        let hasCards = !cards.isEmpty
        let cardBlock: CGFloat = hasCards ? 68 + IslandStyle.rowSpacing : 0
        let neededRows = tiles.isEmpty ? 0 : Int(ceil(Double(tiles.count) / Double(columns)))
        let fittingRows = max(tiles.isEmpty ? 0 : 1, Int((budget - cardBlock + IslandStyle.tileSpacing) / rowHeight))
        rows = min(neededRows, fittingRows)
        let rail = rows > 0 ? CGFloat(rows) * IslandStyle.tileHeight + CGFloat(rows - 1) * IslandStyle.tileSpacing : 0
        if hasCards {
            cardHeight = min(96, max(68, budget - rail - (rows > 0 ? IslandStyle.rowSpacing : 0)))
        } else {
            cardHeight = 0
        }
        if !hasCards && tiles.isEmpty {
            height = min(budget, 140)
        } else {
            height = min(budget, cardHeight + (hasCards && rows > 0 ? IslandStyle.rowSpacing : 0) + rail)
        }
    }

    /// Whether every tile fits in the visible rows; otherwise the rail scrolls sideways.
    var railFits: Bool { tiles.count <= rows * columns }
}

private struct ControlsPage: View {
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var settings: IslandSettingsStore
    let context: IslandPageContext

    init(environment: IslandEnvironment, context: IslandPageContext) {
        self.environment = environment
        self.settings = environment.settingsStore
        self.context = context
    }

    var body: some View {
        let layout = ControlsLayout(environment: environment, width: context.width, budget: context.budget)
        VStack(alignment: .leading, spacing: IslandStyle.rowSpacing) {
            if !layout.cards.isEmpty { cardRow(layout) }
            if layout.rows > 0 { rail(layout) }
            if layout.cards.isEmpty && layout.tiles.isEmpty {
                IslandUnavailableView(symbol: "slider.horizontal.3", message: "Choose what appears in Dynamic Island settings.")
            }
        }
        .frame(width: context.width, height: layout.height, alignment: .top)
    }

    @ViewBuilder private func cardRow(_ layout: ControlsLayout) -> some View {
        let height = layout.cardHeight
        HStack(spacing: IslandStyle.rowSpacing) {
            if layout.showsPlayback, let provider = environment.cards[.nowPlaying] {
                IslandCard(padding: 0) { provider.view(.card(height: height), context) }
                    .frame(minWidth: 0, maxWidth: .infinity)
            }
            if layout.showsPlayback {
                if layout.levels.count >= 2 {
                    IslandCard(padding: 0) {
                        VStack(spacing: 6) {
                            ForEach(layout.levels) { level in
                                environment.cards[level].map { $0.view(.row, context) }
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(maxHeight: .infinity)
                    }
                    .frame(width: 160)
                } else if let level = layout.levels.first, let provider = environment.cards[level] {
                    IslandCard(padding: 0) { provider.view(.card(height: height), context) }
                        .frame(width: 160)
                }
            } else {
                ForEach(layout.levels) { level in
                    environment.cards[level].map { provider in
                        IslandCard(padding: 0) { provider.view(.card(height: height), context) }
                            .frame(minWidth: 0, maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(height: height)
    }

    @ViewBuilder private func rail(_ layout: ControlsLayout) -> some View {
        let tiles = layout.tiles.compactMap { environment.controls[$0] }
        if layout.railFits {
            // Tiles share the width equally in reading order; a short last row is centred.
            VStack(spacing: IslandStyle.tileSpacing) {
                ForEach(0..<layout.rows, id: \.self) { row in
                    let slice = Array(tiles.dropFirst(row * layout.columns).prefix(layout.columns))
                    HStack(spacing: IslandStyle.tileSpacing) {
                        ForEach(slice) { tile in ControlTile(model: tile) }
                    }
                    .frame(maxWidth: row == layout.rows - 1 && slice.count < layout.columns && layout.rows > 1
                           ? CGFloat(slice.count) * ControlsLayout.tileStride - IslandStyle.tileSpacing : .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(IslandStyle.tileHeight), spacing: IslandStyle.tileSpacing), count: layout.rows),
                          spacing: IslandStyle.tileSpacing) {
                    ForEach(tiles) { tile in ControlTile(model: tile).frame(width: IslandStyle.tileMinWidth) }
                }
            }
        }
    }
}

/// A Controls tile bound to its model, with the on-state accent the tile kind calls for.
struct ControlTile: View {
    @ObservedObject var model: IslandControlModel
    var body: some View {
        let red = model.id == .microphone || model.id == .recording
        IslandTileView(title: model.title, symbol: model.symbol, isOn: model.isOn,
                       onFill: red ? .red : .yellow, onGlyph: red ? .white : .black,
                       enabled: model.availability.isAvailable) { model.perform() }
    }
}

/// Settings › Content › Controls: the three cards, then a reorderable grid of tile toggles.
private struct ControlsOptions: View {
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var settings: IslandSettingsStore
    @State private var dragging: IslandControlID?

    init(environment: IslandEnvironment) {
        self.environment = environment
        self.settings = environment.settingsStore
    }

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(IslandCardID.allCases) { card in
                    let availability = environment.cards[card]?.availability() ?? .notBuilt
                    IslandOptionCard(title: card.title, symbol: card.symbol,
                                     included: !settings.value.hiddenCards.contains(card), availability: availability) {
                        settings.update { value in
                            if value.hiddenCards.contains(card) { value.hiddenCards.remove(card) } else { value.hiddenCards.insert(card) }
                        }
                    }
                }
            }
            // Brightness needs MenuSprite to control displays (private DisplayServices, DDC for monitors).
            IslandDisplayOptionsView()
            Text("Controls and shortcuts").font(.headline)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(settings.value.orderedControls) { control in
                    let availability = environment.availability(of: control)
                    IslandOptionCard(title: control.title, symbol: control.symbol,
                                     included: !settings.value.hiddenControls.contains(control), availability: availability) {
                        settings.update { $0.setVisible(control, $0.hiddenControls.contains(control)) }
                    }
                    .opacity(dragging == control ? 0.45 : 1)
                    .onDrag {
                        dragging = control
                        return NSItemProvider(object: control.rawValue as NSString)
                    }
                    .onDrop(of: [.text], delegate: ControlReorder(target: control, dragging: $dragging, settings: settings))
                }
            }
        }
    }
}

private struct ControlReorder: DropDelegate {
    let target: IslandControlID
    @Binding var dragging: IslandControlID?
    let settings: IslandSettingsStore

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        MainActor.assumeIsolated {
            settings.update { value in
                var order = value.orderedControls
                guard let from = order.firstIndex(of: dragging), let to = order.firstIndex(of: target) else { return }
                order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                value.controlOrder = order
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

/// A toggle card used across the island's settings: symbol, title, a corner badge (included, can be
/// added, needs setup, unavailable) and a reason line when unavailable.
struct IslandOptionCard: View {
    let title: String
    let symbol: String
    let included: Bool
    let availability: IslandAvailability
    let toggle: () -> Void
    /// Cards in one grid share a height, so a reason line in one card does not leave the rest uneven.
    var minHeight: CGFloat = 76

    var body: some View {
        let available = availability.isAvailable
        Button {
            if available { toggle() } else { availability.fix?() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(available && included ? Color.accentColor : .secondary)
                    .frame(height: 24)
                Text(title).font(.system(size: 11, weight: .medium)).multilineTextAlignment(.center).lineLimit(2)
                    .frame(minHeight: 28, alignment: .top)
                if let reason = availability.reason {
                    Text(reason).font(.caption2).lineLimit(3).multilineTextAlignment(.center)
                        .foregroundStyle(availability.fix == nil ? Color.secondary : Color.accentColor)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(alignment: .topTrailing) {
                Image(systemName: badge)
                    .font(.system(size: 13))
                    .foregroundStyle(available && included ? Color.accentColor : .secondary)
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
    }

    private var badge: String {
        if availability.isAvailable { return included ? "checkmark.circle.fill" : "plus.circle" }
        return availability.fix == nil ? "minus.circle" : "arrow.up.right.circle"
    }
}
