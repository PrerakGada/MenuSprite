import AppKit
import Darwin
import PermissionModel

/// Explicit developer-only launch mode. No diagnostics, timers, output or permission requests
/// run on ordinary launches. Images render our own NSView, never the screen or other apps.
@MainActor
final class NativeValidation {
    unowned let app: AppDelegate
    let directory: URL
    let measurementsOnly: Bool
    private var checks: [String: Bool] = [:]
    private var samples: [[String: Any]] = []

    init(app: AppDelegate, directory: URL, measurementsOnly: Bool = false) {
        self.app = app; self.directory = directory; self.measurementsOnly = measurementsOnly
    }
    func start() {
        Task {
            do { try await run() }
            catch {
                try? "\(error)".write(to: directory.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    private func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.showSettings()
        try await settled()
        checks["correctBundle"] = Bundle.main.bundleIdentifier == "in.prerakgada.MenuSprite"
        checks["realAppContext"] = Bundle.main.bundleURL.pathExtension == "app"
        checks["completeCatalog"] = app.permissionStore?.observations.count == PermissionID.allCases.count
        checks["noRequestsOnOpen"] = app.permissionStore?.requestInFlight == nil
        checks["unknownNotDenied"] = app.permissionStore?.observations[.fullDiskAccess]?.state == .unknown
        checks["screenAudioSeparate"] = app.permissionStore?.observations[.systemAudio]?.state == .unknown
        checks["allCategoriesDefault"] = app.permissionStore?.visiblePermissions.count == PermissionCatalog.all.count
        if measurementsOnly {
            try await measureLifecycle()
            return
        }
        try snapshot("01-all-light", appearance: .aqua)
        try snapshot("02-all-dark", appearance: .darkAqua)
        app.settingsWindow?.appearance = nil

        app.permissionStore?.search = "Automation"
        app.permissionStore?.expanded.insert(.automation)
        try await pause(0.3)
        checks["automationSearch"] = app.permissionStore?.visiblePermissions.map(\.id) == [.automation]
        try snapshot("03-automation")
        app.permissionStore?.search = "Files & Folders"
        app.permissionStore?.expanded.insert(.filesAndFolders)
        try await pause(0.3)
        checks["resourceScopeCount"] = app.permissionStore?.observations[.filesAndFolders]?.resources.count == 5
        try snapshot("04-file-scopes")
        app.permissionStore?.search = ""
        app.permissionStore?.filter = .used
        try await pause(0.3)
        checks["featureUseSeparate"] = app.permissionStore?.visiblePermissions.map(\.id) == [.login]
        try snapshot("05-app-services")
        app.permissionStore?.filter = .all
        app.permissionStore?.search = "Health data"
        app.permissionStore?.expanded.insert(.health)
        try await pause(0.3)
        try snapshot("06-unavailable")
        app.permissionStore?.search = "no-matching-permission-xyz"
        try await pause(0.3)
        checks["emptySearch"] = app.permissionStore?.visiblePermissions.isEmpty == true
        try snapshot("07-empty-search")
        app.permissionStore?.search = ""
        app.permissionStore?.expanded = []
        let previousRefreshCount = app.permissionStore?.refreshCount ?? 0
        app.permissionStore?.refresh()
        try await settled()
        checks["explicitRefresh"] = (app.permissionStore?.refreshCount ?? 0) > previousRefreshCount

        // Real System Settings handoff, then activation via NSApplication. No grants change.
        if let fullDisk = PermissionCatalog.all.first(where: { $0.id == .fullDiskAccess }) {
            let count = app.permissionStore?.refreshCount ?? 0
            app.permissionStore?.manage(fullDisk)
            try await pause(2)
            checks["settingsOpened"] = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.systempreferences" }
            app.settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await settled()
            checks["refreshOnReturn"] = (app.permissionStore?.refreshCount ?? 0) > count
        }
        app.permissionStore?.notice = nil
        app.settingsWindow?.makeFirstResponder(nil)
        try writeObservations()
        try snapshot("08-ready")
        try await measureLifecycle()
    }

    private func measureLifecycle() async throws {
        app.settingsWindow?.makeFirstResponder(nil)
        try await pause(2)
        try await measure("page-open-idle", seconds: 30)

        weak let previousStore = app.permissionStore
        app.closeSettings()
        try await pause(1)
        checks["closedWindowReleased"] = app.settingsWindow == nil
        checks["closedStoreReleased"] = previousStore == nil
        try await measure("page-closed-idle", seconds: 30)

        for _ in 0..<10 {
            app.showSettings()
            try await settled()
            app.closeSettings()
            try await pause(0.15)
        }
        try await measure("closed-after-ten-reopens", seconds: 30)
        app.showSettings()
        try await settled()
        checks["reopenFreshCheck"] = (app.permissionStore?.refreshCount ?? 0) > 0
        try writeObservations()
        try writeReport()
        try "Validation complete. No permission requests were made.\n".write(to: directory.appendingPathComponent("complete.txt"), atomically: true, encoding: .utf8)
    }

    private func settled() async throws {
        try await pause(0.2)
        for _ in 0..<60 {
            if app.permissionStore?.isRefreshing == false { return }
            try await pause(0.1)
        }
        throw NSError(domain: "NativeValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Status refresh did not settle"])
    }
    private func pause(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    private func snapshot(_ name: String, appearance: NSAppearance.Name? = nil) throws {
        guard let window = app.settingsWindow, let view = window.contentView else { return }
        if let appearance { window.appearance = NSAppearance(named: appearance) }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    private func writeObservations() throws {
        guard let store = app.permissionStore else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let observations = Dictionary(uniqueKeysWithValues: store.observations.map { ($0.key.rawValue, $0.value) })
        try encoder.encode(observations).write(to: directory.appendingPathComponent("observations.json"))
    }

    private func usage() -> (resident: UInt64, footprint: UInt64, cpu: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let cpu = Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1_000_000
        return (result == KERN_SUCCESS ? info.resident_size : 0, result == KERN_SUCCESS ? info.phys_footprint : 0, cpu)
    }

    private func measure(_ label: String, seconds: Double) async throws {
        let before = usage()
        let start = Date()
        try await pause(seconds)
        let after = usage()
        let elapsed = Date().timeIntervalSince(start)
        samples.append(["phase": label, "elapsedSeconds": elapsed,
                        "residentMiB": Double(after.resident) / 1_048_576,
                        "physicalFootprintMiB": Double(after.footprint) / 1_048_576,
                        "cpuPercentOneCore": (after.cpu - before.cpu) / elapsed * 100,
                        "cpuSeconds": after.cpu - before.cpu])
        try writeReport()
    }

    private func writeReport() throws {
        let report: [String: Any] = ["bundleID": Bundle.main.bundleIdentifier ?? "", "bundlePath": Bundle.main.bundlePath,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "pid": ProcessInfo.processInfo.processIdentifier,
            "checks": checks, "samples": samples,
            "measurement": measurementsOnly
                ? "Release app, fresh native launch with no snapshot rendering or UI driver; TASK_VM_INFO + getrusage; one-shot measurement sleeps only. No helper processes."
                : "Release app in native bundle; TASK_VM_INFO + getrusage; one-shot validation sleeps only. Snapshot rendering precedes measurements and can warm UI caches. No helper processes."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
    }
}
