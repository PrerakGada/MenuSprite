import AppKit
import SystemMonitoring

/// Exercises the hub in the installed app: the brand item's own click opens it, every tab renders
/// with live readings, only the visible tab's readings are requested, and closing releases
/// everything the tabs started. Evidence is written only to the directory passed on the command line.
@MainActor
final class HubValidation {
    let app: AppDelegate
    let directory: URL
    var checks: [[String: Any]] = []
    var measurements: [[String: Any]] = []
    init(app: AppDelegate, directory: URL) { self.app = app; self.directory = directory }

    func start() {
        Task {
            do { try await run() }
            catch {
                checks.append(["name": "Completed hub validation", "passed": false, "error": error.localizedDescription])
                try? report()
            }
            app.hub?.close()
            app.finishHeadlessMeasurement()
        }
    }

    private func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]) }
    private func pause(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    private func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let hub = app.hub else { throw CocoaError(.validationMissingMandatoryProperty) }
        let baseline = app.monitoringStore.requestedMetricCount
        try await pause(2)
        try await measure("hub-closed", seconds: 12)

        // The real interaction: a plain click on the brand status item, not a private entry point.
        check("Hub is closed before the brand item is clicked", !hub.isVisible)
        app.clickBrandItemForValidation()
        try await pause(1.2)
        check("Clicking the brand item opens the hub", hub.isVisible)
        check("Hub opens on a real panel with content", hub.contentView != nil)

        var perTab: [[String: Any]] = []
        for tab in HubTab.available {
            app.showHubTabForValidation(tab)
            try await pause(tab == .ai ? 4 : 2.5)
            check("\(tab.title) tab is selected", hub.selectedTab == tab)
            let requested = Set(app.monitoringStore.requestedHubMetricsForValidation)
            check("\(tab.title) requests only its own readings", requested == Set(tab.metricIDs))
            let available = tab.metricIDs.filter { app.monitoringStore.readings[$0]?.available == true }
            // Sensors are hardware-dependent, so the bar is that the tab's readings arrive at all,
            // not that every one of them exists on this Mac.
            if !tab.metricIDs.isEmpty {
                check("\(tab.title) tab shows live readings", !available.isEmpty)
            }
            let ranking = app.hubProcessKindForValidation
            check("\(tab.title) runs a process collector only where it is shown",
                  (tab == .apps || tab == .power) == (ranking != nil))
            if let view = hub.contentView { try snapshot(view, "hub-\(tab.rawValue)") }
            if tab == .ai, let accounts = app.accountsStore, let window = hub.panelWindow {
                check("AI tab schedules its next reload while open", accounts.nextReloadAt != nil)
                let before = accounts.reloadRequests
                // A real key event through the application's dispatch, the path a pressed ⌘R takes.
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: "r",
                                                charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15) {
                    window.makeKey()
                    NSApp.sendEvent(event)
                }
                check("Command-R on the AI tab reloads usage", accounts.reloadRequests == before + 1)
                try await pause(5)
                check("Usage finishes loading after Command-R", !accounts.isLoadingUsage && accounts.lastReloadAt != nil)
                check("Command-R leaves the hub open", hub.isVisible)
            }
            perTab.append(["tab": tab.rawValue, "requested": requested.sorted(),
                           "availableReadings": available.count, "ofRequested": tab.metricIDs.count,
                           "processCollector": ranking?.rawValue ?? "none"])
        }
        try JSONSerialization.data(withJSONObject: perTab, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("hub-tabs.json"))

        app.showHubTabForValidation(.apps)
        try await pause(6)
        try await measure("hub-open-apps-tab", seconds: 15)
        app.showHubTabForValidation(.system)
        try await pause(3)
        try await measure("hub-open-system-tab", seconds: 15)

        // A second click on the brand item closes it again, the way a menu-bar panel should behave.
        // Recorded first: an outside click or app switch during the run closes the hub by design,
        // and the closing click would then reopen it.
        check("Hub is still open before the closing click", hub.isVisible)
        app.clickBrandItemForValidation()
        try await pause(1)
        check("Clicking the brand item again closes the hub", !hub.isVisible)
        check("Closing releases the process collector", app.hubProcessKindForValidation == nil)
        check("Closing removes every hub reading request", app.monitoringStore.requestedHubMetricsForValidation.isEmpty)
        check("Closing stops the AI board's auto-reload", app.accountsStore?.nextReloadAt == nil)
        try await pause(1)
        check("Demand returns to what the menu bar alone needs", app.monitoringStore.requestedMetricCount <= baseline)
        try await measure("hub-closed-again", seconds: 12)

        for _ in 0..<3 {
            app.clickBrandItemForValidation(); try await pause(0.6)
            app.clickBrandItemForValidation(); try await pause(0.4)
        }
        check("Repeated open and close leaves nothing running",
              !hub.isVisible && app.hubProcessKindForValidation == nil
              && app.monitoringStore.requestedHubMetricsForValidation.isEmpty)
        app.clickBrandItemForValidation(); try await pause(0.6)
        app.closeFrontWindow(); try await pause(0.4)
        check("Command-W closes the hub", !hub.isVisible)
        try report()
    }

    private func snapshot(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
    private func usage() -> (rss: Double, footprint: Double, cpu: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return (status == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : -1,
                status == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1,
                Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6)
    }
    private func measure(_ name: String, seconds: Double) async throws {
        let before = usage(), start = Date()
        try await pause(seconds)
        let after = usage(), elapsed = Date().timeIntervalSince(start)
        measurements.append(["phase": name, "seconds": elapsed, "physicalFootprintMiB": after.footprint,
                             "residentMiB": after.rss, "cpuPercentOneCore": (after.cpu - before.cpu) / elapsed * 100])
        try report()
    }
    private func report() throws {
        let body: [String: Any] = [
            "bundle": Bundle.main.bundlePath,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
            "checks": checks, "measurements": measurements,
            "note": "Installed signed app with the user's own saved sprites. The hub is opened by clicking the brand status item, not by a private entry point. Snapshots are MenuSprite's own view render. Short samples are not an overnight benchmark."
        ]
        try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
    }
}
