import AppKit
import PowerControl
import PermissionModel
import CryptoKit
import SystemMonitoring
import AIAccounts

@MainActor
final class ReleaseValidation {
    let app: AppDelegate
    let directory: URL
    var checks: [[String:Any]] = []
    init(app: AppDelegate, directory: URL) { self.app = app; self.directory = directory }
    func start() {
        Task {
            do { try await run() }
            catch { check("Release validation completed", false); try? error.localizedDescription.write(to: directory.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8) }
            try? report()
            app.powerStore.stopAwake()
            NSApp.terminate(nil)
        }
    }
    func check(_ name: String, _ pass: Bool) { checks.append(["name":name,"passed":pass]) }
    func pause(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds*1000))) }
    func run() async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        check("Public-preview policy compiled in", BuildFeatures.publicPreview && !BuildFeatures.privilegedPowerControls)
        let resources = Bundle.main.resourceURL!
        check("No privileged executable or installers", !FileManager.default.fileExists(atPath:resources.appendingPathComponent("MenuSpritePowerHelper").path) && !FileManager.default.fileExists(atPath:resources.appendingPathComponent("install-power-helper.sh").path))
        check("Only MenuSprite bundle identity", Bundle.main.bundleIdentifier == "in.prerakgada.MenuSprite")
        let configurations = app.monitoringStore.sprites
        check("Fresh install has six configured items", configurations.count == 6)
        check("Battery item among fresh-install defaults", configurations.contains { $0.metricIDs == ["battery.charge"] })
        check("One CPU usage reading on fresh install", configurations.filter { $0.metricIDs.contains("cpu.usage") }.count == 1)
        check("Network and fan/temp paired defaults", configurations.filter { $0.layout == .twoRows }.count == 2)
        check("AI Accounts board available", app.accountsStore != nil)
        check("Normal-weight system defaults", configurations.allSatisfy { !$0.bold })
        let fan = configurations.first { $0.metricIDs.contains("sensor.fanSpeed") }
        check("Filled fan with independent blue icon", fan?.symbol == "fan.fill" && fan?.iconColorHex == "79BFFA" && fan?.showIcon == true)
        var ai = SpriteConfiguration(name: "Usage", metricIDs: ["ai.claude.weekly"])
        ai.colorRule = .usagePacePercent; ai.colorHex = "FFFFFF"; ai.bold = true; ai.showIcon = false
        let preview = StackedReadout.attributedText(columns: [.init(label: "Claude", value: "49%", colorHex: "FF453A")], config: ai)
        let digit = preview.attribute(.foregroundColor, at: preview.length - 2, effectiveRange: nil) as? NSColor
        let suffix = preview.attribute(.foregroundColor, at: preview.length - 1, effectiveRange: nil) as? NSColor
        check("Public renderer preserves white digits and colored percent", digit?.greenComponent == 1 && (suffix?.redComponent ?? 0) > (suffix?.greenComponent ?? 1))
        let current = Date()
        check("Public weekly pace uses day buckets", UsagePace.evaluate(.init(id: "weekly", label: "Weekly", usedPercent: 49,
            resetsAt: current.addingTimeInterval(5.5 * 86_400), windowSeconds: 604_800), now: current)?.level == .over)
        check("Readout side margins", StackedReadout.horizontalPadding == 3)
        let store = app.powerStore!
        check("No assertions created on launch",store.assertionIDs.isEmpty)
        store.keepDisplay = false; store.pauseWhenLocked = false; store.acOnly = false
        store.appRules = [Bundle.main.bundleIdentifier!:"MenuSprite validation"]
        store.resumeRules()
        check("Selected running app rule creates a native assertion",store.awake && !store.assertionIDs.isEmpty)
        store.duration = 0.25; store.startAwake(); try await pause(0.6)
        check("Timer expiry preserves automatic rule",store.awake && !store.automationPaused && store.manualUntil == nil)
        store.duration = 3600; store.startAwake(); store.pauseRules()
        check("Pausing rules preserves a manual session", store.awake && store.manualUntil != nil && store.automationPaused)
        store.stopAwake()
        check("Explicit stop pauses rules and releases assertions",store.automationPaused && store.assertionIDs.isEmpty)
        store.resumeRules(); store.duration = 0.3; store.startAwake(); store.handleSleep()
        check("Sleep releases manual session and assertions",store.manualUntil == nil && store.assertionIDs.isEmpty)
        store.resumeAfterSleep(); try await pause(0.6)
        check("Old timer does not pause rules after wake",store.awake && !store.automationPaused)
        store.setSessionActive(false)
        check("Inactive session releases assertion",store.assertionIDs.isEmpty)
        store.setSessionActive(true)
        check("Returning session reevaluates rules",store.awake)
        store.stopAwake(); store.appRules = [:]
        try await pause(3)
        check("CPU and RAM readings in native release",app.monitoringStore.readings["cpu.usage"]?.available == true && app.monitoringStore.readings["memory.usage"]?.available == true)
        let permission = PermissionStore(); permission.opened(); try await pause(0.3)
        check("Public helper access marked unavailable in build",permission.observation(for:.backgroundHelpers).state == .unavailableInBuild)
        permission.closed()
        check("All temporary sleep assertions released",store.assertionIDs.isEmpty)
        try report()
    }
    func report() throws {
        let executable = try Data(contentsOf: Bundle.main.executableURL!)
        let result: [String:Any] = ["bundle":Bundle.main.bundlePath,"version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? "",
                                  "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "",
                                  "executableSHA256": SHA256.hash(data: executable).map { String(format: "%02x", $0) }.joined(), "checks":checks,
                                  "note":"Developer ID-signed public bundle; isolated monitoring configuration and UserDefaults. Real IOPM assertions. Sleep/wake and user-session callbacks simulated, no physical sleep forced, no permission request or privileged operation." ]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report.json"))
    }
}
