import Foundation
import notify

/// macOS's own charge limit, driven the way AlDente drives it on macOS 26.4+ firmware.
///
/// On this generation the SMC's charge-inhibit keys are read-only or entitlement-gated,
/// so no third party can stop charging directly. PowerUIAgent (root) owns a manual charge
/// limit instead: it registers a charge-control policy with powerd, and powerd enforces it
/// through the firmware — holding the level while the adapter powers the Mac, draining to it
/// when the pack is above it, and surviving sleep, relaunch and MenuSprite quitting.
///
/// PowerUI's client API accepts only 80–100 in 5% steps. PowerUIAgent's stored preference,
/// `mclLimitValue` in its root domain, takes any whole percentage, and the agent re-reads it
/// when `com.apple.smartcharging.defaultschanged` is posted. Measured on Nebula, 24 Sep 2026:
/// writing 55 moved powerd's enforced policy from `soclimit 80` to `soclimit 55, drain`.
/// Measured 25 Sep: a *changed* value reaches powerd in 6–20 s; re-writing an unchanged value
/// does nothing, and at 100 the agent ignores the preference entirely (see PowerStore).
public enum SystemChargeLimit {
    public static let domain = "com.apple.smartcharging.topoffprotection"
    public static let key = "mclLimitValue"
    public static let changed = "com.apple.smartcharging.defaultschanged"
    /// The floor matches AlDente's; below this a charge limit stops being a care setting.
    public static let range = 20...100

    /// Root only: the preference lives in PowerUIAgent's (root's) domain.
    public static func write(_ percent: Int) throws {
        guard geteuid() == 0 else { throw PowerFailure("Administrator helper is required") }
        guard range.contains(percent) else { throw PowerFailure("Choose a charge limit from \(range.lowerBound)% to 100%") }
        let domain = self.domain as CFString
        CFPreferencesSetValue(key as CFString, percent as CFNumber, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw PowerFailure("macOS did not save the charge limit")
        }
        guard stored() == percent else { throw PowerFailure("macOS did not keep the charge limit") }
        notify_post(changed)
    }

    /// The stored value; readable only by root.
    public static func stored() -> Int? {
        CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int
    }
}

/// A charge-control policy powerd is enforcing right now, read from its own world-readable
/// record. This is the ground truth for the UI: what macOS is doing, not what was asked for.
public struct EnforcedChargeLimit: Equatable, Sendable {
    public let limit: Int
    /// powerd runs the Mac from the battery while the pack is above the limit.
    public let drain: Bool

    public static let recordPath = "/Library/Preferences/com.apple.powerd.charging.plist"

    /// The strictest policy in force, or nil when none is (macOS charges to full).
    public static func current(path: String = recordPath) -> EnforcedChargeLimit? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> EnforcedChargeLimit? {
        guard let outer = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let archived = outer["policies"] as? Data,
              let inner = try? PropertyListSerialization.propertyList(from: archived, format: nil) as? [String: Any],
              let objects = inner["$objects"] as? [Any] else { return nil }
        let policies = objects.compactMap { object -> EnforcedChargeLimit? in
            guard let entry = object as? [String: Any], let limit = entry["soclimit"] as? Int,
                  (1...100).contains(limit), entry["terminated"] as? Bool != true else { return nil }
            return EnforcedChargeLimit(limit: limit, drain: entry["drain"] as? Bool ?? false)
        }
        return policies.min { $0.limit < $1.limit }
    }
}

/// The MagSafe connector's LED, SMC key `ACLC`. Values follow charlie0129/batt.
public enum MagSafeLED: UInt8, Codable, Sendable {
    case system = 0
    case off = 1
    case green = 3
    case amber = 4
    /// The connector's own slow error blink — amber; the LED has no red.
    case blinkAmber = 6

    /// Green while the cable holds the level, amber while charging, blinking amber while the
    /// Mac runs from its battery with the cable connected.
    public static func desired(pluggedIn: Bool?, charging: Bool, amperage: Int?) -> MagSafeLED {
        guard pluggedIn == true else { return .system }
        if let amperage, amperage < -50 { return .blinkAmber }
        if charging || (amperage ?? 0) > 50 { return .amber }
        return .green
    }
}

/// Sailing: once the pack has reached the limit, it is not topped up again until it falls more
/// than `band` below it. macOS's own limit is exact — it recharges the moment the level dips a
/// fraction under it, under load or after unplugged use — so inside the band MenuSprite sets
/// macOS's limit to the current level, which holds the pack where it is: no charge, no drain.
public enum Sailing {
    public static let choices = [0, 3, 5, 10]

    /// The limit macOS should hold now, and whether a recharge back up to the limit is under way.
    /// `recharging` carries over between calls: a recharge that started below the band runs all
    /// the way to the limit instead of stopping as soon as it re-enters the band.
    public static func target(limit: Int, band: Int, percent: Int?, recharging: Bool) -> (limit: Int, recharging: Bool) {
        guard band > 0, let percent, percent < limit else { return (limit, false) }
        if percent < limit - band || recharging { return (limit, true) }
        return (max(1, percent), false)
    }
}
