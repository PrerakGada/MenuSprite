import AppKit
import SwiftUI

/// A floating utility window for the tools panel and the Command Bar: borderless, non-activating (so
/// the app you were in stays in front), able to take the keyboard, on every Space and over full-screen
/// apps, with a dark HUD surface. Tiling window managers skip it. Keys reach `keyHandler` before
/// anything inside, so arrows and Return work whatever has focus; returning false passes them on.
@MainActor
final class ToolsFloatingPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    init(size: CGSize, cornerRadius: CGFloat, title: String) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.title = title
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let surface = NSVisualEffectView()
        surface.material = .hudWindow
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = cornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        contentView = surface
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .unknown }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Hosts SwiftUI content on the HUD surface.
    func host<Content: View>(_ view: Content) {
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        guard let surface = contentView else { return }
        surface.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: surface.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
    }

    /// Shows with a short fade (none under Reduce Motion) and takes the keyboard.
    func present(at frame: CGRect) {
        setFrame(frame, display: false)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = reduce ? 1 : 0
        makeKeyAndOrderFront(nil)
        guard !reduce else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            animator().alphaValue = 1
        }
    }

    /// The screen under the pointer, where both panels open.
    static var pointerScreen: NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }
}

/// Closes a floating panel when the person clicks elsewhere (within 2 pt of its edge counts as on it)
/// or another app comes forward, unless `suppressed` says the panel is busy (editing, a hosted
/// utility, a dialog). Clicks from the Accessibility Keyboard never count. Installed only while the
/// panel is on screen.
@MainActor
final class FloatingPanelDismissal {
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    func install(on panel: NSPanel, suppressed: @escaping @MainActor @Sendable () -> Bool,
                 dismiss: @escaping @MainActor @Sendable () -> Void) {
        remove()
        let outside: (NSPoint) -> Void = { [weak panel] point in
            guard let panel, !suppressed(), !PanelInteraction.isSuspended, !Self.accessibilityKeyboardInFront,
                  !panel.frame.insetBy(dx: -2, dy: -2).contains(point) else { return }
            dismiss()
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { outside(point) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak panel] event in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                if event.window !== panel { outside(point) }
            }
            return event
        }) { monitors.append(local) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            let bundle = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard pid != ProcessInfo.processInfo.processIdentifier, bundle != Self.accessibilityKeyboard,
                      !suppressed(), !PanelInteraction.isSuspended else { return }
                dismiss()
            }
        })
    }

    func remove() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }

    private static let accessibilityKeyboard = "com.apple.AccessibilityVisualsAgent"
    private static var accessibilityKeyboardInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == accessibilityKeyboard
    }
}
