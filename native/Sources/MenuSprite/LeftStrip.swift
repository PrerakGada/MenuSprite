import AppKit
import ApplicationServices
import SystemMonitoring

/// Which sprites sit on the left strip rather than the right side of the menu bar. Kept apart from the
/// sprite's configuration: it is where a sprite sits on this Mac, and nothing moves until Prerak moves it.
@MainActor
final class SpritePlacement {
    static let shared = SpritePlacement()
    private static let key = "MenuSprite.LeftStripSprites"
    private let defaults: UserDefaults
    private var left: Set<UUID>
    var changed: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        left = Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(UUID.init(uuidString:)))
    }
    func isLeft(_ id: UUID) -> Bool { left.contains(id) }
    func setLeft(_ id: UUID, _ value: Bool) {
        guard isLeft(id) != value else { return }
        if value { left.insert(id) } else { left.remove(id) }
        defaults.set(left.map(\.uuidString).sorted(), forKey: Self.key)
        changed?()
    }
}

/// A sprite's button on the strip. A secondary click reaches the sprite's action the way a status
/// item's `sendAction(on: .rightMouseUp)` does, and the first click counts although MenuSprite is
/// never the active app.
private final class StripButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) { sendAction(action, to: target) }
}

/// The strip's content view: reports the pointer arriving, so ⌘ is only watched while it is there.
private final class StripRootView: NSView {
    var entered: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { entered?() }
}

private final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Sprites drawn over the frontmost app's menus, on the left of the menu bar, so the right side keeps
/// its room for macOS and other apps. The strip starts after the app's bold name, covers the app's
/// menus and stops before the notch or the first status item. Pointing at it and holding ⌘ fades it
/// and lets clicks through to the real menus; letting go brings it back, unless a menu is open, in
/// which case it waits for the menu to close. Spec: `docs/left-strip.md`.
@MainActor
final class LeftStrip {
    private let panel = StripPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let root = StripRootView()
    private let pill = NSView()
    private var buttons: [NSButton] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The frontmost app's menus in screen x: the app-name menu's right edge and the last menu's. Nil
    /// until read; `end` is nil when Accessibility could not read them.
    private var menus: (start: CGFloat, end: CGFloat?)?
    private var statusLimit: CGFloat?
    private var readGeneration = 0
    private var revealed = false
    private var menuOpen = false
    private var pointerTimer: Timer?
    private static let padding: CGFloat = 8
    private static let spacing: CGFloat = 10

