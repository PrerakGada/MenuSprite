import AppKit
import IslandKit
import QuartzCore
import SwiftUI

/// The island's one window: borderless, non-activating, one level above status items and below menus,
/// on every desktop. Its transparent parts pass clicks to whatever is beneath.
@MainActor
final class IslandPanel: NSPanel {
    /// Set true only for explicit openings, so a hover-opened island never takes the keyboard.
    var allowsKey = false
    var scrollHandler: ((NSEvent) -> Bool)?
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // Stationary, not transient: transient windows vanish on Show Desktop.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        title = "Dynamic Island"
        isMovable = false
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, scrollHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Tiling window managers list non-activating panels described as dialogs; an unknown subrole keeps
    /// the island out of them while it stays an accessibility window.
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .unknown }

    /// Ordering out detaches a sheet without running its completion; end it first.
    override func orderOut(_ sender: Any?) {
        if let sheet = attachedSheet { endSheet(sheet, returnCode: .cancel) }
        super.orderOut(sender)
    }
}

/// The window's content: a flipped container holding a display-sized stage centred at the top. The
/// stage never changes size, so window resizes never make SwiftUI lay out again.
@MainActor
final class IslandHostView: NSView {
    let stage: IslandStageView
    /// Whether a point in stage coordinates takes the mouse.
    var takesMouse: ((CGPoint) -> Bool)?
    var trackingChanged: ((Bool) -> Void)?
    /// File drags over the island: entered (returns whether files are accepted), exited, dropped.
    var dragEntered: (() -> Bool)?
    var dragExited: (() -> Void)?
    var dropped: ((NSPasteboard) -> Bool)?
    /// Whether a drag's pasteboard holds anything the island accepts.
    var accepts: ((NSPasteboard) -> Bool)?
    private var tracking: NSTrackingArea?

    init(stage: IslandStageView) {
        self.stage = stage
        super.init(frame: .zero)
        addSubview(stage)
    }

    /// Registers the dragged types the island accepts (set by the Files section's drop types).
    func acceptDrags(of types: [NSPasteboard.PasteboardType]) {
        unregisterDraggedTypes()
        if !types.isEmpty { registerForDraggedTypes(types) }
    }

