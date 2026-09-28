import Foundation
import IslandKit

/// The AI Agents section's choices, one defaults key each under `MenuSprite.Island.Agents.`. A key
/// never written reads as its default, so a new setup gets the live activity and both alerts on.
@MainActor
final class AgentsOptionsStore: ObservableObject {
    nonisolated static let prefix = "MenuSprite.Island.Agents."
    @Published private(set) var value: AgentOptions
    private let defaults: UserDefaults

    private enum Key: String {
        case agents, cards, hiddenCards, limitDisplay, liveActivity, reading, finishNotice, finishMinimum,
             limitWarning, warnAt, renewalNotice, period
        var name: String { AgentsOptionsStore.prefix + rawValue }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = Self.load(defaults)
    }

    func update(_ change: (inout AgentOptions) -> Void) {
        var copy = value
        change(&copy)
        guard copy != value else { return }
        value = copy
        save(copy)
    }

    private static func load(_ defaults: UserDefaults) -> AgentOptions {
        var options = AgentOptions()
        func string(_ key: Key) -> String? { defaults.string(forKey: key.name) }
        func bool(_ key: Key, _ fallback: Bool) -> Bool { defaults.object(forKey: key.name) as? Bool ?? fallback }
        func number(_ key: Key, _ fallback: Double) -> Double { (defaults.object(forKey: key.name) as? NSNumber)?.doubleValue ?? fallback }
        if let stored = defaults.stringArray(forKey: Key.agents.name) {
            let on = Set(stored.compactMap(AgentKind.init(rawValue:)))
            for agent in AgentKind.allCases where !on.contains(agent) { options.setAgent(agent, false) }
        }
        if let stored = defaults.stringArray(forKey: Key.cards.name) { options.cardOrder = AgentCard.normalized(stored) }
        if let stored = defaults.stringArray(forKey: Key.hiddenCards.name) { options.hiddenCards = Set(stored.compactMap(AgentCard.init(rawValue:))) }
        options.limitDisplay = string(.limitDisplay).flatMap(AgentLimitDisplay.init(rawValue:)) ?? options.limitDisplay
        options.liveActivity = bool(.liveActivity, options.liveActivity)
        options.reading = string(.reading).flatMap(AgentReading.init(rawValue:)) ?? options.reading
        options.finishNotice = bool(.finishNotice, options.finishNotice)
        options.finishMinimum = number(.finishMinimum, options.finishMinimum)
        options.limitWarning = bool(.limitWarning, options.limitWarning)
        options.warnAt = number(.warnAt, options.warnAt)
        options.renewalNotice = bool(.renewalNotice, options.renewalNotice)
        options.period = string(.period).flatMap(AgentPeriod.init(rawValue:)) ?? options.period
        return options
    }

    private func save(_ options: AgentOptions) {
        defaults.set(AgentKind.allCases.filter(options.isOn).map(\.rawValue), forKey: Key.agents.name)
        defaults.set(options.cardOrder.map(\.rawValue), forKey: Key.cards.name)
        defaults.set(options.hiddenCards.map(\.rawValue).sorted(), forKey: Key.hiddenCards.name)
        defaults.set(options.limitDisplay.rawValue, forKey: Key.limitDisplay.name)
        defaults.set(options.liveActivity, forKey: Key.liveActivity.name)
        defaults.set(options.reading.rawValue, forKey: Key.reading.name)
        defaults.set(options.finishNotice, forKey: Key.finishNotice.name)
        defaults.set(options.finishMinimum, forKey: Key.finishMinimum.name)
        defaults.set(options.limitWarning, forKey: Key.limitWarning.name)
        defaults.set(options.warnAt, forKey: Key.warnAt.name)
        defaults.set(options.renewalNotice, forKey: Key.renewalNotice.name)
        defaults.set(options.period.rawValue, forKey: Key.period.name)
    }
}
