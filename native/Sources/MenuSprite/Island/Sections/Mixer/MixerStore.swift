import Foundation
import IslandKit

/// The mixer's remembered settings in the app's defaults, one key each under
/// `MenuSprite.Island.Mixer.<option>`. Changes land in memory at once; a fader drag writes the
/// defaults only when it ends. With no defaults (renders, previews) nothing is persisted.
@MainActor
final class MixerStore: ObservableObject {
    private enum Key: String {
        case volumes, lastAudible, routes, hidden, showsFinder, hideInactive, arrangement
        var name: String { "MenuSprite.Island.Mixer." + rawValue }
    }

    @Published private(set) var preferences: MixerPreferences
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        var loaded = MixerPreferences()
        if let defaults {
            loaded.volumes = MixerPreferences.cleanVolumes(defaults.object(forKey: Key.volumes.name))
            loaded.lastAudible = MixerPreferences.cleanVolumes(defaults.object(forKey: Key.lastAudible.name))
            loaded.routes = MixerDevice.cleanRoutes(MixerPreferences.cleanStrings(defaults.object(forKey: Key.routes.name)))
            loaded.hidden = MixerPreferences.cleanStrings(defaults.object(forKey: Key.hidden.name))
            loaded.hidden[MixerListing.finderBundleID] = nil
            loaded.showsFinder = defaults.object(forKey: Key.showsFinder.name) as? Bool ?? true
            loaded.hideInactive = defaults.object(forKey: Key.hideInactive.name) as? Bool ?? false
            loaded.arrangement = MixerArrangement.decode(defaults.object(forKey: Key.arrangement.name))
        }
        preferences = loaded
    }

    /// Applies a change in memory; `persist: false` while a fader is being dragged.
    func update(persist: Bool = true, _ change: (inout MixerPreferences) -> Void) {
        var copy = preferences
        change(&copy)
        guard copy != preferences else { return }
        preferences = copy
        if persist { save() }
    }

    func save() {
        guard let defaults else { return }
        let value = preferences
        defaults.set(value.volumes, forKey: Key.volumes.name)
        defaults.set(value.lastAudible, forKey: Key.lastAudible.name)
        defaults.set(value.routes, forKey: Key.routes.name)
        defaults.set(value.hidden, forKey: Key.hidden.name)
        defaults.set(value.showsFinder, forKey: Key.showsFinder.name)
        defaults.set(value.hideInactive, forKey: Key.hideInactive.name)
        defaults.set(value.arrangement.data, forKey: Key.arrangement.name)
    }
}
