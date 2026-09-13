import AppKit
import SystemMonitoring

@MainActor
final class ReadoutValidation {
    let app: AppDelegate
    let directory: URL
    var checks: [[String: Any]] = []
    var measurements: [[String: Any]] = []
    init(app: AppDelegate, directory: URL) { self.app = app; self.directory = directory }
    func start() {
        Task {
            do { try await run() }
            catch { check("Completed readout validation: \(error.localizedDescription)", false); try? report() }
            app.finishHeadlessMeasurement()
            app.showMonitoring()
        }
    }
    func check(_ name: String, _ result: Bool) { checks.append(["name": name, "passed": result]) }
    func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Task.sleep(for: .seconds(5))
        let store = app.monitoringStore!
        let visible = store.sprites.filter { $0.enabled && $0.showInMenuBar }
        check("CPU usage appears exactly once", visible.filter { $0.metricIDs.contains("cpu.usage") }.count == 1)
        let network = visible.first { $0.metricIDs == ["network.upload", "network.download"] }
        let hardware = visible.first { $0.metricIDs == ["sensor.fanSpeed", "sensor.cpuTemperature"] }
        check("Network is one two-row item", network?.layout == .twoRows)
        check("Fan and CPU temperature are one two-row item", hardware?.layout == .twoRows)
        check("One status item per visible sprite", app.spriteMenuBar?.itemCount == store.sprites.filter(\.showInMenuBar).count)
        for id in ["network.upload", "network.download", "sensor.fanSpeed", "sensor.cpuTemperature"] {
            check("Live \(id)", store.readings[id]?.available == true)
        }
        let fans = store.readings.filter { $0.key.hasPrefix("sensor.F") && $0.key.hasSuffix("Ac") }.values.compactMap(\.number)
        check("Fan value is maximum of actual fan readings", !fans.isEmpty && store.readings["sensor.fanSpeed"]?.number == fans.max())
        for config in [network, hardware].compactMap({ $0 }) {
            let columns = store.menuColumns(config)
            let layout = StackedReadout.layout(columns: columns, config: config, height: NSStatusBar.system.thickness)
            check("\(config.name): first reading above second", layout.columns.count == 2 && layout.columns[0].value.minY > layout.columns[1].value.maxY)
            check("\(config.name): readings share a column", abs(layout.columns[0].value.maxX - layout.columns[1].value.maxX) < 0.01)
            let image = StackedReadout.image(columns: columns, config: config, height: NSStatusBar.system.thickness)
            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(config.name + ".png"))
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store.sprites).write(to: directory.appendingPathComponent("active-sprites.json"))
        try encoder.encode(store.readings).write(to: directory.appendingPathComponent("readings.json"))
        let before = usage(), start = Date()
        try await Task.sleep(for: .seconds(15))
        let after = usage(), seconds = Date().timeIntervalSince(start)
        measurements = [["phase": "five-readouts-settings-closed", "seconds": seconds, "physicalFootprintMiB": after.footprint, "residentMiB": after.rss, "cpuPercentOneCore": (after.cpu - before.cpu) / seconds * 100]]
        check("No process-list collectors opened", store.sprites.allSatisfy { app.spriteMenuBar?.memoryBoardStoreForValidation($0.id) == nil })
        try report()
    }
    func usage() -> (rss: Double, footprint: Double, cpu: Double) {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return (status == KERN_SUCCESS ? Double(info.resident_size)/1048576 : -1, status == KERN_SUCCESS ? Double(info.phys_footprint)/1048576 : -1, Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)/1e6)
    }
    func report() throws {
        let body: [String: Any] = ["bundle": Bundle.main.bundlePath, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "checks": checks, "measurements": measurements,
                                  "note": "Installed signed app and actual saved configuration. Images use the live native menu-bar renderer, not a screen capture. No fan-control or permission writes. Resource sample with settings/panels closed and CPU/RAM/PWR/Network/Fan+CPU-temperature at 2s."]
        try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
    }
}
