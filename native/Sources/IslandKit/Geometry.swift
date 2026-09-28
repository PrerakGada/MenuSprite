import CoreGraphics
import Foundation

/// The camera housing the island hangs from: the real notch, or one we draw on a display without one.
public struct IslandCutout: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public var isPhysical: Bool
    public init(width: CGFloat, height: CGFloat, isPhysical: Bool) {
        self.width = width; self.height = height; self.isPhysical = isPhysical
    }
}

/// Everything geometry needs to know about the display hosting the island.
public struct IslandDisplayMetrics: Equatable, Sendable {
    /// The display's frame in global Cocoa coordinates (origin bottom-left).
    public var frame: CGRect
    public var cutout: IslandCutout
    /// The menu bar's height on this display.
    public var barHeight: CGFloat
    public var scale: CGFloat

    public init(frame: CGRect, cutout: IslandCutout, barHeight: CGFloat, scale: CGFloat) {
        self.frame = frame; self.cutout = cutout; self.barHeight = barHeight; self.scale = scale
    }

    /// Builds the metrics from what `NSScreen` reports. A display is notched when both the camera
    /// width (the gap between the two auxiliary top areas) and the top safe-area inset are positive.
    public static func make(frame: CGRect, auxiliaryLeft: CGRect?, auxiliaryRight: CGRect?, safeAreaTop: CGFloat,
                            barHeight: CGFloat, scale: CGFloat) -> IslandDisplayMetrics {
        var cameraWidth: CGFloat = 0
        if let left = auxiliaryLeft, let right = auxiliaryRight { cameraWidth = max(0, right.minX - left.maxX) }
        let cameraHeight = min(64, max(0, safeAreaTop))
        let cutout: IslandCutout
        if cameraWidth > 0, cameraHeight > 0 {
            cutout = IslandCutout(width: cameraWidth, height: cameraHeight, isPhysical: true)
        } else {
            // A MacBook-notch profile scaled to this display's menu bar.
            let width = min(180 * barHeight / 32, frame.width * 0.7)
            cutout = IslandCutout(width: width, height: barHeight, isPhysical: false)
        }
        return IslandDisplayMetrics(frame: frame, cutout: cutout, barHeight: max(barHeight, cutout.height), scale: scale)
    }

    /// Pixel-aligns a length or coordinate on this display.
    public func align(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
    public func alignUp(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
}

/// Resolving the menu bar's height: a showing bar measures 16…64, a hidden one falls back to what
/// this display last measured, then to the system thickness, then to 24.
public enum IslandBarHeight {
    public static let valid: ClosedRange<CGFloat> = 16...64
    public static func resolve(measuredGap: CGFloat, remembered: CGFloat?, systemThickness: CGFloat) -> CGFloat {
        if valid.contains(measuredGap) { return measuredGap }
        if let remembered, valid.contains(remembered) { return remembered }
        if valid.contains(systemThickness) { return systemThickness }
        return 24
    }
}

/// The notch-like outline: flat top, concave "shoulders" flaring into the screen edge, straight
/// sides and rounded bottom corners. Sizes scale with height so a 32-pt strip has corners like the
/// real cutout and a collapse settles inside it.
public struct IslandSilhouette: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public init(width: CGFloat, height: CGFloat) { self.width = max(0, width); self.height = max(0, height) }

    public var shoulder: CGFloat { min(14, 0.19 * height) }
    public var cornerRadius: CGFloat { min(28, 0.34 * height) }
    public var bottomRadius: CGFloat { max(0, min(cornerRadius, height / 2, (width - 2 * shoulder) / 2)) }
    /// The width between the shoulders, where content and floating buttons are placed.
    public var bodyWidth: CGFloat { max(0, width - 2 * shoulder) }

    /// The outline in a y-down coordinate space whose origin is the island's top-left corner, offset
    /// by `origin`.
    public func path(origin: CGPoint = .zero) -> CGPath {
        let path = CGMutablePath()
        guard width > 0, height > 0 else { return path }
        let k: CGFloat = 0.5523
        let s = min(shoulder, width / 2)
        let b = bottomRadius
        let x0 = origin.x, y0 = origin.y, w = width, h = height
        path.move(to: CGPoint(x: x0, y: y0))
        // Left shoulder: from the top edge, bending inward and down to (s, s).
        path.addCurve(to: CGPoint(x: x0 + s, y: y0 + s),
                      control1: CGPoint(x: x0 + k * s, y: y0),
                      control2: CGPoint(x: x0 + s, y: y0 + s - k * s))
        path.addLine(to: CGPoint(x: x0 + s, y: y0 + h - b))
        path.addCurve(to: CGPoint(x: x0 + s + b, y: y0 + h),
                      control1: CGPoint(x: x0 + s, y: y0 + h - b + k * b),
                      control2: CGPoint(x: x0 + s + b - k * b, y: y0 + h))
        path.addLine(to: CGPoint(x: x0 + w - s - b, y: y0 + h))
        path.addCurve(to: CGPoint(x: x0 + w - s, y: y0 + h - b),
                      control1: CGPoint(x: x0 + w - s - b + k * b, y: y0 + h),
                      control2: CGPoint(x: x0 + w - s, y: y0 + h - b + k * b))
        path.addLine(to: CGPoint(x: x0 + w - s, y: y0 + s))
        path.addCurve(to: CGPoint(x: x0 + w, y: y0),
                      control1: CGPoint(x: x0 + w - s, y: y0 + s - k * s),
                      control2: CGPoint(x: x0 + w - k * s, y: y0))
        path.closeSubpath()
        return path
    }

    /// Whether a point (same y-down space, island origin at zero) lies inside the drawn shape.
    public func contains(_ point: CGPoint) -> Bool {
        guard point.x >= 0, point.y >= 0, point.x <= width, point.y <= height else { return false }
        return path().contains(point)
    }
}

/// Everything the open island's layout needs.
public struct IslandOpenLayout: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    /// Distance from the island's top to the header row.
    public var headerTop: CGFloat
    public var headerHeight: CGFloat
    /// True when the header splits into halves beside the physical camera.
    public var headerBesideCamera: Bool
    public var contentTop: CGFloat
    public var contentWidth: CGFloat
    public var pageHeight: CGFloat
    public var budget: CGFloat
}

