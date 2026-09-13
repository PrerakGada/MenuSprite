import AppKit
import SystemMonitoring

@MainActor
struct ProcessBoardContent {
    let kind: ProcessPanelKind
    let monitoring: MonitoringStore
    let processes: MemoryBoardStore
    var mainValue: String {
        guard let value = monitoring.readings[kind.summaryID]?.number else { return "—" }
        return kind == .power ? String(format: "%.1f W", value) : String(format: "%.0f%%", value)
    }
    var subtitle: String {
        switch kind {
        case .memory: "\(bytes("memory.used")) / \(bytes("memory.total"))"
        case .cpu: "Whole Mac · average across all CPU cores"
        case .power: "Total Mac draw · system power sensor"
        }
    }
    var stats: [(String, String)] {
        switch kind {
        case .memory:
            [("Memory used", "\(bytes("memory.used")) / \(bytes("memory.total"))"), ("Pressure", monitoring.readings["memory.pressure"]?.text ?? "Unknown"),
             ("App memory", bytes("memory.app")), ("Wired", bytes("memory.wired")), ("Compressed", bytes("memory.compressed")), ("Cached files", bytes("memory.cached")), ("Swap used", bytes("memory.swapUsed"))]
        case .cpu:
            [("User", value("cpu.user")), ("System", value("cpu.system")), ("Idle", value("cpu.idle")),
             ("Load · 1 minute", value("cpu.load1")), ("Load · 5 minutes", value("cpu.load5")), ("Load · 15 minutes", value("cpu.load15")), ("Logical cores", value("cpu.cores"))]
        case .power:
            [("Mac power draw", value("sensor.PSTR")), ("Adapter input", value("sensor.PDTR")), ("Battery flow ±", value("battery.power")),
             ("Power source", value("battery.state")), ("Battery", value("battery.charge")), ("Low Power Mode", value("system.lowPower")), ("Whole-Mac CPU", value("cpu.usage"))]
        }
    }
    var explanation: String {
        switch kind {
        case .memory: "App totals use kernel footprint, including compressed allocations, and do not add up to physical RAM. Sizes are binary GiB/MiB."
        case .cpu: "Recent CPU time, summed across an app's observed helpers. 100% means one fully occupied core; multi-threaded apps can exceed 100%. The headline averages across all cores."
        case .power: "Average CPU power from macOS per-process CPU energy counters (nanojoules divided by elapsed time). These are CPU-only attributions, not each app's total electrical draw or Activity Monitor's Energy Impact score. GPU, display and other components are not assigned to apps."
        }
    }
    func formatted(_ row: ProcessConsumerRate) -> String { (row.missingCount > 0 ? "≥ " : "") + kind.formatted(row.value) }
    func tooltip(_ row: ProcessConsumerRate) -> String {
        let consumer = row.consumer
        let presentation = consumer.presentation
        var result = "\(presentation.title): \(formatted(row)), \(consumer.processCount) processes"
        if let subtitle = presentation.subtitle { result += "\n" + subtitle }
        result += "\n" + presentation.explanation
        if consumer.bundlePath == nil, let process = consumer.processes.first, !process.executablePath.isEmpty {
            result += "\nExecutable: " + ProcessPresentation.shortPath(process.executablePath)
        }
        if row.missingCount > 0 { result += "\nSubtotal: \(row.missingCount) processes are awaiting an interval or unavailable." }
        return result + "\n" + consumer.processes.sorted { (row.processValues[$0.pid] ?? -1) > (row.processValues[$1.pid] ?? -1) }.prefix(8).map { process in
            "\(process.name) (PID \(process.pid)): \(row.processValues[process.pid].map(kind.formatted) ?? "Unavailable / awaiting interval")"
        }.joined(separator: "\n")
    }
    private func value(_ id: String) -> String { monitoring.display(id, compact: true) }
    private func bytes(_ id: String) -> String { MemoryBoardFormat.bytes(monitoring.readings[id]?.number) }
}

extension SpriteConfiguration {
    var processPanelKind: ProcessPanelKind? {
        guard !metricIDs.isEmpty else { return nil }
        if metricIDs.allSatisfy({ $0.hasPrefix("memory.") }) { return .memory }
        if metricIDs.allSatisfy({ $0.hasPrefix("cpu.") }) { return .cpu }
        let powerIDs: Set<String> = ["sensor.PSTR", "sensor.PDTR", "battery.power", "battery.adapterRated"]
        if metricIDs.allSatisfy({ powerIDs.contains($0) }) { return .power }
        return nil
    }
}
