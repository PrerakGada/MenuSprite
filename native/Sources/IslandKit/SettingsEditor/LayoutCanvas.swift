import CoreGraphics
import Foundation

/// The Layout tab's editing canvas: the open island at half size (smaller in narrow windows) with the
/// floating buttons as editor circles around it, the "+" slots, the drop zones shown while dragging and
/// the resize grip. All positions are canvas points, y down. The circles keep editor spacing rather than
/// the live island's, so they stay usable when the preview is small.
public struct IslandLayoutCanvas: Equatable, Sendable {
    /// Tall enough for the tallest custom island at half size plus the bottom zone.
    public static let height: CGFloat = 400
    public static let islandTop: CGFloat = 20
    public static let maximumScale: CGFloat = 0.5
    public static let minimumScale: CGFloat = 0.2
    public static let horizontalAllowance: CGFloat = 112
    public static let buttonDiameter: CGFloat = 30
    public static let sideOffset: CGFloat = 18
    public static let firstSlotOffset: CGFloat = 30
    public static let slotSpacing: CGFloat = 40
    public static let bottomOffset: CGFloat = 24
    public static let gripDiameter: CGFloat = 24
    /// The grip sits at least this far below the island's top, clear of the third right slot.
    public static let gripMinimumDrop: CGFloat = 139
    public static let gripInset: CGFloat = 3
    public static let sideZoneWidth: CGFloat = 62
    /// How far outside the island a side zone begins.
    public static let sideZoneReach: CGFloat = 48
    public static let bottomZoneHeight: CGFloat = 58
    /// A press that moves less than this is a click, not a drag.
    public static let dragThreshold: CGFloat = 5

    public var canvasWidth: CGFloat
    /// The island's real size, before scaling.
    public var islandSize: CGSize
    public var scale: CGFloat
    /// The scaled island in the canvas.
    public var island: CGRect

    public init(canvasWidth: CGFloat, islandSize: CGSize) {
        self.canvasWidth = canvasWidth
        self.islandSize = islandSize
        scale = Self.scale(canvasWidth: canvasWidth, islandWidth: islandSize.width)
        let width = islandSize.width * scale, height = islandSize.height * scale
        island = CGRect(x: (canvasWidth - width) / 2, y: Self.islandTop, width: width, height: height)
    }

    /// Half size, or (canvas width − 112) ÷ island width when that is smaller, never below 20 %.
    public static func scale(canvasWidth: CGFloat, islandWidth: CGFloat) -> CGFloat {
        guard islandWidth > 0 else { return maximumScale }
        return min(maximumScale, max(minimumScale, (canvasWidth - horizontalAllowance) / islandWidth))
    }

    /// The centre of slot `index` on a side holding `count` buttons. Buttons underneath are centred
    /// under the island as a group.
    public func slot(_ side: IslandFloatingSide, index: Int, count: Int) -> CGPoint {
        let step = CGFloat(index) * Self.slotSpacing
        switch side {
        case .left: return CGPoint(x: island.minX - Self.sideOffset, y: island.minY + Self.firstSlotOffset + step)
        case .right: return CGPoint(x: island.maxX + Self.sideOffset, y: island.minY + Self.firstSlotOffset + step)
        case .bottom:
            let start = island.midX - CGFloat(max(0, count - 1)) * Self.slotSpacing / 2
            return CGPoint(x: start + step, y: island.maxY + Self.bottomOffset)
        }
    }

    /// Where every configured button is drawn.
    public func centers(_ layout: IslandFloatingLayout) -> [UUID: CGPoint] {
        var result: [UUID: CGPoint] = [:]
        for side in IslandFloatingSide.allCases {
            let buttons = layout.buttons(on: side)
            for (index, button) in buttons.enumerated() { result[button.id] = slot(side, index: index, count: buttons.count) }
        }
        return result
    }