/// How tall a page wants to be.
public enum IslandPageHeight: Equatable, Sendable {
    /// Exactly this tall, capped at the budget.
    case fixed(CGFloat)
    /// As tall as the budget allows (lists).
    case fill
}

public enum IslandGeometry {
    public static let edgeMargin: CGFloat = 12
    public static let restingWing: CGFloat = 44
    public static let horizontalInset: CGFloat = 28
    public static let headerRowHeight: CGFloat = 36
    public static let headerSpacing: CGFloat = 12
    public static let bottomInset: CGFloat = 16
    public static let gutter: CGFloat = 72
    public static let menuMargin: CGFloat = 8
    public static let hoverGrowth: CGFloat = 10
    public static let hoverLift: CGFloat = 5
    public static let floatingDiameter: CGFloat = 44

    public static func presetWidth(_ settings: IslandSettings) -> CGFloat {
        switch settings.size {
        case .compact: 480
        case .spacious: 560
        case .custom: settings.customWidth
        }
    }

    /// The widest a strip may be on this display.
    public static func maxStripWidth(_ display: IslandDisplayMetrics) -> CGFloat {
        display.frame.width - 2 * edgeMargin
    }

    /// A one-row strip: the camera plus a wing each side, as tall as the camera.
    public static func strip(_ display: IslandDisplayMetrics, wing: CGFloat) -> CGSize {
        CGSize(width: min(maxStripWidth(display), display.cutout.width + 2 * max(0, wing)), height: display.cutout.height)
    }

    /// Side room when the island is allowed over the menus: what an empty menu bar would leave.
    public static func emptyBarRoom(_ display: IslandDisplayMetrics) -> CGFloat {
        max(0, (display.frame.width - 2 * menuMargin - display.cutout.width) / 2)
    }

    /// Resting wings are 44 pt or nothing: never drawn cramped.
    public static func restingWing(room: CGFloat?) -> CGFloat {
        guard let room, room >= restingWing else { return 0 }
        return restingWing
    }

    /// The closed island grows a little under the pointer: up to 10 pt per side and 5 pt taller,
    /// never beyond the free room.
    public static func hoverEmphasis(_ base: CGSize, display: IslandDisplayMetrics, room: CGFloat?, currentWing: CGFloat) -> CGSize {
        let free = max(0, (room ?? 0) - currentWing)
        let grow = min(hoverGrowth, free)
        return CGSize(width: min(maxStripWidth(display), base.width + 2 * grow), height: base.height + hoverLift)
    }

    /// The small "Preview on hover" panel.
    public static func peek(_ display: IslandDisplayMetrics) -> CGSize {
        CGSize(width: min(maxStripWidth(display), max(display.cutout.width + 110, 340)),
               height: display.cutout.height + 10 + 52)
    }

    /// Width of the open island: the preset, never narrower than the camera, leaving room for the
    /// floating-button gutters.
    public static func openWidth(_ display: IslandDisplayMetrics, settings: IslandSettings) -> CGFloat {
        let limit = display.frame.width - 2 * edgeMargin - 2 * gutter
        return max(0, min(max(presetWidth(settings), display.cutout.width + 36), limit))
    }

    /// Page budget before the height cap: Compact 180, Spacious 264, Custom from its maximum height.
    /// Vertical pages (lists, detail pages) get at least 320 in the presets.
    public static func budget(_ display: IslandDisplayMetrics, settings: IslandSettings, vertical: Bool,
                              headerTop: CGFloat, headerHeight: CGFloat) -> CGFloat {
        let chrome = headerHeight + headerSpacing + bottomInset
        switch settings.size {
        case .compact: return vertical ? 320 : 180
        case .spacious: return vertical ? 320 : 264
        case .custom: return max(60, settings.customHeight - headerTop - chrome)
        }
    }