    // A drag that started inside MenuSprite (a shelf tile) has a source and is refused.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil, accepts?(sender.draggingPasteboard) == true, dragEntered?() == true else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource == nil && accepts?(sender.draggingPasteboard) == true ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dragExited?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropped?(sender.draggingPasteboard) ?? false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        positionStage()
        updateTrackingAreas()
    }

    func positionStage() {
        let size = stage.frame.size
        stage.setFrameOrigin(NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: 0))
    }

    func stagePoint(fromWindow point: NSPoint) -> CGPoint {
        stage.convert(point, from: nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inStage = stage.convert(point, from: superview)
        guard takesMouse?(inStage) == true else { return nil }
        return super.hitTest(point)
    }

    /// One tracking area over the island's target shape and the floating-button corridors, kept in
    /// stage coordinates and rebuilt whenever the window moves the stage. The target, not the animated
    /// edge: a resize never turns a still pointer into an exit.
    private var trackedRect: CGRect = .null

    func updateTracking(_ rect: CGRect) {
        trackedRect = rect
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard !trackedRect.isNull, !trackedRect.isEmpty else { return }
        let local = convert(trackedRect, from: stage)
        let area = NSTrackingArea(rect: local, options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { trackingChanged?(true) }
    override func mouseExited(with event: NSEvent) { trackingChanged?(false) }
}

/// The stage: the black island canvas masked by the silhouette, the outline, the activation area and
/// the floating buttons. Only the mask and outline paths animate.
@MainActor
final class IslandStageView: NSView {
    /// Flipped like the stage: the mask's path is in top-down stage coordinates, and an unflipped
    /// canvas would draw it mirrored, off the bottom of the window (the island then showed only its outline).
    let canvas = IslandFlippedView()
    let maskLayer = CAShapeLayer()
    let outlineLayer = CAShapeLayer()
    let outlineMask = CALayer()
    let activation = IslandActivationView()
    private(set) var contentHost: NSView?
    private(set) var floatingHost: NSView?
    private var generation = 0
    private var motionStart: CFTimeInterval = 0
    private var motionPlan: IslandMotionPlan?
    private var origin: (CGSize) -> CGPoint = { _ in .zero }

    override var isFlipped: Bool { true }

    init(size: CGSize) {
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.masksToBounds = false
        canvas.frame = bounds
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.black.cgColor
        maskLayer.frame = bounds
        maskLayer.fillColor = NSColor.black.cgColor
        maskLayer.isGeometryFlipped = false
        canvas.layer?.mask = maskLayer
        addSubview(canvas)
        outlineLayer.frame = bounds
        outlineLayer.fillColor = nil
        outlineLayer.lineWidth = 2
        outlineLayer.strokeColor = NSColor.white.withAlphaComponent(0.65).cgColor
        outlineLayer.isHidden = true
        // The top point of the stroke is left undrawn so no line runs along the screen edge.
        outlineMask.backgroundColor = NSColor.black.cgColor
        outlineMask.frame = CGRect(x: 0, y: 1, width: size.width, height: size.height - 1)
        outlineLayer.mask = outlineMask
        layer?.addSublayer(outlineLayer)
        addSubview(activation)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func install(content: NSView, floating: NSView) {
        content.frame = bounds
        canvas.addSubview(content)
        contentHost = content
        floating.frame = bounds
        addSubview(floating, positioned: .below, relativeTo: activation)
        floatingHost = floating
    }

    func setOrigin(_ origin: @escaping (CGSize) -> CGPoint) { self.origin = origin }

    /// The size on screen right now, mid-motion included, so a reversal continues from it.
    func presentedSize(fallback: CGSize) -> CGSize {
        guard let plan = motionPlan, plan.duration > 0 else { return fallback }
        let elapsed = CACurrentMediaTime() - motionStart
        guard elapsed < plan.duration else { return plan.target }
        let index = min(plan.sizes.count - 1, max(0, Int(elapsed * IslandMotionPlan.sampleRate)))
        return plan.sizes[index]
    }

    func path(for size: CGSize) -> CGPath {
        IslandSilhouette(width: size.width, height: size.height).path(origin: origin(size))
    }

    /// Animates the silhouette through a planned resize; `completion` runs once, for the latest motion only.
    func animate(_ plan: IslandMotionPlan, outline: NSColor?, completion: @escaping () -> Void) {
        generation += 1
        let current = generation
        let finalPath = path(for: plan.target)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineLayer.isHidden = outline == nil
        if let outline { outlineLayer.strokeColor = outline.cgColor }
        if plan.isEmpty || plan.duration <= 0 {
            maskLayer.removeAllAnimations()
            outlineLayer.removeAllAnimations()
            maskLayer.path = finalPath
            outlineLayer.path = finalPath
            motionPlan = nil
            CATransaction.commit()
            completion()
            return
        }
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = plan.sizes.map { path(for: $0) }
        animation.keyTimes = plan.sizes.indices.map { NSNumber(value: Double($0) / Double(plan.sizes.count - 1)) }
        animation.duration = plan.duration
        animation.calculationMode = .linear
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.generation == current else { return }
            self.motionPlan = nil
            completion()
        }
        // Core Animation does not promise which thread runs this: hop explicitly, never assume.
        CATransaction.setCompletionBlock { @Sendable in
            DispatchQueue.main.async { MainActor.assumeIsolated { finish() } }
        }
        maskLayer.path = finalPath
        outlineLayer.path = finalPath
        maskLayer.add(animation, forKey: "morph")
        outlineLayer.add(animation, forKey: "morph")
        motionPlan = plan
        motionStart = CACurrentMediaTime()
        CATransaction.commit()
        CATransaction.flush()
    }

    func setOutline(_ color: NSColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineLayer.isHidden = color == nil
        if let color { outlineLayer.strokeColor = color.cgColor }
        CATransaction.commit()
    }
}

final class IslandFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A transparent click target over the camera region: a press cancels a pending hover, a release toggles.
@MainActor
final class IslandActivationView: NSView {
    var pressed: (() -> Void)?
    var released: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed?() }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { released?() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
}

/// A hosting view that takes the first click even when the island is not key. With `hitArea` set,
/// it takes only points inside that area and lets everything else reach the views beneath.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var hitArea: ((CGPoint) -> Bool)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hitArea, !hitArea(convert(point, from: superview)) { return nil }
        return super.hitTest(point)
    }
}
