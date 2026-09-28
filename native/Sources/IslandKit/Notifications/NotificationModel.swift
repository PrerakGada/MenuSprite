import Foundation

// The plain data the Notifications section works with. The app reads Notification Center's
// Accessibility tree into `NotificationAXNode`s on its own queue; everything after that (finding
// banners, building messages, identity, the inbox) is pure and tested against synthetic trees.

/// Accessibility names the reader and parser agree on. Undocumented behaviour of macOS 26's
/// Notification Center: anything that does not match is rejected, never guessed.
public enum NotificationAX {
    public static let bundleID = "com.apple.notificationcenterui"

    public static let bannerSubrole = "AXNotificationCenterBanner"
    public static let alertSubrole = "AXNotificationCenterAlert"
    public static let bannerStackSubrole = "AXNotificationCenterBannerStack"
    public static let alertStackSubrole = "AXNotificationCenterAlertStack"

    public static let staticTextRole = "AXStaticText"
    public static let imageRole = "AXImage"
    public static let pressAction = "AXPress"
    /// Roles whose contents are typed by the person (inline reply). Never read, never descended into.
    public static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"]
    /// Controls whose own label text is chrome ("Reply", "Options"), never message content.
    public static let controlRoles: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton"]

    public static let maxFieldBytes = 16_384
    public static let maxLabelBytes = 256
    public static let maxDescriptionBytes = 50_000
    public static let maxIdentifierBytes = 2_048
}

/// One element of Notification Center's tree, as read. Values are filled only where the reader is
/// allowed to read them: `text` for static texts, `imageLabel` for images.
public struct NotificationAXNode: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var text: String?
    public var imageLabel: String?
    public var children: [NotificationAXNode]
    /// The reader's index for this element, so later reads and actions can find it again.
    public var handle: Int

    public init(role: String? = nil, subrole: String? = nil, identifier: String? = nil, text: String? = nil,
                imageLabel: String? = nil, children: [NotificationAXNode] = [], handle: Int = -1) {
        self.role = role; self.subrole = subrole; self.identifier = identifier; self.text = text
        self.imageLabel = imageLabel; self.children = children; self.handle = handle
    }

    public var isEditable: Bool { role.map(NotificationAX.editableRoles.contains) ?? false }
    public var isControl: Bool { role.map(NotificationAX.controlRoles.contains) ?? false }
}

/// The text of one notification, split the way Notification Center labels it.
public struct NotificationFields: Hashable, Sendable {
    /// The app's name as the banner prints it, when it does.
    public var header: String?
    /// The sender or headline. Always present in a parsed notification.
    public var title: String
    /// A conversation or thread name.
    public var subtitle: String?
    /// The message itself.
    public var body: String?

    public init(header: String? = nil, title: String, subtitle: String? = nil, body: String? = nil) {
        self.header = header; self.title = title; self.subtitle = subtitle; self.body = body
    }
}

/// The app a notification came from, when it could be established.
public struct NotificationSource: Hashable, Sendable {
    public var name: String?
    public var bundleID: String?
    /// The app bundle's path, for its icon and for launching it.
    public var path: String?

    public init(name: String?, bundleID: String? = nil, path: String? = nil) {
        self.name = name; self.bundleID = bundleID; self.path = path
    }
}

/// A banner found on screen in one complete read.
public struct NotificationSnapshotItem: Equatable, Sendable {
    public var fields: NotificationFields
    public var source: NotificationSource?
    /// The root's durable native identity (a UUID-bearing identifier), if it has one.
    public var nativeID: String?
    /// The reader's token for the root element; equal tokens mean the same Accessibility element.
    public var element: UInt64
    public var canPress: Bool
    /// The root's exact custom close action, when it has exactly one.
    public var closeAction: String?
    /// Alerts (and anything in an alert stack) stay until the person acts; never closed for them.
    public var isPersistent: Bool

    public init(fields: NotificationFields, source: NotificationSource? = nil, nativeID: String? = nil, element: UInt64,
                canPress: Bool = false, closeAction: String? = nil, isPersistent: Bool = false) {
        self.fields = fields; self.source = source; self.nativeID = nativeID; self.element = element
        self.canPress = canPress; self.closeAction = closeAction; self.isPersistent = isPersistent
    }
}

/// What identifies one notification across reads: its native identity when it has one, otherwise
/// the Accessibility element; the content must match either way.
public struct NotificationKey: Hashable, Sendable {
    public var nativeID: String?
    public var fields: NotificationFields
    public var element: UInt64

    public init(nativeID: String?, fields: NotificationFields, element: UInt64) {
        self.nativeID = nativeID; self.fields = fields; self.element = element
    }

    public init(_ item: NotificationSnapshotItem) {
        self.init(nativeID: item.nativeID, fields: item.fields, element: item.element)
    }

    /// The same notification: same content and (same native identity, or no native identity and
    /// the same element). Identical text from different notifications stays distinct.
    public func identifies(_ item: NotificationSnapshotItem) -> Bool {
        guard fields == item.fields else { return false }
        if let nativeID { return item.nativeID == nativeID }
        return item.nativeID == nil && item.element == element
    }
}

/// The native banner behind a mirror while it is still on screen.
public struct NotificationLiveTarget: Equatable, Sendable {
    public var element: UInt64
    public var canPress: Bool
    public var closeAction: String?
    public var isPersistent: Bool
    /// Two roots claimed the same native identity in the latest read; nothing may act on either.
    public var isAmbiguous: Bool
}

/// One message in the inbox.
public struct NotificationMirror: Identifiable, Equatable, Sendable {
    public let id: Int
    public var key: NotificationKey
    public var source: NotificationSource?
    public var receivedAt: Date
    /// Nil once the native banner is gone: the text stays, the native Open goes.
    public var live: NotificationLiveTarget?

    public var fields: NotificationFields { key.fields }
    public var canOpenNatively: Bool { live.map { $0.canPress && !$0.isAmbiguous } ?? false }
    public var canOpenSourceApp: Bool { source?.bundleID != nil }
    public var canOpen: Bool { canOpenNatively || canOpenSourceApp }
    public var appName: String? { fields.header ?? source?.name }
}
