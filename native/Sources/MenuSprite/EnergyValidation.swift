import AppKit
import PowerControl

import SystemMonitoring

/// Explicit native validation only. Uses isolated preferences/configuration and
/// never enables charge controls, installs helpers, or changes AlDente settings.
@MainActor
final class EnergyValidation {
    let app: AppDelegate
    let directory: URL
    private var checks: [[String: Any]] = []
    private var measurements: [[String: Any]] = []
    init(app: AppDelegate, directory: URL) { self.app = app; self.directory = directory }
    func start() {
        Task {
            do { try await run() }
            catch { check("Validation completed: \(error.localizedDescription)", false); try? report() }
            app.spriteMenuBar?.closeBoardsForValidation(); NSApp.terminate(nil)
        }
    }
    private func check(_ name: String, _ pass: Bool) { checks.append(["name": name, "passed": pass]) }
    private func pause(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
    private func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await pause(3)
        let baseline = app.monitoringStore.requestedMetricCount
        check("Correct native app identity", Bundle.main.bundleIdentifier == "in.prerakgada.MenuSprite" && Bundle.main.bundlePath.hasSuffix(".app"))
        check("Battery controls off before opening", app.powerStore.snapshot.mode == .off && app.powerStore.assertionIDs.isEmpty)
        try await measure("closed-fresh", seconds: 12)
        guard let config = app.monitoringStore.sprites.first(where: { $0.processPanelKind == .power }) else { throw CocoaError(.validationMissingMandatoryProperty) }
        NSApp.activate(ignoringOtherApps: true)
        _ = app.spriteMenuBar?.openBoardForValidation(config.id)
        var board = app.spriteMenuBar?.energyBoardForValidation(config.id)
        let reverse = CommandLine.arguments.contains("--energy-reverse")
        board?.forceReducedMotion = reverse
        try await pause(4)
        var process = app.spriteMenuBar?.memoryBoardStoreForValidation(config.id)
        check("Power opens the native energy dashboard", board != nil && board?.view.window?.isVisible == true)
        guard board?.view.window?.isVisible == true else { throw PowerFailure("Dashboard closed during validation") }
        check("Panel acquires one battery status observer", app.powerStore.batteryObserverCount == 1)
        check("Extra readings requested only for open panel", app.monitoringStore.requestedMetricCount > baseline)
        check("Battery control remains off after opening", app.powerStore.snapshot.mode == .off && app.powerStore.assertionIDs.isEmpty)
        if !app.powerStore.helperInstalled || app.powerStore.batteryConflict != nil {
            check("Control actions blocked with an honest reason", board?.controlActionsEnabled == false && app.powerStore.batteryControlReason != nil)
        }
        let readings = app.monitoringStore.readings
        let flow = EnergyFlow(readings: readings)
        check("Real system power available", flow.system != nil)
        check("Real battery level and temperature available", flow.charge != nil && flow.temperature != nil)
        check("Measured values are used directly", flow.system == readings["sensor.PSTR"]?.number && flow.adapter == readings["sensor.PDTR"]?.number && flow.battery == readings["battery.power"]?.number)
        if let adapter = flow.adapter, let system = flow.system, let battery = flow.battery, let difference = flow.difference {
            check("Difference is explicit measured residual", abs(difference - (adapter - system - battery)) < 0.00001)
        }
        check("Live accessible CPU energy ranking", process?.ranked.contains { $0.value > 0 } == true)
        check("Animation runs only for observed flow", reverse || !flow.hasLiveFlow || board?.isAnimating == true || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        try await measure(reverse ? "dashboard-reduced-first" : "dashboard-visible-motion", seconds: 15)
        board?.forceReducedMotion = !reverse
        try await pause(0.5)
        check("Motion preference changes animation state", reverse ? (board?.isAnimating == true || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) : board?.isAnimating == false)
        try await measure(reverse ? "dashboard-motion-after-warmup" : "dashboard-reduced-motion", seconds: 10)
        board?.forceReducedMotion = true
        if let board {
            board.view.window?.appearance = NSAppearance(named: .darkAqua)
            board.document.updateLayers(); board.document.needsDisplay = true
            try await pause(0.3); try render(board.view, name: "energy-dark")
            board.view.window?.appearance = NSAppearance(named: .aqua)
            board.document.updateLayers(); board.document.needsDisplay = true
            try await pause(0.3); try render(board.view, name: "energy-light")
            board.view.window?.appearance = nil
            board.expandLimitForValidation(); try await pause(0.2); try render(board.view, name: "energy-limit")
        }
        let count = process?.sampleCount ?? 0
        board?.refreshForValidation()
        for _ in 0..<30 { if (process?.sampleCount ?? 0) > count { break }; try await pause(0.2) }
        check("Explicit Refresh updates processes", (process?.sampleCount ?? 0) > count)
        weak var weakBoard = board
        weak var weakProcess = process
        app.spriteMenuBar?.closeBoardsForValidation()
        check("Close stops animations and collector", board?.isStopped == true && board?.isAnimating == false && process?.isRunning == false)
        board = nil; process = nil
        try await pause(0.7)
        check("Closed dashboard and process store released", weakBoard == nil && weakProcess == nil)
        check("Panel-only demand removed", app.monitoringStore.requestedMetricCount == baseline)
        check("Battery observer released", app.powerStore.batteryObserverCount == 0)
        try await measure("closed-after-review", seconds: 12)
        for kind in [ProcessPanelKind.memory, .cpu] {
            if let config = app.monitoringStore.sprites.first(where: { $0.processPanelKind == kind }) {
                let view = app.spriteMenuBar?.openBoardForValidation(config.id)
                check("\(kind.title) panel still opens", view != nil)
                app.spriteMenuBar?.closeBoardsForValidation()
            }
        }
        try JSONEncoder().encode(readings.filter { ProcessPanelKind.power.metricIDs.contains($0.key) }).write(to: directory.appendingPathComponent("readings.json"))
        try report()
    }
    private func render(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
    private func usage() -> (rss: Double, footprint: Double, cpu: Double) {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return (status == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : -1, status == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1, Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6)
    }
    private func measure(_ name: String, seconds: Double) async throws {
        let before = usage(), start = Date(); try await pause(seconds); let after = usage()
        measurements.append(["phase": name, "seconds": Date().timeIntervalSince(start), "residentMiB": after.rss, "physicalFootprintMiB": after.footprint, "cpuPercentOneCore": (after.cpu - before.cpu) / Date().timeIntervalSince(start) * 100])
        try report()
    }
    private func report() throws {
        let result: [String: Any] = ["bundle": Bundle.main.bundlePath, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "checks": checks, "measurements": measurements,
            "note": "Actual native app and sensor/process readings; isolated monitoring configuration and power preferences. The explicit diagnostic pins its panel during measurement; normal panels dismiss on outside interaction. No helper installation, battery control, sleep override or permission request. AlDente left running. Core Animation compositor work is not included in this process's CPU measurement."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
    }
}
