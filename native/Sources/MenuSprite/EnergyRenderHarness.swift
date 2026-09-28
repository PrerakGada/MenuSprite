import AppKit
import SystemMonitoring

/// Renders the Battery & Power dashboard to PNG files without showing anything: no status items,
/// no window on screen. For checking its look while Prerak is using the Mac.
///
///     MenuSprite --energy-render <dir> [--wait <seconds>]
///
/// Its PowerStore runs on throwaway preferences with charge control off, so building it never
/// writes a limit; the handle is drawn at a preview value instead.
@MainActor
enum EnergyRenderHarness {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--energy-render"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        let wait = arguments.firstIndex(of: "--wait").flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 12
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = IslandRenderHarness.scratchDefaults(in: directory)
        defaults.set(false, forKey: "power.saverEnabled")
        let monitoring = MonitoringStore(configurationURL: directory.appendingPathComponent("render-monitoring.json"))
        let power = PowerStore(preferences: defaults)
        let processes = MemoryBoardStore(kind: .power)
        monitoring.setHubMetrics(Set(ProcessPanelKind.power.metricIDs))
        processes.start()
        let board = EnergyBoardController(monitoring: monitoring, processes: processes, power: power, id: nil, embedded: true,
                                          configure: {}, showPower: {}, close: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 1180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = board
        window.setContentSize(NSSize(width: 440, height: 1180))
        board.document.previewLimit = 80
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            var report: [String] = []
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                window.appearance = NSAppearance(named: appearance)
                board.view.layoutSubtreeIfNeeded()
                board.document.updateLayers(); board.document.needsDisplay = true; board.view.needsDisplay = true
                try? await Task.sleep(for: .milliseconds(300))
                let view = board.view
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = directory.appendingPathComponent("energy-\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                report.append("\(name) → \(url.lastPathComponent)")
            }
            // The flow's layouts, from made-up readings: charging, draining on the cable, battery only, adapter only.
            window.appearance = NSAppearance(named: .darkAqua)
            let cases: [(String, Double?, Double, Double)] = [("charging", 87, 52.1, 34.4), ("draining", 44, -36, 78.3),
                                                               ("battery", nil, -18.2, 17.6), ("adapter", 24, 0, 22.7)]
            for (name, adapter, battery, system) in cases {
                var readings: [String: Reading] = ["battery.power": Reading(battery), "sensor.PSTR": Reading(system), "battery.charge": Reading(64)]
                if let adapter { readings["sensor.PDTR"] = Reading(adapter) }
                board.document.previewFlow = EnergyFlow(readings: readings)
                board.document.updateLayers(); board.view.needsLayout = true; board.view.layoutSubtreeIfNeeded()
                board.document.needsDisplay = true
                try? await Task.sleep(for: .milliseconds(200))
                let area = NSRect(x: 0, y: 0, width: board.document.bounds.width, height: board.document.flowRect.maxY + 10)
                guard let rep = board.document.bitmapImageRepForCachingDisplay(in: area) else { continue }
                board.document.cacheDisplay(in: area, to: rep)
                let url = directory.appendingPathComponent("flow-\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                report.append("\(name) → \(url.lastPathComponent) (flow \(Int(board.document.flowRect.height)) pt)")
            }
            board.document.previewFlow = nil
            let flow = board.document.flow
            report.append("adapter \(EnergyFlow.watts(flow.adapter)) system \(EnergyFlow.watts(flow.system)) battery \(EnergyFlow.watts(flow.battery)) other \(EnergyFlow.watts(flow.difference)) charge \(flow.charge.map { "\($0)" } ?? "—")")
            report.append("apps ranked \(processes.ranked.count), top \(processes.ranked.first.map { "\($0.consumer.presentation.title) \($0.value)" } ?? "—")")
            board.stop(); processes.stop()
            print(report.joined(separator: "\n"))
            exit(0)
        }
        app.run()
    }
}
