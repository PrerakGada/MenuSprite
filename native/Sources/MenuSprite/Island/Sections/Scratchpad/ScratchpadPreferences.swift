import Foundation
import IslandKit

/// The Scratchpad's own options, under `MenuSprite.Island.Scratchpad.<option>`. Pad text is never
/// stored here: it lives in its own private file, so it stays out of preferences and backups.
@MainActor
final class ScratchpadPreferences: ObservableObject {
    private static let prefix = "MenuSprite.Island.Scratchpad."
    private let defaults: UserDefaults?

    @Published var retention: ScratchpadRetention { didSet { defaults?.set(retention.rawValue, forKey: Self.prefix + "retention") } }
    /// Read at click time by the floating pad, so flipping it affects an open pad.
    @Published var closeOnClickOutside: Bool { didSet { defaults?.set(closeOnClickOutside, forKey: Self.prefix + "closeOnClickOutside") } }
    @Published var background: Double {
        didSet {
            let resolved = ScratchpadBackground.resolve(background)
            if resolved != background { background = resolved; return }
            defaults?.set(background, forKey: Self.prefix + "background")
        }
    }
    /// No shortcut until the person records one.
    @Published var shortcut: IslandShortcut? {
        didSet { defaults?.set(shortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.prefix + "shortcut") }
    }

    /// Pass nil for renders: defaults that are never saved.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        retention = ScratchpadRetention(stored: defaults?.string(forKey: Self.prefix + "retention"))
        closeOnClickOutside = defaults?.object(forKey: Self.prefix + "closeOnClickOutside") as? Bool ?? true
        background = ScratchpadBackground.resolve(defaults?.object(forKey: Self.prefix + "background") as? Double ?? ScratchpadBackground.standard)
        shortcut = defaults?.data(forKey: Self.prefix + "shortcut").flatMap { try? JSONDecoder().decode(IslandShortcut.self, from: $0) }
    }
}
