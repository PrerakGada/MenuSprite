import AppKit
import IslandKit
import SwiftUI

/// Whether a floating button's action can run on this Mac. Explore, Settings and Keep open always can;
/// a section or tile follows its owner's availability.
@MainActor
enum IslandActionAvailability {
    static func of(_ action: IslandFloatingAction, in environment: IslandEnvironment) -> IslandAvailability {
        switch action {
        case .explore, .settings, .pin: .available
        case .section(let id): environment.availability(of: id)
        case .control(let id): environment.availability(of: id)
        }
    }
}

/// "Add button": a search field, then every action in two groups. Unavailable actions are listed but
/// cannot be chosen.
struct IslandAddButtonPopover: View {
    @ObservedObject var environment: IslandEnvironment
    let add: (IslandFloatingAction) -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add button").font(.headline)
            TextField("Find an action", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
            IslandActionGrid(environment: environment, query: query, choose: add)
        }
        .padding(16)
        .frame(width: 330)
        .onAppear { searching = true }
    }
}

/// "Edit button": name, side, order within the side, the action, and removal.
struct IslandEditButtonPopover: View {
    let buttonID: UUID
    @ObservedObject var environment: IslandEnvironment
    @ObservedObject var settings: IslandSettingsStore
    let dismiss: () -> Void
    @State private var name: String?
    @State private var query = ""

    var body: some View {
        if let button = settings.value.floating.buttons.first(where: { $0.id == buttonID }) {
            form(button)
        }
    }

    private func form(_ button: IslandFloatingButton) -> some View {
        let layout = settings.value.floating
        let siblings = layout.buttons(on: button.side)
        let position = siblings.firstIndex(of: button) ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            Text("Edit button").font(.headline)
            field("Name") {
                TextField(button.action.title, text: nameBinding(button)).textFieldStyle(.roundedBorder)
            }
            field("Position") {
                IslandSegments(titles: IslandFloatingSide.allCases.map(\.title),
                               selected: IslandFloatingSide.allCases.firstIndex(of: button.side) ?? 0,
                               enabled: IslandFloatingSide.allCases.map { $0 == button.side || !layout.isFull($0) }) { index in
                    let side = IslandFloatingSide.allCases[index]
                    guard side != button.side else { return }
                    settings.update { $0.floating.move(buttonID, to: side, at: $0.floating.buttons(on: side).count) }
                }
                .frame(height: 24)
            }
            HStack {
                Button("Move up") { settings.update { $0.floating.shift(buttonID, by: -1) } }.disabled(position == 0)
                Button("Move down") { settings.update { $0.floating.shift(buttonID, by: 1) } }.disabled(position >= siblings.count - 1)
            }
            field("Action") {
                TextField("Find an action", text: $query).textFieldStyle(.roundedBorder)
                IslandActionGrid(environment: environment, query: query, current: button.action) { action in
                    var changed = button
                    changed.action = action
                    settings.update { $0.floating.update(changed) }
                }
            }
            Divider()
            Button("Remove button", role: .destructive) {
                settings.update { $0.floating.remove(buttonID) }
                dismiss()
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    /// The field keeps what is typed (so spaces between words survive); the saved label is trimmed.
    private func nameBinding(_ button: IslandFloatingButton) -> Binding<String> {
        Binding(get: { name ?? button.label }, set: { value in
            let text = String(value.prefix(40))
            name = text
            var changed = button
            changed.label = text
            settings.update { $0.floating.update(changed) }
        })
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Every action a floating button can have, in "Open a section" and "Quick actions", filtered by a query.
struct IslandActionGrid: View {
    @ObservedObject var environment: IslandEnvironment
    let query: String
    var current: IslandFloatingAction?
    let choose: (IslandFloatingAction) -> Void

    var body: some View {
        let sections = IslandActionSearch.filter(query, IslandFloatingAction.sectionGroup)
        let quick = IslandActionSearch.filter(query, IslandFloatingAction.quickGroup)
        ScrollView(.vertical) {
            if sections.isEmpty && quick.isEmpty {
                Text("No results")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    group("Open a section", sections)
                    group("Quick actions", quick)
                }
            }
        }
        .frame(height: 200)
    }

    @ViewBuilder private func group(_ title: String, _ actions: [IslandFloatingAction]) -> some View {
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 4) {
                    ForEach(actions) { item($0) }
                }
            }
        }
    }

    private func item(_ action: IslandFloatingAction) -> some View {
        let availability = IslandActionAvailability.of(action, in: environment)
        let chosen = current == action
        return Button { choose(action) } label: {
            HStack(spacing: 8) {
                Image(systemName: action.symbol).frame(width: 18)
                Text(action.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(chosen ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(chosen ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!availability.isAvailable)
        .opacity(availability.isAvailable ? 1 : 0.4)
        .help(availability.reason ?? action.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A native segmented control whose segments can be disabled one by one (a full side cannot be chosen).
struct IslandSegments: NSViewRepresentable {
    let titles: [String]
    let selected: Int
    let enabled: [Bool]
    let changed: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: context.coordinator,
                           action: #selector(Coordinator.segmentChanged(_:)))
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.changed = changed
        for index in titles.indices where index < control.segmentCount {
            control.setEnabled(enabled.indices.contains(index) ? enabled[index] : true, forSegment: index)
        }
        control.selectedSegment = selected
    }

    @MainActor
    final class Coordinator: NSObject {
        var changed: (Int) -> Void
        init(changed: @escaping (Int) -> Void) { self.changed = changed }
        @objc func segmentChanged(_ sender: NSSegmentedControl) { changed(sender.selectedSegment) }
    }
}
