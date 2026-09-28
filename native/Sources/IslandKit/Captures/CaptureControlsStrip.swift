import CoreGraphics
import Foundation

/// The capture controls hosted in the island while a capture chooses its area. They collapse to a
/// small target after 3 s without use, but never while the pointer is over them, a control has
/// keyboard focus or a menu is open; the condition is checked again when the deadline arrives. The
/// target reopens them on a click, or once the pointer has rested on it for 0.25 s. A drag on the
/// selection surface hides them completely; a drag that selects nothing brings back only the target.
///
/// Times are plain seconds from any clock, so the rules run the same under test. Each chooser session
/// has its own number, and a deadline scheduled for an earlier session changes nothing.
public struct CaptureControlsStrip: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case expanded, collapsed, hidden, ended }

    public static let idleDelay: Double = 3
    public static let hoverDelay: Double = 0.25

    public let session: Int
    public private(set) var phase: Phase = .expanded
    public private(set) var collapseAt: Double?
    public private(set) var reopenAt: Double?
    private var pointerInside = false
    private var focused = false
    private var menuOpen = false
    /// Set by a manual collapse: a pointer that has not moved off the target does not reopen it.
    private var reopenBlocked = false

    public init(session: Int, now: Double) {
        self.session = session
        collapseAt = now + Self.idleDelay
    }

    public var inUse: Bool { pointerInside || focused || menuOpen }
    public var isExpanded: Bool { phase == .expanded }

    /// When the next deadline falls, if any.
    public var nextDeadline: Double? {
        switch phase {
        case .expanded: collapseAt
        case .collapsed: reopenAt
        case .hidden, .ended: nil
        }
    }

    /// The pointer moved. `inside` is whether it is over what currently takes clicks: the controls
    /// while expanded, the target while collapsed. Moving about outside never postpones a collapse.
    public mutating func pointer(inside: Bool, now: Double) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        switch phase {
        case .expanded:
            if !inside { collapseAt = now + Self.idleDelay }
        case .collapsed:
            if inside {
                reopenAt = reopenBlocked ? nil : now + Self.hoverDelay
            } else {
                reopenAt = nil
                reopenBlocked = false
            }
        case .hidden, .ended:
            break
        }
    }

    /// A control gained or lost keyboard focus. Losing it restores the full 3 s.
    public mutating func focus(_ focused: Bool, now: Double) {
        self.focused = focused
        if !focused, phase == .expanded { collapseAt = now + Self.idleDelay }
    }

    public mutating func menu(_ open: Bool, now: Double) {
        menuOpen = open
        if !open, phase == .expanded { collapseAt = now + Self.idleDelay }
    }

    /// The Collapse button. The pointer is treated as resting where it is, so it cannot reopen the
    /// controls until it has left the target.
    public mutating func collapse() {
        guard phase == .expanded else { return }
        phase = .collapsed
        collapseAt = nil
        reopenAt = nil
        pointerInside = false
        reopenBlocked = true
    }

    /// A click on the target reopens the controls without cancelling the capture.
    public mutating func activateTarget(now: Double) {
        guard phase == .collapsed else { return }
        expand(now: now)
    }

    /// A drag began on the selection surface: nothing of the strip shows or takes clicks.
    public mutating func dragBegan() {
        guard phase != .ended else { return }
        phase = .hidden
        collapseAt = nil
        reopenAt = nil
        pointerInside = false
    }

    /// A drag ended without selecting anything: only the target returns.
    public mutating func dragEnded() {
        guard phase == .hidden else { return }
        phase = .collapsed
        reopenBlocked = false
    }

    /// The capture finished or was cancelled; nothing is left scheduled.
    public mutating func end() {
        phase = .ended
        collapseAt = nil
        reopenAt = nil
    }

    /// Applies a deadline that has arrived. A deadline for another session does nothing. Returns true
    /// when the phase changed.
    @discardableResult
    public mutating func tick(now: Double, session: Int) -> Bool {
        guard session == self.session else { return false }
        switch phase {
        case .expanded:
            guard let at = collapseAt, now >= at else { return false }
            collapseAt = nil
            // In use: stay open; the deadline is set again when the use ends.
            guard !inUse else { return false }
            phase = .collapsed
            reopenBlocked = false
            return true
        case .collapsed:
            guard let at = reopenAt, now >= at else { return false }
            expand(now: now)
            return true
        case .hidden, .ended:
            return false
        }
    }

    /// Whether a point in the strip's window takes the mouse. Everywhere else clicks fall through to the
    /// selection surface; while collapsed (including during the collapse animation) only the target counts.
    public func takesMouse(at point: CGPoint, controls: CGRect, target: CGRect) -> Bool {
        switch phase {
        case .expanded: controls.contains(point)
        case .collapsed: target.contains(point)
        case .hidden, .ended: false
        }
    }

    private mutating func expand(now: Double) {
        phase = .expanded
        reopenAt = nil
        reopenBlocked = false
        // The pointer (or the click) is on the target, which is part of the expanded controls.
        pointerInside = true
        collapseAt = now + Self.idleDelay
    }
}

/// Sizes of the capture controls in the island.
public enum CaptureControlsGeometry {
    public static let cameraGap: CGFloat = 10
    public static let headerHeight: CGFloat = 28
    public static let headerSpacing: CGFloat = 12
    public static let toolsHeight: CGFloat = 74
    public static let bottomInset: CGFloat = 16
    public static let audioRowHeight: CGFloat = 40
    public static let targetExtraWidth: CGFloat = 56

    /// Below the camera: the header, the tool tiles and, for the recording tool, the audio switches.
    public static func expandedHeight(cutoutHeight: CGFloat, tool: CaptureTool) -> CGFloat {
        cutoutHeight + cameraGap + headerHeight + headerSpacing + toolsHeight + bottomInset
            + (tool.showsAudioOptions ? audioRowHeight : 0)
    }

    /// The collapsed target: 28 pt either side of the camera, as tall as the closed island.
    public static func collapsedSize(cutout: IslandCutout) -> CGSize {
        CGSize(width: cutout.width + targetExtraWidth, height: cutout.height)
    }
}
