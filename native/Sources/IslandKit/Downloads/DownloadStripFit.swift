import CoreGraphics
import Foundation

/// The download's compact strip beside the camera: how wide its wings are for the side room the menu
/// bar leaves, what each wing can hold at that width, and how far content stays from the curved ends.
public enum DownloadStripFit {
    /// The short strip: arrow on the left, percent on the right.
    public static let defaultWing: CGFloat = 56
    /// Below this much side room there are no wings.
    public static let minimumRoom: CGFloat = 44
    /// From this much side room the wing grows to fit the file name.
    public static let nameRoom: CGFloat = 94
    public static let nameWing: ClosedRange<CGFloat> = 64...160
    /// The narrowest wing that draws each piece.
    public static let arrowMinimumWing: CGFloat = 40
    public static let percentMinimumWing: CGFloat = 36
    public static let nameMinimumWing: CGFloat = 64
    /// Space between the arrow and the name, and between the name and the camera.
    public static let arrowToName: CGFloat = 6
    public static let nameToCamera: CGFloat = 4
    /// Breathing room every strip keeps between its content and its silhouette.
    public static let edgeGap: CGFloat = 5

    /// Where the download goes on the closed island.
    public enum Placement: Equatable, Sendable {
        case wings(CGFloat)
        /// One camera-wide row below a physical camera whose menu bar has no side room.
        case footer
        /// Only the camera shape (a drawn camera without room).
        case hidden
    }

    public static func placement(room: CGFloat, physicalCamera: Bool, nameWidth: CGFloat?, arrowWidth: CGFloat,
                                 stripHeight: CGFloat) -> Placement {
        let wing = wing(room: room, nameWidth: nameWidth, arrowWidth: arrowWidth, stripHeight: stripHeight)
        if wing > 0 { return .wings(wing) }
        return physicalCamera ? .footer : .hidden
    }

    /// 0 below 44 pt of room; the fitted name wing (64…160, never past the room) from 94 pt when a
    /// name exists; otherwise 56, or the room when that is less.
    public static func wing(room: CGFloat, nameWidth: CGFloat?, arrowWidth: CGFloat, stripHeight: CGFloat) -> CGFloat {
        guard room >= minimumRoom else { return 0 }
        guard room >= nameRoom, let nameWidth, nameWidth > 0 else { return min(defaultWing, room) }
        let inset = edgeInset(stripHeight: stripHeight, contentHeight: arrowSize(stripHeight: stripHeight), round: true)
        let fitted = (inset + arrowWidth + arrowToName + nameWidth + nameToCamera).rounded(.up)
        return min(room, min(nameWing.upperBound, max(nameWing.lowerBound, fitted)))
    }

    public static func showsArrow(wing: CGFloat) -> Bool { wing >= arrowMinimumWing }
    public static func showsName(wing: CGFloat) -> Bool { wing >= nameMinimumWing }
    public static func showsPercent(wing: CGFloat) -> Bool { wing >= percentMinimumWing }

    /// The arrow's point size: at most 17, and 10 pt shorter than the strip.
    public static func arrowSize(stripHeight: CGFloat) -> CGFloat { max(8, min(17, stripHeight - 10)) }

    /// How far a vertically centred box of `contentHeight` must sit from the strip's end to stay
    /// `edgeGap` clear of the silhouette: past the shoulder, and inside the bottom corner's arc. Text
    /// passes 0.72 × its font size (digits have no descenders); a round mark passes `round: true`.
    public static func edgeInset(stripHeight: CGFloat, contentHeight: CGFloat, round: Bool = false) -> CGFloat {
        let h = max(0, stripHeight)
        let shoulder = min(14, 0.19 * h)
        let radius = min(28, 0.34 * h, h / 2)
        let straight = shoulder + edgeGap
        let cornerRadius = round ? contentHeight / 2 : 0
        let boxBottom = (h + contentHeight) / 2
        // The box's own corner circle must stay within the arc shrunk by the gap.
        let dy = (boxBottom - cornerRadius) - (h - radius)
        guard dy > 0 else { return straight }
        let reach = radius - edgeGap - cornerRadius
        guard reach > dy else { return max(straight, shoulder + radius) }
        let dx = (reach * reach - dy * dy).squareRoot()
        return max(straight, shoulder + radius - dx - cornerRadius)
    }
}
