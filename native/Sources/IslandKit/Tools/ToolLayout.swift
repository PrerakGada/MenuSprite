import CoreGraphics
import Foundation

public enum IslandToolDirection: Sendable {
    case left, right, up, down
}

/// The island's Tools rail: 76 × 72 pt tiles, 6 pt apart, in as many rows as the page budget allows.
/// While every column fits the width the tiles read in rows and a short last row is centred; once
/// there are more, the rail scrolls sideways and fills column by column. The arrow keys follow
/// whichever flow is on screen and stop at the ends.
public struct IslandToolRail: Equatable, Sendable {
    public static let tileWidth: CGFloat = 76
    public static let tileHeight: CGFloat = 72
    public static let spacing: CGFloat = 6
    public static let emptyHeight: CGFloat = 140

    public let count: Int
    /// Tiles that fit across the page.
    public let columns: Int
    public let rows: Int
    private let budget: CGFloat

    public init(count: Int, width: CGFloat, budget: CGFloat) {
        self.count = max(0, count)
        self.budget = budget
        columns = max(1, Int((width + Self.spacing) / (Self.tileWidth + Self.spacing)))
        let needed = Int(ceil(Double(self.count) / Double(columns)))
        let fitting = max(1, Int((budget + Self.spacing) / (Self.tileHeight + Self.spacing)))
        rows = min(needed, fitting)
    }

    /// Every tile is visible without scrolling.
    public var fits: Bool { count <= rows * columns }

    /// Columns the scrolling rail has.
    public var scrollColumns: Int { rows == 0 ? 0 : Int(ceil(Double(count) / Double(rows))) }

    public var height: CGFloat {
        guard rows > 0 else { return min(budget, Self.emptyHeight) }
        return min(budget, CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * Self.spacing)
    }

    /// The tile indices of each row, in reading order (for the fitting layout).
    public var readingRows: [Range<Int>] {
        stride(from: 0, to: count, by: columns).map { $0..<min(count, $0 + columns) }
    }

    /// The tile indices of each row of the scrolling layout, which fills column by column.
    public var scrollingRows: [[Int]] {
        (0..<rows).map { row in stride(from: row, to: count, by: rows).map { $0 } }
    }

    public func move(_ index: Int, _ direction: IslandToolDirection) -> Int {
        guard count > 0 else { return index }
        let index = min(max(0, index), count - 1)
        return fits ? moveReading(index, direction) : moveScrolling(index, direction)
    }

    /// Reading order: left and right step through the flow, up and down change row and land on the
    /// tile drawn nearest, accounting for a centred short last row.
    private func moveReading(_ index: Int, _ direction: IslandToolDirection) -> Int {
        switch direction {
        case .left: return max(0, index - 1)
        case .right: return min(count - 1, index + 1)
        case .up, .down:
            let row = index / columns
            let target = direction == .up ? row - 1 : row + 1
            guard target >= 0, target * columns < count else { return index }
            return nearest(inRow: target, to: drawnColumn(of: index))
        }
    }

    /// Column order: up and down step through the flow, left and right change column.
    private func moveScrolling(_ index: Int, _ direction: IslandToolDirection) -> Int {
        switch direction {
        case .up: return max(0, index - 1)
        case .down: return min(count - 1, index + 1)
        case .left: return index - rows >= 0 ? index - rows : index
        case .right:
            if index + rows < count { return index + rows }
            return index / rows + 1 < scrollColumns ? count - 1 : index
        }
    }

    private func tiles(inRow row: Int) -> Int { min(columns, count - row * columns) }

    private func drawnColumn(of index: Int) -> Double {
        let row = index / columns
        return Double(index % columns) + Double(columns - tiles(inRow: row)) / 2
    }

    private func nearest(inRow row: Int, to column: Double) -> Int {
        let tiles = tiles(inRow: row)
        let offset = Double(columns - tiles) / 2
        let position = Int((column - offset).rounded(.toNearestOrAwayFromZero))
        return row * columns + min(max(0, position), tiles - 1)
    }
}

/// The floating tools panel's grid: three columns, arrows clamped at the edges, 1–9 pick by position.
public enum IslandToolGrid {
    public static let columns = 3

    public static func move(_ index: Int, _ direction: IslandToolDirection, count: Int, columns: Int = columns) -> Int {
        guard count > 0 else { return index }
        let index = min(max(0, index), count - 1)
        let column = index % columns
        switch direction {
        case .left: return column > 0 ? index - 1 : index
        case .right: return column < columns - 1 && index + 1 < count ? index + 1 : index
        case .up: return index - columns >= 0 ? index - columns : index
        case .down:
            if index + columns < count { return index + columns }
            // Below a column the short last row does not reach: its last tile.
            return index / columns < (count - 1) / columns ? count - 1 : index
        }
    }

    /// The tile a digit key picks, 1 being the first.
    public static func index(forDigit digit: Int, count: Int) -> Int? {
        guard (1...9).contains(digit), digit <= count else { return nil }
        return digit - 1
    }
}

/// Where the floating panels sit on the pointer's screen. Both stay 16 pt inside the visible frame.
public enum IslandToolPlacement {
    public static let margin: CGFloat = 16

    /// The tools panel: centred horizontally, with 38% of the free height above it and 62% below.
    public static func toolsPanel(size: CGSize, visible: CGRect) -> CGRect {
        let free = max(0, visible.height - size.height)
        let top = visible.maxY - free * 0.38
        return clamp(CGRect(x: visible.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), in: visible)
    }

    /// The tools panel after its content changed size: the top edge and centre stay where they were.
    public static func refit(_ frame: CGRect, to size: CGSize, visible: CGRect) -> CGRect {
        clamp(CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), in: visible)
    }

    public static let commandBarWidth: CGFloat = 560
    /// The list grows to this height (about fourteen rows), then scrolls.
    public static let commandBarListLimit: CGFloat = 452

    /// The Command Bar: its top edge 28% of the way down the visible frame; it grows downwards.
    public static func commandBar(height: CGFloat, visible: CGRect) -> CGRect {
        let top = visible.maxY - visible.height * 0.28
        return clamp(CGRect(x: visible.midX - commandBarWidth / 2, y: top - height, width: commandBarWidth, height: height), in: visible)
    }

    /// Keeps a frame wholly inside the visible frame less the margin, shrinking it if it cannot fit and
    /// keeping its top edge when it has to move.
    static func clamp(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let bounds = visible.insetBy(dx: margin, dy: margin)
        guard bounds.width > 0, bounds.height > 0 else { return frame }
        var result = frame
        result.size.width = min(frame.width, bounds.width)
        result.size.height = min(frame.height, bounds.height)
        if result.height < frame.height { result.origin.y = frame.maxY - result.height }
        result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }
}
