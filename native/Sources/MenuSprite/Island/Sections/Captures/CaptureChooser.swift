import AppKit
import IslandKit

/// One display photographed as the chooser opened. Screenshots of an area or the whole display are
/// cut from this still, so they show exactly what the person saw while choosing.
struct FrozenDisplay {
    let displayID: CGDirectDisplayID
    /// The display's frame in AppKit's global space.
    let frame: CGRect
    let scale: CGFloat
    let image: CGImage
}

/// An area remembered for "Repeat the last region" (R).
struct CaptureRegion: Equatable {
    let displayID: CGDirectDisplayID
    /// Display top-left points.
    let rect: CGRect
}

/// What the person chose.
struct CaptureChoice {
    enum Target {
        /// Display top-left points.
        case area(CGRect)
        case window(CaptureWindowInfo)
        case display
    }

    let tool: CaptureTool
    let target: Target
    let display: FrozenDisplay
    let snapshot: CaptureSnapshot
}

/// One selection session: the frozen displays under a selection surface, and the capture controls in
/// the island (collapsing after 3 s of no use) or in a floating bar. The service allows one at a time.
/// Everything it schedules belongs to its session number and ends with it.
@MainActor
final class CaptureChooser {
    /// What the controls draw; the chooser keeps it current.
    let controls: CaptureControlsModel
    private(set) var strip: CaptureControlsStrip
    let inIsland: Bool
    let session: Int
    let options: CaptureOptions
    let canRepeat: Bool
    private(set) var spaceHeld = false
    /// A drag is under way on any display (keys arrive at whichever overlay is key).
    private var dragging = false

    private let snapshot: CaptureSnapshot
    private let displays: [FrozenDisplay]
    private let excluded: Set<CGWindowID>
    private let lastRegion: CaptureRegion?
    private let islandScreen: NSScreen?
    private let settings: IslandSettings
    private var overlays: [CaptureOverlayPanel] = []
    private var controlsPanel: CaptureControlsPanel?
    private var deadline: Task<Void, Never>?
    private var scheduledAt: Double?
    private var finished = false
    private let finish: (CaptureChoice?) -> Void

    init(tool: CaptureTool, session: Int, inIsland: Bool, islandScreen: NSScreen?, settings: IslandSettings,
         options: CaptureOptions, snapshot: CaptureSnapshot, displays: [FrozenDisplay], excluded: Set<CGWindowID>,
         lastRegion: CaptureRegion?, finish: @escaping (CaptureChoice?) -> Void) {
        self.session = session
        self.inIsland = inIsland
        self.islandScreen = islandScreen
        self.settings = settings
        self.options = options
        self.snapshot = snapshot
        self.displays = displays
        self.excluded = excluded
        self.lastRegion = lastRegion
        self.finish = finish
        canRepeat = lastRegion.map { region in displays.contains { $0.displayID == region.displayID } } ?? false
        strip = CaptureControlsStrip(session: session, now: Self.now)
        controls = CaptureControlsModel(tool: tool, canRepeat: canRepeat)
        controls.select = { [weak self] in self?.select($0) }
        controls.collapse = { [weak self] in self?.collapse() }
        controls.reopen = { [weak self] in self?.activateTarget() }
        controls.close = { [weak self] in self?.cancel() }
        controls.repeatRegion = { [weak self] in self?.repeatRegion() }
    }

    var tool: CaptureTool { controls.tool }

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Puts the surface on every display and the controls on top, and takes the keyboard.
    func present() {
        for display in displays {
            guard let screen = NSScreen.screens.first(where: { $0.captureDisplayID == display.displayID }) else { continue }
            let panel = CaptureOverlayPanel(screen: screen, image: display.image, chooser: self)
            panel.orderFrontRegardless()
            overlays.append(panel)
        }
        let pointerScreen = NSScreen.underPointer
        let controlScreen = inIsland ? (islandScreen ?? pointerScreen) : pointerScreen
        if let controlScreen {
            let panel = CaptureControlsPanel(chooser: self, screen: controlScreen, inIsland: inIsland, settings: settings)
            panel.orderFrontRegardless()
            controlsPanel = panel
        }
        NSApp.activate()
        let key = overlays.first { $0.screen == pointerScreen } ?? overlays.first
        key?.makeKeyAndOrderFront(nil)
        if let key { key.makeFirstResponder(key.overlay) }
        pointerMoved(to: NSEvent.mouseLocation)
        scheduleDeadline()
    }

    /// Closes everything this session opened; nothing stays scheduled.
    func end() {
        deadline?.cancel()
        deadline = nil
        scheduledAt = nil
        updateStrip { $0.end() }
        overlays.forEach { $0.dismiss() }
        overlays.removeAll()
        controlsPanel?.retire()
        controlsPanel = nil
    }

    // MARK: From the controls

    func select(_ tool: CaptureTool) {
        guard tool != self.tool else { return }
        controls.tool = tool
        controlsPanel?.layoutForTool()
    }

    func collapse() {
        updateStrip { $0.collapse() }
        stripChanged()
    }

    func activateTarget() {
        updateStrip { $0.activateTarget(now: Self.now) }
        stripChanged()
    }

    func cancel() { complete(nil) }

    func repeatRegion() {
        guard canRepeat, let region = lastRegion, let display = displays.first(where: { $0.displayID == region.displayID }) else {
            NSSound.beep()
            return
        }
        complete(CaptureChoice(tool: tool, target: .area(region.rect), display: display, snapshot: snapshot))
    }

