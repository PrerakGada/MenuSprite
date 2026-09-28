import SwiftUI

/// One tool's global shortcut: registered only while the island runs and a key is recorded, and
/// honest when macOS refuses it (another app already owns the combination).
@MainActor
final class IslandToolShortcut: ObservableObject {
    @Published private(set) var refused = false
    private let name: String
    private let action: () -> Void
    private var active = false

    init(name: String, action: @escaping () -> Void) {
        self.name = name
        self.action = action
    }

    func activate(_ shortcut: IslandShortcut?) {
        active = true
        apply(shortcut)
    }

    /// The recorded key changed.
    func apply(_ shortcut: IslandShortcut?) {
        guard active else { return }
        refused = !IslandShortcuts.shared.register(name, shortcut, action: action)
    }

    func deactivate() {
        active = false
        IslandShortcuts.shared.unregister(name)
        refused = false
    }
}

/// A settings row: label, the recorder, and an orange line when macOS refused the combination.
struct IslandToolShortcutRow: View {
    let title: String
    @Binding var shortcut: IslandShortcut?
    @ObservedObject var registration: IslandToolShortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                IslandShortcutRecorder(shortcut: $shortcut)
            }
            if registration.refused && shortcut != nil {
                Text("macOS refused this shortcut. Another app may already use it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if shortcut == nil {
                Text("No shortcut. Click to record one; ⌫ clears it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
