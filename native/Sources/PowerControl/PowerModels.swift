import Foundation

public enum PowerIdentity {
    public static let service = "in.prerakgada.MenuSprite.PowerHelper"
    public static let appRequirement = "anchor apple generic and identifier \"in.prerakgada.MenuSprite\" and certificate leaf[subject.OU] = \"RC63N3VU27\""
    public static let helperRequirement = "anchor apple generic and identifier \"in.prerakgada.MenuSprite.PowerHelper\" and certificate leaf[subject.OU] = \"RC63N3VU27\""
    public static let helperPath = "/Library/PrivilegedHelperTools/\(service)"
    public static let journalPath = "/Library/Application Support/MenuSprite/PowerRecovery.json"
}
@objc public protocol PowerHelperProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}
public enum BatteryMode: String, Codable, Sendable { case off, maintain, topUp, discharge }
public struct ChargeBand: Codable, Equatable, Sendable {
    public var lower: Int
    public var upper: Int
    public init(lower: Int = 50, upper: Int = 55) { self.lower = lower; self.upper = upper }
    public var valid: Bool { lower >= 20 && upper <= 100 && lower < upper }
}
public struct BatteryDecision: Equatable, Sendable {
    public let mode: BatteryMode
    public let charge: Bool
    public let adapter: Bool
}
public enum BatteryPolicy {
    /// Hysteresis: preserve the current charge state inside the chosen band.
    public static func decide(mode: BatteryMode, band: ChargeBand, percent: Int, chargingAllowed: Bool) -> BatteryDecision? {
        guard band.valid, (0...100).contains(percent), mode != .off else { return nil }
        if mode == .topUp && percent < 100 { return .init(mode: .topUp, charge: true, adapter: true) }
        if mode == .discharge && percent > band.upper { return .init(mode: .discharge, charge: false, adapter: false) }
        let allow = percent <= band.lower ? true : (percent >= band.upper ? false : chargingAllowed)
        return .init(mode: .maintain, charge: allow, adapter: true)
    }
}
public struct PowerRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case status, battery, stopBattery, startLid, stopLid, heartbeat, stopAll, chargeLimit, lowPower }
    public var action: Action
    public var mode: BatteryMode
    public var band: ChargeBand
    public var duration: TimeInterval
    /// `chargeLimit` only: the percentage for macOS's own charge limit.
    public var limit: Int?
    /// Carried on every request, so the helper follows the app's MagSafe LED setting after a
    /// sleep, a reconnect or a helper restart without a separate command. Nil leaves it alone.
    public var led: Bool?
    /// `lowPower` only: turn macOS's Low Power Mode on or back to the normal (automatic) mode.
    public var lowPower: Bool?
    public init(_ action: Action, mode: BatteryMode = .off, band: ChargeBand = .init(), duration: TimeInterval = 3600,
                limit: Int? = nil, led: Bool? = nil, lowPower: Bool? = nil) {
        self.action = action; self.mode = mode; self.band = band; self.duration = duration
        self.limit = limit; self.led = led; self.lowPower = lowPower
    }
}
public struct PowerSnapshot: Codable, Sendable {
    public var percent: Int?
    public var pluggedIn: Bool?
    public var chargingAllowed: Bool?
    public var adapterEnabled: Bool?
    public var chargeSupported = false
    public var dischargeSupported = false
    /// Live battery instrumentation, read every sample so the UI can show what
    /// the hardware is actually doing rather than what was last commanded.
    public var chargeCurrent: Int?
    public var batteryVoltage: Int?
    public var capability = "Checking firmware"
    public var mode: BatteryMode = .off
    public var band = ChargeBand()
    public var lidActive = false
    public var sleepDisabled: Bool?
    public var recoveryPending = false
    public var helperConnected = false
    public var error: String?
    /// What the helper last read back from macOS's stored charge limit (root-only).
    public var systemLimit: Int?
    /// Optional so an app talking to an older helper still decodes its replies.
    public var ledControl: Bool?
    public var led: MagSafeLED?
    public var controlCeiling: Int? { mode == .off ? nil : (mode == .topUp ? 100 : band.upper) }
    public init() {}
}
public struct PowerFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
