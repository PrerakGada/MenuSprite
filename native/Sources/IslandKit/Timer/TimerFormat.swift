import Foundation

/// Every way the timer writes a length of time. Countdowns round up (never finishing early) and stop at
/// three hours; stopwatches round down (never showing a second that has not passed) and stop at
/// 99:59:59. Hours beside the camera and on the ruler read "1h35", never "1:35", which looked like
/// minutes and seconds.
public enum TimerFormat {
    /// The stopwatch's largest reading, 99:59:59.
    public static let stopwatchLimit: Double = 359_999

    /// The page's big countdown clock: "MM:SS" below an hour, "H:MM:SS" from an hour. Invalid or
    /// negative readings show "00:00".
    public static func clock(countdown remaining: Double) -> String {
        clock(seconds: countdownSeconds(remaining))
    }

    /// The page's stopwatch clock, same shape, rounding down and growing past three hours.
    public static func clock(stopwatch elapsed: Double) -> String {
        clock(seconds: stopwatchSeconds(elapsed))
    }

    /// The reading beside the camera for a countdown: "59s" in the last minute, whole minutes "14m"
    /// below an hour, "1h35" from an hour. "0s" when invalid or done.
    public static func strip(countdown remaining: Double, locale: Locale = .current) -> String {
        let seconds = countdownSeconds(remaining)
        if seconds <= 0 { return narrowSeconds(0, locale: locale) }
        if seconds < 60 { return narrowSeconds(seconds, locale: locale) }
        if seconds < 3600 { return narrowMinutes(seconds / 60, locale: locale) }
        return hours(Double(seconds), limit: TimerSession.maximumLength)
    }

    /// The reading beside the camera for a stopwatch: "12:05" (seconds kept so it visibly ticks) below
    /// an hour, then "1h05", stopping at "99h59".
    public static func strip(stopwatch elapsed: Double) -> String {
        let seconds = stopwatchSeconds(elapsed)
        if seconds < 3600 { return clock(seconds: seconds) }
        return hours(Double(seconds), limit: stopwatchLimit)
    }

    /// Hours with a literal "h" and two-digit minutes, rounding the minutes down: 5700 → "1h35".
    /// Capped at `limit`; an unreadable value reads "0h00".
    public static func hours(_ seconds: Double, limit: Double) -> String {
        let value = seconds.isFinite ? min(max(0, seconds), limit) : 0
        let minutes = Int((value / 60).rounded(.down))
        return "\(minutes / 60)h" + twoDigits(minutes % 60)
    }

    /// A countdown length in the locale's narrow units, for menus and VoiceOver: "14m", "59s", "1h 1m".
    /// Rounds up to the second, then down to the minute once past a minute.
    public static func duration(_ remaining: Double, locale: Locale = .current) -> String {
        let seconds = countdownSeconds(remaining)
        if seconds < 60 { return narrowSeconds(max(0, seconds), locale: locale) }
        return narrowMinutes(seconds / 60, locale: locale)
    }

    /// A whole number of minutes in narrow units: "5m", "1h 30m".
    public static func minutes(_ minutes: Int, locale: Locale = .current) -> String {
        narrowMinutes(max(0, minutes), locale: locale)
    }

    /// Minutes spelled out for VoiceOver: "15 minutes", "1 hour, 30 minutes".
    public static func spokenMinutes(_ minutes: Int, locale: Locale = .current) -> String {
        Duration.seconds(max(0, minutes) * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(locale))
    }

    /// A reading with its digits normalised, so the strip is re-measured only when the text gains or
    /// loses a character ("10m" → "9m"), not every second.
    public static func shape(_ text: String) -> String {
        String(text.map { $0.isNumber ? "0" : $0 })
    }

    // MARK: Pieces

    /// Whole seconds a countdown shows: rounded up, capped at three hours, zero when invalid.
    static func countdownSeconds(_ remaining: Double) -> Int {
        guard remaining.isFinite, remaining > 0 else { return 0 }
        return Int(min(remaining, TimerSession.maximumLength).rounded(.up))
    }

    /// Whole seconds a stopwatch shows: rounded down, capped at 99:59:59, zero when invalid.
    static func stopwatchSeconds(_ elapsed: Double) -> Int {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return Int(min(elapsed, stopwatchLimit).rounded(.down))
    }

    static func clock(seconds: Int) -> String {
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        if hours > 0 { return "\(hours):" + twoDigits(minutes) + ":" + twoDigits(rest) }
        return twoDigits(minutes) + ":" + twoDigits(rest)
    }

    static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }

    static func narrowSeconds(_ seconds: Int, locale: Locale) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .narrow).locale(locale))
    }

    static func narrowMinutes(_ minutes: Int, locale: Locale) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow).locale(locale))
    }
}
