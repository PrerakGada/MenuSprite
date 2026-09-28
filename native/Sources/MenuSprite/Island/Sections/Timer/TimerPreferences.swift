import Foundation
import IslandKit

/// The Timer section's remembered choices, stored under `MenuSprite.Island.Timer.*`. In the render
/// harness it keeps them in memory only, so an off-screen render never writes the person's defaults.
@MainActor
final class TimerPreferences: ObservableObject {
    @Published private(set) var value: TimerSettings
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        defaults?.register(defaults: TimerSettings.defaultValues)
        value = defaults.map(TimerSettings.init(defaults:)) ?? TimerSettings()
    }

    func update(_ change: (inout TimerSettings) -> Void) {
        var copy = value
        change(&copy)
        guard copy != value else { return }
        value = copy
        if let defaults { copy.write(to: defaults) }
    }
}
