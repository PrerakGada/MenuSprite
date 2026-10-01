import Foundation

/// What the app asks of the fans. It rides on every helper request, like the MagSafe LED setting,
/// so the helper follows it again after a sleep, a reconnect or a helper restart.
public enum FanTarget: Codable, Equatable, Hashable, Sendable {
    /// macOS manages the fans; MenuSprite writes nothing.
    case automatic
    /// Every fan held at this percentage of its own maximum speed.
    case percent(Int)
    public static let presets = [80, 90, 100]
    public var isManual: Bool { self != .automatic }
    public var percent: Int? { if case .percent(let value) = self { value } else { nil } }
}

/// One fan as the firmware reports it. `controllable` means both its mode and target keys accept writes.
public struct FanState: Codable, Equatable, Sendable {
    public let index: Int
    public var rpm: Double
    public var minimum: Double
    public var maximum: Double
    public var target: Double?
    /// The fan is in the firmware's manual (forced) mode — MenuSprite's or another app's.
    public var manual: Bool
    public var controllable: Bool
    public init(index: Int, rpm: Double, minimum: Double, maximum: Double, target: Double?, manual: Bool, controllable: Bool) {
        self.index = index; self.rpm = rpm; self.minimum = minimum; self.maximum = maximum
        self.target = target; self.manual = manual; self.controllable = controllable
    }
}

public enum FanPolicy {
    /// A percentage is of the fan's own maximum, never below the firmware's minimum.
    public static func rpm(percent: Int, for fan: FanState) -> Double {
        (fan.maximum * Double(percent) / 100).clamped(fan.minimum, fan.maximum).rounded()
    }
    /// The lowest percentage that is not simply the firmware minimum for every fan.
    public static func lowestPercent(_ fans: [FanState]) -> Int {
        let ratios = fans.filter { $0.maximum > 0 }.map { $0.minimum / $0.maximum * 100 }
        return min(100, max(1, Int((ratios.max() ?? 30).rounded(.up))))
    }
    public static func valid(_ target: FanTarget) -> Bool {
        guard let percent = target.percent else { return true }
        return (1...100).contains(percent)
    }
}

extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}
