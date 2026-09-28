import AppKit
import IslandKit
import SwiftUI
import UniformTypeIdentifiers

/// The shelf's own options, under `MenuSprite.Island.Files.<option>`. Where Files opens and the
/// drop target while dragging are island settings (`filesInIsland`, `dragReveal`) and live there.
@MainActor
final class ShelfPreferences: ObservableObject {
    static let prefix = "MenuSprite.Island.Files."
    private let defaults: UserDefaults?

    /// Collapse the island after a drag out lands in another app. Off.
    @Published var closeAfterDrop: Bool { didSet { save(closeAfterDrop, "closeAfterDrop") } }
    /// Dragged items leave the shelf once another app accepts them; pinned items stay. On.
    @Published var removeAfterDrop: Bool { didSet { save(removeAfterDrop, "removeAfterDrop") } }
    /// With Files in a separate window: shaking the pointer while dragging opens it. On.
    @Published var shakeToOpen: Bool { didSet { save(shakeToOpen, "shakeToOpen") } }
    /// Apps whose drags never reveal the shelf, by bundle identifier.
    @Published var exceptions: [String] { didSet { defaults?.set(exceptions, forKey: Self.prefix + "exceptions") } }

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults?.object(forKey: Self.prefix + key) as? Bool ?? fallback }
        closeAfterDrop = flag("closeAfterDrop", false)
        removeAfterDrop = flag("removeAfterDrop", true)
        shakeToOpen = flag("shakeToOpen", true)
        exceptions = defaults?.stringArray(forKey: Self.prefix + "exceptions") ?? []
    }

    private func save(_ value: Bool, _ key: String) { defaults?.set(value, forKey: Self.prefix + key) }
}

/// Settings › Content › Files.
struct ShelfOptionsView: View {
    @ObservedObject var settings: IslandSettingsStore
    @ObservedObject var preferences: ShelfPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Open Files in") {
                Picker("Open Files in", selection: Binding(get: { settings.value.filesInIsland },
                                                           set: { value in settings.update { $0.filesInIsland = value } })) {
                    Text("Dynamic Island").tag(true)
                    Text("Separate window").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if settings.value.filesInIsland {
                toggle("Show a drop target while dragging",
                       detail: "While you drag files anywhere, the island offers a place to drop them.",
                       isOn: Binding(get: { settings.value.dragReveal }, set: { value in settings.update { $0.dragReveal = value } }))
            } else {
                toggle("Open by shaking the pointer while dragging",
                       detail: "Shake quickly left and right while dragging files to bring up the shelf window.",
                       isOn: $preferences.shakeToOpen)
            }
            toggle("Close after dropping into another app", detail: nil, isOn: $preferences.closeAfterDrop)
            toggle("Remove items after dropping", detail: "Pinned items always stay on the shelf.", isOn: $preferences.removeAfterDrop)
            exceptions
        }
    }

    private func toggle(_ title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
    }

    private var exceptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Never reveal for drags from")
            Text("Drags that start in these apps never bring up the drop target or the shelf window.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(preferences.exceptions, id: \.self) { bundle in
                HStack(spacing: 8) {
                    appIcon(bundle)
                    Text(appName(bundle)).lineLimit(1)
                    Spacer()
                    Button {
                        preferences.exceptions.removeAll { $0 == bundle }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            Button("Add App…", action: addApp)
        }
    }

    private func appURL(_ bundle: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) }

    private func appName(_ bundle: String) -> String {
        appURL(bundle).map { FileManager.default.displayName(atPath: $0.path) } ?? bundle
    }

    @ViewBuilder private func appIcon(_ bundle: String) -> some View {
        if let url = appURL(bundle) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "app").frame(width: 16, height: 16)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        preferences.exceptions = Array(NSOrderedSet(array: preferences.exceptions + added)) as? [String] ?? preferences.exceptions
    }
}
