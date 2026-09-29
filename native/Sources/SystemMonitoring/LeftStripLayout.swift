import Foundation

/// Where the left strip sits in the menu bar: just after the frontmost app's bold name, across that
/// app's menus, and never past the notch or the first status item. Pure, so it is tested without a screen.
/// Every x is in one horizontal coordinate space (Cocoa screen points).
public enum LeftStripLayout {
    /// Clear space kept after the app name and before the notch or first status item.
    public static let edgeGap: Double = 6

    /// - Parameters:
    ///   - start: right edge of the app-name menu (the bold one).
    ///   - menusEnd: right edge of the app's last menu, or nil when it could not be read; the strip then
    ///     runs to `limit` so nothing it should cover is left showing.
    ///   - limit: left edge of the notch, or of the leftmost status item on a display without one.
    ///   - content: width the sprites need.
    /// - Returns: the strip's left edge and width, or nil when the room left is too small to draw in.
    public static func span(start: Double, menusEnd: Double?, limit: Double, content: Double,
                            minimum: Double = 24) -> (x: Double, width: Double)? {
        let x = start + edgeGap
        let end = limit - edgeGap
        guard end - x >= minimum else { return nil }
        let cover = (menusEnd.map { $0 + 2 } ?? end) - x
        return (x, min(max(content, cover), end - x))
    }
}