    /// The "+" circle: the next free slot on a side, or nil when the side is full.
    public func addSlot(_ side: IslandFloatingSide, in layout: IslandFloatingLayout) -> CGPoint? {
        let count = layout.buttons(on: side).count
        guard count < IslandFloatingLayout.perSide else { return nil }
        return slot(side, index: count, count: count)
    }

    public func zone(_ side: IslandFloatingSide) -> CGRect {
        let top = island.minY + Self.firstSlotOffset - Self.buttonDiameter / 2 - 11
        let height = CGFloat(IslandFloatingLayout.perSide - 1) * Self.slotSpacing + Self.buttonDiameter + 22
        switch side {
        case .left:
            return CGRect(x: island.minX - Self.sideZoneReach, y: top, width: Self.sideZoneWidth, height: height)
        case .right:
            return CGRect(x: island.maxX + Self.sideZoneReach - Self.sideZoneWidth, y: top, width: Self.sideZoneWidth, height: height)
        case .bottom:
            // Never narrower than three buttons, so a tiny preview still has a usable target.
            let width = max(island.width, CGFloat(IslandFloatingLayout.perSide - 1) * Self.slotSpacing + Self.buttonDiameter + 16)
            return CGRect(x: island.midX - width / 2, y: island.maxY + Self.bottomOffset - Self.bottomZoneHeight / 2,
                          width: width, height: Self.bottomZoneHeight)
        }
    }

    /// The drop zone under a point; where zones overlap, the one whose centre is nearest.
    public func zone(at point: CGPoint) -> IslandFloatingSide? {
        let hits = IslandFloatingSide.allCases.filter { zone($0).contains(point) }
        return hits.min { distance(point, zone($0)) < distance(point, zone($1)) }
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        hypot(point.x - rect.midX, point.y - rect.midY)
    }

    /// Whether a side takes the dragged button: its own side always, another only while it has room.
    public func accepts(_ side: IslandFloatingSide, dragging id: UUID, in layout: IslandFloatingLayout) -> Bool {
        layout.buttons(on: side).contains { $0.id == id } || !layout.isFull(side)
    }

    /// Where a dropped button goes among the other buttons on `side`: before the first whose slot lies
    /// after the drop point (below it on a side, to its right underneath).
    public func insertionIndex(of id: UUID, at point: CGPoint, on side: IslandFloatingSide, in layout: IslandFloatingLayout) -> Int {
        let buttons = layout.buttons(on: side)
        let others = buttons.enumerated().filter { $0.element.id != id }
        for (position, entry) in others.enumerated() {
            let center = slot(side, index: entry.offset, count: buttons.count)
            if side == .bottom ? center.x > point.x : center.y > point.y { return position }
        }
        return others.count
    }

    /// Applies a drop. Outside every zone, or on a full side, nothing changes and it returns false.
    @discardableResult
    public func drop(_ id: UUID, at point: CGPoint, in layout: inout IslandFloatingLayout) -> Bool {
        guard let side = zone(at: point), accepts(side, dragging: id, in: layout) else { return false }
        return layout.move(id, to: side, at: insertionIndex(of: id, at: point, on: side, in: layout))
    }

    /// The resize grip: on the island's bottom-right corner, slid down on short islands.
    public var gripCenter: CGPoint {
        CGPoint(x: island.maxX - Self.gripInset,
                y: max(island.maxY + Self.gripInset, island.minY + Self.gripMinimumDrop))
    }

    /// Custom width and maximum height for a grip drag that began at `start` (real island points). The
    /// island stays centred, so its width changes by twice the horizontal travel. Values snap to the
    /// sliders' 10-pt steps and stay within their ranges.
    public static func resize(from start: CGSize, translation: CGSize, scale: CGFloat) -> (width: Double, height: Double) {
        let scale = max(scale, 0.01)
        let width = Double(start.width + 2 * translation.width / scale)
        let height = Double(start.height + translation.height / scale)
        return (snap(width, IslandSettings.customWidthRange), snap(height, IslandSettings.customHeightRange))
    }

    static func snap(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max((value / 10).rounded() * 10, range.lowerBound), range.upperBound)
    }
}
