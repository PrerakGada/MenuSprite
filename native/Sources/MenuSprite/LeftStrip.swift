import AppKit
import ApplicationServices
import SystemMonitoring

/// Which sprites sit on the left strip rather than the right side of the menu bar. Kept apart from the
/// sprite's configuration: it is where a sprite sits on this Mac, and nothing moves until Prerak moves it.
@MainActor
final class SpritePlacement: ObservableObject {
    static let shared = SpritePlacement()
    private static let key = "MenuSprite.LeftStripSprites"
    private static let revealKey = "MenuSprite.LeftStripReveal"
    private let defaults: UserDefaults
    private var left: Set<UUID>
    var changed: (() -> Void)?

    /// What pointing at the strip does. Prerak's default (29 Sep): the sprites answer clicks and drags at
    /// once, and resting on the strip for `hoverDelay` fades it to show the app's menus. He tried ⌘ for the
    /// sprites and rejected it: two hands to read a board. The first design, ⌘ for the menus, stays a choice.
    enum Reveal: String, CaseIterable, Identifiable {
        case hover, command
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hover: "Sprites first · rest on the strip for the app's menus"
            case .command: "Sprites stay · hold ⌘ for the app's menus"
            }
        }
    }
    var reveal: Reveal {
        didSet {
            guard reveal != oldValue else { return }
            defaults.set(reveal.rawValue, forKey: Self.revealKey)
            changed?()
        }
        willSet { objectWillChange.send() }
    }

    static let hoverDelays: [Double] = [0.5, 1, 1.5, 2, 3]
    private static let delayKey = "MenuSprite.LeftStripHoverDelay"
    /// Seconds of resting on the strip before it fades to show the app's menus.
    var hoverDelay: Double {
        willSet { objectWillChange.send() }
        didSet { defaults.set(hoverDelay, forKey: Self.delayKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverDelay = (defaults.object(forKey: Self.delayKey) as? Double).map { min(max($0, 0.2), 10) } ?? 1
        left = Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(UUID.init(uuidString:)))
        reveal = defaults.string(forKey: Self.revealKey).flatMap(Reveal.init(rawValue:)) ?? .hover
    }
    func isLeft(_ id: UUID) -> Bool { left.contains(id) }
    func setLeft(_ id: UUID, _ value: Bool) {
        guard isLeft(id) != value else { return }
        objectWillChange.send()
        if value { left.insert(id) } else { left.remove(id) }
        defaults.set(left.map(\.uuidString).sorted(), forKey: Self.key)
        changed?()
    }
}

