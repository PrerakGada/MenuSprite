import AppKit
import SwiftUI
import WorkTracking

/// Explicit diagnostic. Real paneclock snapshot, isolated rates/manual entries, no collector changes.
@MainActor
final class WorkValidation {
    let app: AppDelegate
    let directory: URL
    private var checks: [[String: Any]] = []
    private var measurements: [[String: Any]] = []
    init(app: AppDelegate, directory: URL) { self.app = app; self.directory = directory }
    func start() {
        Task {
            do {
                try await run()
                try await measure("work-window-closed-after-release", seconds: 10)
            }
            catch { checks.append(["name": error.localizedDescription, "passed": false]) }
            try? JSONSerialization.data(withJSONObject: ["checks": checks, "measurements": measurements], options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"))
            app.workWindow?.close(); NSApp.terminate(nil)
        }
    }
    private func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
    private func pause() async throws { try await Task.sleep(for: .milliseconds(600)) }
    private func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferencesURL = directory.appendingPathComponent("test-work-settings.json")
        var preferences = WorkPreferences()
        let snapshot = directory.appendingPathComponent("paneclock.snapshot.db")
        if FileManager.default.fileExists(atPath: snapshot.path) { preferences.sourcePath = snapshot.path }
        try WorkRepository.savePreferences(preferences, to: preferencesURL)
        try await measure("before-work-window", seconds: 6)
        app.openWork(preferencesURL: preferencesURL)
        guard let store = app.workStore, let window = app.workWindow else { throw WorkFailure("Work report window did not open") }
        for _ in 0..<30 { if !store.loading { break }; try await pause() }
        check("Signed installed app", Bundle.main.bundlePath == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/MenuSprite.app").path)
        check("Real source loaded", !store.source.isEmpty && store.error == nil)
        guard !store.source.isEmpty else { throw WorkFailure(store.error ?? "Source returned no intervals") }
        store.period = .all
        let total = store.source.reduce(0) { $0 + $1.seconds }
        check("Full source reconciles with report", abs(store.tracked - total) < 0.001)
        check("Daily buckets reconcile", abs(WorkReport.daily(store.filtered).reduce(0) { $0 + $1.seconds } - total) < 0.001)
        check("No invented billing defaults", store.billable == 0 && store.projects.allSatisfy { $0.rate == nil })
        if CommandLine.arguments.contains("--work-measure") {
            try await measure("work-window-open-no-screenshots", seconds: 10)
            app.workWindow?.close()
            return
        }
        try WorkReport.csv(store.filtered, range: store.range, detail: false).write(to: directory.appendingPathComponent("real-summary.csv"), atomically: true, encoding: .utf8)
        try WorkReport.csv(store.filtered, range: store.range, detail: true).write(to: directory.appendingPathComponent("real-intervals.csv"), atomically: true, encoding: .utf8)
        let allCount = store.projects.count
        guard let searchProject = store.projects.first else { throw WorkFailure("No project rows") }
        store.search = searchProject.name
        check("Project search filters real data", !store.filtered.isEmpty && store.filtered.count <= allCount
              && store.filtered.allSatisfy { $0.name.localizedCaseInsensitiveContains(searchProject.name) })
        store.search = ""; store.client = ""
        check("Unassigned client filter", !store.filtered.isEmpty && store.filtered.allSatisfy { $0.client.isEmpty })
        store.client = nil
        guard let first = store.projects.first else { throw WorkFailure("No project rows") }
        store.selectedProject = first.id
        window.appearance = NSAppearance(named: .aqua)
        try await pause(); try render(window, "work-light")
        try await measure("work-window-open", seconds: 6)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: WorkBoard(store: store).preferredColorScheme(.dark))
        try await pause(); try render(window, "work-dark")
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: WorkBoard(store: store).preferredColorScheme(.light))
        window.setContentSize(NSSize(width: 1000, height: 700))
        try await pause(); try render(window, "work-compact")
        window.setContentSize(NSSize(width: 1240, height: 850))
        store.billingProject = first; try await pause()
        check("Billing opens a native sheet", window.attachedSheet != nil)
        if let sheet = window.attachedSheet { try render(sheet, "work-billing") }
        store.billingProject = nil; try await pause()
        check("Project billing saves", store.configure(first, client: "Validation client", billable: true, hourly: "5000.25", currency: "INR"))
        check("Client override changes attribution in report", store.projects.first { $0.id == first.id }?.client == "Validation client")
        check("Estimated amount uses entered rate", store.projects.first { $0.id == first.id }?.amount == WorkReport.roundMoney(Decimal(first.seconds / 3600) * Decimal(string: "5000.25")!))
        check("Settings survive reopening", try WorkRepository.loadPreferences(preferencesURL).rates["Validation client"]?.hourly == Decimal(string: "5000.25")!)
        let oldCount = store.preferences.manual.count
        let manual = WorkInterval(start: Date().addingTimeInterval(-3600), end: Date().addingTimeInterval(-1800), seconds: 1800,
                                  project: "Validation meeting", client: "Validation client", note: "Isolated native action check", manual: true)
        check("Manual action saves", store.addManual(manual, allowOverlap: true))
        check("Manual time is included once", store.preferences.manual.count == oldCount + 1 && store.projects.contains { $0.name == manual.project && abs($0.seconds - 1800) < 0.01 })
        store.removeManual(manual.id)
        check("Manual deletion persists", store.preferences.manual.count == oldCount)
        store.undoRemove()
        check("Manual deletion can be undone", store.preferences.manual.count == oldCount + 1)
        store.removeManual(manual.id)
        store.showManual = true; try await pause()
        check("Add time opens a native sheet", window.attachedSheet != nil)
        if let sheet = window.attachedSheet { try render(sheet, "work-add-time") }
        store.showManual = false; store.showAI = true; try await pause(); try render(window, "work-ai")
        store.showAI = false; store.showSource = true; try await pause(); try render(window, "work-source")
        store.closed()
        check("Close stops refresh and releases source rows", !store.isOpen && store.source.isEmpty && store.projects.isEmpty)
        store.opened()
        for _ in 0..<30 { if !store.loading { break }; try await pause() }
        check("Reopen reloads real history", !store.source.isEmpty && store.error == nil)
        let evidence: [String: Any] = ["sourceIntervals": store.source.count, "sourceActiveSeconds": total, "sourcePath": preferences.sourcePath,
                                        "nativeCollector": false, "aiAccounting": "not connected", "settings": preferencesURL.path]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("coverage.json"))
        app.workWindow?.close()
        check("Window close clears app references", app.workWindow == nil && app.workStore == nil)
        try await measure("work-window-closed", seconds: 6)
        // Finally exercise the normal live database path, without persisting it or changing its writer.
        let live = try await Task.detached(priority: .utility) { try WorkRepository.read(URL(fileURLWithPath: WorkPreferences().sourcePath)) }.value
        check("Installed app can read the live paneclock WAL", live.count >= store.source.count && live.count > 0)
    }
    private func render(_ window: NSWindow, _ name: String) throws {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw WorkFailure("Cannot render \(name)") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
    private func measure(_ phase: String, seconds: Double) async throws {
        func sample() -> (Double, Double) {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            return (status == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1, cpu)
        }
        let before = sample(), start = Date()
        try await Task.sleep(for: .seconds(seconds))
        let after = sample(), elapsed = Date().timeIntervalSince(start)
        measurements.append(["phase": phase, "physicalMiB": after.0, "cpuPercentOneCore": (after.1 - before.1) / elapsed * 100, "seconds": elapsed])
    }
}
