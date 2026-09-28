import AppKit
import SwiftUI

/// A borderless, non-activating, key-capable floating panel for the island's tools when they open in
/// their own window (the floating scratchpad, the clipboard history window). Typing and pasting still
/// land in the app behind it.
@MainActor
final class FloatingToolPanel: NSPanel {
    /// Esc, unless something inside handled it first (an input method composing handles its own Esc).
    var onCancel: (() -> Void)?

    init(size: CGSize, minimum: CGSize, resizable: Bool) {
        var style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        if resizable { style.insert(.resizable) }
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        minSize = minimum
        isMovableByWindowBackground = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .unknown }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Owns one tool panel: built when it opens, released when it closes, so nothing is held at rest.
/// Opens centred on the pointer's screen, 58% of the way up, and keeps its spot while the app runs.
/// Closes on Esc and on a click outside (local and global monitors, 2-pt tolerance), unless
/// `keepsOpen` says otherwise at the moment of the click.
@MainActor
final class FloatingToolWindow {
    private let size: CGSize
    private let minimum: CGSize
    private let resizable: Bool
    private let title: String
    private var panel: FloatingToolPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var savedFrame: NSRect?

    /// Read at click time: true while pinned or while a dialog of the tool is up.
    var keepsOpen: () -> Bool = { false }
    /// Called after the panel closed, for any reason.
    var didClose: (() -> Void)?
    /// Whether the panel holds the keyboard; published for ⌘-number badges and focus.
    let keyState = FloatingToolKeyState()

    init(title: String, size: CGSize, minimum: CGSize, resizable: Bool) {
        self.title = title
        self.size = size
        self.minimum = minimum
        self.resizable = resizable
    }

    var isVisible: Bool { panel?.isVisible == true }
    var isKey: Bool { panel?.isKeyWindow == true }
    var window: NSWindow? { panel }

    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }

    /// Shows the panel with `content`, fading in over 0.13 s, and gives it the keyboard.
    func show<Content: View>(_ content: @autoclosure () -> Content) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = FloatingToolPanel(size: savedFrame?.size ?? size, minimum: minimum, resizable: resizable)
        panel.title = title
        panel.onCancel = { [weak self] in self?.close() }
        let host = NSHostingView(rootView: content().environment(\.colorScheme, .dark))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(placement(for: panel.frame.size), display: false)
        self.panel = panel
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.13
            panel.animator().alphaValue = 1
        }
        keyState.isKey = panel.isKeyWindow
        installMonitors(panel)
    }

    func focus() { panel?.makeKeyAndOrderFront(nil) }

    func close() {
        guard let panel else { return }
        savedFrame = panel.frame
        removeMonitors()
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
        keyState.isKey = false
        didClose?()
    }

    private func placement(for size: CGSize) -> NSRect {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let savedFrame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedFrame) }) {
            return NSRect(origin: savedFrame.origin, size: size)
        }
        var origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.58 - size.height / 2)
        origin.x = min(max(origin.x, visible.minX + 16), visible.maxX - size.width - 16)
        origin.y = min(max(origin.y, visible.minY + 16), visible.maxY - size.height - 16)
        return NSRect(origin: origin, size: size)
    }

    private func installMonitors(_ panel: FloatingToolPanel) {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.outsideClick(at: NSEvent.mouseLocation, window: nil) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.outsideClick(at: NSEvent.mouseLocation, window: event.window) }
            return event
        }) { monitors.append(local) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyState.isKey = true }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyState.isKey = false }
        })
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func outsideClick(at point: NSPoint, window: NSWindow?) {
        guard let panel, panel.isVisible else { return }
        // The tool's own alerts and save panels are not "outside".
        if let window, window !== panel, window.level == IslandToolDialogs.level || window is NSSavePanel || window.isSheet { return }
        if window === panel || panel.frame.insetBy(dx: -2, dy: -2).contains(point) { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.AccessibilityVisualsAgent" { return }
        if keepsOpen() { return }
        close()
    }
}

/// The panel's key state as something SwiftUI can observe.
@MainActor
final class FloatingToolKeyState: ObservableObject {
    @Published var isKey = false
}

/// Alerts and save panels raised by the island's tools: their own windows, one level above the
/// island, never sheets (a sheet would move and reskin the borderless island).
@MainActor
enum IslandToolDialogs {
    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

    /// Runs an alert above the island and returns the button pressed.
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        alert.window.level = level
        alert.window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        return PanelInteraction.suspended { alert.runModal() }
    }

    /// Asks for a name in an alert with a 240-pt field. Nil when cancelled.
    static func askForName(title: String, current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return run(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// A destructive confirmation; true when confirmed.
    static func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return run(alert) == .alertFirstButtonReturn
    }

    /// A save panel above the island. The completion gets the chosen URL, or nil when cancelled.
    static func save(suggestedName: String, completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        panel.level = level
        panel.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        NSApp.activate()
        panel.begin { response in
            let url = response == .OK ? panel.url : nil
            MainActor.assumeIsolated { completion(url) }
        }
    }
}