/// A sprite's button on the strip. A secondary click reaches the sprite's action the way a status
/// item's `sendAction(on: .rightMouseUp)` does, and the first click counts although MenuSprite is
/// never the active app.
private final class StripButton: NSButton {
    weak var strip: LeftStrip?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// A press that moves more than a few points drags the sprite along the strip; otherwise it is a
    /// click, sent on mouse-up like a status item's.
    override func mouseDown(with event: NSEvent) {
        guard let window, let strip else { super.mouseDown(with: event); return }
        strip.spritesInUse()
        let start = event.locationInWindow.x
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let dx = next.locationInWindow.x - start
            if next.type == .leftMouseUp {
                if dragging { strip.endDrag() } else { sendAction(action, to: target) }
                return
            }
            if !dragging, abs(dx) > 3 { dragging = true; strip.beginDrag(self) }
            if dragging { strip.drag(by: dx) }
        }
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) { strip?.spritesInUse(); sendAction(action, to: target) }
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
/// menus and stops before the notch or the first status item. By default the sprites take clicks and
/// drags at once, and resting on the strip for a moment fades it so the real menus can be used; the
/// other choice keeps the sprites and fades them while ⌘ is held. Either way a menu opened through the faded strip keeps it
/// faded until the menu closes. Spec: `docs/left-strip.md`.
@MainActor
final class LeftStrip {
    private let panel = StripPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let root = StripRootView()
    private let pill = NSView()
    private var buttons: [NSButton] = []
    private var ids: [UUID] = []
    /// Called with the strip's sprites in their new order after one is dragged.
    var reorder: (([UUID]) -> Void)?
    private var dragged: NSButton?
    private var dragStartX: CGFloat = 0
    private var hoverSince: Double?
    /// A sprite was clicked or dragged: no fading until the pointer leaves, so a board being read keeps its strip.
    private var inUse = false
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
        button.strip = self
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        return button
    }

    /// The strip's sprites, left to right.
    func arrange(_ entries: [(id: UUID, button: NSButton)]) {
        let buttons = entries.map(\.button)
        for button in self.buttons where !buttons.contains(button) { button.removeFromSuperview() }
        for button in buttons where button.superview !== pill { pill.addSubview(button) }
        self.buttons = buttons; ids = entries.map(\.id)
        relayout()
    }

    /// Places the strip for the current screen, app and sprite widths. Cheap enough to run on every
    /// sprite redraw: the menus and status items are read only when the app, space or screen changes.
    func relayout() {
        guard let screen = NSScreen.main, let bar = Self.menuBar(on: screen), !buttons.isEmpty else { hide(); return }
        var limit = Self.notchLeftEdge(on: screen) ?? screen.frame.maxX
        if let statusLimit, statusLimit > bar.minX { limit = min(limit, statusLimit) }
        let start = menus?.start ?? Self.estimatedAppNameEnd(on: screen)
        for button in buttons where button !== dragged { button.sizeToFit() }
        let content = Self.padding * 2 + buttons.reduce(0) { $0 + $1.frame.width } + Self.spacing * CGFloat(buttons.count - 1)
        guard let span = LeftStripLayout.span(start: start, menusEnd: menus?.end.map(Double.init), limit: limit, content: content) else { hide(); return }
        let frame = NSRect(x: span.x, y: bar.minY, width: span.width, height: bar.height).integral
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        let inset: CGFloat = bar.height > 30 ? 4 : 2
        pill.frame = NSRect(x: 0, y: inset, width: frame.width, height: frame.height - inset * 2)
        pill.layer?.cornerRadius = pill.frame.height / 2
        placeButtons(animated: false)
        if !panel.isVisible { panel.alphaValue = revealed ? 0 : 1; panel.orderFrontRegardless() }
    }

    private func hide() { if panel.isVisible { panel.orderOut(nil) } }

    /// Each sprite in its slot, in `buttons` order; a sprite being dragged stays under the pointer.
    private func placeButtons(animated: Bool) {
        var x = Self.padding
        for button in buttons {
            let size = button.frame.size
            let frame = NSRect(x: x, y: ((pill.frame.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + Self.spacing
            if button === dragged { continue }
            if animated { button.animator().frame = frame } else { button.frame = frame }
        }
    }

    // MARK: Dragging to reorder

    fileprivate func spritesInUse() { inUse = true; hoverSince = nil }

    fileprivate func beginDrag(_ button: NSButton) {
        dragged = button; dragStartX = button.frame.minX
        pill.addSubview(button, positioned: .above, relativeTo: nil)
    }

    fileprivate func drag(by dx: CGFloat) {
        guard let dragged, let from = buttons.firstIndex(of: dragged) else { return }
        let x = min(max(dragStartX + dx, 0), pill.frame.width - dragged.frame.width)
        dragged.frame.origin.x = x
        // The slot is where the dragged sprite's centre falls among the others' centres.
        let centre = x + dragged.frame.width / 2
        var others = buttons; others.remove(at: from)
        let to = others.firstIndex { $0.frame.midX > centre } ?? others.count
        guard to != from else { return }
        buttons.remove(at: from); buttons.insert(dragged, at: to)
        ids.insert(ids.remove(at: from), at: to)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            placeButtons(animated: true)
        }
    }

    fileprivate func endDrag() {
        guard dragged != nil else { return }
        dragged = nil
        placeButtons(animated: false)
        reorder?(ids)
    }

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

    // MARK: Showing the real menus

    /// Watches the pointer and ⌘ only while the pointer is over the strip or the strip is faded: a
    /// global key monitor would need Accessibility and would run all day. Changing the reveal choice
    /// while faded is settled on the next tick.
    private func watchPointer() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pointerTick() } }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
        pointerTick()
    }

    private func pointerTick() {
        guard dragged == nil else { return }
        let command = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command
        let over = panel.isVisible && panel.frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
        switch SpritePlacement.shared.reveal {
        case .command:
            if revealed {
                if !command && !menuOpen { setRevealed(false) }
                return
            }
            if command && over { setRevealed(true); return }
        case .hover:
            if revealed {
                // Leaving brings the sprites back, unless a menu is open; ⌘ over the strip does at once.
                if over ? command : !menuOpen { setRevealed(false) }
                return
            }
            if over && !command && !inUse {
                // Sprites answer clicks until the pointer has rested this long; then the menus show.
                let now = ProcessInfo.processInfo.systemUptime
                if let since = hoverSince { if now - since >= SpritePlacement.shared.hoverDelay { setRevealed(true) } } else { hoverSince = now }
                return
            }
            hoverSince = nil
            if !over { inUse = false }
        }
        if !over { pointerTimer?.invalidate(); pointerTimer = nil }
    }

    private func setRevealed(_ value: Bool) {
        revealed = value; hoverSince = nil
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
