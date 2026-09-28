import Foundation
import IslandKit

/// Clipboard history's own options, under `MenuSprite.Island.Clipboard.<option>`. History is off
/// until the person turns it on; nothing watches the pasteboard before then.
@MainActor
final class ClipboardPreferences: ObservableObject {
    private static let prefix = "MenuSprite.Island.Clipboard."
    private let defaults: UserDefaults?

    @Published var keepHistory: Bool { didSet { defaults?.set(keepHistory, forKey: Self.prefix + "keepHistory") } }
    /// "Also save copied images and files".
    @Published var includeMedia: Bool { didSet { defaults?.set(includeMedia, forKey: Self.prefix + "includeMedia") } }
    /// "Skip text that looks like a password or key".
    @Published var skipSensitive: Bool { didSet { defaults?.set(skipSensitive, forKey: Self.prefix + "skipSensitive") } }
    /// Bundle identifiers of apps whose copies are never kept.
    @Published var ignoredApps: [String] { didSet { defaults?.set(ignoredApps, forKey: Self.prefix + "ignoredApps") } }
    @Published var limit: ClipboardLimit { didSet { defaults?.set(limit.stored, forKey: Self.prefix + "limit") } }
    /// No shortcut until the person records one.
    @Published var shortcut: IslandShortcut? {
        didSet { defaults?.set(shortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.prefix + "shortcut") }
    }

    /// Pass nil for renders: defaults that are never saved.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        keepHistory = defaults?.bool(forKey: Self.prefix + "keepHistory") ?? false
        includeMedia = defaults?.object(forKey: Self.prefix + "includeMedia") as? Bool ?? true
        skipSensitive = defaults?.object(forKey: Self.prefix + "skipSensitive") as? Bool ?? true
        ignoredApps = defaults?.stringArray(forKey: Self.prefix + "ignoredApps") ?? []
        limit = ClipboardLimit(stored: defaults?.object(forKey: Self.prefix + "limit") as? Int ?? ClipboardLimit.standard.stored)
        shortcut = defaults?.data(forKey: Self.prefix + "shortcut").flatMap { try? JSONDecoder().decode(IslandShortcut.self, from: $0) }
    }
}
