import AppKit
import SystemMonitoring

/// Opt-in evidence from the installed app's real configuration, live readings and status buttons.
@MainActor
enum UsageReadoutValidation {
    static func start(app: AppDelegate, directory: URL) {
        Task {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // Initial labels and the first response can fall inside a sprite's 30-second redraw interval.
                try await Task.sleep(for: .seconds(35))
                let store = app.monitoringStore!
                for config in store.sprites where config.showInMenuBar {
                    if let image = app.spriteMenuBar?.readoutForValidation(config.id)?.image,
                       let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(config.name + ".png"))
                    }
                }
                let sprites = store.sprites.filter { $0.opensAccountsBoard && $0.showInMenuBar }
                var checks: [[String: Any]] = []
                var evidence: [[String: Any]] = []
                func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
                let weekly = sprites.first { $0.metricIDs == ["ai.codex.weekly", "ai.claude.weekly"] }
                let session = sprites.first { $0.metricIDs == ["ai.claude.session"] }
                check("Weekly limits together; Claude session separate", sprites.count == 2 && weekly != nil && session != nil)
                check("GPT weekly above Claude weekly", weekly?.layout == .twoRows &&
                      weekly.map { store.menuColumns($0).map(\.label) } == ["GPT", "Claude"])
                check("Session has only Claude above its percentage", session?.layout == .stacked &&
                      session.map { store.menuColumns($0).map(\.label) } == ["Claude"])
                check("Weekly labels stay hidden", weekly?.showLabels == false)
                check("Other readouts retain their default weight", store.sprites.filter { !$0.opensAccountsBoard }.allSatisfy { !$0.bold })
                for config in sprites {
                    check("\(config.name): bold white text, colored percent only", config.enabled && !config.showIcon &&
                          config.bold && config.colorHex == "FFFFFF" && config.colorRule == .usagePacePercent)
                    let rendered = app.spriteMenuBar?.readoutForValidation(config.id)
                    check("\(config.name): actual status image retains colors", rendered?.image?.isTemplate == false)
                    if let image = rendered?.image, let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(config.name + ".png"))
                    }
                    for (id, column) in zip(config.metricIDs, store.menuColumns(config)) {
                        let pace = store.usagePace(id)
                        check("\(id): live usage and valid reset window", store.readings[id]?.number != nil && pace != nil)
                        var row: [String: Any] = ["id": id, "text": column.label + " " + column.value,
                                                 "color": column.colorHex ?? "fixed", "level": pace?.level.rawValue ?? "unknown"]
                        if let pace {
                            row["bucket"] = pace.bucket; row["bucketCount"] = pace.bucketCount
                            row["allowance"] = pace.allowance; row["warningCeiling"] = pace.warningCeiling
                        }
                        if let frame = rendered?.frame { row["statusFrame"] = NSStringFromRect(frame) }
                        evidence.append(row)
                    }
                }
                let body: [String: Any] = ["bundle": Bundle.main.bundlePath, "checks": checks, "readouts": evidence,
                                          "note": "Actual installed status-button images and live provider readings. Auto-switch disabled for validation. No configuration changes."]
                try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("report.json"))
            } catch {
                try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("error.txt"))
            }
            app.finishHeadlessMeasurement()
        }
    }
}
