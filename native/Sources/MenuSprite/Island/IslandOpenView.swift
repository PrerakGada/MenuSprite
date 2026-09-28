import AppKit
import IslandKit
import SwiftUI

/// The open island: a header row (split beside a physical camera when wide enough) and one page —
/// a section, the Explore gallery or the app panel.
struct IslandOpenView: View {
    @ObservedObject var presentation: IslandPresentation
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var notices: IslandNoticeCenter
    let commands: IslandCommands

    var body: some View {
        if let layout = presentation.openLayout, let context = presentation.pageContext {
            ZStack(alignment: .topLeading) {
                header(layout)
                    .frame(width: layout.width, height: layout.headerHeight)
                    .offset(y: layout.headerTop)
                page(context)
                    .frame(width: layout.contentWidth, height: layout.pageHeight, alignment: .top)
                    .clipped()
                    .offset(x: IslandGeometry.horizontalInset, y: layout.contentTop)
            }
            .frame(width: layout.width, height: layout.height, alignment: .topLeading)
            .foregroundStyle(.white)
        }
    }

    // MARK: Header

    @ViewBuilder private func header(_ layout: IslandOpenLayout) -> some View {
        let inset = IslandGeometry.horizontalInset
        HStack(spacing: 0) {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            if layout.headerBesideCamera {
                Color.clear.frame(width: presentation.camera.width + 16)
            }
            trailing.frame(maxWidth: layout.headerBesideCamera ? .infinity : nil, alignment: .trailing)
        }
        .padding(.horizontal, inset)
        .contentShape(Rectangle())
        .onHover { commands.headerHover($0) }
    }

    @ViewBuilder private var leading: some View {
        if let notice = notices.current, notice.kind.isLevel, case .level(let symbol, let value) = notice.style {
            // A volume or brightness change while open takes over the title row; the page stays usable.
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 18)
                IslandMeter(value: value).frame(maxWidth: 96)
                Text("\(Int((value * 100).rounded()))%").font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 8) {
                if presentation.destination == .explore || presentation.destination == .appPanel {
                    Button { commands.open(.section(environment.visibleSections.first ?? .controls)) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26)
                    }
                    .buttonStyle(IslandButtonStyle(cornerRadius: 8))
                    .accessibilityLabel("Back")
                } else if !environment.liveFloating.buttons.contains(where: { $0.action == .explore }) {
                    Button { commands.open(.explore) } label: {
                        Image(systemName: "square.grid.2x2").font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26)
                    }
                    .buttonStyle(IslandButtonStyle(cornerRadius: 8))
                    .accessibilityLabel("Explore")
                }
                Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1).fixedSize()
                if presentation.destination == .explore {
                    ExploreSearchField(query: $presentation.exploreQuery)
                }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 6) {
            if let accessory = sectionAccessory { accessory }
            Menu {
                Button(environment.isPinned ? "Allow automatic closing" : "Keep open") { commands.togglePin() }
                Button("Settings…") { commands.openSettings() }
                Divider()
                Button("Collapse") { commands.close() }
            } label: {
                Image(systemName: environment.isPinned ? "pin.fill" : "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(presentation.headerHover || environment.isPinned ? 0.9 : 0.35))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }

    private var title: String {
        switch presentation.destination {
        case .section(let id): id.headerTitle
        case .explore: "Explore"
        case .appPanel: "MenuSprite"
        }
    }

    private var sectionAccessory: AnyView? {
        guard case .section(let id) = presentation.destination, let context = presentation.pageContext else { return nil }
        return environment.sections[id]?.headerAccessory(context)
    }

    // MARK: Page

    @ViewBuilder private func page(_ context: IslandPageContext) -> some View {
        switch presentation.destination {
        case .section(let id):
            if let section = environment.sections[id] {
                section.page(context).id(id)
            }
        case .explore:
            ExploreGallery(presentation: presentation, environment: environment, commands: commands, width: context.width)
        case .appPanel:
            IslandAppPanelPage(environment: environment)
        }
    }
}

/// The gallery of every visible section, searchable.
struct ExploreGallery: View {
    @ObservedObject var presentation: IslandPresentation
    @ObservedObject var environment: IslandEnvironment
    let commands: IslandCommands
    let width: CGFloat

    var body: some View {
        let sections = IslandNavigation.search(presentation.exploreQuery, in: environment.visibleSections)
        let paging = IslandExplorePaging(count: sections.count, contentWidth: width, height: 320)
        let columns = Array(repeating: GridItem(.flexible(minimum: IslandExplorePaging.tileWidth), spacing: IslandExplorePaging.spacing),
                            count: paging.columns)
        if sections.isEmpty {
            IslandUnavailableView(symbol: "magnifyingglass", message: "No section matches “\(presentation.exploreQuery)”.")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: IslandExplorePaging.spacing) {
                    ForEach(sections) { section in
                        Button { commands.open(.section(section)) } label: {
                            VStack(spacing: 6) {
                                Image(systemName: section.symbol)
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(section == .music ? Color.pink : section == .calendar ? .red : section == .timer ? .orange : .white.opacity(0.85))
                                Text(section.title).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                                Text("⌥⌘\(String(section.shortcut).uppercased())").font(.system(size: 9, weight: .medium)).foregroundStyle(IslandStyle.tertiaryText)
                            }
                            .frame(maxWidth: .infinity, minHeight: IslandExplorePaging.tileHeight)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IslandStyle.surface))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(presentation.exploreHighlight == section ? Color.white.opacity(0.8) : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(IslandButtonStyle())
                        .accessibilityLabel(section.title)
                    }
                }
            }
        }
    }
}

