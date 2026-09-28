import CoreGraphics
import Foundation

/// The AI Agents page's card grid: two cards per row in reading order when the page is wide enough,
/// with charts and a card left without a partner taking a full row.
public enum AgentGrid {
    public static let pairingWidth: CGFloat = 390
    public static let rowHeight: CGFloat = 96
    public static let chartRowHeight: CGFloat = 118
    public static let spacing: CGFloat = 10

    /// Rows of item indexes, given which items are charts.
    public static func rows(charts: [Bool], width: CGFloat) -> [[Int]] {
        guard width >= pairingWidth else { return charts.indices.map { [$0] } }
        var rows: [[Int]] = []
        var pending: Int?
        for (index, isChart) in charts.enumerated() {
            if isChart {
                if let waiting = pending { rows.append([waiting]); pending = nil }
                rows.append([index])
            } else if let waiting = pending {
                rows.append([waiting, index])
                pending = nil
            } else {
                pending = index
            }
        }
        if let waiting = pending { rows.append([waiting]) }
        return rows
    }

    /// The page is exactly as tall as its rows.
    public static func height(rows: [[Int]], charts: [Bool]) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        let heights = rows.map { row in row.contains { charts[$0] } ? chartRowHeight : rowHeight }
        return heights.reduce(0, +) + CGFloat(rows.count - 1) * spacing
    }
}

/// The closed island while an agent works: marks on the left, one reading on the right.
public enum AgentStrip {
    public static let wingRange: ClosedRange<CGFloat> = 44...80
    /// Below this the reading is hidden; below `marksMinimum` the marks too.
    public static let readingMinimum: CGFloat = 42
    public static let marksMinimum: CGFloat = 28
    /// Extra room kept beside the camera.
    public static let cameraGap: CGFloat = 6
    /// The breathing room every strip keeps between content and its curved end.
    public static let edgeGap: CGFloat = 5

    /// One working agent's mark is 14 pt; two share the wing at 11 pt each.
    public static func markSize(count: Int) -> CGFloat { count > 1 ? 11 : 14 }

    /// Each mark sits in a frame 1.45 × its size + 1, the marks 1 pt apart.
    public static func marksWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let size = markSize(count: count)
        return CGFloat(count) * (1.45 * size + 1) + CGFloat(count - 1)
    }

    public static func fontSize(height: CGFloat) -> CGFloat { max(8, min(15, height - 7)) }

    /// Wings fit the wider of the reading and the marks, clamped to 44…80.
    public static func wing(readingWidth: CGFloat, marksWidth: CGFloat, inset: CGFloat) -> CGFloat {
        let fitted = (max(readingWidth + inset, marksWidth + inset) + cameraGap).rounded(.up)
        return min(wingRange.upperBound, max(wingRange.lowerBound, fitted))
    }

    /// The reading's shape: digits made alike, so the wing is re-measured only when the number of
    /// characters (not their value) changes.
    public static func shape(_ text: String) -> String {
        String(text.map { $0.isNumber ? "0" : $0 })
    }

    /// How far content must stay from the strip's end: clear of the shoulder by the gap, and a
    /// vertically centred box of this height and corner radius the gap away from the bottom corner arc.
    public static func edgeInset(height: CGFloat, contentHeight: CGFloat, contentRadius: CGFloat = 0) -> CGFloat {
        let shape = IslandSilhouette(width: 400, height: height)
        let straight = shape.shoulder + edgeGap
        let radius = shape.bottomRadius
        let centre = CGPoint(x: shape.shoulder + radius, y: height - radius)
        let cornerY = (height + contentHeight) / 2 - contentRadius
        let dy = cornerY - centre.y
        guard dy > 0 else { return straight }
        let reach = radius - contentRadius - edgeGap
        guard reach > dy else { return max(straight, centre.x - contentRadius) }
        return max(straight, centre.x - contentRadius - (reach * reach - dy * dy).squareRoot())
    }

    /// Text boxes are 0.72 × the font size tall: digits have no descenders.
    public static func textInset(height: CGFloat, fontSize: CGFloat) -> CGFloat {
        edgeInset(height: height, contentHeight: 0.72 * fontSize)
    }

    /// Resting wings keep min(16, shoulder + 5) from the curve.
    public static func restInset(height: CGFloat) -> CGFloat {
        min(16, IslandSilhouette(width: 400, height: height).shoulder + edgeGap)
    }
}
