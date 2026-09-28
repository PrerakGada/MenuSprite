import AppKit
import SystemMonitoring

@MainActor
final class ProcessPanelValidation {
    let app: AppDelegate
    let directory: URL
    var checks: [[String: Any]] = []
    var measurements: [[String: Any]] = []
    init(app: AppDelegate, directory: URL) { self.app = app; self.directory = directory }
    func start() {
        Task {
            do { try await run() }
            catch { check("Completed validation: \(error.localizedDescription)", false); try? report() }
            app.finishHeadlessMeasurement(); app.spriteMenuBar?.closeBoardsForValidation()
            if let cpu = app.monitoringStore.sprites.first(where: { $0.processPanelKind == .cpu }) { _ = app.spriteMenuBar?.openBoardForValidation(cpu.id) }
        }
    }
    func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]) }
    func pause(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
    func run() async throws {
        let initialDemand = app.monitoringStore.requestedMetricCount
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await pause(3)
        try await measure("all-process-panels-closed", seconds: 15)
        for kind in [ProcessPanelKind.cpu, .power, .memory] {
            guard let sprite = app.monitoringStore.sprites.first(where: { $0.processPanelKind == kind && $0.enabled && $0.showInMenuBar }) else { throw CocoaError(.validationMissingMandatoryProperty) }
            var view = app.spriteMenuBar?.openBoardForValidation(sprite.id)
            var board = app.spriteMenuBar?.memoryBoardStoreForValidation(sprite.id)
            check("\(kind.title): correct native panel", view != nil && board?.kind == kind)
            // Wait for the first real sample rather than assuming it lands inside a
            // fixed pause: a full process scan runs long on a loaded Mac, and a slow
            // first sample is not a failure of what this harness checks.
            for _ in 0..<40 where board?.snapshot == nil || board?.ranked.isEmpty != false { try await pause(0.5) }
            guard let snapshot = board?.snapshot, let ranked = board?.ranked, !ranked.isEmpty else { throw CocoaError(.coderReadCorrupt) }
            check("\(kind.title): live ranked rows", !ranked.isEmpty && ranked.contains { $0.value > 0 })
            check("\(kind.title): descending and finite", zip(ranked, ranked.dropFirst()).allSatisfy { $0.value >= $1.value } && ranked.allSatisfy { $0.value.isFinite && $0.value >= 0 })
            check("\(kind.title): aggregate equals member readings", ranked.allSatisfy { abs($0.value - $0.processValues.values.reduce(0, +)) < 0.00001 })
            let pids = ranked.flatMap { $0.processValues.keys }
            check("\(kind.title): no duplicate PID attribution", Set(pids).count == pids.count)
            check("\(kind.title): real summary", app.monitoringStore.readings[kind.summaryID]?.available == true)
            if kind == .power {
                check("Power: energy support observed in native app", board?.energyObserved == true && snapshot.consumers.flatMap(\.processes).contains { ($0.energyNanojoules ?? 0) > 0 })
                check("Power: CPU-only scope visible", kind.listTitle.contains("CPU power") && ProcessBoardContent(kind: kind, monitoring: app.monitoringStore, processes: board!).explanation.contains("CPU-only"))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: directory.appendingPathComponent("\(kind.rawValue)-source.json"))
            let rows = ranked.map { row -> [String: Any] in ["name": row.consumer.name, "value": row.value, "missing": row.missingCount, "pidValues": Dictionary(uniqueKeysWithValues: row.processValues.map { (String($0.key), $0.value) })] }
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("\(kind.rawValue)-ranked.json"))
            let before = board?.sampleCount ?? 0
            if kind != .memory { try await measure("\(kind.rawValue)-panel-open", seconds: 15) }
            else { try await pause(1) }
            if kind != .memory { check("\(kind.title): ongoing refresh", (board?.sampleCount ?? 0) > before) }
            // A quit request cuts the interval short so a row that went actually
            // leaves the list at once; without it the row lingers up to 5 seconds
            // and a successful quit reads as a click that did nothing.
            let beforeResample = board?.sampleCount ?? 0
            board?.resample()
            try await pause(1.2)
            check("\(kind.title): a quit request resamples within a second", (board?.sampleCount ?? 0) > beforeResample)
            if let view { checkQuitControls(in: view, kind: kind, ranked: board?.ranked ?? ranked) }
            if let view { try render(view, name: kind.rawValue) }
            view = nil
            weak let released = board
            app.closeFrontWindow()
            check("\(kind.title): close stops collector", board?.isRunning == false && board?.ranked.isEmpty == true)
            board = nil; try await pause(0.5)
            check("\(kind.title): closed collector released", released == nil)
        }
        verifyCPUTimebase()
        check("Panel-only demand removed", app.monitoringStore.requestedMetricCount == initialDemand)
        try await measure("after-closing-all-panels", seconds: 15)
        try report()
    }
    private func verifyCPUTimebase() {
        var raw = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &raw) { p in p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let converted = Double(raw.ri_user_time + raw.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        check("Mach CPU ticks agree with independent getrusage seconds", status == 0 && abs(converted - cpu) < max(0.05, cpu * 0.1))
    }
    private func render(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-panel.png"))
        // The panel only shows what fits; the scrolling document carries the whole
        // process list, including rows and row controls below the fold.
        if let document = scrollDocument(in: view) {
            document.layoutSubtreeIfNeeded(); document.displayIfNeeded()
            guard let full = document.bitmapImageRepForCachingDisplay(in: document.bounds) else { return }
            document.cacheDisplay(in: document.bounds, to: full)
            try full.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-list.png"))
        }
    }
    /// The row buttons act immediately, so the binding between a button and the
    /// row drawn beside it is checked in the real panel, not only in tests.
    private func checkQuitControls(in view: NSView, kind: ProcessPanelKind, ranked: [ProcessConsumerRate]) {
        guard let document = scrollDocument(in: view) else { return check("\(kind.title): quit controls reachable", false) }
        let buttons = document.subviews.compactMap { $0 as? NSButton }.filter {
            !$0.isHidden && (($0.accessibilityLabel() ?? "").hasPrefix("Quit ") || ($0.accessibilityLabel() ?? "").hasPrefix("Force quit ")
                             || ($0.accessibilityLabel() ?? "").contains("does not permit quitting"))
        }
        let rows = Array(ranked.prefix(30))
        check("\(kind.title): one quit control per listed row", !buttons.isEmpty && buttons.count == rows.count)
        check("\(kind.title): each quit control names the row it sits on",
              zip(buttons, rows).allSatisfy { ($0.0.accessibilityLabel() ?? "").contains($0.1.consumer.presentation.title) })
        check("\(kind.title): quit is offered only for rows this user owns",
              zip(buttons, rows).allSatisfy { $0.0.isEnabled == ProcessTermination.plan(for: $0.1.consumer).canQuit })
        check("\(kind.title): quit controls sit beside their row, inside the list",
              zip(buttons, rows).allSatisfy { $0.0.frame.maxX <= document.bounds.width && $0.0.frame.minX > document.bounds.width / 2 })
    }
    private func scrollDocument(in view: NSView) -> NSView? {
        if let scroll = view as? NSScrollView { return scroll.documentView }
        for subview in view.subviews { if let found = scrollDocument(in: subview) { return found } }
        return nil
    }
    private func usage() -> (rss: Double, footprint: Double, cpu: Double) {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return (status == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : -1, status == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1, Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6)
    }
    private func measure(_ phase: String, seconds: Double) async throws {
        let before = usage(), start = Date(); try await pause(seconds); let after = usage(), duration = Date().timeIntervalSince(start)
        measurements.append(["phase": phase, "seconds": duration, "physicalFootprintMiB": after.footprint, "residentMiB": after.rss, "cpuPercentOneCore": (after.cpu - before.cpu) / duration * 100])
        try report()
    }
    private func report() throws {
        let result: [String: Any] = ["bundle": Bundle.main.bundlePath, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "checks": checks, "measurements": measurements,
                                   "note": "Installed signed app with actual saved CPU/RAM/PWR. Process panels only while open; no helper or permission request. CPU percent uses one-core convention. App power is CPU-energy-derived only. Open measurements precede each panel's native diagnostic render; later phases include warmed caches."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
    }
}
