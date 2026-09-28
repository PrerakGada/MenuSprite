import AppKit
import IslandKit

/// Opens the separate shelf window when the pointer is shaken while dragging content from another
/// app, with one passive global monitor of left mouse down, drag and up: no event tap and no
/// Accessibility grant. Per gesture it reads the drag pasteboard's change count and checks its types
/// only once that count moves. A 0.15-s watchdog runs only during a content drag and reads the
/// physical button, because a mouse-up can be swallowed. Exists only while the island runs with Files
/// in a separate window and shake-to-open on. (The island's own drop target is revealed by the shell.)
@MainActor
final class ShelfDragWatcher {
    /// Whether drags from this app (by bundle identifier) are ignored.
    var isExcluded: (String?) -> Bool = { _ in false }
    /// The pointer was shaken during a content drag.
    var onShake: () -> Void = {}

    private var monitor: Any?
    private let pasteboard = NSPasteboard(name: .drag)
    private var gesture = ShelfDragGesture()
    private var shake = ShelfShakeDetector()
    private var watchdog: Timer?
    private var excluded = false
    private var sourceWindow = 0

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            let type = event.type, window = event.windowNumber, x = Double(NSEvent.mouseLocation.x), time = event.timestamp
            MainActor.assumeIsolated { self?.handle(type, window: window, x: x, time: time) }
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: handler)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endGesture()
    }

    private func handle(_ type: NSEvent.EventType, window: Int, x: Double, time: TimeInterval) {
        switch type {
        case .leftMouseDown:
            gesture.mouseDown(changeCount: pasteboard.changeCount)
            beginGesture(window: window)
        case .leftMouseDragged:
            if !gesture.isActive { beginGesture(window: window) }
            if gesture.needsChangeCount {
                let count = pasteboard.changeCount
                if gesture.dragged(changeCount: count, hasDroppableType: { ShelfPasteboard.hasDroppableType(pasteboard) }) {
                    startWatchdog()
                    excluded = isExcluded(Self.sourceApp(window: sourceWindow))
                }
            }
            if gesture.isContentDrag, !excluded, shake.move(x: x, at: time) { onShake() }
        case .leftMouseUp:
            endGesture()
        default:
            break
        }
    }

    private func beginGesture(window: Int) {
        sourceWindow = window
        excluded = false
        shake.reset()
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if !CGEventSource.buttonState(.combinedSessionState, button: .left) { self?.endGesture() }
            }
        }
    }

    private func endGesture() {
        watchdog?.invalidate()
        watchdog = nil
        gesture.mouseUp()
    }

    /// The app the drag started in: the owner of the window under the mouse-down (one window's
    /// details, which needs no screen-recording grant), else the frontmost app.
    static func sourceApp(window: Int) -> String? {
        if window > 0, let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window)) as? [[String: Any]],
           let pid = info.first?[kCGWindowOwnerPID as String] as? pid_t {
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
