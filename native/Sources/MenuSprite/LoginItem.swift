import Foundation
import ServiceManagement

/// "Open at login", through `SMAppService.mainApp` — the modern registration, so the entry appears
/// under Login Items in System Settings and macOS owns the on/off switch. It matters beyond
/// convenience here: MenuSprite re-applies the owned menu-bar spacing when it launches
/// (`MenuBarSpacing.enforce`), and only a login item is there to do that at login.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// `requiresApproval` means the user switched it off in System Settings; registering again would
    /// not turn it back on, so the UI says so instead of claiming success.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            return false
        }
    }
}
