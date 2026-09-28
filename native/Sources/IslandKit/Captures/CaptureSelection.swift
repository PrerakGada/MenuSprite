import CoreGraphics
import Foundation

/// The chooser's tools in their fixed order. The number keys pick them: 1 Screenshot, 2 Screen recording.
public enum CaptureTool: String, CaseIterable, Codable, Sendable {
    case screenshot, recording

    public var title: String { self == .screenshot ? "Screenshot" : "Screen recording" }
    public var symbol: String { self == .screenshot ? "camera.viewfinder" : "record.circle" }
    /// Only a recording has sound, so only its tool shows the "Mac sound" and "Microphone" switches.
    public var showsAudioOptions: Bool { self == .recording }
    public var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public init?(number: Int) {
        guard Self.allCases.indices.contains(number - 1) else { return nil }
        self = Self.allCases[number - 1]
    }
}

/// What happens to a screenshot as soon as it is taken. "Ask each time" leaves it to the preview.
public enum CaptureAfterAction: String, CaseIterable, Codable, Sendable {
    case ask, save, saveAndCopy, copy

    public var title: String {
        switch self {
        case .ask: "Ask each time"
        case .save: "Save"
        case .saveAndCopy: "Save & Copy"
        case .copy: "Copy"
        }
    }

    public var saves: Bool { self == .save || self == .saveAndCopy }
    public var copies: Bool { self == .copy || self == .saveAndCopy }
    public var isAutomatic: Bool { self != .ask }
}

/// A drag on the selection surface, in the display's own top-left point space (the space
/// ScreenCaptureKit's source rectangle uses). A press that never moves 4 pt is a click, which picks a
/// window. Shift makes a square, Option grows from the starting point, and Space held during the drag
/// moves the whole selection instead of resizing it. The result is clamped to the display.
public struct CaptureDragSelection: Equatable, Sendable {
    public static let clickTolerance: CGFloat = 4
    public static let minimumSide: CGFloat = 2

    public let bounds: CGRect
    public private(set) var anchor: CGPoint
    public private(set) var current: CGPoint
    public private(set) var square = false
    public private(set) var fromCenter = false
    /// True once the pointer has travelled beyond the click tolerance.
    public private(set) var isDrag = false
    private var pointer: CGPoint

    public init(start: CGPoint, bounds: CGRect) {
        self.bounds = bounds
        anchor = start
        current = start
        pointer = start
    }

    public mutating func drag(to point: CGPoint, square: Bool = false, fromCenter: Bool = false, moving: Bool = false) {
        defer { pointer = point }
        if !isDrag, hypot(point.x - anchor.x, point.y - anchor.y) >= Self.clickTolerance { isDrag = true }
        if moving, isDrag {
            let before = rect
            var dx = point.x - pointer.x
            var dy = point.y - pointer.y
            dx = min(max(dx, bounds.minX - before.minX), bounds.maxX - before.maxX)
            dy = min(max(dy, bounds.minY - before.minY), bounds.maxY - before.maxY)
            anchor.x += dx; anchor.y += dy
            current.x += dx; current.y += dy
            return
        }
        current = point
        self.square = square
        self.fromCenter = fromCenter
    }

    /// Changing Shift or Option mid-drag reshapes the selection without moving the pointer.
    public mutating func setModifiers(square: Bool, fromCenter: Bool) {
        self.square = square
        self.fromCenter = fromCenter
    }

    public var isClick: Bool { !isDrag }

    /// The selected area, clamped to the display.
    public var rect: CGRect {
        var dx = current.x - anchor.x
        var dy = current.y - anchor.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        let raw: CGRect
        if fromCenter {
            raw = CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy), width: 2 * abs(dx), height: 2 * abs(dy))
        } else {
            raw = CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy))
        }
        let clamped = raw.intersection(bounds)
        return clamped.isNull ? .zero : clamped
    }

    /// The area to capture, or nil for a click or a selection under 2 × 2 pt.
    public var usableRect: CGRect? {
        let rect = rect
        guard isDrag, rect.width >= Self.minimumSide, rect.height >= Self.minimumSide else { return nil }
        return rect
    }
}

/// One on-screen window as the window list reports it, in global top-left points.
public struct CaptureWindowInfo: Equatable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    public var layer: Int
    public var alpha: Double
    public var isOnScreen: Bool

    public init(id: UInt32, frame: CGRect, layer: Int = 0, alpha: Double = 1, isOnScreen: Bool = true) {
        self.id = id; self.frame = frame; self.layer = layer; self.alpha = alpha; self.isOnScreen = isOnScreen
    }
}

/// Which window a click on the selection surface picks.
public enum CaptureWindowPicker {
    public static let minimumSide: CGFloat = 40

    /// Ordinary windows only: the normal layer, on screen, visible, at least 40 × 40 pt.
    public static func isPickable(_ window: CaptureWindowInfo) -> Bool {
        window.layer == 0 && window.isOnScreen && window.alpha > 0.01
            && window.frame.width >= minimumSide && window.frame.height >= minimumSide
    }

    /// The frontmost pickable window containing `point`. `windows` is ordered front to back, as the
    /// window server lists them; windows in `excluding` (the capture's own) are never picked.
    public static func pick(at point: CGPoint, in windows: [CaptureWindowInfo], excluding: Set<UInt32> = []) -> CaptureWindowInfo? {
        windows.first { !excluding.contains($0.id) && isPickable($0) && $0.frame.contains(point) }
    }
}

/// Conversions between AppKit's global space (origin at the primary display's bottom-left, y up) and
/// the window server's (origin at its top-left, y down), and from points to an image's pixels.
public enum CaptureCoordinates {
    public static func quartz(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public static func quartz(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A rectangle in a display's local points, as whole pixels of an image of that display.
    public static func pixels(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
    }
}

/// Recorded areas land on even pixel edges (video encoders want even sizes) and are never smaller
/// than 32 px either way; the result stays inside the display.
public enum CaptureRecordingArea {
    public static let minimumPixels: CGFloat = 32

    public static func snap(_ rect: CGRect, scale: CGFloat, bounds: CGRect) -> CGRect {
        let scale = max(scale, 1)
        func even(_ value: CGFloat, _ round: FloatingPointRoundingRule) -> CGFloat { (value / 2).rounded(round) * 2 }
        let limitW = even(bounds.width * scale, .down)
        let limitH = even(bounds.height * scale, .down)
        let originX = bounds.minX * scale
        let originY = bounds.minY * scale
        var width = min(limitW, max(minimumPixels, even(rect.width * scale, .up)))
        var height = min(limitH, max(minimumPixels, even(rect.height * scale, .up)))
        width = max(0, width); height = max(0, height)
        var x = originX + even(rect.minX * scale - originX, .down)
        var y = originY + even(rect.minY * scale - originY, .down)
        x = min(max(x, originX), originX + limitW - width)
        y = min(max(y, originY), originY + limitH - height)
        return CGRect(x: x / scale, y: y / scale, width: width / scale, height: height / scale)
    }
}

/// How dark the selection surface is. With the controls in the island the frozen screen is shown
/// as it is until a drag begins; a drag, or the standalone chooser, dims it a little.
public enum CaptureDim {
    public static let standard = 0.22

    public static func amount(controlsInIsland: Bool, dragging: Bool) -> Double {
        controlsInIsland && !dragging ? 0 : standard
    }
}
