import CoreGraphics
import Foundation

/// Timing the Notifications section relies on.
public enum NotificationTiming {
    /// Accessibility callbacks are coalesced into one read this long after the first.
    public static let scanDelay: TimeInterval = 0.12
    /// Wait before closing the native banner, so a short alert sound can finish. Shorter than the
    /// island's own notice, so the message is still readable there when the original goes.
    public static let closeGrace: TimeInterval = 1.2
    /// The installed-apps list is walked at most this often.
    public static let installedAppsRefresh: TimeInterval = 600
}

/// The section's own options, stored under `MenuSprite.Island.Notifications.<option>`.
public enum NotificationPreferences {
    public static let showBannersKey = "MenuSprite.Island.Notifications.showBanners"
    public static let closeOriginalsKey = "MenuSprite.Island.Notifications.closeOriginals"
    /// New messages appear beside the camera unless turned off.
    public static let showBannersDefault = true
    /// Native banners are left alone unless the person opts in.
    public static let closeOriginalsDefault = false
}

/// When the Notifications section does what.
public enum NotificationPolicy {
    /// The reader runs only while the island is on, the section is shown and Accessibility is granted.
    public static func readerRuns(islandRunning: Bool, sectionVisible: Bool, trusted: Bool) -> Bool {
        islandRunning && sectionVisible && trusted
    }

    /// A new arrival becomes a closed-island notice only while the reader runs and the option is on.
    public static func postsBanner(readerRuns: Bool, showBanners: Bool) -> Bool { readerRuns && showBanners }

    /// The native banner is closed only with both opt-ins (section on, option on), after the island
    /// actually showed it, while the island is closed, and never for a persistent alert.
    public static func closesOriginal(readerRuns: Bool, closeOriginals: Bool, noticeShown: Bool, islandOpen: Bool,
                                      isPersistent: Bool) -> Bool {
        readerRuns && closeOriginals && noticeShown && !islandOpen && !isPersistent
    }

    /// A banner held open under the pointer gives way only to the next notification or to something
    /// strictly more urgent (volume, a finished timer); battery and clipboard wait their turn.
    public static func heldBannerYields(to incoming: IslandNoticeKind) -> Bool {
        incoming == .notification || incoming.priority > IslandNoticeKind.notification.priority
    }
}

/// The words a notification shows in the closed island and reads aloud.
public enum NotificationText {
    /// The left wing: the sender, or the app's name when there is no title.
    public static func compactTitle(_ fields: NotificationFields, appName: String?) -> String {
        let title = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? (appName ?? "") : title
    }

    /// The right wing: conversation and message on one detail line.
    public static func compactDetail(_ fields: NotificationFields) -> String {
        [fields.subtitle, fields.body].compactMap { value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
    }

    /// Spoken as app, sender, conversation, message; missing parts are skipped, never repeated.
    public static func spoken(_ fields: NotificationFields, appName: String?) -> String {
        var parts: [String] = []
        for part in [appName, fields.title, fields.subtitle, fields.body] {
            guard let value = part?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  parts.last != value else { continue }
            parts.append(value)
        }
        return parts.joined(separator: ", ")
    }
}

/// A text block in the message card.
public enum NotificationTextStyle: CaseIterable, Sendable {
    case title, subtitle, body

    public var pointSize: CGFloat {
        switch self {
        case .title: 14
        case .subtitle, .body: 13
        }
    }

    public var lineLimit: Int {
        switch self {
        case .title: 2
        case .subtitle: 1
        case .body: 6
        }
    }
}

/// The message card a held banner opens into: about as wide as a native banner, as tall as its
/// message measures, never taller than the display allows.
public enum NotificationPreviewLayout {
    public static let minimumWidth: CGFloat = 400
    /// The card leaves this much beside a wide camera (half each side).
    public static let cameraClearance: CGFloat = 200
    public static let horizontalInset: CGFloat = 16
    public static let headerHeight: CGFloat = 28
    public static let headerSpacing: CGFloat = 6
    public static let textSpacing: CGFloat = 3
    public static let actionSpacing: CGFloat = 10
    public static let actionRowHeight: CGFloat = 28

    /// min(max(400, camera + 200), open island width).
    public static func width(camera: CGFloat, openWidth: CGFloat) -> CGFloat {
        min(max(minimumWidth, camera + cameraClearance), openWidth)
    }

    public static func textWidth(cardWidth: CGFloat) -> CGFloat { max(0, cardWidth - 2 * horizontalInset) }

    /// The card's content height. `measure` wraps the text at the given width and reports its line
    /// height and how many lines it takes unlimited; the line limits are applied here. Empty text
    /// takes no space.
    public static func contentHeight(_ fields: NotificationFields, hasActionRow: Bool, textWidth: CGFloat,
                                     measure: (String, NotificationTextStyle, CGFloat) -> (lineHeight: CGFloat, lines: Int)) -> CGFloat {
        var height = headerHeight + headerSpacing
        var blocks = 0
        for (style, text) in [(NotificationTextStyle.title, fields.title), (.subtitle, fields.subtitle), (.body, fields.body)] {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let measured = measure(text, style, textWidth)
            if blocks > 0 { height += textSpacing }
            height += CGFloat(min(max(1, measured.lines), style.lineLimit)) * measured.lineHeight
            blocks += 1
        }
        if hasActionRow { height += actionSpacing + actionRowHeight }
        return ceil(height)
    }

    /// The tallest content the card may have: the display less 48 pt, the camera row above and the
    /// bottom inset below.
    public static func maximumContentHeight(displayHeight: CGFloat, cutoutHeight: CGFloat) -> CGFloat {
        max(0, displayHeight - 48 - cutoutHeight - 10 - 16)
    }
}

/// The inbox page: a sideways rail of 240-pt cards in as many rows as fit a nominal 120-pt row
/// (two on Spacious, one on Compact); the cards stretch to share the height.
public enum NotificationRail {
    public static let cardWidth: CGFloat = 240
    public static let nominalRowHeight: CGFloat = 120
    public static let spacing: CGFloat = 8

    public static func rows(height: CGFloat) -> Int {
        max(1, Int((height + spacing) / (nominalRowHeight + spacing)))
    }

    public static func cardHeight(height: CGFloat) -> CGFloat {
        let rows = rows(height: height)
        return max(0, (height - CGFloat(rows - 1) * spacing) / CGFloat(rows))
    }
}
