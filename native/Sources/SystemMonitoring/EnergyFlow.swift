import Foundation

/// Independently sampled power sensors do not always balance. Preserve the
/// measured branches and name a positive residual as a difference, not a device.
public struct EnergyFlow: Sendable, Equatable {
    public let adapter: Double?
    public let system: Double?
    public let battery: Double? // positive charges the pack, negative leaves it
    public let charge: Double?
    public let temperature: Double?
    public let sourceState: String?
    public let difference: Double?
    public let imbalance: Bool
    public var batteryOut: Double? { battery.map { $0 < 0 ? -$0 : 0 } }
    public var batteryIn: Double? { battery.map { $0 > 0 ? $0 : 0 } }
    public var hasLiveFlow: Bool { [adapter, batteryOut, system, batteryIn].compactMap { $0 }.contains { $0 > 0.05 } }
    public init(readings: [String: Reading], now: Date = Date(), maximumAge: TimeInterval = 8) {
        func current(_ id: String) -> Reading? {
            guard let r = readings[id], now.timeIntervalSince(r.measuredAt) >= -1,
                  now.timeIntervalSince(r.measuredAt) <= maximumAge else { return nil }
            return r
        }
        func number(_ id: String, range: ClosedRange<Double>) -> Double? {
            guard let v = current(id)?.number, v.isFinite, range.contains(v) else { return nil }
            return v
        }
        adapter = number("sensor.PDTR", range: 0...1000)
        system = number("sensor.PSTR", range: 0...1000)
        battery = number("battery.power", range: -1000...1000)
        charge = number("battery.charge", range: 0...100)
        temperature = number("battery.temperature", range: -20...120)
        sourceState = current("battery.state")?.text
        if let adapter, let system, let battery {
            let residual = adapter - system - battery
            difference = residual >= 0 ? residual : nil
            imbalance = residual < -0.5
        } else { difference = nil; imbalance = false }
    }
    public static func watts(_ value: Double?) -> String {
        value.map { String(format: "%.1f W", $0) } ?? "—"
    }
}

/// Histories break across gaps and invalid samples; an unavailable reading is
/// never represented as a fabricated zero or a line bridging a long sleep.
public enum EnergyChart {
    public static func segments(_ points: [HistoryPoint], maximumGap: TimeInterval, breaks: [Date] = []) -> [[HistoryPoint]] {
        var result: [[HistoryPoint]] = []
        var breakNext = false
        for point in points {
            guard point.value.isFinite else { breakNext = true; continue }
            if let last = result.last?.last, point.time <= last.time { continue }
            let failedBetween = result.last?.last.map { previous in breaks.contains { $0 > previous.time && $0 < point.time } } ?? false
            if result.isEmpty || breakNext || failedBetween || point.time.timeIntervalSince(result.last!.last!.time) > maximumGap {
                result.append([point])
            } else { result[result.count - 1].append(point) }
            breakNext = false
        }
        return result
    }
    public static func scale(_ values: [Double], percent: Bool = false, reference: Double? = nil) -> ClosedRange<Double> {
        if percent { return 0...100 }
        let valid = (values + [reference].compactMap { $0 }).filter { $0.isFinite }
        let low = min(0, valid.min() ?? 0), high = max(1, valid.max() ?? 1)
        return low...(high + max(1, (high - low) * 0.15))
    }
}