    public static func openLayout(_ display: IslandDisplayMetrics, settings: IslandSettings, page: IslandPageHeight,
                                  vertical: Bool = false, forceFullHeaderRow: Bool = false,
                                  hasBottomButtons: Bool = false) -> IslandOpenLayout {
        let width = openWidth(display, settings: settings)
        let contentWidth = max(0, width - 2 * horizontalInset)
        let camera = display.cutout
        let split = camera.isPhysical && !forceFullHeaderRow && contentWidth >= camera.width + 200
        let headerTop: CGFloat = (camera.isPhysical && !split) ? camera.height + 10 : 0
        let headerHeight: CGFloat = split ? max(camera.height, headerRowHeight) : headerRowHeight
        let chrome = headerHeight + headerSpacing + bottomInset
        var budget = budget(display, settings: settings, vertical: vertical, headerTop: headerTop, headerHeight: headerHeight)
        // The display bounds every page, and bottom floating buttons need their own row.
        let screenLimit = display.frame.height - 48 - (hasBottomButtons ? gutter : 0)
        var heightLimit = screenLimit
        if settings.size == .custom { heightLimit = min(heightLimit, settings.customHeight) }
        budget = max(0, min(budget, heightLimit - headerTop - chrome))
        let pageHeight: CGFloat
        switch page {
        case .fill: pageHeight = budget
        case .fixed(let value): pageHeight = min(max(0, value), budget)
        }
        let height = display.alignUp(headerTop + chrome + pageHeight)
        return IslandOpenLayout(width: display.align(width), height: height, headerTop: headerTop, headerHeight: headerHeight,
                                headerBesideCamera: split, contentTop: headerTop + headerHeight + headerSpacing,
                                contentWidth: contentWidth, pageHeight: pageHeight, budget: budget)
    }

    /// The island's frame on screen, in global Cocoa coordinates: centred, hanging from the top edge.
    public static func frame(for size: CGSize, on display: IslandDisplayMetrics) -> CGRect {
        let x = display.align(display.frame.midX - size.width / 2)
        return CGRect(x: x, y: display.frame.maxY - size.height, width: size.width, height: size.height)
    }
}

/// Where the round buttons beside the open island sit, relative to the island's top-left corner in a
/// y-down space, and the corridors that keep a hover-opened island open while the pointer travels to them.
public struct IslandFloatingPlacement: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        public var id: UUID
        public var center: CGPoint
    }
    public var slots: [Slot]
    public var corridors: [CGRect]

    public static let spacing: CGFloat = 54
    public static let offset: CGFloat = 34
    public static let radius: CGFloat = 22
    public static let corridorMargin: CGFloat = 16

    public static func make(layout: IslandFloatingLayout, island: CGSize, headerTop: CGFloat, headerHeight: CGFloat,
                            barHeight: CGFloat) -> IslandFloatingPlacement {
        let silhouette = IslandSilhouette(width: island.width, height: island.height)
        let bodyLeft = silhouette.shoulder
        let bodyRight = island.width - silhouette.shoulder
        let bodyTop = silhouette.shoulder
        let headerCenter = max(headerTop + headerHeight / 2, barHeight + 6 + radius)
        var slots: [Slot] = []
        var corridors: [CGRect] = []
        for side in [IslandFloatingSide.left, .right] {
            let buttons = layout.buttons(on: side)
            guard !buttons.isEmpty else { continue }
            let span = CGFloat(buttons.count - 1) * spacing
            let mid = island.height / 2
            let first = max(bodyTop + radius + 12, min(headerCenter, mid - span / 2))
            let x = side == .left ? bodyLeft - offset : bodyRight + offset
            for (index, button) in buttons.enumerated() {
                slots.append(Slot(id: button.id, center: CGPoint(x: x, y: first + CGFloat(index) * spacing)))
            }
            let top = first - radius, bottom = first + span + radius
            let rect = side == .left
                ? CGRect(x: x - radius, y: top, width: bodyLeft - (x - radius), height: bottom - top)
                : CGRect(x: bodyRight, y: top, width: x + radius - bodyRight, height: bottom - top)
            corridors.append(rect.insetBy(dx: -corridorMargin, dy: -corridorMargin))
        }
        let bottomButtons = layout.buttons(on: .bottom)
        if !bottomButtons.isEmpty {
            let span = CGFloat(bottomButtons.count - 1) * spacing
            let y = island.height + offset
            let startX = island.width / 2 - span / 2
            for (index, button) in bottomButtons.enumerated() {
                slots.append(Slot(id: button.id, center: CGPoint(x: startX + CGFloat(index) * spacing, y: y)))
            }
            let rect = CGRect(x: startX - radius, y: island.height - 1, width: span + 2 * radius, height: offset + radius + 1)
            corridors.append(rect.insetBy(dx: -corridorMargin, dy: -corridorMargin))
        }
        return IslandFloatingPlacement(slots: slots, corridors: corridors)
    }

    /// The slot whose circle contains the point, if any. The gap next to the island takes no clicks.
    public func slot(at point: CGPoint) -> Slot? {
        slots.first { hypot($0.center.x - point.x, $0.center.y - point.y) <= Self.radius }
    }

    public func corridorContains(_ point: CGPoint) -> Bool { corridors.contains { $0.contains(point) } }
}
