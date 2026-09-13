import AppKit
import Darwin
import SystemMonitoring

/// Explicit local acceptance mode with an isolated configuration file. Ordinary
/// launches never run this harness or its measurement sleeps/snapshot exports.
@MainActor
final class MonitoringValidation {
    private unowned let app: AppDelegate
    private let directory: URL
    private let measurementsOnly: Bool
    private var checks: [String: Bool] = [:]
    private var samples: [[String: Any]] = []
    init(app: AppDelegate, directory: URL, measurementsOnly: Bool = false) {
        self.app = app; self.directory = directory; self.measurementsOnly = measurementsOnly
    }
    func start() {
        Task {
            do { try await run() }
            catch {
                try? String(describing: error).write(to: directory.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
                app.finishHeadlessMeasurement()
                app.showMonitoring()
            }
        }
    }
    private func pause(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
    private func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = app.monitoringStore!
        if measurementsOnly { try await measureWithoutUI(); return }
        app.showMonitoring()
        for _ in 0..<100 {
            if !store.discoveringSensors { break }
            try await pause(0.1)
        }
        try await pause(2.5)
        _ = await store.sampleAllForValidation()
        try await pause(1)
        let all = await store.sampleAllForValidation()
        checks["installedBundle"] = Bundle.main.bundlePath == NSHomeDirectory() + "/Applications/MenuSprite.app"
        checks["identity"] = Bundle.main.bundleIdentifier == "in.prerakgada.MenuSprite"
        checks["permissionPageNotOpened"] = app.permissionStore == nil
        checks["catalogUnique"] = Set(store.catalog.map(\.id)).count == store.catalog.count
        checks["allBaseReadingsPresent"] = Set(MonitoringCatalog.base.map(\.id)).isSubset(of: Set(store.catalog.map(\.id)))
        checks["cpuInRange"] = (0...100).contains(store.readings["cpu.usage"]?.number ?? -1)
        checks["memoryInRange"] = (0...100).contains(store.readings["memory.usage"]?.number ?? -1)
        checks["networkInterval"] = store.readings["network.download"]?.number != nil
        checks["noInvalidNumbers"] = all.readings.values.allSatisfy { $0.number?.isFinite ?? true }
        checks["diskCapacity"] = (store.readings["disk.total"]?.number ?? 0) > (store.readings["disk.used"]?.number ?? 0)
        checks["hardwareSensorsDiscovered"] = store.catalog.contains { $0.id == "sensor.F0Ac" }
        checks["systemPowerReported"] = (store.readings["sensor.PSTR"]?.number ?? -1) > 0
        checks["cpuTemperatureReported"] = (store.readings["sensor.cpuTemperature"]?.number ?? -1) > 0
        try snapshot("01-monitoring", view: app.monitoringWindow?.contentView)

        var custom = SpriteConfiguration(name: "Review sprite", symbol: "network", metricIDs: ["network.download", "network.upload"])
        custom.fontSize = 14; custom.bold = true; custom.colorHex = "78DFBD"; custom.interval = 5
        custom.showLabels = false; custom.networkBits = true
        store.save(custom)
        let restored = MonitoringStore(configurationURL: directory.appendingPathComponent("test-config.json"))
        checks["configurationRoundTrip"] = restored.sprites.contains(custom)
        checks["twoNativeStatusItems"] = app.spriteMenuBar?.itemCount == 2
        try await checkSavedSensorColdStart()
        store.edit(custom)
        try await pause(0.7)
        try snapshot("02-sprite-editor", view: app.monitoringWindow?.sheets.first?.contentView)
        store.isShowingEditor = false
        try await pause(0.5)
        try await checkBoard(custom.id)
        app.closeMonitoring()
        try await pause(0.5)
        checks["monitoringWindowReleased"] = app.monitoringWindow == nil && !store.libraryOpen

        custom.showInMenuBar = false; custom.enabled = true
        store.replaceForValidation([custom])
        try await pause(0.5)
        checks["hiddenStillEnabled"] = store.isSampling && app.spriteMenuBar?.itemCount == 0
        custom.showInMenuBar = true; custom.enabled = false
        store.replaceForValidation([custom])
        try await pause(0.5)
        let stoppedCount = store.sampleCount
        try await pause(2.5)
        checks["disabledStopsSampling"] = !store.isSampling && store.sampleCount == stoppedCount
        checks["disabledCanRemainVisible"] = app.spriteMenuBar?.itemCount == 1
        try await measure("all-sprites-paused-window-closed", seconds: 30)

        let system = SpriteConfiguration(name: "System", symbol: "cpu", metricIDs: ["cpu.usage", "memory.usage"])
        store.replaceForValidation([system])
        try await pause(4.5)
        checks["reenableReprimesCounters"] = store.readings["cpu.usage"]?.available == true
        try await measure("cpu-memory-sprite-2s-window-closed", seconds: 30)

        var broad = SpriteConfiguration(name: "Full monitor", symbol: "gauge.with.dots.needle.50percent", metricIDs: ["cpu.usage", "memory.usage", "network.download", "network.upload", "gpu.usage", "disk.read", "sensor.PSTR", "sensor.cpuTemperature"])
        broad.showInMenuBar = false // sample broad load without crowding the real menu bar
        store.replaceForValidation([broad])
        try await pause(4.5)
        try await measure("eight-readings-2s-window-closed", seconds: 30)

        store.suspend()
        try await pause(0.3)
        checks["sleepCallbackStopsSampling"] = !store.isSampling
        store.resume()
        try await pause(4.5)
        checks["wakeCallbackResumes"] = store.isSampling && store.readings["cpu.usage"]?.available == true
        checks["historyIsBounded"] = store.history.values.allSatisfy { $0.count <= 60 }

        store.replaceForValidation([system])
        for _ in 0..<5 {
            app.showMonitoring(); try await pause(0.35)
            app.closeMonitoring(); try await pause(0.35)
        }
        try await pause(3)
        try await measure("closed-after-five-window-cycles", seconds: 30)
        app.showMonitoring()
        try await pause(2.5)
        try snapshot("03-ready", view: app.monitoringWindow?.contentView)
        try writeReadings()
        try report()
        guard checks.values.allSatisfy({ $0 }) else {
            throw NSError(domain: "MonitoringValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed: \(checks.filter { !$0.value }.keys.sorted().joined(separator: ", "))"])
        }
        try "Passed. Configuration isolated from normal user sprites.\n".write(to: directory.appendingPathComponent("complete.txt"), atomically: true, encoding: .utf8)
    }
    private func checkBoard(_ id: UUID) async throws {
        let board = app.spriteMenuBar?.openBoardForValidation(id)
        try await pause(0.4)
        checks["nativeReadoutOpensBoard"] = board != nil
        try snapshot("02b-menu-board", view: board)
        app.spriteMenuBar?.closeBoardsForValidation()
    }
    private func measureWithoutUI() async throws {
        let store = app.monitoringStore!
        var system = SpriteConfiguration(name: "System", symbol: "cpu", metricIDs: ["cpu.usage", "memory.usage"])
        system.enabled = false
        store.replaceForValidation([system])
        try await pause(4)
        checks["windowNeverOpened"] = app.monitoringWindow == nil && app.settingsWindow == nil
        checks["samplingStopped"] = !store.isSampling
        let pausedCount = store.sampleCount
        try await measure("fresh-host-all-paused", seconds: 30)
        checks["pausedSampleCountUnchanged"] = pausedCount == store.sampleCount
        system.enabled = true
        store.replaceForValidation([system])
        try await pause(4.5)
        try await measure("fresh-host-cpu-memory-2s", seconds: 30)
        let broad = SpriteConfiguration(name: "Full monitor", symbol: "gauge.with.dots.needle.50percent", metricIDs: ["cpu.usage", "memory.usage", "network.download", "network.upload", "gpu.usage", "disk.read", "sensor.PSTR", "sensor.cpuTemperature"])
        store.replaceForValidation([broad])
        try await pause(4.5)
        try await measure("fresh-host-eight-readings-2s", seconds: 30)
        checks["eightLiveReadings"] = broad.metricIDs.allSatisfy { store.readings[$0]?.available == true }
        checks["noCatalogWindowDiscovery"] = !store.catalog.contains { $0.id == "sensor.F0Ac" }
        store.replaceForValidation([system])
        try writeReadings(); try report()
        guard checks.values.allSatisfy({ $0 }) else { throw CocoaError(.validationMissingMandatoryProperty) }
        try "Passed. Fresh resident host, no windows or snapshot rendering.\n".write(to: directory.appendingPathComponent("complete.txt"), atomically: true, encoding: .utf8)
        app.finishHeadlessMeasurement()
    }
    private func checkSavedSensorColdStart() async throws {
        let probeURL = directory.appendingPathComponent("sensor-config.json")
        let fan = SpriteConfiguration(name: "Persisted fan", symbol: "fan", metricIDs: ["sensor.F0Ac"])
        let writer = MonitoringStore(configurationURL: probeURL)
        writer.setLibraryOpen(true)
        for _ in 0..<100 {
            if !writer.discoveringSensors { break }
            try await pause(0.1)
        }
        writer.replaceForValidation([fan]); writer.setLibraryOpen(false); writer.stop()
        let reader = MonitoringStore(configurationURL: probeURL)
        checks["savedSensorMetadata"] = reader.metric("sensor.F0Ac").unit == .rpm
        reader.start()
        try await pause(2.5)
        checks["savedSensorRunsWithoutWindow"] = !reader.libraryOpen && reader.readings["sensor.F0Ac"]?.available == true
        reader.stop()
    }
    private func snapshot(_ name: String, view: NSView?) throws {
        guard let view else { return }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }
    private func usage() -> (rss: Double, footprint: Double, cpu: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return (status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1,
                status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1, cpu)
    }
    private func measure(_ phase: String, seconds: Double) async throws {
        let before = usage(); let start = Date()
        let samplesBefore = app.monitoringStore.sampleCount
        try await pause(seconds)
        let after = usage(); let elapsed = Date().timeIntervalSince(start)
        samples.append(["phase": phase, "seconds": elapsed, "residentMiB": after.rss, "physicalFootprintMiB": after.footprint,
                        "cpuPercentOneCore": (after.cpu - before.cpu) / elapsed * 100, "sampleCount": app.monitoringStore.sampleCount,
                        "samplesDuringPhase": app.monitoringStore.sampleCount - samplesBefore,
                        "libraryOpenAtEnd": app.monitoringStore.libraryOpen,
                        "requestedReadingsAtEnd": app.monitoringStore.requestedMetricCount])
        try report()
    }
    private func writeReadings() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(app.monitoringStore.readings).write(to: directory.appendingPathComponent("readings.json"))
        try encoder.encode(app.monitoringStore.catalog).write(to: directory.appendingPathComponent("catalog.json"))
    }
    private func report() throws {
        let body: [String: Any] = ["bundlePath": Bundle.main.bundlePath, "bundleID": Bundle.main.bundleIdentifier ?? "", "pid": ProcessInfo.processInfo.processIdentifier,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "checks": checks, "samples": samples,
            "catalogCount": app.monitoringStore.catalog.count, "note": measurementsOnly
                ? "Installed release app, fresh resident host, isolated config, no window/editor/board opening or diagnostic screenshots. TASK_VM_INFO and getrusage. No helpers or permission requests."
                : "Installed release app; isolated config; native view rendering before measurements can warm caches. TASK_VM_INFO and getrusage. No helpers, capture or permission requests. Sleep/wake callbacks are simulated; no actual system sleep was forced."]
        try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
    }
}
