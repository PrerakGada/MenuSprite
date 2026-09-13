import AppKit
import SystemMonitoring

@MainActor
final class MemoryValidation {
    let app: AppDelegate
    let directory: URL
    var checks: [[String: Any]] = []
    var measurements: [[String: Any]] = []
    init(app: AppDelegate, directory: URL) { self.app = app; self.directory = directory }
    func start() {
        Task {
            do { try await run() }
            catch { checks.append(["name": "Completed memory validation", "passed": false, "error": error.localizedDescription]); try? report() }
            app.finishHeadlessMeasurement()
            app.spriteMenuBar?.closeBoardsForValidation()
            if let ram = app.monitoringStore.sprites.first(where: \.isMemoryBoard) { _ = app.spriteMenuBar?.openBoardForValidation(ram.id) }
        }
    }
    func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]) }
    func pause(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
    func run() async throws {
        let initialDemand = app.monitoringStore.requestedMetricCount
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let sprite = app.monitoringStore.sprites.first(where: { $0.isMemoryBoard && $0.enabled && $0.showInMenuBar }) else { throw CocoaError(.validationMissingMandatoryProperty) }
        check("No process collector before opening RAM", app.spriteMenuBar?.memoryBoardStoreForValidation(sprite.id) == nil)
        try await pause(3)
        try await measure("three-readouts-memory-panel-closed", seconds: 20)
        var boardView = app.spriteMenuBar?.openBoardForValidation(sprite.id)
        guard boardView != nil else { throw CocoaError(.validationMissingMandatoryProperty) }
        var board: MemoryBoardStore? = app.spriteMenuBar?.memoryBoardStoreForValidation(sprite.id)
        check("RAM opens the specialized Memory panel", board != nil)
        try await pause(3)
        guard let result = board?.snapshot else { throw CocoaError(.coderReadCorrupt) }
        check("Native process snapshot is populated", result.readableCount > 0 && !result.consumers.isEmpty && result.error == nil)
        check("Consumers ranked descending", zip(result.consumers, result.consumers.dropFirst()).allSatisfy { $0.bytes >= $1.bytes })
        let records = result.consumers.flatMap(\.processes)
        let contextual = result.consumers.filter { $0.bundlePath == nil && $0.processes.contains { $0.context?.workingDirectory != nil } }
        check("Native runtime working directories available", !contextual.isEmpty)
        check("Runtime context is visible and keeps a PID", contextual.allSatisfy { $0.presentation.subtitle?.contains("PID ") == true })
        check("Context labels do not change group identifiers", result.consumers.allSatisfy { !$0.id.isEmpty && !$0.presentation.title.isEmpty })
        let vms = result.consumers.filter { $0.processes.contains { ProcessPresentation.isVirtualMachine($0.executablePath) } }
        check("VM host labels require resource evidence", vms.allSatisfy { c in c.presentation.title == "Virtual machine service" || c.processes.contains { $0.context?.evidencePath != nil } })
        check("Each readable PID attributed exactly once", Set(records.map(\.pid)).count == records.count && records.count == result.readableCount)
        check("App totals equal their member footprints", result.consumers.allSatisfy { $0.bytes == $0.processes.reduce(0) { $0 + $1.bytes } })
        check("This native app is included", records.contains { $0.pid == ProcessInfo.processInfo.processIdentifier && $0.bytes > 0 })
        let keys = MemoryBoard.metricIDs
        check("Complete memory breakdown has live values", keys.allSatisfy { app.monitoringStore.readings[$0]?.available == true })
        let used = app.monitoringStore.readings["memory.used"]?.number ?? -1
        let total = app.monitoringStore.readings["memory.total"]?.number ?? -1
        let appMemory = app.monitoringStore.readings["memory.app"]?.number ?? -1
        let wired = app.monitoringStore.readings["memory.wired"]?.number ?? -1
        let compressed = app.monitoringStore.readings["memory.compressed"]?.number ?? -1
        check("Memory breakdown agrees with shared sampler", used > 0 && total >= used && abs(used - appMemory - wired - compressed) < 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: directory.appendingPathComponent("process-memory.json"))
        let labels = result.consumers.map { c in ["title": c.presentation.title, "subtitle": c.presentation.subtitle ?? "", "evidence": c.presentation.explanation, "id": c.id] }
        try JSONSerialization.data(withJSONObject: labels, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("process-labels.json"))
        try encoder.encode(app.monitoringStore.readings.filter { keys.contains($0.key) }).write(to: directory.appendingPathComponent("memory-readings.json"))
        let before = board?.sampleCount ?? 0
        try await measure("memory-panel-open-app-list-5s", seconds: 20)
        check("App list refreshes while open", (board?.sampleCount ?? 0) > before)
        try snapshot(boardView!, "memory-panel")
        boardView = nil
        weak let released = board
        app.spriteMenuBar?.closeBoardsForValidation()
        check("Closing stops the process collector", board?.isRunning == false)
        check("Closing clears process data and icons", board?.snapshot == nil && board?.icons.isEmpty == true)
        board = nil
        try await pause(1)
        check("Closed board collector is released", released == nil)
        check("Additional memory-board demand removed", app.monitoringStore.requestedMetricCount == initialDemand)
        try await measure("three-readouts-after-memory-panel-close", seconds: 20)
        for _ in 0..<3 {
            _ = app.spriteMenuBar?.openBoardForValidation(sprite.id); try await pause(0.4)
            app.spriteMenuBar?.closeBoardsForValidation(); try await pause(0.3)
        }
        check("Repeated open/close leaves no collector", app.spriteMenuBar?.memoryBoardStoreForValidation(sprite.id) == nil)
        _ = app.spriteMenuBar?.openBoardForValidation(sprite.id); try await pause(0.4)
        app.closeFrontWindow(); try await pause(0.3)
        check("Command-W path closes Memory and releases its collector", app.spriteMenuBar?.memoryBoardStoreForValidation(sprite.id) == nil)
        try report()
    }
    func snapshot(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
    func usage() -> (rss: Double, footprint: Double, cpu: Double) {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return (status == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : -1, status == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1,
                Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6)
    }
    func measure(_ name: String, seconds: Double) async throws {
        let before = usage(), start = Date(); try await pause(seconds); let after = usage(), elapsed = Date().timeIntervalSince(start)
        measurements.append(["phase": name, "seconds": elapsed, "physicalFootprintMiB": after.footprint, "residentMiB": after.rss, "cpuPercentOneCore": (after.cpu - before.cpu) / elapsed * 100])
        try report()
    }
    func report() throws {
        let body: [String: Any] = ["bundle": Bundle.main.bundlePath, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "checks": checks, "measurements": measurements,
                                  "note": "Installed signed app with actual saved readouts. Process accounting through libproc, no root/helper or permissions prompt. Render is MenuSprite's own native view. Post-close memory includes warmed UI caches; short samples are not an overnight benchmark."]
        try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
    }
}
