import CoreGraphics

/// The mixer page's arithmetic: a 32-pt header, then the desk of fader columns. Every column is a
/// 32-pt top (mute button or app icon), a one-line caption, the fader track and a 28-pt row for the
/// percentage, so the master fader and the app faders line up.
public struct MixerDeskLayout: Equatable, Sendable {
    public static let headerHeight: CGFloat = 32
    public static let headerGap: CGFloat = 8
    public static let masterWidth: CGFloat = 72
    public static let columnWidth: CGFloat = 96
    public static let topHeight: CGFloat = 32
    public static let captionHeight: CGFloat = 14
    public static let footerHeight: CGFloat = 28
    public static let spacing: CGFloat = 4
    /// Fader width; the level bar draws its track at 78 % of it (28 pt).
    public static let faderWidth: CGFloat = 36

    /// The desk below the header: at least 104 pt.
    public let deskHeight: CGFloat
    /// The fader track: 32…160 pt.
    public let track: CGFloat

    public init(pageHeight: CGFloat) {
        deskHeight = max(104, pageHeight - Self.headerHeight - Self.headerGap)
        let fixed = Self.topHeight + Self.captionHeight + Self.footerHeight + 3 * Self.spacing
        track = min(160, max(32, deskHeight - fixed))
    }
}