    init() {
        panel.level = .statusBar
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.animationBehavior = .none
        // No .fullScreenAuxiliary: a full-screen app has no menu bar for the strip to sit on.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Black like the Island, so sprites drawn for a dark bar (white numbers) stay readable.
        panel.appearance = NSAppearance(named: .darkAqua)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.cgColor
        root.addSubview(pill)
        root.entered = { [weak self] in self?.watchPointer() }
        panel.contentView = root

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshZone() }
            }))
        }
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshZone() }
        }))
        // Any app's menu tracking is announced here; it only matters while the strip is faded, to keep
        // it faded while a menu opened through it is still open.
        let distributed = DistributedNotificationCenter.default()
        for (name, open) in [("com.apple.HIToolbox.beginMenuTrackingNotification", true), ("com.apple.HIToolbox.endMenuTrackingNotification", false)] {
            observers.append((distributed, distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuOpen = open }
            }))
        }
        refreshZone()
    }

    func tearDown() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        pointerTimer?.invalidate(); pointerTimer = nil
        for button in buttons { button.removeFromSuperview() }
        buttons = []
        panel.orderOut(nil)
    }

    func makeButton() -> NSButton {
        let button = StripButton()
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        return button
    }

    /// The strip's sprites, left to right.
    func arrange(_ buttons: [NSButton]) {
        for button in self.buttons where !buttons.contains(button) { button.removeFromSuperview() }
        for button in buttons where button.superview !== pill { pill.addSubview(button) }
        self.buttons = buttons
        relayout()
    }

    /// Places the strip for the current screen, app and sprite widths. Cheap enough to run on every
    /// sprite redraw: the menus and status items are read only when the app, space or screen changes.
    func relayout() {
        guard let screen = NSScreen.main, let bar = Self.menuBar(on: screen), !buttons.isEmpty else { hide(); return }
        var limit = Self.notchLeftEdge(on: screen) ?? screen.frame.maxX
        if let statusLimit, statusLimit > bar.minX { limit = min(limit, statusLimit) }
        let start = menus?.start ?? Self.estimatedAppNameEnd(on: screen)
        for button in buttons { button.sizeToFit() }
        let content = Self.padding * 2 + buttons.reduce(0) { $0 + $1.frame.width } + Self.spacing * CGFloat(buttons.count - 1)
        guard let span = LeftStripLayout.span(start: start, menusEnd: menus?.end.map(Double.init), limit: limit, content: content) else { hide(); return }
        let frame = NSRect(x: span.x, y: bar.minY, width: span.width, height: bar.height).integral
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        let inset: CGFloat = bar.height > 30 ? 4 : 2
        pill.frame = NSRect(x: 0, y: inset, width: frame.width, height: frame.height - inset * 2)
        pill.layer?.cornerRadius = pill.frame.height / 2
        var x = Self.padding
        for button in buttons {
            let size = button.frame.size
            button.frame = NSRect(x: x, y: ((pill.frame.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + Self.spacing
        }
        if !panel.isVisible { panel.alphaValue = revealed ? 0 : 1; panel.orderFrontRegardless() }
    }

    private func hide() { if panel.isVisible { panel.orderOut(nil) } }

    // MARK: Where the strip may sit

    /// Re-reads the frontmost app's menus and the leftmost status item. Menus are read again shortly
    /// after, because an app that has only just launched is still building its menu bar.
    private func refreshZone() {
        statusLimit = Self.leftmostStatusItem(on: NSScreen.main, excluding: panel.isVisible ? CGWindowID(panel.windowNumber) : nil)
        readGeneration += 1
        let generation = readGeneration
        relayout()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        for delay in [0.0, 0.5, 1.5] {
            Task { @MainActor [weak self] in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                let frames = await Task.detached(priority: .utility) { AppMenuBarReader.frames(pid: pid) }.value
                guard let self, generation == self.readGeneration else { return }
                self.applyMenus(frames)
            }
        }
    }

    private func applyMenus(_ frames: [CGRect]?) {
        guard let screen = NSScreen.main else { return }
        // Accessibility reports x in the same global space Cocoa uses; y is not needed.
        let onScreen = (frames ?? []).filter { $0.width > 0 && $0.minX >= screen.frame.minX - 1 && $0.maxX <= screen.frame.maxX + 1 }
        // The first two are the Apple menu and the app's bold name; those stay visible. Unreadable
        // menus fall back to the estimate rather than keeping the previous app's.
        guard onScreen.count >= 2 else { menus = nil; relayout(); return }
        menus = (onScreen[1].maxX, onScreen.count > 2 ? onScreen.dropFirst(2).map(\.maxX).max() : onScreen[1].maxX)
        relayout()
    }

    /// The menu bar's rectangle, or nil when the bar is hidden (auto-hide, or a full-screen space).
    private static func menuBar(on screen: NSScreen) -> NSRect? {
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        guard height >= 16 else { return nil }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    private static func notchLeftEdge(on screen: NSScreen) -> CGFloat? {
        guard var area = screen.auxiliaryTopLeftArea, area.width > 0, area.width < screen.frame.width else { return nil }
        // Reported in screen-local points on some displays; bring it into global space.
        if !screen.frame.intersects(area) { area = area.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }
        return area.maxX
    }

    /// Without Accessibility the app's menus cannot be read; this places the strip after the app's
    /// name by measuring it in the menu bar's bold font, with room for the Apple menu before it.
    private static func estimatedAppNameEnd(on screen: NSScreen) -> CGFloat {
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: .regular))
        return screen.frame.minX + 44 + (name as NSString).size(withAttributes: [.font: font]).width + 16
    }

    /// The left edge of the leftmost status item on the screen's menu bar. Window bounds and levels are
    /// readable without Screen Recording; nothing else about those windows is read.
    private static func leftmostStatusItem(on screen: NSScreen?, excluding own: CGWindowID?) -> CGFloat? {
        guard let screen, let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let top = primary.frame.maxY - screen.frame.maxY
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        var leftmost: CGFloat?
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == statusLayer,
                  (info[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) }) != own,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  abs(rect.minY - top) < 2, rect.height < 60,
                  rect.minX >= screen.frame.minX, rect.maxX <= screen.frame.maxX + 1 else { continue }
            leftmost = min(leftmost ?? rect.minX, rect.minX)
        }
        return leftmost
    }

    // MARK: Hold ⌘ for the real menus

    /// Watches the pointer and ⌘ only while the pointer is over the strip or the strip is faded: a
    /// global key monitor would need Accessibility and would run all day.
    private func watchPointer() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pointerTick() } }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
        pointerTick()
    }

    private func pointerTick() {
        let command = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command
        let over = panel.isVisible && panel.frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
        if revealed {
            if !command && !menuOpen { setRevealed(false) }
            return
        }
        if command && over { setRevealed(true); return }
        if !over { pointerTimer?.invalidate(); pointerTimer = nil }
    }

    private func setRevealed(_ value: Bool) {
        revealed = value
        panel.ignoresMouseEvents = value
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = value ? 0 : 1
        }
    }
}

/// The frontmost app's menu bar items, read through Accessibility. Frames only — no titles.
enum AppMenuBarReader {
    nonisolated static func frames(pid: pid_t) -> [CGRect]? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // A hung app must not hold the strip up.
        AXUIElementSetMessagingTimeout(app, 0.3)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        return items.compactMap(frame)
    }

    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