    // MARK: From the selection surface

    func pointerMoved(to global: CGPoint) {
        if let panel = controlsPanel, inIsland {
            let local = panel.topLeft(global)
            let inside = strip.takesMouse(at: local, controls: panel.expandedRect, target: panel.targetRect)
            panel.ignoresMouseEvents = !inside
            updateStrip { $0.pointer(inside: inside, now: Self.now) }
            scheduleDeadline()
        }
        updateHighlight(global)
    }

    func dragBegan(on overlay: CaptureOverlayView) {
        dragging = true
        updateStrip { $0.dragBegan() }
        stripChanged()
        overlays.forEach { $0.overlay.setHighlight(nil) }
    }

    func selectionEnded(_ selection: CaptureDragSelection, on overlay: CaptureOverlayView, at point: CGPoint) {
        dragging = false
        spaceHeld = false
        guard let display = displays.first(where: { $0.displayID == overlay.displayID }) else { return }
        if let rect = selection.usableRect {
            complete(CaptureChoice(tool: tool, target: .area(rect), display: display, snapshot: snapshot))
        } else if selection.isClick, let window = pickWindow(at: point, on: display) {
            complete(CaptureChoice(tool: tool, target: .window(window), display: display, snapshot: snapshot))
        } else {
            overlay.clearSelection()
            if strip.phase == .hidden {
                updateStrip { $0.dragEnded() }
                stripChanged()
            }
        }
    }

    /// Returns true when the key was handled.
    func handleKey(_ event: NSEvent) -> Bool {
        switch CaptureChooserKeys.action(for: CaptureKeyPress(event), context: .init(dragging: dragging)) {
        case .cancel:
            complete(nil)
        case .captureDisplay:
            let point = NSEvent.mouseLocation
            guard let display = displays.first(where: { $0.frame.contains(point) }) ?? displays.first else { return true }
            complete(CaptureChoice(tool: tool, target: .display, display: display, snapshot: snapshot))
        case .repeatRegion:
            repeatRegion()
        case .selectTool(let tool):
            select(tool)
        case .moveSelection:
            spaceHeld = true
        case .passThrough, .activateFocused, .ignore:
            // The controls never hold keyboard focus (they are clicked, not tabbed to), so there is
            // nothing to pass a key to; swallowing it avoids the system's beep.
            break
        }
        return true
    }

    func spaceReleased() { spaceHeld = false }

    // MARK: Private

    /// Publishes the strip only when it really changed, so pointer moves do not redraw the controls.
    private func updateStrip(_ change: (inout CaptureControlsStrip) -> Void) {
        var next = strip
        change(&next)
        guard next != strip else { return }
        strip = next
        if controls.phase != next.phase { controls.phase = next.phase }
    }

    /// Hides everything at once, but releases the windows only after the event that ended the session
    /// (a mouse-up or key in one of them) has returned.
    private func complete(_ choice: CaptureChoice?) {
        guard !finished else { return }
        finished = true
        overlays.forEach { $0.orderOut(nil) }
        controlsPanel?.orderOut(nil)
        Task { @MainActor in
            self.end()
            self.finish(choice)
        }
    }

    private func stripChanged() {
        if let panel = controlsPanel {
            panel.stripChanged(strip.phase)
            if inIsland, strip.phase != .hidden {
                panel.ignoresMouseEvents = !strip.takesMouse(at: panel.topLeft(NSEvent.mouseLocation),
                                                             controls: panel.expandedRect, target: panel.targetRect)
            }
        }
        scheduleDeadline()
    }

    /// One task waits for the strip's next deadline; it belongs to this session only, and is replaced
    /// only when the deadline moves.
    private func scheduleDeadline() {
        let at = inIsland ? strip.nextDeadline : nil
        guard at != scheduledAt else { return }
        scheduledAt = at
        deadline?.cancel()
        guard let at else { deadline = nil; return }
        let session = self.session
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, at - Self.now)))
            guard !Task.isCancelled, let self else { return }
            self.scheduledAt = nil
            var changed = false
            self.updateStrip { changed = $0.tick(now: Self.now, session: session) }
            if changed { self.stripChanged() } else { self.scheduleDeadline() }
        }
    }

    private func pickWindow(at point: CGPoint, on display: FrozenDisplay) -> CaptureWindowInfo? {
        let origin = displayOrigin(display)
        let global = CGPoint(x: point.x + origin.x, y: point.y + origin.y)
        return CaptureWindowPicker.pick(at: global, in: snapshot.windows, excluding: excluded)
    }

    private func updateHighlight(_ global: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let quartz = CaptureCoordinates.quartz(global, primaryHeight: primaryHeight)
        let window = strip.phase == .hidden ? nil : CaptureWindowPicker.pick(at: quartz, in: snapshot.windows, excluding: excluded)
        for panel in overlays {
            guard let display = displays.first(where: { $0.displayID == panel.overlay.displayID }), let window,
                  display.frame.contains(global) else {
                panel.overlay.setHighlight(nil)
                continue
            }
            let origin = displayOrigin(display)
            panel.overlay.setHighlight(window.frame.offsetBy(dx: -origin.x, dy: -origin.y))
        }
    }

    /// The display's top-left corner in the window server's global space.
    private func displayOrigin(_ display: FrozenDisplay) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CaptureCoordinates.quartz(display.frame, primaryHeight: primaryHeight).origin
    }
}
