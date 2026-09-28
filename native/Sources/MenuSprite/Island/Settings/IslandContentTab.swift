import IslandKit
import SwiftUI

/// Content: the sections list (show, hide, reorder), the selected section's options, and a live preview
/// of its page, beside the options in a wide window and above them in a narrow one.
struct IslandContentTab: View {
    @ObservedObject var model: IslandSettingsModel
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var settings: IslandSettingsStore
    let width: CGFloat

    var body: some View {
        let layout = IslandContentEditorLayout(pageWidth: width)
        HStack(alignment: .top, spacing: IslandContentEditorLayout.spacing) {
            IslandSectionsList(model: model, environment: environment, settings: settings)
                .frame(width: layout.listWidth)
                .frame(maxHeight: .infinity, alignment: .top)
            switch layout.preview {
            case .column(let previewWidth):
                IslandSectionOptions(section: model.selection, environment: environment) { EmptyView() }
                    .frame(width: layout.optionsWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                IslandSectionPreviewPanel(section: model.selection, environment: environment, settings: settings,
                                          width: previewWidth, maxHeight: nil)
            case .above(let maxHeight):
                // Stacked, the preview scrolls away with the options so a short window still shows them.
                IslandSectionOptions(section: model.selection, environment: environment) {
                    IslandSectionPreviewPanel(section: model.selection, environment: environment, settings: settings,
                                              width: layout.optionsWidth, maxHeight: maxHeight)
                }
                .frame(width: layout.optionsWidth)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

/// Every section in island order: a checkbox to show or hide it, its tile and name. Click selects,
/// drag reorders.
private struct IslandSectionsList: View {
    @ObservedObject var model: IslandSettingsModel
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var settings: IslandSettingsStore
    @State private var dragging: IslandSectionID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sections").font(.system(size: 15, weight: .semibold))
            Text("Drag to change the order. Untick a section to leave it out of the island.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(settings.value.orderedSections) { row($0).id($0) }
                    }
                }
                .onChange(of: model.scrollRequest) { proxy.scrollTo(model.selection, anchor: .center) }
                .onAppear { proxy.scrollTo(model.selection, anchor: .center) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IslandSettingsStyle.cardFill))
        // A drag released between rows still ends the drag.
        .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return true }
    }

    private func row(_ section: IslandSectionID) -> some View {
        let available = environment.availability(of: section).isAvailable
        let visible = available && settings.value.isVisible(section)
        let selected = model.selection == section
        return HStack(spacing: 9) {
            Toggle(section.title, isOn: Binding(get: { visible }, set: { value in settings.update { $0.setVisible(section, value) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!available)
            IslandSectionTile(section: section, dimmed: !visible)
            Text(section.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(available ? Color.primary : Color.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            dragging = nil
            model.selection = section
        }
        .opacity(dragging == section ? 0.45 : 1)
        .onDrag {
            dragging = section
            return NSItemProvider(object: section.rawValue as NSString)
        }
        .onDrop(of: [.text], delegate: SectionReorder(target: section, dragging: $dragging, settings: settings))
        .help(section.summary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { model.selection = section }
        .accessibilityAction(named: "Move up") { move(section, by: -1) }
        .accessibilityAction(named: "Move down") { move(section, by: 1) }
    }

    private func move(_ section: IslandSectionID, by offset: Int) {
        settings.update { $0.sectionOrder = IslandSectionOrder.shift(section, by: offset, in: $0.orderedSections) }
    }
}

private struct SectionReorder: DropDelegate {
    let target: IslandSectionID
    @Binding var dragging: IslandSectionID?
    let settings: IslandSettingsStore

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        MainActor.assumeIsolated {
            settings.update { $0.sectionOrder = IslandSectionOrder.move(dragging, onto: target, in: $0.orderedSections) }
        }
    }

    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) {}
}

/// The selected section's header (tile, title, summary, why it is unavailable) and its options card,
/// under an optional leading view (the preview, in a narrow window).
private struct IslandSectionOptions<Leading: View>: View {
    let section: IslandSectionID
    @ObservedObject var environment: IslandEnvironment
    @ViewBuilder var leading: Leading

    var body: some View {
        let availability = environment.availability(of: section)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                leading
                HStack(alignment: .top, spacing: 12) {
                    IslandSectionTile(section: section, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title).font(.system(size: 17, weight: .semibold))
                        Text(section.summary).font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let reason = availability.reason {
                            HStack(spacing: 10) {
                                Text(reason).font(.system(size: 12)).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let fix = availability.fix {
                                    Button(availability.fixTitle ?? "Set Up…") { fix() }.controlSize(.small)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                if let options = environment.sections[section]?.options() {
                    options
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IslandSettingsStyle.cardFill))
                } else {
                    Text("This section has no options.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The selected page as the island draws it, hanging under a strip standing in for the menu bar. One
/// scale for every section (from the tallest page), so switching sections never moves the layout.
private struct IslandSectionPreviewPanel: View {
    let section: IslandSectionID
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var settings: IslandSettingsStore
    let width: CGFloat
    let maxHeight: CGFloat?

    private static let padding: CGFloat = 12

    var body: some View {
        let tallest = IslandSettingsPreview.tallest(environment: environment)
        let inner = width - 2 * Self.padding
        let scale = IslandContentEditorLayout.previewScale(islandWidth: tallest.width, tallestHeight: tallest.height,
                                                           availableWidth: inner, maxHeight: maxHeight)
        let size = IslandSettingsPreview.layout(section, environment: environment).0
        let pageSize = CGSize(width: size.width, height: size.height)
        let shown = environment.availability(of: section).isAvailable && settings.value.isVisible(section)
        let bar = IslandSettingsPreview.display.barHeight * scale
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .top) {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: bar)
                IslandScaled(size: pageSize, scale: scale) {
                    IslandPreviewIsland(section: section, environment: environment, outline: settings.value.outline)
                }
                .opacity(shown ? 1 : 0.4)
            }
            .frame(width: inner, height: tallest.height * scale, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Label(shown ? "Preview" : "Hidden from the island", systemImage: shown ? "eye" : "eye.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(Self.padding)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IslandSettingsStyle.cardFill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown ? "Preview of \(section.title)" : "\(section.title) is hidden from the island")
    }
}
