import CoreGraphics
import Foundation

/// How the Timer page divides its height. A content width of 400 pt or more is "wide": Start sits at
/// the end of the mode row. Narrower, Start takes a bottom row of its own.
public enum TimerPageLayout {
    public static let modeRow: CGFloat = 36
    public static let gap: CGFloat = 8
    public static let ruler: CGFloat = 82
    public static let minimumRuler: CGFloat = 56
    public static let readouts: CGFloat = 28
    public static let bottomRow: CGFloat = 36
    public static let active: CGFloat = 96
    public static let activeSessionLine: CGFloat = 22
    public static let wideWidth: CGFloat = 400

    public static func isWide(_ width: CGFloat) -> Bool { width >= wideWidth }

    /// The setup page: mode row, ruler row (shrinking to 56 pt on a short island before anything is
    /// cut), Pomodoro readouts on a wide island, and the bottom row on a narrow one.
    public static func setup(mode: TimerMode, width: CGFloat, budget: CGFloat) -> (height: CGFloat, ruler: CGFloat) {
        var fixed = modeRow + gap
        if mode == .pomodoro && isWide(width) { fixed += gap + readouts }
        if !isWide(width) { fixed += gap + bottomRow }
        let ruler = min(Self.ruler, max(minimumRuler, budget - fixed))
        return (fixed + ruler, ruler)
    }

    /// The page while a session exists: one row, plus "Session N of M" for Pomodoro.
    public static func activeHeight(mode: TimerMode) -> CGFloat {
        mode == .pomodoro ? active + activeSessionLine : active
    }
}

/// The closed island's timer strip: the reading on the right, the timer's mark on the left, both at
/// the island's ends and clear of its curved corners.
public enum TimerStripMetrics {
    public static let minimumWing: CGFloat = 44
    public static let maximumWing: CGFloat = 64
    /// Below this much side room the wings are dropped; the timer never moves below the camera.
    public static let minimumRoom: CGFloat = 64
    /// Air beside the camera.
    public static let cameraAir: CGFloat = 6
    /// The breathing room every strip keeps between its content and its outline.
    public static let edgeGap: CGFloat = 5
    public static let readingMinimumWing: CGFloat = 42
    public static let markMinimumWing: CGFloat = 28

    public static func readingFontSize(height: CGFloat) -> CGFloat { max(1, min(16, height - 6)) }
    public static func markSize(height: CGFloat) -> CGFloat { max(1, min(20, height - 10)) }
    /// Digits have no descenders, so text is treated as a box 0.72 × its font size tall.
    public static func textBoxHeight(fontSize: CGFloat) -> CGFloat { 0.72 * fontSize }

    public static func showsReading(wing: CGFloat) -> Bool { wing >= readingMinimumWing }
    public static func showsMark(wing: CGFloat) -> Bool { wing >= markMinimumWing }

    /// How far content must sit from the strip's end: past the shoulder plus the gap, and far enough
    /// that a vertically centred box of this height and corner radius stays the gap away from the
    /// bottom corner's arc.
    public static func edgeInset(stripHeight: CGFloat, contentHeight: CGFloat, cornerRadius: CGFloat = 0) -> CGFloat {
        let outline = IslandSilhouette(width: 10_000, height: stripHeight)
        let shoulder = outline.shoulder, radius = outline.bottomRadius
        let straight = shoulder + edgeGap
        let boxCornerY = (stripHeight + contentHeight) / 2 - cornerRadius
        let arcCentreY = stripHeight - radius
        let dy = boxCornerY - arcCentreY
        guard dy > 0 else { return straight }
        let reach = radius - edgeGap - cornerRadius
        guard reach > dy else { return max(straight, shoulder + radius - cornerRadius) }
        let x = shoulder + radius - (reach * reach - dy * dy).squareRoot() - cornerRadius
        return max(straight, x)
    }

    /// The width a strip's content needs on one side: the wider of the reading and the mark, each with
    /// its inset, plus air beside the camera.
    public static func fit(readingWidth: CGFloat, height: CGFloat) -> CGFloat {
        let font = readingFontSize(height: height)
        let mark = markSize(height: height)
        let reading = readingWidth + edgeInset(stripHeight: height, contentHeight: textBoxHeight(fontSize: font))
        let markSide = mark + edgeInset(stripHeight: height, contentHeight: mark, cornerRadius: mark / 2)
        return max(reading, markSide) + cameraAir
    }

    /// Both wings take what the wider side needs, rounded up, within 44…64 pt.
    public static func wing(fit: CGFloat) -> CGFloat {
        guard fit.isFinite else { return maximumWing }
        return min(maximumWing, max(minimumWing, fit.rounded(.up)))
    }
}
