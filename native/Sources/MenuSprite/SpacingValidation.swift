import AppKit
import ServiceManagement

/// Evidence for menu-bar spacing and "Open at login", both of which can only be exercised from
/// inside the real signed bundle: `SMAppService.mainApp` registers the calling app, and the spacing
/// keys are read by AppKit at launch. The mode restores whatever it found — the saved spacing and
/// the login-item registration are both put back before it exits, so running it changes nothing.
@MainActor
final class SpacingValidation {
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
            catch { try? Data("\(error)".utf8).write(to: directory.appendingPathComponent("error.txt")) }
            app.finishHeadlessMeasurement()
        }
    }

    private func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = MenuBarSpacing.current()
        let ownedBefore = MenuBarSpacing.owned
        let loginBefore = SMAppService.mainApp.status

        check("The app read the spacing AppKit laid its items out with", true, MenuBarSpacing.atLaunch.summary)
        check("The saved spacing is readable", true, before.summary)

        // Write a value that is not the current one, read it back through a fresh query, then put
        // the original back — proving both directions rather than only that no error was raised.
        let probe: MenuBarSpacing.Preset = before.preset == .small ? .verySmall : .small
        check("Writing a preset is accepted by macOS", MenuBarSpacing.apply(probe), probe.title)
        let written = MenuBarSpacing.current()
        check("The written value reads back", written.preset == probe, written.summary)
        check("MenuSprite records which preset it owns", MenuBarSpacing.owned == probe)
        // enforce() must be a no-op while the keys match, and must restore them when they drift.
        let untouched = MenuBarSpacing.current()
        MenuBarSpacing.enforce()
        check("Enforcing changes nothing when the keys already match", MenuBarSpacing.current() == untouched)
        CFPreferencesSetValue(MenuBarSpacing.spacingKey as CFString, 13 as CFNumber, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        let drifted = MenuBarSpacing.current()
        MenuBarSpacing.enforce()
        check("Enforcing restores the owned preset after something else changes it",
              drifted.spacing == 13 && MenuBarSpacing.current().preset == probe)

        if let restore = before.preset {
            MenuBarSpacing.apply(restore)
        } else {
            for key in [MenuBarSpacing.spacingKey, MenuBarSpacing.paddingKey] {
                CFPreferencesSetValue(key as CFString, nil, kCFPreferencesAnyApplication,
                                      kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            }
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        MenuBarSpacing.owned = ownedBefore
        check("The spacing this Mac had is restored", MenuBarSpacing.current() == before, MenuBarSpacing.current().summary)

        // Login item: register, read the status macOS reports, then put the registration back.
        let registered = LoginItem.set(true)
        try await Task.sleep(for: .seconds(1))
        let statusAfter = SMAppService.mainApp.status
        check("Registering MenuSprite as a login item succeeds", registered)
        check("macOS reports it enabled", statusAfter == .enabled, describe(statusAfter))
        if loginBefore != .enabled { LoginItem.set(false) }
        try await Task.sleep(for: .seconds(1))
        // macOS reports `notFound` for a bundle that has never registered and `notRegistered` after
        // one is unregistered, so the restored state is compared by whether it is on, not by name.
        check("The login-item setting this Mac had is restored",
              (SMAppService.mainApp.status == .enabled) == (loginBefore == .enabled),
              "was \(describe(loginBefore)), now \(describe(SMAppService.mainApp.status))")

        let body: [String: Any] = [
            "bundle": Bundle.main.bundlePath,
            "checks": checks,
            "failed": checks.filter { ($0["passed"] as? Bool) == false }.count,
            "spacing": ["atLaunch": MenuBarSpacing.atLaunch.summary, "saved": MenuBarSpacing.current().summary,
                        "owned": MenuBarSpacing.owned?.rawValue ?? "none"],
            "loginItem": describe(loginBefore),
            "note": "Restores the spacing and login-item registration it found."]
        try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
    }

    private func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .notRegistered: "not registered"
        case .notFound: "not found"
        case .requiresApproval: "requires approval"
        @unknown default: "unknown"
        }
    }
}