struct ExploreSearchField: View {
    @Binding var query: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(IslandStyle.secondaryText)
            TextField("Find a section", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(maxWidth: 160)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

/// MenuSprite's own hub, embedded as a page when "Open app panel" is set to the island.
struct IslandAppPanelPage: View {
    @ObservedObject var environment: IslandEnvironment
    var body: some View {
        if let hub = environment.appPanel {
            hub()
        } else {
            IslandUnavailableView(symbol: "macwindow", message: "The app panel is not available.")
        }
    }
}

/// The round buttons beside the open island.
struct IslandFloatingView: View {
    @ObservedObject var presentation: IslandPresentation
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var settings: IslandSettingsStore
    let commands: IslandCommands

    var body: some View {
        let layout = environment.liveFloating
        let open = presentation.surface == .open
        let placement = presentation.openLayout.map {
            IslandFloatingPlacement.make(layout: layout, island: presentation.size, headerTop: $0.headerTop,
                                         headerHeight: $0.headerHeight, barHeight: presentation.display?.barHeight ?? 32)
        }
        ZStack(alignment: .topLeading) {
            Color.clear
            if open, let placement {
                ForEach(layout.buttons) { button in
                    if let slot = placement.slots.first(where: { $0.id == button.id }) {
                        FloatingButton(button: button, isOn: isOn(button.action)) { commands.floating(button.action) }
                            .position(x: presentation.origin.x + slot.center.x, y: slot.center.y)
                            .scaleEffect(presentation.floatingVisible ? 1 : 0.4)
                            .opacity(presentation.floatingVisible ? 1 : 0)
                            .animation(presentation.floatingVisible ? .spring(duration: 0.38, bounce: 0.12) : .easeIn(duration: 0.16),
                                       value: presentation.floatingVisible)
                            .allowsHitTesting(presentation.floatingVisible)
                    }
                }
            }
        }
        .frame(width: presentation.stage.width, height: presentation.stage.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private func isOn(_ action: IslandFloatingAction) -> Bool {
        switch action {
        case .pin: environment.isPinned
        case .section(let id): presentation.destination == .section(id)
        case .explore: presentation.destination == .explore
        case .control(let id): environment.controls[id]?.isOn ?? false
        case .settings: false
        }
    }
}

private struct FloatingButton: View {
    let button: IslandFloatingButton
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.black)
                Circle().strokeBorder(Color.white.opacity(isOn ? 0.55 : (hovering ? 0.3 : 0.16)), lineWidth: 1)
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
            }
            .frame(width: IslandGeometry.floatingDiameter, height: IslandGeometry.floatingDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(button.displayTitle)
        .accessibilityLabel(button.displayTitle)
    }

    private var symbol: String {
        if button.action == .pin, isOn { return "pin.fill" }
        return button.action.symbol
    }
}
