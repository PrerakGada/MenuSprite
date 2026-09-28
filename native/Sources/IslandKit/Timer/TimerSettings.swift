import Foundation

/// The Timer section's remembered choices: the mode, the Pomodoro cycle and the alarm sound. The live
/// session is deliberately not among them, so a relaunch can never bring back yesterday's timer.
/// Values are clamped as they are read, so an out-of-range stored value cannot overflow a deadline.
public struct TimerSettings: Equatable, Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case mode, focusMinutes, shortBreakMinutes, longBreakMinutes, sessionsBeforeLongBreak, totalSessions, sound
        public var defaultsKey: String { "MenuSprite.Island.Timer." + rawValue }
    }

    public var mode: TimerMode = .timer
    public var plan: PomodoroPlan = .standard
    /// Play a sound when time is up.
    public var sound = true

    public init() {}

    /// Every key with its default, for `UserDefaults.register(defaults:)`.
    public static var defaultValues: [String: Any] {
        TimerSettings().values
    }

    public init(defaults: UserDefaults) {
        func integer(_ key: Key, _ fallback: Int) -> Int {
            guard let number = defaults.object(forKey: key.defaultsKey) as? NSNumber else { return fallback }
            let value = number.doubleValue
            guard value.isFinite else { return fallback }
            return Int(max(-1e6, min(1e6, value)))
        }
        let standard = PomodoroPlan.standard
        mode = (defaults.string(forKey: Key.mode.defaultsKey)).flatMap(TimerMode.init(rawValue:)) ?? .timer
        plan = PomodoroPlan(focusMinutes: integer(.focusMinutes, standard.focusMinutes),
                            shortBreakMinutes: integer(.shortBreakMinutes, standard.shortBreakMinutes),
                            longBreakMinutes: integer(.longBreakMinutes, standard.longBreakMinutes),
                            sessionsBeforeLongBreak: integer(.sessionsBeforeLongBreak, standard.sessionsBeforeLongBreak),
                            totalSessions: integer(.totalSessions, standard.totalSessions))
        sound = (defaults.object(forKey: Key.sound.defaultsKey) as? Bool) ?? true
    }

    public func write(to defaults: UserDefaults) {
        for (key, value) in values { defaults.set(value, forKey: key) }
    }

    private var values: [String: Any] {
        [Key.mode.defaultsKey: mode.rawValue,
         Key.focusMinutes.defaultsKey: plan.focusMinutes,
         Key.shortBreakMinutes.defaultsKey: plan.shortBreakMinutes,
         Key.longBreakMinutes.defaultsKey: plan.longBreakMinutes,
         Key.sessionsBeforeLongBreak.defaultsKey: plan.sessionsBeforeLongBreak,
         Key.totalSessions.defaultsKey: plan.totalSessions,
         Key.sound.defaultsKey: sound]
    }
}
