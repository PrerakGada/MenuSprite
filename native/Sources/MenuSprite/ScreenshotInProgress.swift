import AppKit
import CoreGraphics

/// A screenshot being taken: macOS's own (⇧⌘3/4/5) or a capture app. Its crosshair, toolbar and overlay
/// are another app's windows, so the boards' outside-click and app-switch dismissal would read the first
/// click of a screenshot as the user leaving and close the very board being captured.
@MainActor
enum ScreenshotInProgress {
    static let bundleIDs: Set<String> = [
        "com.apple.screencaptureui", "com.apple.screenshot.launcher", "com.apple.Screenshot",
        "com.engaze.screenroll", "pl.maketheweb.cleanshotx", "cc.ffitch.shottr",
    ]
    /// A capture ends by handing the front back to another app and only then takes the picture
    /// (Screenroll reactivates the previous app as its overlay closes), so the board must outlive that.
    static let grace: TimeInterval = 2
    /// A capture last seen longer ago than this was abandoned, not finished.
    static let longestCapture: TimeInterval = 120
    private static var seenAt: Date?
    /// When a check first found the capture gone; the grace runs from here, not from when it was last
    /// seen, because nothing is asked during the drag itself and a slow drag would outlast it.
    private static var endedAt: Date?

    static func isCaptureApp(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return bundleIDs.contains(id) || id.hasPrefix("com.TechSmith.Snagit")
    }

    /// True while a capture tool is in front or has a window up outside the menu bar, and for a moment
    /// after. Asked only when a board is about to close, so the window list is read on clicks, not on a timer.
    static var isInProgress: Bool {
        let now = Date()
        if isCaptureApp(NSWorkspace.shared.frontmostApplication) || captureWindowOnScreen() {
            seenAt = now
            endedAt = nil
            return true
        }
        guard let seen = seenAt, now.timeIntervalSince(seen) < longestCapture else {
            seenAt = nil; endedAt = nil
            return false
        }
        let ended = endedAt ?? now
        endedAt = ended
        if now.timeIntervalSince(ended) < grace { return true }
        seenAt = nil; endedAt = nil
        return false
    }

    private static func captureWindowOnScreen() -> Bool {
        let pids = Set(NSWorkspace.shared.runningApplications.filter { isCaptureApp($0) }.map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) else { return false }
            // A capture app's own menu-bar item is not a capture.
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let y = bounds["Y"], let height = bounds["Height"] else { return true }
            return !(y <= 0 && height <= 50)
        }
    }
}
