import Foundation

public enum AccessState: String, Codable, Sendable, CaseIterable {
    case checking, granted, notGranted, notRequested, limited, writeOnly, restricted
    case unknown, unavailable, unavailableInBuild
    case pasteboardDefault, pasteboardAsk, pasteboardAllow, pasteboardDeny
    case notRegistered, enabled, requiresApproval, notFound, notConfigured

    public var label: String {
        switch self {
        case .checking: "Checking…"
        case .granted: "Granted"
        case .notGranted: "Not granted"
        case .notRequested: "Not requested"
        case .limited: "Limited"
        case .writeOnly: "Write only"
        case .restricted: "Restricted by system"
        case .unknown: "Check in System Settings"
        case .unavailable: "Unavailable on this macOS"
        case .unavailableInBuild: "Unavailable in this build"
        case .pasteboardDefault: "Default (not requested)"
        case .pasteboardAsk: "Ask each time"
        case .pasteboardAllow: "Always allow"
        case .pasteboardDeny: "Always deny"
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Requires approval"
        case .notFound: "Service not found"
        case .notConfigured: "Not configured"
        }
    }

    public var isGranted: Bool { self == .granted || self == .pasteboardAllow }
    public static func preflight(_ allowed: Bool) -> Self { allowed ? .granted : .notGranted }
}

public struct ResourceStatus: Codable, Sendable, Equatable {
    public let name: String
    public let value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

public struct Observation: Codable, Sendable {
    public var state: AccessState
    public var detail: String
    public var method: String
    public var checkedAt: Date
    public var resources: [ResourceStatus]
    public var stale: Bool

    public init(_ state: AccessState, _ detail: String, method: String,
                resources: [ResourceStatus] = [], checkedAt: Date = Date(), stale: Bool = false) {
        self.state = state; self.detail = detail; self.method = method
        self.resources = resources; self.checkedAt = checkedAt; self.stale = stale
    }

    /// A failed refresh preserves evidence and its original timestamp; it never manufactures a denial.
    public func failedRefresh(_ message: String) -> Self {
        var result = self
        result.stale = true
        result.detail = message + " Last successful check: " + detail
        return result
    }
}

public enum PermissionID: String, Codable, Sendable, CaseIterable {
    case accessibility, inputMonitoring, screenRecording, systemAudio, remoteDesktop
    case camera, microphone, speech
    case filesAndFolders, fullDiskAccess, automation, appManagement, developerTools
    case contacts, calendars, reminders, photos, music, homeKit, focus, motion
    case bluetooth, localNetwork, location, passkeys, notifications, pasteboard, health, tracking
    case login, backgroundHelpers, administrator, selectedFiles, keychain, extensions, hardware
}

public struct SettingsDestination: Codable, Sendable {
    public let anchor: String?
    public let path: String
    public init(_ anchor: String?, _ path: String) { self.anchor = anchor; self.path = path }
    public var urlString: String {
        if let anchor { return "x-apple.systempreferences:com.apple.preference.security?" + anchor }
        return "x-apple.systempreferences:com.apple.preference.security"
    }
}

public struct Permission: Identifiable, Sendable {
    public let id: PermissionID
    public let name: String
    public let icon: String
    public let group: String
    public let purpose: String
    public let explanation: String
    public let settings: SettingsDestination?
    public let requestable: Bool
    public let usedBy: String
    public let isOtherAccess: Bool

    public init(_ id: PermissionID, _ name: String, _ icon: String, _ group: String,
                _ purpose: String, explanation: String, anchor: String? = nil,
                settingsName: String? = nil, hasSettings: Bool = true,
                requestable: Bool = false, usedBy: String = "Not used by MenuSprite",
                isOtherAccess: Bool = false) {
        self.id = id; self.name = name; self.icon = icon; self.group = group
        self.purpose = purpose; self.explanation = explanation; self.requestable = requestable
        self.usedBy = usedBy; self.isOtherAccess = isOtherAccess
        self.settings = hasSettings ? SettingsDestination(anchor, "System Settings → Privacy & Security → " + (settingsName ?? name)) : nil
    }

    public func canRequest(_ state: AccessState) -> Bool {
        guard requestable else { return false }
        if [.accessibility, .inputMonitoring, .screenRecording].contains(id) { return state == .notGranted }
        return state == .notRequested
    }

    public func matches(_ query: String) -> Bool {
        let text = [name, group, purpose, usedBy, explanation].joined(separator: " ")
        return query.isEmpty || text.localizedStandardContains(query)
    }
}
