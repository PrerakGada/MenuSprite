import AppKit
import IslandKit
import QuartzCore

/// The selection surface on one display: a borderless panel above everything showing the frozen
/// screen, with a crosshair. It takes the first click even while the island holds the keyboard.
@MainActor
final class CaptureOverlayPanel: CaptureUtilityPanel {
    let overlay: CaptureOverlayView

    init(screen: NSScreen, image: CGImage, chooser: CaptureChooser) {
        overlay = CaptureOverlayView(size: screen.frame.size, image: image, displayID: screen.captureDisplayID,
                                     scale: screen.backingScaleFactor)
        super.init(frame: screen.frame, level: NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())))
        allowsKey = true
        acceptsMouseMovedEvents = true
        overlay.chooser = chooser
        contentView = overlay
        setFrame(screen.frame, display: false)
    }

    func dismiss() {
        overlay.chooser = nil
        retire()
    }
}

/// Draws the frozen display, the dim, the selection and the window under the pointer with Core
/// Animation layers (the still image is composited once, so dragging only moves outlines), and turns
/// mouse and keys into chooser events. Points are handled in the display's top-left space.
@MainActor
final class CaptureOverlayView: NSView {
    let displayID: CGDirectDisplayID
    let scale: CGFloat
    weak var chooser: CaptureChooser?
    private(set) var selection: CaptureDragSelection?
    private var highlight: CGRect?
    private var reportedDrag = false

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let sizeLayer = CATextLayer()

    init(size: CGSize, image: CGImage, displayID: CGDirectDisplayID, scale: CGFloat) {
        self.displayID = displayID
        self.scale = scale
        super.init(frame: CGRect(origin: .zero, size: size))
        let root = CALayer()
        layer = root
        wantsLayer = true
        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds
        dimLayer.fillRule = .evenOdd
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth = 1
        highlightLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        highlightLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        highlightLayer.lineWidth = 2
        sizeLayer.fontSize = 11
        sizeLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLayer.foregroundColor = NSColor.white.cgColor
        sizeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        sizeLayer.cornerRadius = 5
        sizeLayer.alignmentMode = .center
        sizeLayer.contentsScale = scale
        sizeLayer.isHidden = true
        for sublayer in [imageLayer, dimLayer, highlightLayer, borderLayer, sizeLayer] { root.addSublayer(sublayer) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /// Pointer moves arrive on every display, not only the key one.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    /// Shows the window a click would pick (display top-left points), or nothing.
    func setHighlight(_ rect: CGRect?) {
        guard rect != highlight else { return }
        highlight = rect
        refresh()
    }

    /// Clears a selection that ended without capturing anything.
    func clearSelection() {
        selection = nil
        reportedDrag = false
        refresh()
    }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let selected = selection.flatMap { $0.isDrag ? $0.rect : nil }
        let dim = CaptureDim.amount(controlsInIsland: chooser?.inIsland ?? false, dragging: selected != nil)
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        if let selected { dimPath.addRect(layerRect(selected)) }
        dimLayer.path = dimPath
        dimLayer.fillColor = NSColor.black.withAlphaComponent(dim).cgColor
        borderLayer.path = selected.map { CGPath(rect: layerRect($0).insetBy(dx: -0.5, dy: -0.5), transform: nil) }
        highlightLayer.path = (selected == nil ? highlight : nil).map { CGPath(rect: layerRect($0).insetBy(dx: 1, dy: 1), transform: nil) }
        if let selected, selected.width >= 1, selected.height >= 1 {
            let pixels = CaptureCoordinates.pixels(selected, scale: scale)
            sizeLayer.string = "\(Int(pixels.width)) × \(Int(pixels.height))"
            let width: CGFloat = 96
            var frame = CGRect(x: selected.maxX - width, y: selected.maxY + 6, width: width, height: 18)
            if frame.maxY > bounds.height - 4 { frame.origin.y = selected.maxY - 24 }
            frame.origin.x = max(4, frame.minX)
            sizeLayer.frame = layerRect(frame)
            sizeLayer.isHidden = false
        } else {
            sizeLayer.isHidden = true
        }
        CATransaction.commit()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        NSCursor.crosshair.set()
        selection = CaptureDragSelection(start: topLeft(event), bounds: bounds)
        reportedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard var selection, let chooser else { return }
        let flags = event.modifierFlags
        selection.drag(to: topLeft(event), square: flags.contains(.shift), fromCenter: flags.contains(.option), moving: chooser.spaceHeld)
        self.selection = selection
        if selection.isDrag, !reportedDrag {
            reportedDrag = true
            chooser.dragBegan(on: self)
        }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection else { return }
        chooser?.selectionEnded(selection, on: self, at: topLeft(event))
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        chooser?.pointerMoved(to: NSEvent.mouseLocation)
    }

    override func flagsChanged(with event: NSEvent) {
        guard var selection else { return }
        selection.setModifiers(square: event.modifierFlags.contains(.shift), fromCenter: event.modifierFlags.contains(.option))
        self.selection = selection
        refresh()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if chooser?.handleKey(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == CaptureKeyCode.space { chooser?.spaceReleased() }
    }

    // MARK: Geometry

    private func topLeft(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    /// A top-left rectangle in the layer's bottom-left space.
    private func layerRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}
