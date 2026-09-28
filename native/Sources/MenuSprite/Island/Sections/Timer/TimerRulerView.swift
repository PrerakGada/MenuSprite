import AppKit
import IslandKit
import SwiftUI

/// The minute ruler as a SwiftUI view: drag, click, scroll or use the arrow keys to pick 1…180
/// minutes. One haptic tick per minute.
struct TimerRulerView: NSViewRepresentable {
    @Binding var minutes: Int
    var enabled = true
    var accessibilityLabel = "Minutes"
    var onStep: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TimerRulerControl {
        let control = TimerRulerControl()
        control.value = TimerRuler.clamp(minutes)
        control.changed = { [weak coordinator = context.coordinator] value in coordinator?.changed(value) }
        return control
    }

    func updateNSView(_ control: TimerRulerControl, context: Context) {
        context.coordinator.parent = self
        control.isEnabled = enabled
        control.setAccessibilityLabel(accessibilityLabel)
        let value = TimerRuler.clamp(minutes)
        if !control.isTracking, control.value != value { control.value = value }
    }

    @MainActor
    final class Coordinator {
        var parent: TimerRulerView
        init(_ parent: TimerRulerView) { self.parent = parent }
        func changed(_ value: Int) {
            parent.minutes = value
            parent.onStep()
        }
    }
}

/// A horizontal tape of minute ticks 14 pt apart, centred on a fixed orange pointer. Drawn in
/// `draw(_:)` (only the ticks in view), with its own mouse, scroll and key handling, and exposed to
/// VoiceOver as an adjustable slider whose value is spoken as a duration.
final class TimerRulerControl: NSControl {
    var value = 15 {
        didSet { if value != oldValue { needsDisplay = true } }
    }
    var changed: ((Int) -> Void)?
    private(set) var isTracking = false

    private var drag: TimerRuler.Drag?
    private var pressX: CGFloat = 0
    private var moved = false
    private var scroll = TimerRuler.Scroll()
    private var keyboardFocus = false

    /// The row the ruler was designed for; everything scales with the actual height.
    private static let designHeight: CGFloat = 82

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.designHeight) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { needsDisplay = true } }
    }

    private func set(_ minutes: Int) {
        let clamped = TimerRuler.clamp(minutes)
        guard clamped != value else { return }
        value = clamped
        changed?(clamped)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if keyboardFocus { keyboardFocus = false; needsDisplay = true }
        let x = convert(event.locationInWindow, from: nil).x
        drag = TimerRuler.Drag(startX: x, value: value)
        pressX = x
        moved = false
        isTracking = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = drag else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if !moved, abs(x - pressX) < 3 { return }
        moved = true
        let minutes = current.move(to: x)
        drag = current
        set(minutes)
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; isTracking = false }
        guard drag != nil, !moved else { return }
        let x = convert(event.locationInWindow, from: nil).x
        set(TimerRuler.minute(atOffset: x - bounds.midX, selected: value))
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else { super.scrollWheel(with: event); return }
        if event.phase == .began || event.phase == .mayBegin { scroll.reset() }
        let steps = scroll.steps(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                 precise: event.hasPreciseScrollingDeltas)
        if steps != 0 { set(value + steps) }
        if [.ended, .cancelled].contains(event.phase) || [.ended, .cancelled].contains(event.momentumPhase) {
            scroll.reset()
        }
    }

    // MARK: Keyboard

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            keyboardFocus = NSApp.currentEvent?.type == .keyDown
            needsDisplay = true
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { keyboardFocus = false; needsDisplay = true }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let key: TimerRuler.Key? = switch event.specialKey {
        case .leftArrow?: .left
        case .rightArrow?: .right
        case .upArrow?: .up
        case .downArrow?: .down
        case .home?: .home
        case .end?: .end
        default: nil
        }
        guard isEnabled, let key else { super.keyDown(with: event); return }
        set(TimerRuler.minute(after: key, selected: value))
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { NSNumber(value: value) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: TimerRuler.range.lowerBound) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: TimerRuler.range.upperBound) }
    override func accessibilityValueDescription() -> String? { TimerFormat.spokenMinutes(value) }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard isEnabled, let number = accessibilityValue as? NSNumber else { return }
        set(TimerRuler.clamp(number.doubleValue))
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        set(value + 1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        set(value - 1)
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let scale = bounds.height / Self.designHeight
        let labelHeight = 18 * scale
        let tickTop = labelHeight + 5 * scale
        let tickHeight = 38 * scale
        let enabledAlpha: CGFloat = isEnabled ? 1 : 0.4
        let dim: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.65 : 0.35
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 14 * scale, weight: .medium)
        let centre = bounds.midX

        for minute in TimerRuler.visibleMinutes(selected: value, width: bounds.width) {
            let offset = TimerRuler.offset(of: minute, selected: value)
            let fade = TimerRuler.edgeOpacity(offset: offset, width: bounds.width)
            guard fade > 0 else { continue }
            let x = centre + offset
            let strength = minute <= value ? 1 : dim
            NSColor.systemOrange.withAlphaComponent(strength * fade * enabledAlpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 2, y: tickTop, width: 4, height: tickHeight), xRadius: 2, yRadius: 2).fill()
            guard TimerRuler.hasLabel(minute) else { continue }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: NSColor.white.withAlphaComponent((minute == value ? 0.95 : 0.6) * fade * enabledAlpha),
            ]
            let text = TimerRuler.label(minute) as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: x - size.width / 2, y: (labelHeight - size.height) / 2), withAttributes: attributes)
        }

        // The fixed pointer under the selected tick.
        let pointerTop = tickTop + tickHeight + 5 * scale
        let half = 5 * scale
        let pointer = NSBezierPath()
        pointer.move(to: NSPoint(x: centre, y: pointerTop))
        pointer.line(to: NSPoint(x: centre + half, y: pointerTop + 7 * scale))
        pointer.line(to: NSPoint(x: centre - half, y: pointerTop + 7 * scale))
        pointer.close()
        NSColor.systemOrange.withAlphaComponent(enabledAlpha).setFill()
        pointer.fill()

        if keyboardFocus, window?.firstResponder === self {
            NSColor.systemOrange.withAlphaComponent(0.8).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            ring.lineWidth = 1
            ring.stroke()
        }
    }
}
