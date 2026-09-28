import AppKit
import PowerControl
import SystemMonitoring

/// Evidence for the menu-bar battery item, taken from the installed app's own status
/// button and the exact menu a secondary click builds. It reads and renders only —
/// no charge command is sent and no firmware is written by this mode.
@MainActor
final class BatteryItemValidation {
    private let app: AppDelegate
    private let directory: URL
    private var checks: [[String: Any]] = []
    init(app: AppDelegate, directory: URL) { self.app = app; self.directory = directory }

    private func check(_ name: String, _ passed: Bool, _ detail: String? = nil) {
        var row: [String: Any] = ["name": name, "passed": passed]
        if let detail { row["detail"] = detail }
        checks.append(row)
    }

    func start() {
        Task {
            do { try await run() }
            catch { try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("error.txt")) }
            app.finishHeadlessMeasurement()
        }
    }

    private func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let store = app.monitoringStore, let bar = app.spriteMenuBar, let power = app.powerStore else {
            throw PowerFailure("The app did not finish launching")
        }
        // Ask the root helper what the firmware actually supports, then give the sampler time
        // for a first battery reading and that round trip time to land.
        power.askHelperForCapability()
        try await Task.sleep(for: .seconds(12))

        guard let config = store.sprites.first(where: { $0.isBatteryItem && $0.showInMenuBar }) else {
            throw PowerFailure("No battery item is in the menu bar")
        }
        check("A battery item exists in the menu bar", true, config.name)
        check("It asks for the battery charge reading", config.metricIDs == ["battery.charge"])
        check("A live charge was sampled", store.readings["battery.charge"]?.number != nil,
              store.display("battery.charge", compact: true))

        let rendered = bar.readoutForValidation(config.id)
        check("The status button carries an image", rendered?.image != nil)
        if let image = rendered?.image, let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("battery-item.png"))
            let glyphWidth = BatteryGlyph.width(forHeight: 14)
            check("The drawn battery is wider than a square symbol slot", image.size.width > glyphWidth,
                  "image \(Int(image.size.width))pt, glyph \(Int(glyphWidth))pt")
        }

        // The glyph is built from readings, never from an assumption about the hardware.
        let glyph = store.batteryGlyph(ceiling: power.activeCeiling)
        check("The glyph level matches the sampled charge",
              glyph.percent == store.readings["battery.charge"]?.number, glyph.summary)
        check("A ceiling tick is drawn only while the hardware is being limited",
              (glyph.ceiling != nil) == (power.snapshot.mode != .off),
              "mode \(power.snapshot.mode.rawValue), ceiling \(glyph.ceiling.map(String.init) ?? "none")")

        guard let menu = bar.contextMenuForValidation(config.id) else { throw PowerFailure("No secondary-click menu was built") }
        let titles = menu.items.map(\.title)
        try JSONSerialization.data(withJSONObject: titles, options: [.prettyPrinted])
            .write(to: directory.appendingPathComponent("menu.json"))
        check("Secondary click offers the Battery & Power dashboard", titles.contains("Battery & Power…"))
        check("Secondary click offers the sprite's own settings", titles.contains("Configure sprite…"))
        check("The menu states the live battery level", titles.first?.hasPrefix("Battery") == true, titles.first ?? "")
        check("The menu states what the hardware is doing", titles.contains(power.limitStatus), power.limitStatus)

        if let reason = power.batteryRequestReason {
            check("Unavailable charge control explains itself instead of offering a dead control",
                  titles.contains(reason) && !titles.contains { $0.hasPrefix("Limit charging") }, reason)
        } else {
            check("Charge limit can be turned on from the menu", titles.contains { $0.hasPrefix("Limit charging to") })
            check("Top up is offered", titles.contains("Top up to 100% once"))
            let limits = menu.items.first { $0.title == "Charge limit" }?.submenu
            check("Every preset ceiling is listed", SpriteContextMenu.presets.allSatisfy { preset in
                limits?.items.contains { $0.title == "\(preset)%" } == true })
            check("The saved ceiling is the checked preset",
                  limits?.items.first { $0.state == .on }?.title == "\(power.band.upper)%",
                  "band \(power.band.lower)–\(power.band.upper)%")
            check("The toggle reflects the running control, not just the saved intent",
                  menu.items.first { $0.title.hasPrefix("Limit charging to") }?.state
                    == (power.saverEnabled || power.snapshot.mode == .maintain ? .on : .off))
        }

        // Left click still opens the dashboard rather than the menu.
        check("Primary click opens the Battery & Power dashboard", bar.openBoardForValidation(config.id) != nil)
        bar.closeBoardsForValidation()

        let body: [String: Any] = [
            "bundle": Bundle.main.bundlePath,
            "checks": checks,
            "menu": titles,
            "failed": checks.filter { ($0["passed"] as? Bool) == false }.count,
            "battery": ["percent": power.snapshot.percent ?? -1, "pluggedIn": power.snapshot.pluggedIn ?? false,
                        "mode": power.snapshot.mode.rawValue, "saverEnabled": power.saverEnabled,
                        "band": "\(power.band.lower)-\(power.band.upper)",
                        "chargeSupported": power.snapshot.chargeSupported,
                        "dischargeSupported": power.snapshot.dischargeSupported,
                        "capability": power.snapshot.capability,
                        "helperConnected": power.snapshot.helperConnected,
                        "helperStatus": power.helperStatus,
                        "helperInstalled": power.helperInstalled,
                        "reason": power.batteryRequestReason ?? "available"],
            "note": "Read-only. This mode sends no charge command and writes no firmware."]
        try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
    }
}
