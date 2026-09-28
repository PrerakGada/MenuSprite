import AppKit
import IslandKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Screen Recording access. Checked without asking whenever it matters; asked for only from a capture
/// the person started, and never in headless mode. There is no polling.
@MainActor
enum CapturePermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system's request (macOS shows it only the first time) and reports the result.
    static func request(headless: Bool) -> Bool {
        guard !headless else { return isGranted }
        return isGranted || CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Clears a grant made stale by a new code signature, so macOS asks again on the next capture.
    static func startOver() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", identifier]
        try? process.run()
    }
}

/// The capture feature's own windows: the selection surface, the controls, the preview and the
/// recording pill. They never appear in captures, never hide when another app is active, and are
/// found by class when a capture leaves MenuSprite's own interface out.
class CaptureUtilityPanel: NSPanel {
    var allowsKey = false

    init(frame: NSRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        sharingType = .none
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .unknown }

    /// Orders the panel out now and lets go of its content on the next turn, so a click or key inside
    /// it that led here has finished first.
    func retire() {
        orderOut(nil)
        Task { @MainActor in self.contentView = nil }
    }
}

/// A hosting view that acts on the first click even while another app is active.
final class CaptureHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Which of MenuSprite's windows a capture leaves out.
@MainActor
enum CaptureOwnWindows {
    /// The capture interface always; the island when it hosts the controls or is hidden from captures.
    static func excluded(includeIsland: Bool) -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        for window in NSApp.windows {
            if window is CaptureUtilityPanel || (!includeIsland && window is IslandPanel) {
                ids.insert(CGWindowID(window.windowNumber))
            }
        }
        return ids
    }

    /// The screen the island is on, when it has a window.
    static var islandScreen: NSScreen? { NSApp.windows.first { $0 is IslandPanel }?.screen }
}

/// What can be captured, read once per chooser session: ScreenCaptureKit's displays and windows, and the
/// window server's front-to-back list for picking windows. Own windows are excluded from the same
/// snapshot the filter is built from, so a stale id can never exclude another app's window.
@MainActor
struct CaptureSnapshot {
    let content: SCShareableContent
    /// Front to back, in global top-left points.
    let windows: [CaptureWindowInfo]

    static func take() async throws -> CaptureSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return CaptureSnapshot(content: content, windows: windowList())
    }

    func display(_ id: CGDirectDisplayID) -> SCDisplay? { content.displays.first { $0.displayID == id } }
    func window(_ id: CGWindowID) -> SCWindow? { content.windows.first { $0.windowID == id } }

    /// Everything on the display except `ids`. MenuSprite is excluded as an app and only its other listed
    /// windows are let back in, so a window the snapshot does not list (the island lives in a Space of
    /// its own) is left out rather than slipping into the picture.
    func filter(display: SCDisplay, excluding ids: Set<CGWindowID>) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let own = content.applications.first(where: { $0.processID == pid }) else {
            return SCContentFilter(display: display, excludingWindows: content.windows.filter { ids.contains($0.windowID) })
        }
        let kept = content.windows.filter { $0.owningApplication?.processID == pid && !ids.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: [own], exceptingWindows: kept)
    }

    private static func windowList() -> [CaptureWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return CaptureWindowInfo(id: CGWindowID(number), frame: frame,
                                     layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                     alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                                     isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? true)
        }
    }
}

/// Still images through ScreenCaptureKit, in the display's full pixel resolution and sRGB. Never the
/// `screencapture` tool: a child process is judged by the privacy system on its own standing.
enum CaptureShooter {
    static func display(_ filter: SCContentFilter, size: CGSize, scale: CGFloat) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = Int((size.width * scale).rounded())
        configuration.height = Int((size.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    static func window(_ window: SCWindow, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

extension NSScreen {
    var captureDisplayID: CGDirectDisplayID { IslandHardware.displayID(of: self) }

    /// The island's measurements on this screen, as the shell computes them.
    var islandMetrics: IslandDisplayMetrics {
        let bar = IslandBarHeight.resolve(measuredGap: frame.maxY - visibleFrame.maxY, remembered: nil,
                                          systemThickness: NSStatusBar.system.thickness)
        return IslandDisplayMetrics.make(frame: frame, auxiliaryLeft: auxiliaryTopLeftArea, auxiliaryRight: auxiliaryTopRightArea,
                                         safeAreaTop: safeAreaInsets.top, barHeight: bar, scale: backingScaleFactor)
    }

    /// The screen under the pointer.
    static var underPointer: NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(point, $0.frame, false) } ?? main
    }
}
