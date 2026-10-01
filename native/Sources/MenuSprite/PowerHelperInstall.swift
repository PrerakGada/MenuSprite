import AppKit
import PowerControl
import ServiceManagement

/// Where MenuSprite's root power helper stands. It is a launchd daemon inside the app bundle
/// (Contents/Library/LaunchDaemons names Contents/MacOS/MenuSpritePowerHelper), registered through
/// SMAppService and allowed by the person in System Settings → General → Login Items & Extensions.
enum PowerHelperState: Equatable {
    /// Not registered: power controls are off. Nothing asks for anything until the person turns them on.
    case off
    /// Registered; macOS waits for "Allow in the Background" in System Settings.
    case needsApproval
    case on
    /// The Terminal-installed helper of the first developer builds (/Library/PrivilegedHelperTools).
    /// It still works; turning power controls on moves it into the bundle.
    case legacy
    /// This copy of the app carries no daemon plist: a damaged or hand-assembled bundle.
    case missing
}

@MainActor
enum PowerHelperInstall {
    static var service: SMAppService { .daemon(plistName: PowerIdentity.daemonPlistName) }
    static var legacyInstalled: Bool { FileManager.default.fileExists(atPath: PowerIdentity.legacyDaemonPlist) }
    private static var bundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(PowerIdentity.daemonPlistName)").path)
    }

    /// Reading the status never prompts; only `enable()` does.
    static func state() -> PowerHelperState {
        // The old install first: it is what answers until it is moved, whatever macOS says about the new one.
        if legacyInstalled { return .legacy }
        switch service.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        // A daemon that was never registered reports notFound rather than notRegistered.
        default: return bundled ? .off : .missing
        }
    }

    /// Set by the first `enable()`; release validation checks that a launch never reaches it.
    private(set) static var registrationRequested = false
    /// Registers the daemon. The first time, macOS lists MenuSprite under Login Items & Extensions
    /// and the person allows it there; until then launchd will not start it.
    static func enable() throws -> PowerHelperState {
        registrationRequested = true
        do { try service.register() }
        catch {
            // A daemon awaiting approval reports that as an error from register().
            let now = state()
            if now == .needsApproval || now == .on { return now }
            // Opened straight from Downloads, macOS runs the app from a randomised read-only copy and
            // will not register anything inside it.
            if Bundle.main.bundlePath.contains("/AppTranslocation/") {
                throw PowerFailure("Move MenuSprite to your Applications folder, open it from there, and try again.")
            }
            throw error
        }
        return state()
    }

    /// launchd stops the helper with SIGTERM, and it hands everything back before exiting.
    static func disable() async throws { try await service.unregister() }

    static func openApproval() { SMAppService.openSystemSettingsLoginItems() }

    /// Removes the Terminal-installed helper so the bundled one can take its launchd label. The old
    /// helper hands back first (`--restore`); its recovery journal stays for the new one to read.
    /// macOS asks for an administrator password once.
    static func removeLegacy() throws {
        let label = PowerIdentity.legacyLabel, tool = PowerIdentity.legacyHelperPath, plist = PowerIdentity.legacyDaemonPlist
        // Restore with the daemon stopped, so no running controller races it; if restoring fails, put the
        // old daemon back and change nothing else, so the old helper keeps working.
        let script = "/bin/launchctl bootout system/\(label) 2>/dev/null; "
            + "if [ -x '\(tool)' ] && ! '\(tool)' --restore; then /bin/launchctl bootstrap system '\(plist)'; exit 1; fi; "
            + "/bin/rm -f '\(plist)' '\(tool)'"
        let source = "do shell script \"\(script)\" with administrator privileges with prompt "
            + "\"MenuSprite is moving its power helper into the app, where macOS manages it.\""
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            // -128: the person cancelled the password prompt.
            if error[NSAppleScript.errorNumber] as? Int == -128 { throw PowerFailure("Cancelled. The old power helper is still in place.") }
            throw PowerFailure(error[NSAppleScript.errorMessage] as? String ?? "The old power helper could not be removed.")
        }
        guard !legacyInstalled else { throw PowerFailure("The old power helper is still installed.") }
    }
}
