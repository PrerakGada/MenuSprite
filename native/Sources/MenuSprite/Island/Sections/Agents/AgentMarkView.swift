import AppKit
import IslandKit
import QuartzCore
import SwiftUI

extension AgentKind {
    var color: Color { Color(red: tint.red, green: tint.green, blue: tint.blue) }
    var nsColor: NSColor { NSColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1) }
}

extension AgentLimitTone {
    func color(_ agent: AgentKind) -> Color {
        switch self {
        case .agent: agent.color
        case .orange: .orange
        case .red: .red
        }
    }
}

/// A decoration that moves only while someone can see it: its window visible and not covered, the
/// view and its ancestors shown, and Reduce Motion off. The motion is a compositor animation on a
/// layer, so no timer or view update runs while it plays, and updates keep its phase.
class AgentMotionView: NSView {
    var wantsMotion = false { didSet { if wantsMotion != oldValue { refreshMotion() } } }
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        removeObservers()
        guard let newWindow else { return }
        let occlusion = NotificationCenter.default
        observers.append((occlusion, occlusion.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                           object: newWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMotion() }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMotion() }
        }))
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshMotion() }
    override func viewDidHide() { super.viewDidHide(); refreshMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshMotion() }

    func teardown() {
        removeObservers()
        stopMotion()
    }

    private func removeObservers() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
    }

    func refreshMotion() {
        let visible = window.map { $0.occlusionState.contains(.visible) } ?? false
        if wantsMotion, visible, !isHiddenOrHasHiddenAncestor, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startMotion()
        } else {
            stopMotion()
        }
    }

    func startMotion() {}
    func stopMotion() {}
}

/// An agent's mark, drawn once into a small bitmap in its tint. It breathes while its agent works.
final class AgentMarkLayerView: AgentMotionView {
    private let mark = CALayer()
    private var drawn: (symbol: String, size: CGFloat, scale: CGFloat, tint: NSColor)?
    var agent: AgentKind = .claude { didSet { redraw() } }
    var size: CGFloat = 14 { didSet { redraw(); needsLayout = true } }
    var tint: NSColor? { didSet { redraw() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(mark)
        mark.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        mark.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); redraw() }

    private func redraw() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let color = tint ?? agent.nsColor
        if let drawn, drawn.symbol == agent.symbol, drawn.size == size, drawn.scale == scale, drawn.tint == color { return }
        drawn = (agent.symbol, size, scale, color)
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.86, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: agent.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let canvas = NSSize(width: size, height: size)
        let image = NSImage(size: canvas, flipped: false) { rect in
            let fitted = symbol.size.width > 0 ? min(rect.width / symbol.size.width, rect.height / symbol.size.height, 1) : 1
            let box = NSSize(width: symbol.size.width * fitted, height: symbol.size.height * fitted)
            let target = NSRect(x: (rect.width - box.width) / 2, y: (rect.height - box.height) / 2, width: box.width, height: box.height)
            symbol.draw(in: target)
            color.set()
            target.fill(using: .sourceAtop)
            return true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.contentsScale = scale
        mark.contents = image.layerContents(forContentsScale: scale)
        CATransaction.commit()
    }

    override func startMotion() {
        guard mark.animation(forKey: "breathe") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.84
        scale.toValue = 1.0
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.7
        opacity.toValue = 1.0
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 1.2
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        mark.add(group, forKey: "breathe")
    }

    override func stopMotion() { mark.removeAnimation(forKey: "breathe") }
}

/// A small solid dot with a ring that spreads and fades while an agent works.
final class AgentPulseLayerView: AgentMotionView {
    private let dot = CALayer()
    private let ring = CAShapeLayer()
    var color: NSColor = .white { didSet { applyColor() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)
        ring.fillColor = nil
        ring.lineWidth = 1
        ring.opacity = 0
        applyColor()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height) / 1.9
        let frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        dot.frame = frame
        dot.cornerRadius = side / 2
        ring.bounds = CGRect(origin: .zero, size: frame.size)
        ring.position = CGPoint(x: frame.midX, y: frame.midY)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        CATransaction.commit()
    }

    private func applyColor() {
        dot.backgroundColor = color.cgColor
        ring.strokeColor = color.cgColor
    }

    override func startMotion() {
        guard ring.animation(forKey: "pulse") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.9
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.6
        opacity.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 1.6
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: "pulse")
    }

    override func stopMotion() { ring.removeAnimation(forKey: "pulse") }
}

/// An agent's mark in SwiftUI: still, or breathing while the agent works.
struct AgentMark: NSViewRepresentable {
    var agent: AgentKind
    var size: CGFloat
    var animated = false
    var tint: Color?

    func makeNSView(context: Context) -> AgentMarkLayerView { AgentMarkLayerView(frame: .zero) }

    func updateNSView(_ view: AgentMarkLayerView, context: Context) {
        view.agent = agent
        view.size = size
        view.tint = tint.map { NSColor($0) }
        view.wantsMotion = animated
    }

    static func dismantleNSView(_ view: AgentMarkLayerView, coordinator: ()) { view.teardown() }
}

/// The working dot beside a card's title.
struct AgentPulse: NSViewRepresentable {
    var color: Color
    var active = true

    func makeNSView(context: Context) -> AgentPulseLayerView { AgentPulseLayerView(frame: .zero) }

    func updateNSView(_ view: AgentPulseLayerView, context: Context) {
        view.color = NSColor(color)
        view.wantsMotion = active
    }

    static func dismantleNSView(_ view: AgentPulseLayerView, coordinator: ()) { view.teardown() }
}
