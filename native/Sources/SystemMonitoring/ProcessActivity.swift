import Foundation
import Darwin

public enum ProcessPanelKind: String, Codable, Sendable, CaseIterable {
    case memory, cpu, power
    public var title: String { switch self { case .memory: "Memory"; case .cpu: "CPU"; case .power: "Power" } }
    public var symbol: String { switch self { case .memory: "memorychip"; case .cpu: "cpu"; case .power: "bolt" } }
    public var summaryID: String { switch self { case .memory: "memory.usage"; case .cpu: "cpu.usage"; case .power: "sensor.PSTR" } }
    public var metricIDs: [String] {
        switch self {
        case .memory: ["memory.usage", "memory.used", "memory.total", "memory.pressure", "memory.app", "memory.wired", "memory.compressed", "memory.cached", "memory.swapUsed"]
        case .cpu: ["cpu.usage", "cpu.user", "cpu.system", "cpu.idle", "cpu.load1", "cpu.load5", "cpu.load15", "cpu.cores"]
        case .power: ["sensor.PSTR", "sensor.PDTR", "battery.power", "battery.state", "battery.charge", "battery.temperature", "battery.cycles", "battery.capacityRatio", "battery.remaining", "battery.timeToFull", "system.lowPower", "cpu.usage"]
        }
    }
    public var listTitle: String { switch self { case .memory: "Apps & processes"; case .cpu: "Apps & processes · CPU"; case .power: "Apps & processes · CPU power" } }
    public var scope: String {
        switch self {
        case .memory: "Includes helpers; shared services may appear separately."
        case .cpu: "100% = one CPU core; apps can exceed 100%."
        case .power: "CPU energy only; excludes GPU, display and other components."
        }
    }
    public func formatted(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        switch self {
        case .memory:
            if value >= 1_073_741_824 { return String(format: "%.2f GiB", value / 1_073_741_824) }
            if value >= 1_048_576 { return String(format: "%.1f MiB", value / 1_048_576) }
            return String(format: "%.0f KiB", value / 1024)
        case .cpu: return String(format: "%.1f%%", value)
        case .power: return value >= 1 ? String(format: "%.2f W", value) : String(format: "%.1f mW", value * 1000)
        }
    }
}
public struct ProcessConsumerRate: Identifiable, Sendable {
    public let consumer: MemoryConsumer
    public let value: Double
    public let processValues: [Int32: Double]
    public let missingCount: Int
    /// The consumer's sub-rows, ranked by the same readings.
    public var members: [ProcessConsumerRate] = []
    public var id: String { consumer.id }
}
public struct ProcessInterval: Sendable {
    public let cpuPercent: Double?
    public let cpuWatts: Double?
}
/// CPU counters are Mach absolute-time units; energy counters are nanojoules.
/// Baselines follow PID + birth identity and reset with the panel's sampler.
public struct ProcessActivityRates: Sendable {
    private var previous: [Int32: ProcessMemoryRecord] = [:]
    public private(set) var intervals: [Int32: ProcessInterval] = [:]
    public private(set) var hasInterval = false
    public private(set) var energyObserved = false
    private let nanosecondsPerTick: Double
    public init(nanosecondsPerTick: Double? = nil) {
        if let nanosecondsPerTick { self.nanosecondsPerTick = nanosecondsPerTick }
        else {
            var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
            self.nanosecondsPerTick = Double(timebase.numer) / Double(max(1, timebase.denom))
        }
    }
    public mutating func update(_ records: [ProcessMemoryRecord]) {
        hasInterval = !previous.isEmpty
        var next: [Int32: ProcessMemoryRecord] = [:], values: [Int32: ProcessInterval] = [:]
        for record in records {
            next[record.pid] = record
            if let energy = record.energyNanojoules, energy > 0 { energyObserved = true }
            guard let old = previous[record.pid], old.started == record.started,
                  let time = record.sampledUptime, let oldTime = old.sampledUptime,
                  time.isFinite, oldTime.isFinite, time > oldTime else { continue }
            let elapsed = time - oldTime
            var cpu: Double?, watts: Double?
            if let current = record.cpuTicks, let baseline = old.cpuTicks, current >= baseline, nanosecondsPerTick.isFinite, nanosecondsPerTick > 0 {
                let value = Double(current - baseline) * nanosecondsPerTick / 1e9 / elapsed * 100
                if value.isFinite && value >= 0 { cpu = value }
            }
            if let current = record.energyNanojoules, let baseline = old.energyNanojoules,
               current > 0, current >= baseline {
                let value = Double(current - baseline) / 1e9 / elapsed
                if value.isFinite && value >= 0 { watts = value }
            }
            values[record.pid] = .init(cpuPercent: cpu, cpuWatts: watts)
        }
        previous = next; intervals = values
    }
    public func rank(_ consumers: [MemoryConsumer], by kind: ProcessPanelKind) -> [ProcessConsumerRate] {
        consumers.compactMap { consumer -> ProcessConsumerRate? in
            let members = consumer.members.map { rank($0, by: kind) } ?? []
            var values: [Int32: Double] = [:]
            for process in consumer.processes {
                let value: Double? = switch kind {
                case .memory: Double(process.bytes)
                case .cpu: intervals[process.pid]?.cpuPercent
                case .power: intervals[process.pid]?.cpuWatts
                }
                if let value { values[process.pid] = value }
            }
            guard !values.isEmpty else { return nil }
            return .init(consumer: consumer, value: values.values.reduce(0, +), processValues: values,
                         missingCount: consumer.processCount - values.count, members: members)
        }.sorted { $0.value == $1.value ? $0.id < $1.id : $0.value > $1.value }
    }
}
